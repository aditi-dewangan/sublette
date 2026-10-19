import XCTest
@testable import Sublette

/// Swiping offline, twice, or fast never sends a swipe the server would count twice.
@MainActor
final class SwipeOutboxTests: XCTestCase {
    private func request(_ listing: String, _ action: SwipeAction = .like, id: String? = nil) -> SwipeRequest {
        SwipeRequest(listingId: listing, renterId: nil, action: action, swipeId: id ?? "swipe-\(listing)")
    }

    func testASwipeIsSentOnceAndForgotten() async {
        let api = StubDeckAPI()
        let outbox = SwipeOutbox(api: api, preferences: .ephemeral())
        outbox.prepare(for: "user-1")

        await outbox.send(request("a"))

        XCTAssertEqual(api.swipes.map(\.swipeId), ["swipe-a"])
        XCTAssertTrue(outbox.pending.isEmpty)
        XCTAssertFalse(outbox.isOffline)
    }

    func testOfflineSwipesWaitAndGoInOrderWithTheirOwnIDs() async {
        let api = StubDeckAPI()
        // Offline for the first two tries: a fails, then a fails again when b is queued.
        api.swipeResults = [.failure(APIError.unreachable), .failure(APIError.unreachable)]
        let outbox = SwipeOutbox(api: api, preferences: .ephemeral())
        outbox.prepare(for: "user-1")

        await outbox.send(request("a"))
        XCTAssertTrue(outbox.isOffline)
        await outbox.send(request("b"))
        XCTAssertEqual(outbox.pending.map(\.id), ["swipe-a", "swipe-b"])

        // Back online.
        await outbox.flush()

        XCTAssertEqual(
            api.swipes.map(\.swipeId), ["swipe-a", "swipe-a", "swipe-a", "swipe-b"],
            "a is resent with the same id, and b waits behind it"
        )
        XCTAssertTrue(outbox.pending.isEmpty)
        XCTAssertFalse(outbox.isOffline)
    }

    func testQueuedSwipesSurviveARelaunch() async {
        let preferences = Preferences.ephemeral()
        let offline = StubDeckAPI()
        offline.swipeResults = [.failure(APIError.unreachable)]
        let before = SwipeOutbox(api: offline, preferences: preferences)
        before.prepare(for: "user-1")
        await before.send(request("a", .pass))

        // "Relaunch": a new outbox reads what was kept on the phone.
        let online = StubDeckAPI()
        let after = SwipeOutbox(api: online, preferences: preferences)
        after.prepare(for: "user-1")
        await after.flush()

        XCTAssertEqual(online.swipes, [request("a", .pass)])
        XCTAssertTrue(preferences.pendingSwipes.isEmpty)
    }

    func testAnotherAccountsQueuedSwipesAreNeverSent() async {
        let preferences = Preferences.ephemeral()
        let offline = StubDeckAPI()
        offline.swipeResults = [.failure(APIError.unreachable)]
        let first = SwipeOutbox(api: offline, preferences: preferences)
        first.prepare(for: "user-1")
        await first.send(request("a"))

        let api = StubDeckAPI()
        let second = SwipeOutbox(api: api, preferences: preferences)
        second.prepare(for: "user-2")
        await second.flush()

        XCTAssertTrue(api.swipes.isEmpty)
        XCTAssertTrue(second.pending.isEmpty)
    }

    func testARefusedSwipeIsDroppedWithItsReason() async {
        let api = StubDeckAPI()
        api.swipeResults = [.failure(APIError.server(
            status: 409, code: "listing_not_eligible",
            message: "This listing doesn't fit your search any more.", fields: []
        ))]
        let outbox = SwipeOutbox(api: api, preferences: .ephemeral())
        outbox.prepare(for: "user-1")

        await outbox.send(request("a"))

        XCTAssertTrue(outbox.pending.isEmpty)
        XCTAssertEqual(outbox.message, "This listing doesn't fit your search any more.")
        XCTAssertEqual(outbox.refusedSwipeID, "swipe-a")
    }

    func testAServerHiccupKeepsTheSwipeForLater() async {
        let api = StubDeckAPI()
        api.swipeResults = [.failure(APIError.server(status: 503, code: "service_unavailable", message: "Try again", fields: []))]
        let outbox = SwipeOutbox(api: api, preferences: .ephemeral())
        outbox.prepare(for: "user-1")

        await outbox.send(request("a"))

        XCTAssertEqual(outbox.pending.map(\.id), ["swipe-a"])
    }

    func testAMatchIsAnnouncedOnceEvenIfTheSwipeIsSentAgain() async {
        let api = StubDeckAPI()
        let like = SwipeRequest(listingId: "listing-1", renterId: "user-2", action: .like, swipeId: "s1")
        api.swipeResults = [
            .success(Fixture.swipeResult(for: like, match: Fixture.match(), created: true)),
            .success(Fixture.swipeResult(for: like, match: Fixture.match(), created: false)),
        ]
        let outbox = SwipeOutbox(api: api, preferences: .ephemeral())
        outbox.prepare(for: "user-1")

        await outbox.send(like)
        XCTAssertEqual(outbox.latestMatch?.id, "match-1")
        outbox.latestMatch = nil

        await outbox.send(like)
        XCTAssertNil(outbox.latestMatch, "the server already had it, so no second match screen")
    }

    func testCancellingAQueuedSwipeMeansItIsNeverSent() async {
        let api = StubDeckAPI()
        api.swipeResults = [.failure(APIError.unreachable)]
        let outbox = SwipeOutbox(api: api, preferences: .ephemeral())
        outbox.prepare(for: "user-1")
        await outbox.send(request("a"))

        XCTAssertTrue(outbox.cancel(swipeID: "swipe-a"))
        await outbox.flush()

        XCTAssertEqual(api.swipes.count, 1, "only the first, failed try")
        XCTAssertFalse(outbox.cancel(swipeID: "swipe-a"))
    }
}

@MainActor
final class RenterDeckModelTests: XCTestCase {
    private var counter = 0

    private func makeDeck(_ api: StubDeckAPI, preferences: Preferences = .ephemeral()) -> RenterDeckModel {
        let outbox = SwipeOutbox(api: api, preferences: preferences)
        outbox.prepare(for: "user-1")
        return RenterDeckModel(api: api, outbox: outbox) { [unowned self] in
            self.counter += 1
            return "swipe-\(self.counter)"
        }
    }

    func testLoadsTheDeckBestFirst() async {
        let api = StubDeckAPI()
        api.deckPages = [.success(DeckPage(items: [Fixture.deckItem("a", score: 90), Fixture.deckItem("b")]))]
        let deck = makeDeck(api)

        await deck.load()

        XCTAssertEqual(deck.cards.map(\.id), ["a", "b"])
        XCTAssertEqual(deck.state, .loaded)
    }

    func testLikingSendsTheTopCardAndMovesOn() async {
        let api = StubDeckAPI()
        api.deckPages = [.success(DeckPage(items: (1...6).map { Fixture.deckItem("l\($0)") }))]
        let deck = makeDeck(api)
        await deck.load()

        await deck.like()

        XCTAssertEqual(api.swipes, [SwipeRequest(listingId: "l1", renterId: nil, action: .like, swipeId: "swipe-1")])
        XCTAssertEqual(deck.top?.id, "l2")
        XCTAssertTrue(deck.canUndo)
    }

    func testUndoAfterASentSwipeAsksTheServerAndPutsTheCardBack() async {
        let api = StubDeckAPI()
        api.deckPages = [.success(DeckPage(items: (1...6).map { Fixture.deckItem("l\($0)") }))]
        let deck = makeDeck(api)
        await deck.load()
        await deck.pass()

        await deck.undo()

        XCTAssertEqual(api.undone, ["swipe-1"])
        XCTAssertEqual(deck.top?.id, "l1")
        XCTAssertFalse(deck.canUndo)
    }

    func testUndoOfAnOfflineSwipeNeverReachesTheServer() async {
        let api = StubDeckAPI()
        api.deckPages = [.success(DeckPage(items: (1...6).map { Fixture.deckItem("l\($0)") }))]
        api.swipeResults = [.failure(APIError.unreachable)]
        let deck = makeDeck(api)
        await deck.load()
        await deck.like()

        await deck.undo()

        XCTAssertTrue(api.undone.isEmpty)
        XCTAssertTrue(deck.outbox.pending.isEmpty, "the queued like is gone")
        XCTAssertEqual(deck.top?.id, "l1")
    }

    func testUndoWhileOfflineKeepsTheSwipeAndSaysSo() async {
        let api = StubDeckAPI()
        api.deckPages = [.success(DeckPage(items: (1...6).map { Fixture.deckItem("l\($0)") }))]
        api.undoResult = .failure(APIError.unreachable)
        let deck = makeDeck(api)
        await deck.load()
        await deck.pass()

        await deck.undo()

        XCTAssertEqual(deck.top?.id, "l2")
        XCTAssertTrue(deck.canUndo)
        XCTAssertEqual(deck.message, "Undo needs a connection. Try again in a moment.")
    }

    func testAReloadNeverShowsACardSwipedOffline() async {
        let api = StubDeckAPI()
        let items = (1...6).map { Fixture.deckItem("l\($0)") }
        api.deckPages = [.success(DeckPage(items: items)), .success(DeckPage(items: items))]
        api.swipeResults = [.failure(APIError.unreachable), .failure(APIError.unreachable)]
        let deck = makeDeck(api)
        await deck.load()
        await deck.like()

        await deck.reload()

        XCTAssertFalse(deck.cards.map(\.id).contains("l1"))
    }

    func testSavingTakesTheCardOutOfTheDeck() async {
        let api = StubDeckAPI()
        api.deckPages = [.success(DeckPage(items: (1...6).map { Fixture.deckItem("l\($0)") }))]
        let deck = makeDeck(api)
        await deck.load()

        await deck.save()

        XCTAssertEqual(api.savedIDs, ["l1"])
        XCTAssertEqual(deck.top?.id, "l2")
        XCTAssertFalse(deck.canUndo, "saving isn't a swipe")
    }

    func testAnEmptyDeckLoadsTheDiagnostics() async {
        let api = StubDeckAPI()
        let blocker = DeckBlocker(field: "parking", kind: .mustHave, removed: 3, message: "3 listings don't have parking.")
        api.diagnosticsResult = .success(DeckDiagnostics(inArea: 3, eligible: 0, seen: 0, topMustHave: blocker, blockers: [blocker]))
        let deck = makeDeck(api)

        await deck.load()

        XCTAssertTrue(deck.isEmpty)
        XCTAssertEqual(deck.diagnostics?.topMustHave?.field, "parking")
    }

    func testANotSetUpSearchSaysWhatToFinish() async {
        let api = StubDeckAPI()
        api.deckPages = [.failure(APIError.server(
            status: 409, code: "renter_profile_incomplete",
            message: "Set up your search first: your dates, budget and area.", fields: []
        ))]
        let deck = makeDeck(api)

        await deck.load()

        XCTAssertEqual(deck.state, .notReady("Set up your search first: your dates, budget and area."))
    }

    func testOfflineLoadSaysSoAndKeepsTheSession() async {
        let api = StubDeckAPI()
        api.deckPages = [.failure(APIError.unreachable)]
        let deck = makeDeck(api)

        await deck.load()

        XCTAssertEqual(deck.state, .failed(APIError.unreachable.userMessage))
    }

    func testAnotherAccountStartsWithAnEmptyDeck() async {
        let api = StubDeckAPI()
        api.deckPages = [.success(DeckPage(items: [Fixture.deckItem("a")]))]
        let deck = makeDeck(api)
        deck.prepare(for: "user-1")
        await deck.load()

        deck.prepare(for: "user-2")

        XCTAssertTrue(deck.cards.isEmpty)
        XCTAssertEqual(deck.state, .idle)
    }
}

@MainActor
final class ListerDeckModelTests: XCTestCase {
    private func makeDeck(_ api: StubDeckAPI, listings: StubListingsAPI) -> ListerDeckModel {
        let outbox = SwipeOutbox(api: api, preferences: .ephemeral())
        outbox.prepare(for: "user-1")
        return ListerDeckModel(deckAPI: api, listingsAPI: listings, outbox: outbox) { "lister-swipe" }
    }

    func testPicksTheFirstLiveListingAndLoadsItsRenters() async {
        let api = StubDeckAPI()
        api.renterPages = ["live": [Fixture.interestedRenter("r1")]]
        let listings = StubListingsAPI()
        listings.pages = [.success(ListingPage(
            items: [Fixture.listing(id: "draft", status: .draft), Fixture.listing(id: "live")],
            nextCursor: nil
        ))]
        let deck = makeDeck(api, listings: listings)

        await deck.load()

        XCTAssertEqual(deck.listings.map(\.id), ["live"])
        XCTAssertEqual(deck.top?.id, "r1")
    }

    func testALikeNamesTheRenterAndAMatchIsAnnounced() async {
        let api = StubDeckAPI()
        api.renterPages = ["live": [Fixture.interestedRenter("r1")]]
        let like = SwipeRequest(listingId: "live", renterId: "r1", action: .like, swipeId: "lister-swipe")
        api.swipeResults = [.success(Fixture.swipeResult(for: like, match: Fixture.match(listingID: "live")))]
        let listings = StubListingsAPI()
        listings.pages = [.success(ListingPage(items: [Fixture.listing(id: "live")], nextCursor: nil))]
        let deck = makeDeck(api, listings: listings)
        await deck.load()

        await deck.like()

        XCTAssertEqual(api.swipes, [like])
        XCTAssertNil(deck.top)
        XCTAssertEqual(deck.outbox.latestMatch?.listing.id, "live")
    }
}

/// The swipe and match responses in docs/contract/samples.
final class SwipeContractTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testSwipeResults() throws {
        let liked = try decoder.decode(SwipeResult.self, from: Fixture.sample("swipe_result"))
        XCTAssertEqual(liked.swipe.side, .renter)
        XCTAssertEqual(liked.swipe.action, .like)
        XCTAssertNil(liked.match)
        XCTAssertTrue(liked.created)

        let matched = try decoder.decode(SwipeResult.self, from: Fixture.sample("swipe_result_match"))
        XCTAssertEqual(matched.swipe.side, .lister)
        XCTAssertEqual(matched.match?.role, .lister)
        XCTAssertEqual(matched.match?.other.firstName, "Aditi")
    }

    func testMatchesSavedUndoAndInterestedRenters() throws {
        let matches = try decoder.decode(MatchPage.self, from: Fixture.sample("matches"))
        XCTAssertEqual(matches.items.first?.role, .renter)
        // Since phase 6, a matched renter sees the exact address.
        XCTAssertEqual(matches.items.first?.listing.isMatched, true)
        XCTAssertNotNil(matches.items.first?.listing.address)

        let saved = try decoder.decode(SavedPage.self, from: Fixture.sample("saved"))
        XCTAssertEqual(saved.items.count, 1)

        let undone = try decoder.decode(Swipe.self, from: Fixture.sample("undo"))
        XCTAssertEqual(undone.action, .pass)

        let renters = try decoder.decode(InterestedRenterPage.self, from: Fixture.sample("interested_renters"))
        XCTAssertEqual(renters.items.first?.renter.year, .junior)
        XCTAssertFalse(renters.items.first?.fits.isEmpty ?? true)
    }

    func testTheSwipeRequestUsesTheServersFieldNames() throws {
        let request = SwipeRequest(listingId: "l1", renterId: nil, action: .like, swipeId: "s1")

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: APIClient.makeEncoder().encode(request)) as? [String: String]
        )

        XCTAssertEqual(body, ["listing_id": "l1", "action": "like", "swipe_id": "s1"])
    }

    func testTheEndpointsMatchTheContract() {
        XCTAssertEqual(Endpoint.saveListing("l1").path, "/v1/saved/l1")
        XCTAssertEqual(Endpoint.unsaveListing("l1").method, .delete)
        XCTAssertEqual(Endpoint.interestedRenters("l1").path, "/v1/listings/l1/deck/renters")
    }
}
