import SwiftUI
import XCTest
@testable import Sublette

/// The SwiftData cache behind offline use.
@MainActor
final class OfflineCacheTests: XCTestCase {
    func testSavedValuesComeBackAndCanBeReplaced() {
        let cache = OfflineCache(inMemory: true)

        cache.save(["a", "b"], key: "u1:deck")
        cache.save(["c"], key: "u1:deck")

        XCTAssertEqual(cache.load([String].self, key: "u1:deck"), ["c"])
        XCTAssertNil(cache.load([String].self, key: "u1:matches"))
    }

    func testAnOldShapeIsTreatedAsNothing() {
        let cache = OfflineCache(inMemory: true)
        cache.save("not a list", key: "u1:deck")

        XCTAssertNil(cache.load([DeckItem].self, key: "u1:deck"))
    }

    func testSigningOutForgetsOnlyThatAccount() {
        let cache = OfflineCache(inMemory: true)
        cache.save([1], key: CacheKey.deck("u1"))
        cache.save([2], key: CacheKey.chat("u1", match: "m"))
        cache.save([3], key: CacheKey.deck("u10"))

        cache.removeAll(accountID: "u1")

        XCTAssertNil(cache.load([Int].self, key: CacheKey.deck("u1")))
        XCTAssertNil(cache.load([Int].self, key: CacheKey.chat("u1", match: "m")))
        XCTAssertEqual(cache.load([Int].self, key: CacheKey.deck("u10")), [3], "u10 starts with u1 but is someone else")
    }

    func testDeckCardsAndMatchesSurviveTheRoundTrip() {
        let cache = OfflineCache(inMemory: true)
        let items = [Fixture.deckItem("l1"), Fixture.deckItem("l2", score: 40)]
        let matches = [Fixture.match(id: "m1")]

        cache.save(items, key: "k1")
        cache.save(matches, key: "k2")

        XCTAssertEqual(cache.load([DeckItem].self, key: "k1"), items)
        XCTAssertEqual(cache.load([Match].self, key: "k2"), matches)
    }
}

/// Opening the app with no connection.
@MainActor
final class OfflineScreensTests: XCTestCase {
    func testTheDeckOpensOfflineWithTheCardsKeptLastTime() async {
        let cache = OfflineCache(inMemory: true)
        let online = StubDeckAPI()
        online.deckPages = [.success(DeckPage(items: (1...3).map { Fixture.deckItem("l\($0)") }))]
        let first = RenterDeckModel(api: online, outbox: SwipeOutbox(api: online, preferences: .ephemeral()), cache: cache)
        first.prepare(for: "u1")
        await first.load()
        await first.pass()

        let offline = StubDeckAPI()
        offline.deckPages = [.failure(APIError.unreachable)]
        let later = RenterDeckModel(api: offline, outbox: SwipeOutbox(api: offline, preferences: .ephemeral()), cache: cache)
        later.prepare(for: "u1")
        await later.load()

        XCTAssertEqual(later.cards.map(\.id), ["l2", "l3"], "the card passed on before isn't back")
        XCTAssertTrue(later.showingSaved)
    }

    func testMatchesAndSavedOpenOffline() async {
        let cache = OfflineCache(inMemory: true)
        let online = StubDeckAPI()
        online.matchesResult = .success(MatchPage(items: [Fixture.match(id: "m1")]))
        online.savedResult = .success(SavedPage(items: [Fixture.listing(id: "s1")]))
        let first = MatchesModel(api: online, chatAPI: StubChatAPI(), preferences: .ephemeral(), cache: cache)
        first.prepare(for: "u1")
        await first.load()

        let offline = StubDeckAPI()
        offline.matchesResult = .failure(APIError.unreachable)
        let later = MatchesModel(api: offline, chatAPI: StubChatAPI(), preferences: .ephemeral(), cache: cache)
        later.prepare(for: "u1")
        await later.load()

        XCTAssertEqual(later.matches.map(\.id), ["m1"])
        XCTAssertEqual(later.saved.map(\.id), ["s1"])
    }

    func testAChatOpensOfflineWithItsHistory() async {
        let cache = OfflineCache(inMemory: true)
        let online = StubChatAPI()
        online.pages = [.success(MessagePage(items: [Fixture.message(id: "a"), Fixture.message(id: "b")], hasMore: false))]
        await ChatModel(match: Fixture.match(), api: online, preferences: .ephemeral(), userID: "u1", cache: cache).load()

        let offline = StubChatAPI()
        offline.pages = [.failure(APIError.unreachable)]
        let chat = ChatModel(match: Fixture.match(), api: offline, preferences: .ephemeral(), userID: "u1", cache: cache)
        await chat.load()

        XCTAssertEqual(chat.messages.map(\.id), ["a", "b"])
    }
}

/// Messages written offline.
@MainActor
final class MessageOutboxTests: XCTestCase {
    private func chat(_ api: StubChatAPI, _ outbox: MessageOutbox, ids: [String] = ["m1", "m2"]) -> ChatModel {
        var queue = ids
        return ChatModel(
            match: Fixture.match(), api: api, preferences: .ephemeral(), userID: "u1",
            outbox: outbox, makeID: { queue.removeFirst() }
        )
    }

    func testAMessageWrittenOfflineWaitsAndThenGoesOutOnce() async {
        let api = StubChatAPI()
        api.sendResults = [.failure(APIError.unreachable)]
        let outbox = MessageOutbox(api: api, cache: OfflineCache(inMemory: true))
        outbox.prepare(for: "u1")
        let model = chat(api, outbox)
        outbox.onSent = { model.delivered($0) }

        await model.send("Is it still free?")
        XCTAssertEqual(model.pending.map(\.waiting), [true])
        XCTAssertFalse(model.pending[0].failed)
        XCTAssertEqual(outbox.queued.map(\.id), ["m1"])

        await outbox.flush()

        XCTAssertEqual(api.sent.map(\.messageId), ["m1", "m1"], "the same id both times")
        XCTAssertEqual(model.messages.map(\.messageId), ["m1"])
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(outbox.queued.isEmpty)
    }

    func testWaitingMessagesSurviveARelaunchAndKeepTheirOrder() async {
        let cache = OfflineCache(inMemory: true)
        let first = MessageOutbox(api: StubChatAPI(), cache: cache)
        first.prepare(for: "u1")
        first.add(QueuedMessage(id: "a", matchID: "match-1", body: "one"))
        first.add(QueuedMessage(id: "b", matchID: "match-1", body: "two"))

        let api = StubChatAPI()
        let relaunched = MessageOutbox(api: api, cache: cache)
        relaunched.prepare(for: "u1")
        let model = ChatModel(match: Fixture.match(), api: api, preferences: .ephemeral(), userID: "u1", outbox: relaunched)
        XCTAssertEqual(model.pending.map(\.body), ["one", "two"])

        await relaunched.flush()

        XCTAssertEqual(api.sent.map(\.body), ["one", "two"])
    }

    func testStillOfflineStopsAtTheFirstMessage() async {
        let api = StubChatAPI()
        api.sendResults = [.failure(APIError.unreachable)]
        let outbox = MessageOutbox(api: api, cache: nil)
        outbox.prepare(for: "u1")
        outbox.add(QueuedMessage(id: "a", matchID: "m", body: "one"))
        outbox.add(QueuedMessage(id: "b", matchID: "m", body: "two"))

        await outbox.flush()

        XCTAssertEqual(api.sent.map(\.messageId), ["a"])
        XCTAssertEqual(outbox.queued.map(\.id), ["a", "b"])
    }

    func testAMessageTheServerRefusesIsMarkedNotSent() async {
        let api = StubChatAPI()
        api.sendResults = [.failure(Fixture.serverError(404, "chat_unavailable", "This chat isn't available any more."))]
        let outbox = MessageOutbox(api: api, cache: nil)
        outbox.prepare(for: "u1")
        outbox.add(QueuedMessage(id: "m1", matchID: "match-1", body: "hi"))
        let model = ChatModel(match: Fixture.match(), api: api, preferences: .ephemeral(), userID: "u1", outbox: outbox)
        outbox.onRefused = { model.refused($0.id, reason: $1) }

        await outbox.flush()

        XCTAssertTrue(outbox.queued.isEmpty)
        XCTAssertEqual(model.pending.map(\.failed), [true])
        XCTAssertEqual(model.problem, "This chat isn't available any more.")
    }

    func testDeletingAWaitingMessageTakesItOutOfTheOutbox() async {
        let api = StubChatAPI()
        api.sendResults = [.failure(APIError.unreachable)]
        let outbox = MessageOutbox(api: api, cache: nil)
        outbox.prepare(for: "u1")
        let model = chat(api, outbox)
        await model.send("hi")

        model.discard(model.pending[0])

        XCTAssertTrue(outbox.queued.isEmpty)
    }

    func testAnotherAccountsWaitingMessagesAreNotLoaded() {
        let cache = OfflineCache(inMemory: true)
        let outbox = MessageOutbox(api: StubChatAPI(), cache: cache)
        outbox.prepare(for: "u1")
        outbox.add(QueuedMessage(id: "a", matchID: "m", body: "one"))

        outbox.prepare(for: "u2")

        XCTAssertTrue(outbox.queued.isEmpty)
    }
}

/// App opens, feature use and crash reports.
@MainActor
final class AnalyticsTests: XCTestCase {
    private var time = Date(timeIntervalSince1970: 1_800_000_000)

    private func model(_ api: StubReleaseAPI, preferences: Preferences = .ephemeral(), signedIn: Bool = true) -> AnalyticsModel {
        let model = AnalyticsModel(api: api, preferences: preferences, now: { [unowned self] in self.time })
        model.isSignedIn = { signedIn }
        return model
    }

    func testNothingIsSentWhileSignedOut() async {
        let api = StubReleaseAPI()
        let analytics = model(api, signedIn: false)

        await analytics.appOpened()
        analytics.used(.map)
        await Task.yield()

        XCTAssertEqual(api.events, [])
    }

    func testAnOpenIsCounted() async {
        let api = StubReleaseAPI()

        await model(api).appOpened()

        XCTAssertEqual(api.events, [.appOpened])
    }

    func testTheSameFeatureTwiceInAMinuteCountsOnce() async throws {
        let api = StubReleaseAPI()
        let analytics = model(api)

        analytics.used(.map)
        analytics.used(.map)
        time += 61
        analytics.used(.map)
        analytics.used(.deck)
        // The sends happen in the background; wait for the three that should.
        for _ in 0..<200 where api.events.count < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(api.events.filter { $0.feature == .map }.count, 2)
        XCTAssertEqual(api.events.filter { $0.feature == .deck }.count, 1)
    }

    func testCrashReportsWaitUntilTheyReachTheServer() async {
        let preferences = Preferences.ephemeral()
        let api = StubReleaseAPI()
        api.crashResults = [.failure(APIError.unreachable)]
        let analytics = model(api, preferences: preferences)
        let report = CrashRequest(kind: "crash", appVersion: "3", osVersion: "iOS 18.1", payload: "{}")

        await analytics.received([report])
        XCTAssertEqual(preferences.pendingCrashReports, [report])

        await analytics.appOpened()
        XCTAssertEqual(preferences.pendingCrashReports, [])
        XCTAssertEqual(api.crashes.count, 2)
    }

    func testACrashReportTheServerRefusesIsDropped() async {
        let preferences = Preferences.ephemeral()
        let api = StubReleaseAPI()
        api.crashResults = [.failure(Fixture.serverError(422, "validation_error", "Too large"))]

        await model(api, preferences: preferences).received([
            CrashRequest(kind: "crash", appVersion: "3", osVersion: "iOS 18", payload: "{}"),
        ])

        XCTAssertEqual(preferences.pendingCrashReports, [])
    }

    func testCrashReportsAreCutToWhatTheServerTakes() {
        let big = Data(repeating: UInt8(ascii: "x"), count: 100_000)

        let report = CrashReporter.report(kind: "hang", appVersion: String(repeating: "9", count: 40), osVersion: "iOS", json: big)

        XCTAssertEqual(report.payload.count, 65_000)
        XCTAssertEqual(report.appVersion.count, 20)
    }

    func testEventsUseTheServersNames() throws {
        let body = try JSONSerialization.jsonObject(with: APIClient.makeEncoder().encode(EventRequest.used(.notifyMe))) as? [String: String]

        XCTAssertEqual(body, ["name": "feature_used", "feature": "notify_me"])
        // Matches FEATURES in backend/app/services/analytics.py.
        XCTAssertEqual(
            AppFeature.allCases.map(\.rawValue),
            ["deck", "map", "matches", "chat", "saved", "undo", "notify_me", "bigger_area",
             "share_listing", "referral", "settings", "report", "block"]
        )
    }
}

/// The share card, referral codes and the logo.
@MainActor
final class ReleaseScreensTests: XCTestCase {
    func testTheShareCardIsTheSizeGroupsShowBest() throws {
        let image = try XCTUnwrap(ShareCardView.render(Fixture.listing(), photo: nil))

        XCTAssertEqual(image.size, CGSize(width: 1080, height: 1350))
    }

    func testTheShareMessageNamesThePlaceNotThePerson() {
        var listing = Fixture.listing()
        listing.rentCents = 95_000

        let text = ShareListingSheet.message(for: listing)

        XCTAssertTrue(text.contains("$950"))
        XCTAssertFalse(text.contains(listing.lister.firstName ?? "@@"))
    }

    func testTheShareLinkIsTheListingsPublicPage() {
        XCTAssertEqual(Endpoint.listingShare("l1").path, "/l/l1")
        XCTAssertFalse(Endpoint.listingShare("l1").requiresAuth)
        XCTAssertEqual(Endpoint.useReferral.path, "/v1/me/referral")
    }

    func testTheInvitationCarriesTheCode() {
        XCTAssertTrue(ReferralCard.invitation(code: "K7P2QXM").contains("K7P2QXM"))
    }

    func testUsersFromTheServerHaveTheirReferralCode() throws {
        let user = try APIClient.makeDecoder().decode(User.self, from: Fixture.sample("user_complete"))

        XCTAssertEqual(user.referralCode, "SUB2027")
        XCTAssertEqual(user.referred, false)
    }

    func testThePinMarkHasItsWindowInsideIt() {
        let contours = PinMarkShape.contours(width: 100)
        let outline = contours[0], window = contours[1]

        XCTAssertEqual(outline.map(\.y).max() ?? 0, 125, accuracy: 0.001, "the tip, 1.25 times the width down")
        XCTAssertEqual(outline.map(\.y).min() ?? 1, 0, accuracy: 0.1)
        XCTAssertEqual(window.map(\.x).max() ?? 0, 70, accuracy: 0.1)
        XCTAssertEqual(window.map(\.x).min() ?? 0, 30, accuracy: 0.1)
    }
}
