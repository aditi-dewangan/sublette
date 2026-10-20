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
