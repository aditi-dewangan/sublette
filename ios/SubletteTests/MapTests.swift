import XCTest
@testable import Sublette

final class PinClustererTests: XCTestCase {
    private let wide = (lat: 0.2, lng: 0.2)

    func testPinsCloseTogetherBecomeOneNumberWhenZoomedOut() {
        let pins = (0..<5).map { Fixture.pin("p\($0)", latitude: 47.66 + Double($0) * 0.0001) }

        let groups = PinClusterer.groups(pins, latitudeSpan: wide.lat, longitudeSpan: wide.lng)

        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isCluster)
        XCTAssertEqual(groups[0].pins.count, 5)
    }

    func testPinsFarApartStayApart() {
        let pins = [Fixture.pin("a", latitude: 47.60), Fixture.pin("b", latitude: 47.75)]

        let groups = PinClusterer.groups(pins, latitudeSpan: wide.lat, longitudeSpan: wide.lng)

        XCTAssertEqual(groups.map(\.id), ["a", "b"])
    }

    func testZoomedInEveryPinStandsAlone() {
        let pins = (0..<5).map { Fixture.pin("p\($0)", latitude: 47.66 + Double($0) * 0.0001) }

        let groups = PinClusterer.groups(pins, latitudeSpan: 0.003, longitudeSpan: 0.003)

        XCTAssertEqual(groups.count, 5)
        XCTAssertFalse(groups.contains(where: \.isCluster))
    }

    func testAMatchIsNeverHiddenInANumber() {
        let pins = [Fixture.pin("a"), Fixture.pin("b"), Fixture.pin("m", state: .matched)]

        let groups = PinClusterer.groups(pins, latitudeSpan: wide.lat, longitudeSpan: wide.lng)

        XCTAssertTrue(groups.contains { $0.id == "m" && !$0.isCluster })
        XCTAssertEqual(groups.first { $0.isCluster }?.pins.map(\.id), ["a", "b"])
    }

    func testEveryPinIsInExactlyOneGroup() {
        var generator = SystemRandomNumberGenerator()
        let pins = (0..<500).map { index in
            Fixture.pin(
                "p\(index)",
                latitude: 47.6 + Double.random(in: 0...0.15, using: &generator),
                longitude: -122.4 + Double.random(in: 0...0.15, using: &generator)
            )
        }

        let groups = PinClusterer.groups(pins, latitudeSpan: 0.15, longitudeSpan: 0.15)

        XCTAssertEqual(groups.flatMap(\.pins).map(\.id).sorted(), pins.map(\.id).sorted())
        XCTAssertLessThanOrEqual(groups.count, 120, "500 pins zoomed out become a few dozen marks")
    }

    func testFiveHundredPinsGroupQuickly() {
        let pins = (0..<500).map { Fixture.pin("p\($0)", latitude: 47.6 + Double($0) * 0.0003) }

        measure {
            _ = PinClusterer.groups(pins, latitudeSpan: 0.15, longitudeSpan: 0.15)
        }
    }
}

final class MapRegionTests: XCTestCase {
    func testTheBoxIsWestSouthEastNorth() {
        let region = MapRegion(latitude: 47.66, longitude: -122.31, latitudeSpan: 0.1, longitudeSpan: 0.2)

        XCTAssertEqual(region.bboxParameter, "-122.41000,47.61000,-122.21000,47.71000")
    }

    func testTheBoxStaysInsideTheWorld() {
        let region = MapRegion(latitude: 80, longitude: 170, latitudeSpan: 40, longitudeSpan: 40)

        XCTAssertEqual(region.bboxParameter, "150.00000,60.00000,180.00000,90.00000")
    }

    func testTheEndpointsMatchTheContract() {
        XCTAssertEqual(Endpoint.mapListing("l1").path, "/v1/map/listings/l1")
        XCTAssertEqual(Endpoint.mapListings(bbox: "1,2,3,4").query, [URLQueryItem(name: "bbox", value: "1,2,3,4")])
    }
}

@MainActor
final class RenterMapModelTests: XCTestCase {
    private let region = MapRegion(latitude: 47.66, longitude: -122.31, latitudeSpan: 0.1, longitudeSpan: 0.1)

    private func makeMap(_ api: StubMapAPI, deck: StubDeckAPI = StubDeckAPI()) -> RenterMapModel {
        let outbox = SwipeOutbox(api: deck, preferences: .ephemeral())
        outbox.prepare(for: "user-1")
        return RenterMapModel(api: api, outbox: outbox) { "map-swipe" }
    }

    func testLoadsThePinsForWhatIsVisible() async {
        let api = StubMapAPI()
        api.pages = [.success(MapPage(items: [Fixture.pin("a"), Fixture.pin("b", latitude: 47.70)], truncated: false))]
        let map = makeMap(api)

        await map.show(region)

        XCTAssertEqual(api.regions, [region])
        XCTAssertEqual(map.pins.map(\.id), ["a", "b"])
        XCTAssertEqual(map.state, .loaded)
        XCTAssertFalse(map.groups.isEmpty)
    }

    func testLikingFromACardTurnsThePinIntoAHeartAndTellsTheDeck() async {
        let api = StubMapAPI()
        api.pages = [.success(MapPage(items: [Fixture.pin("a")], truncated: false))]
        let deck = StubDeckAPI()
        let map = makeMap(api, deck: deck)
        var forgotten: [String] = []
        map.onSwiped = { forgotten.append($0) }
        await map.show(region)
        await map.open("a")

        await map.like()

        XCTAssertNil(map.card)
        XCTAssertEqual(map.pins.first?.state, .liked)
        XCTAssertEqual(deck.swipes, [SwipeRequest(listingId: "a", renterId: nil, action: .like, swipeId: "map-swipe")])
        XCTAssertEqual(forgotten, ["a"])
    }

    func testPassingRemovesThePin() async {
        let api = StubMapAPI()
        api.pages = [.success(MapPage(items: [Fixture.pin("a"), Fixture.pin("b")], truncated: false))]
        let map = makeMap(api)
        await map.show(region)
        await map.open("a")

        await map.pass()

        XCTAssertEqual(map.pins.map(\.id), ["b"])
    }

    func testASwipeMadeOfflineStillShowsAfterAReload() async {
        let api = StubMapAPI()
        let page = MapPage(items: [Fixture.pin("a"), Fixture.pin("b")], truncated: false)
        api.pages = [.success(page), .success(page)]
        let deck = StubDeckAPI()
        deck.swipeResults = [.failure(APIError.unreachable), .failure(APIError.unreachable)]
        let map = makeMap(api, deck: deck)
        await map.show(region)
        await map.open("a")
        await map.like()

        await map.load()

        XCTAssertEqual(map.pins.first { $0.id == "a" }?.state, .liked, "the queued like wins over the server's 'new'")
    }

    func testOfflineKeepsThePinsAlreadyShown() async {
        let api = StubMapAPI()
        api.pages = [.success(MapPage(items: [Fixture.pin("a")], truncated: false)), .failure(APIError.unreachable)]
        let map = makeMap(api)
        await map.show(region)

        await map.show(region)

        XCTAssertEqual(map.pins.map(\.id), ["a"])
        XCTAssertEqual(map.state, .failed(APIError.unreachable.userMessage))
    }

    func testACardThatCannotOpenSaysWhy() async {
        let api = StubMapAPI()
        api.cardResult = .failure(APIError.server(status: 404, code: "listing_not_found", message: "That listing isn't available.", fields: []))
        let map = makeMap(api)

        await map.open("gone")

        XCTAssertNil(map.card)
        XCTAssertEqual(map.cardMessage, "That listing isn't available.")
    }
}

/// The map responses in docs/contract/samples.
final class MapContractTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testPinsDecode() throws {
        let page = try decoder.decode(MapPage.self, from: Fixture.sample("map_listings"))

        XCTAssertEqual(page.items.map(\.state), [.matched, .new])
        XCTAssertEqual(page.items.first?.exact, true)
        XCTAssertEqual(page.items.last?.exact, false)
        XCTAssertEqual(page.items.first?.band, .strong)
        XCTAssertFalse(page.truncated)
    }

    func testCardsDecode() throws {
        let card = try decoder.decode(MapCard.self, from: Fixture.sample("map_card"))
        XCTAssertEqual(card.state, .new)
        XCTAssertNil(card.item.listing.address)
        XCTAssertFalse(card.item.listing.isMatched)

        let matched = try decoder.decode(MapCard.self, from: Fixture.sample("map_card_matched"))
        XCTAssertEqual(matched.state, .matched)
        XCTAssertTrue(matched.item.listing.isMatched)
        XCTAssertNotNil(matched.item.listing.address, "a match sees the exact address")
    }
}
