import XCTest
@testable import Sublette

/// Fixes from the final review.
@MainActor
final class ReviewFixesTests: XCTestCase {
    func testSigningOutForgetsMatchesAndTheirBadge() async {
        let deck = StubDeckAPI()
        var unread = Fixture.match(id: "a")
        unread.unreadCount = 4
        deck.matchesResult = .success(MatchPage(items: [unread]))
        let model = MatchesModel(api: deck, chatAPI: StubChatAPI(), preferences: .ephemeral())
        model.prepare(for: "user-1")
        await model.load()
        _ = model.openChat(unread)

        model.reset()

        XCTAssertEqual(model.matches, [])
        XCTAssertEqual(model.unreadCount(as: .lister), 0)
        XCTAssertNil(model.activeChat)
    }

    func testAnotherAccountsWaitingMessagesAreNeverSent() async {
        let api = StubChatAPI()
        let outbox = MessageOutbox(api: api, cache: OfflineCache(inMemory: true))
        outbox.prepare(for: "user-1")
        outbox.add(QueuedMessage(id: "a", matchID: "m", body: "from user 1"))

        outbox.reset()
        await outbox.flush()

        XCTAssertEqual(api.sent, [], "nobody is signed in to send it as")
        XCTAssertTrue(outbox.queued.isEmpty)
    }

    func testAListerHomeLoadThatIsCancelledIsNotAnError() async {
        let api = StubListingsAPI()
        api.pages = [.failure(APIError.cancelled)]
        let model = ListerHomeModel(api: api)

        await model.load()

        XCTAssertEqual(model.state, .idle)
    }

    func testSigningOutForgetsTheListersListings() async {
        let api = StubListingsAPI()
        api.pages = [.success(ListingPage(items: [Fixture.listing()], nextCursor: nil))]
        let model = ListerHomeModel(api: api)
        await model.load()

        model.reset()

        XCTAssertEqual(model.listings, [])
    }

    func testAStoppedLiveConnectionCanStartAgain() {
        let client = APIClient(baseURL: URL(string: "https://api.example.test")!)
        let events = LiveEvents(client: client, tokens: NoAccessToken())

        events.start()
        events.stop()
        events.start()
        events.stop()

        XCTAssertFalse(events.isConnected)
    }
}

/// Alerts (issue #22) on the phone.
@MainActor
final class AlertsTests: XCTestCase {
    func testAlertTapsOpenTheRightPlace() {
        XCTAssertEqual(NotificationTarget(userInfo: ["kind": "price_drop", "listing_id": "l1", "role": "renter"]), .listing(id: "l1"))
        XCTAssertEqual(NotificationTarget(userInfo: ["kind": "expiring", "listing_id": "l2", "role": "renter"]), .listing(id: "l2"))
        XCTAssertEqual(NotificationTarget(userInfo: ["kind": "digest", "role": "renter"]), .deck)
        XCTAssertEqual(NotificationTarget(userInfo: ["kind": "likes", "role": "lister"]), .renters)
        XCTAssertNil(NotificationTarget(userInfo: ["kind": "price_drop"]), "no listing, nothing to open")
    }

    func testOpeningAListingFromAnAlertGoesToTheRentersMap() {
        let state = AppState(preferences: .ephemeral(), mode: .lister)

        state.openListing("l1")

        XCTAssertEqual(state.mode, .renter)
        XCTAssertEqual(state.tab, .map)
        XCTAssertEqual(state.listingToOpen, "l1")
        state.listingOpened()
        XCTAssertNil(state.listingToOpen)
    }

    func testTheWeeklySummaryOpensTheRentersTab() {
        let state = AppState(preferences: .ephemeral(), mode: .renter)

        state.openRenters()

        XCTAssertEqual(state.mode, .lister)
        XCTAssertEqual(state.tab, .renters)
    }

    func testTheFrequencyIsSentInTheServersWords() throws {
        let body = try JSONSerialization.jsonObject(
            with: APIClient.makeEncoder().encode(AlertFrequencyUpdate(alertFrequency: .instant))
        ) as? [String: String]

        XCTAssertEqual(body, ["alert_frequency": "instant"])
        XCTAssertEqual(AlertFrequency.allCases.map(\.rawValue), ["instant", "daily", "off"])
    }

    func testTheServersUserCarriesTheFrequency() throws {
        let user = try APIClient.makeDecoder().decode(User.self, from: Fixture.sample("user_complete"))

        XCTAssertEqual(user.alertFrequency, .daily)
    }
}

/// Housemate lifestyle (issue #20) on the phone.
@MainActor
final class HomeLifeTests: XCTestCase {
    func testSkippedAnswersAreSentAsNullAndAnsweredOnesInTheServersWords() throws {
        var update = ProfileUpdate(firstName: "A", year: .junior, program: "P", bio: nil, gender: nil, smokes: false, hasPets: false)
        update.homeLife = HomeLife(sleepSchedule: .early, tidiness: .veryTidy)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: APIClient.makeEncoder().encode(update)) as? [String: Any]
        )

        XCTAssertEqual(body["sleep_schedule"] as? String, "early")
        XCTAssertEqual(body["tidiness"] as? String, "very_tidy")
        XCTAssertTrue(body["guests"] is NSNull)
    }

    func testAListingWithNobodyStayingSendsNoHousematesLifestyle() {
        let model = ListingEditorModel(
            listing: nil, schoolName: "UW", api: StubListingsAPI(), uploader: StubUploader(), locator: StubLocator()
        )
        model.homeLife = HomeLife(guests: .rarely)
        model.housematesStaying = 0

        XCTAssertEqual(model.form.homeLife, HomeLife())
    }

    func testTheServersAnswersDecode() throws {
        let user = try APIClient.makeDecoder().decode(User.self, from: Fixture.sample("user_complete"))
        let listing = try APIClient.makeDecoder().decode(Listing.self, from: Fixture.sample("listing_owner"))

        XCTAssertEqual(HomeLife(user: user).answered, 0)
        XCTAssertEqual(HomeLife(listing: listing).answered, 0)
        // Every answer the server allows is known to the app.
        XCTAssertEqual(Tidiness.allCases.map(\.rawValue), ["very_tidy", "tidy", "relaxed"])
        XCTAssertEqual(SleepSchedule.allCases.map(\.rawValue), ["early", "late", "varies"])
        XCTAssertEqual(HowOften.allCases.map(\.rawValue), ["rarely", "sometimes", "often"])
        XCTAssertEqual(HomeVibe.allCases.map(\.rawValue), ["quiet", "social", "either"])
    }
}
