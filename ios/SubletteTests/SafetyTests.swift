import XCTest
@testable import Sublette

/// Reporting, blocking, suspension and the terms (phase 8).
@MainActor
final class SafetyModelTests: XCTestCase {
    func testAReportIsSentWithItsReasonAndTrimmedDetails() async {
        let api = StubSafetyAPI()
        let model = SafetyModel(api: api)

        let sent = await model.report(.message(id: "m1", senderName: "Lee"), reason: .scam, details: "  wants a wire  ")

        XCTAssertTrue(sent)
        XCTAssertEqual(api.reports, [ReportRequest(target: "message", id: "m1", reason: .scam, details: "wants a wire")])
    }

    func testEmptyDetailsAreLeftOut() async {
        let api = StubSafetyAPI()
        _ = await SafetyModel(api: api).report(.listing(id: "l1"), reason: .fake, details: "   ")

        XCTAssertNil(api.reports.first?.details)
    }

    func testAReportThatFailsSaysWhy() async {
        let api = StubSafetyAPI()
        api.reportResult = .failure(APIError.unreachable)
        let model = SafetyModel(api: api)

        let sent = await model.report(.person(id: "u1", name: "Sam"), reason: .harassment, details: "")

        XCTAssertFalse(sent)
        XCTAssertEqual(model.problem, APIError.unreachable.userMessage)
    }

    func testABlockRefreshesEveryListOfPeople() async {
        let api = StubSafetyAPI()
        let model = SafetyModel(api: api)
        let refreshed = Flag()
        model.onBlocksChanged = { refreshed.set() }

        let blocked = await model.block(.listerOf(listingID: "l1", name: "Lee"))

        XCTAssertTrue(blocked)
        XCTAssertEqual(api.blocks, [.listerOf(listingID: "l1", name: "Lee")])
        XCTAssertTrue(refreshed.isSet)
    }

    func testABlockThatFailsChangesNothing() async {
        let api = StubSafetyAPI()
        api.blockResult = .failure(Fixture.serverError(422, "cant_block_yourself", "You can't block yourself."))
        let model = SafetyModel(api: api)
        let refreshed = Flag()
        model.onBlocksChanged = { refreshed.set() }

        let blocked = await model.block(.person(id: "me", name: nil))

        XCTAssertFalse(blocked)
        XCTAssertEqual(model.problem, "You can't block yourself.")
        XCTAssertFalse(refreshed.isSet)
    }

    func testUnblockingRemovesThePersonFromTheList() async {
        let api = StubSafetyAPI()
        let person = BlockedPerson(userId: "u9", firstName: "Jordan", photoUrl: nil, blockedAt: Fixture.now)
        api.blockedResult = .success(BlockPage(items: [person]))
        let model = SafetyModel(api: api)
        await model.loadBlocked()

        await model.unblock(person)

        XCTAssertEqual(api.unblocked, ["u9"])
        XCTAssertEqual(model.blocked, [])
    }

    func testSigningOutForgetsTheBlockedList() async {
        let api = StubSafetyAPI()
        api.blockedResult = .success(BlockPage(items: [
            BlockedPerson(userId: "u9", firstName: nil, photoUrl: nil, blockedAt: Fixture.now),
        ]))
        let model = SafetyModel(api: api)
        await model.loadBlocked()

        model.reset()

        XCTAssertEqual(model.blocked, [])
    }

    func testMenuTitlesNameThePerson() {
        XCTAssertEqual(ReportSubject.person(id: "u", name: "Sam").title, "Report Sam")
        XCTAssertEqual(ReportSubject.listing(id: "l").title, "Report this listing")
        XCTAssertEqual(BlockSubject.listerOf(listingID: "l", name: nil).title, "Block this lister")
        XCTAssertEqual(BlockSubject.person(id: "u", name: "Lee").title, "Block Lee")
    }
}

/// What the app sends, and the server's samples it reads.
@MainActor
final class SafetyContractTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testABlockSendsExactlyOneOfItsTwoFields() throws {
        let encoder = APIClient.makeEncoder()
        let byListing = try JSONSerialization.jsonObject(
            with: encoder.encode(BlockRequest(.listerOf(listingID: "l1", name: "Lee")))
        ) as? [String: String]
        let byPerson = try JSONSerialization.jsonObject(
            with: encoder.encode(BlockRequest(.person(id: "u1", name: nil)))
        ) as? [String: String]

        XCTAssertEqual(byListing, ["listing_id": "l1"])
        XCTAssertEqual(byPerson, ["user_id": "u1"])
    }

    func testAReportUsesTheServersFieldNames() throws {
        let body = try JSONSerialization.jsonObject(
            with: APIClient.makeEncoder().encode(
                ReportRequest(target: "listing", id: "l1", reason: .discrimination, details: "x")
            )
        ) as? [String: String]

        XCTAssertEqual(body, ["target": "listing", "id": "l1", "reason": "discrimination", "details": "x"])
    }

    func testEveryReasonTheServerAllowsIsKnownToTheApp() {
        // Matches backend/app/schemas/safety.py.
        XCTAssertEqual(
            ReportReason.allCases.map(\.rawValue),
            ["scam", "harassment", "inappropriate", "fake", "discrimination", "unsafe", "other"]
        )
    }

    func testSamplesDecode() throws {
        let receipt = try decoder.decode(ReportReceipt.self, from: Fixture.sample("report"))
        XCTAssertEqual(receipt.reason, .scam)
        XCTAssertEqual(receipt.status, "open")

        let blocks = try decoder.decode(BlockPage.self, from: Fixture.sample("blocks"))
        XCTAssertEqual(blocks.items.count, 1)

        let user = try decoder.decode(User.self, from: Fixture.sample("user_terms_accepted"))
        XCTAssertEqual(user.termsAccepted, true)
        XCTAssertFalse(user.needsToAcceptTerms)
        XCTAssertNotNil(user.termsVersion)

        let newUser = try decoder.decode(SessionResponse.self, from: Fixture.sample("session_new_user")).user
        XCTAssertTrue(newUser.needsToAcceptTerms)

        let event = try decoder.decode(LiveEvent.self, from: Fixture.sample("ws_match_removed_event"))
        guard case .matchRemoved(let id) = event else {
            return XCTFail("expected match_removed, got \(event)")
        }
        XCTAssertFalse(id.isEmpty)

        let suspended = try decoder.decode(APIErrorBody.self, from: Fixture.sample("error_account_suspended"))
        XCTAssertEqual(suspended.code, "account_suspended")
        XCTAssertTrue(suspended.message.contains("appeal"))
    }

    func testAProfileSavedByAnOlderVersionIsNotAskedToAcceptAgain() throws {
        // No terms fields at all: treated as accepted until the server says otherwise.
        let old = try decoder.decode(User.self, from: Fixture.sample("user_complete"))
        var stripped = old
        stripped.termsAccepted = nil
        XCTAssertFalse(stripped.needsToAcceptTerms)
    }

    func testPhaseEightPaths() {
        XCTAssertEqual(Endpoint.report.path, "/v1/reports")
        XCTAssertEqual(Endpoint.block.method, .post)
        XCTAssertEqual(Endpoint.unblock(userID: "u1").path, "/v1/blocks/u1")
        XCTAssertEqual(Endpoint.unblock(userID: "u1").method, .delete)
        XCTAssertEqual(Endpoint.acceptTerms.path, "/v1/me/terms")
        XCTAssertFalse(Endpoint.termsPage.requiresAuth)
    }

    func testAListingCanBeRemovedOrExpire() throws {
        var listing = Fixture.listing(status: .removed)
        listing.removedReason = "Photos of another place"
        listing.expiresOn = "2027-02-03"
        let data = try APIClient.makeEncoder().encode(listing)
        let decoded = try decoder.decode(Listing.self, from: data)

        XCTAssertEqual(decoded.status, .removed)
        XCTAssertEqual(decoded.removedReason, "Photos of another place")
        XCTAssertEqual(ListingDetailView.liveUntil(decoded)?.hasPrefix("Live until Feb 3"), true)
    }

    func testTheContactLinkIsAnEmailToSupport() {
        XCTAssertEqual(AppConfiguration.contactURL()?.absoluteString, "mailto:subletteofficial@gmail.com")
        XCTAssertEqual(
            AppConfiguration.contactURL(subject: "Appeal")?.absoluteString,
            "mailto:subletteofficial@gmail.com?subject=Appeal"
        )
    }

    func testAnExpiredListingNotificationOpensMyListings() {
        XCTAssertEqual(
            NotificationTarget(userInfo: ["kind": "listing_expired", "listing_id": "l1", "role": "lister"]),
            .listings
        )
    }
}

/// A block or suspension closes what the student was looking at.
@MainActor
final class BlockedChatTests: XCTestCase {
    func testAMatchRemovedLeavesTheListAndClosesItsChat() async {
        let deck = StubDeckAPI()
        deck.matchesResult = .success(MatchPage(items: [Fixture.match(id: "a"), Fixture.match(id: "b")]))
        let model = MatchesModel(api: deck, chatAPI: StubChatAPI(), preferences: .ephemeral())
        model.prepare(for: "user-1")
        await model.load()
        let chat = model.openChat(Fixture.match(id: "a"))

        model.handle(.matchRemoved(id: "a"))

        XCTAssertEqual(model.matches.map(\.id), ["b"])
        XCTAssertTrue(chat.isGone)
    }

    func testAChatTheServerSaysIsGoneCloses() async {
        let api = StubChatAPI()
        api.pages = [.failure(Fixture.serverError(404, "chat_unavailable", "This chat isn't available any more."))]
        let chat = ChatModel(match: Fixture.match(), api: api, preferences: .ephemeral(), userID: "user-1")

        await chat.load()

        XCTAssertTrue(chat.isGone)
    }

    func testAnotherChatsRemovalLeavesThisOneOpen() {
        let chat = ChatModel(match: Fixture.match(id: "a"), api: StubChatAPI(), preferences: .ephemeral(), userID: "u")

        chat.receive(.matchRemoved(id: "b"))

        XCTAssertFalse(chat.isGone)
    }
}

/// A suspended account sees one screen, from wherever the server says so.
@MainActor
final class SuspensionTests: XCTestCase {
    func testSigningInToASuspendedAccountShowsWhy() async {
        let test = TestSession()
        test.api.verifyResult = .failure(
            Fixture.serverError(403, "account_suspended", "Suspended for spam. To appeal, email us.")
        )
        let model = OnboardingModel(api: test.api, session: test.session, now: { Fixture.now })
        model.email = "sam@uw.edu"
        await model.submitEmail()
        model.code = "123456"

        await model.submitCode()

        XCTAssertEqual(test.session.state, .suspended("Suspended for spam. To appeal, email us."))
        XCTAssertNil(model.errorMessage)
    }

    func testASuspensionReportedTwiceShowsOneScreen() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        let calls = Flag()
        test.session.willSignOut = { calls.set() }

        await test.session.showSuspended("First")
        await test.session.showSuspended("Second")

        XCTAssertEqual(test.session.state, .suspended("First"))
        XCTAssertTrue(calls.isSet)
    }

    func testAProfileSaveAfterSuspensionDoesNotSignBackIn() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        await test.session.showSuspended("Suspended")

        test.session.update(Fixture.completeUser)

        XCTAssertEqual(test.session.state, .suspended("Suspended"))
    }

    func testARefreshRefusedForSuspensionPassesOnTheReason() async {
        let refresher = StubRefresher()
        refresher.result = .failure(Fixture.serverError(403, "account_suspended", "Suspended for spam."))
        let store = InMemoryTokenStore(Fixture.tokens(expiresIn: 10))
        let manager = TokenManager(store: store, refresher: refresher, now: { Fixture.now })
        let reason = Reason()
        await manager.setSuspendedHandler { message in reason.set(message) }

        _ = await manager.accessToken()

        XCTAssertEqual(reason.value, "Suspended for spam.")
        XCTAssertNil(store.load())
    }

    func testAnyRequestAnsweredSuspendedTellsTheTokenManager() async throws {
        let store = InMemoryTokenStore(Fixture.tokens(expiresIn: 600))
        let manager = TokenManager(store: store, refresher: StubRefresher(), now: { Fixture.now })
        let reason = Reason()
        await manager.setSuspendedHandler { message in reason.set(message) }
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code": "account_suspended", "message": "Suspended for spam."}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let client = APIClient(
            baseURL: URL(string: "https://api.example.test")!,
            session: StubURLProtocol.makeSession(),
            tokens: manager
        )

        do {
            let _: User = try await client.send(.me)
            XCTFail("expected a 403")
        } catch {}

        XCTAssertEqual(reason.value, "Suspended for spam.")
        XCTAssertNil(store.load())
    }
}

/// Accepting the terms.
@MainActor
final class TermsTests: XCTestCase {
    func testANewAccountIsAskedToAcceptBeforeAnythingElse() {
        var user = Fixture.newUser
        user.termsVersion = "2026-10-20"
        user.termsAccepted = false

        XCTAssertTrue(user.needsToAcceptTerms)
        user.termsAccepted = true
        XCTAssertFalse(user.needsToAcceptTerms)
    }
}

private final class Reason: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? { lock.withLock { stored } }

    func set(_ text: String) {
        lock.withLock { stored = text }
    }
}
