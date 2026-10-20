import XCTest
@testable import Sublette

/// Commute times to the renter's places (issue #21).
final class StubCommute: CommuteEstimating, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(CommuteMode, Coordinate)] = []
    var answers: [CommuteMode: Int] = [.transit: 18, .walking: 25, .driving: 9]

    var asked: [(CommuteMode, Coordinate)] { lock.withLock { stored } }

    func minutes(from: Coordinate, to: Coordinate, by mode: CommuteMode) async throws -> Int {
        lock.withLock { stored.append((mode, from)) }
        guard let minutes = answers[mode] else {
            throw CommuteError.noRoute
        }
        return minutes
    }
}

@MainActor
final class CommuteTests: XCTestCase {
    private let campus = SavedPlace(id: "p1", name: "Campus", address: "UW", latitude: 47.65, longitude: -122.30)
    private let work = SavedPlace(id: "p2", name: "Work", address: "Office", latitude: 47.61, longitude: -122.33)

    private func makeModel(_ estimator: StubCommute, preferences: Preferences = .ephemeral(), cache: OfflineStoring? = nil) -> CommuteModel {
        let model = CommuteModel(estimator: estimator, preferences: preferences, cache: cache)
        model.prepare(for: "user-1")
        return model
    }

    func testCardsShowTransitAndWalkingToEachPlace() async {
        let estimator = StubCommute()
        let model = makeModel(estimator)
        model.add(campus)
        model.add(work)

        await model.load(for: Fixture.listing())

        XCTAssertEqual(model.lines(for: Fixture.listing()), [
            "Campus: 18 min by transit · 25 min walk",
            "Work: 18 min by transit · 25 min walk",
        ])
    }

    func testNoTransitAndALongWalkShowTheDrive() async {
        let estimator = StubCommute()
        estimator.answers = [.walking: 70, .driving: 12]
        let model = makeModel(estimator)
        model.add(campus)

        await model.load(for: Fixture.listing())

        XCTAssertEqual(model.lines(for: Fixture.listing()), ["Campus: 12 min drive"])
    }

    func testNoRouteAtAllShowsNothing() async {
        let estimator = StubCommute()
        estimator.answers = [:]
        let model = makeModel(estimator)
        model.add(campus)

        await model.load(for: Fixture.listing())

        XCTAssertEqual(model.lines(for: Fixture.listing()), [])
    }

    func testEachTripIsAskedOnceAndRememberedOffline() async {
        let estimator = StubCommute()
        let cache = OfflineCache(inMemory: true)
        let preferences = Preferences.ephemeral()
        let model = makeModel(estimator, preferences: preferences, cache: cache)
        model.add(campus)
        await model.load(for: Fixture.listing())
        await model.load(for: Fixture.listing())
        XCTAssertEqual(estimator.asked.count, 2, "transit and walking, once")

        let later = makeModel(StubCommute(), preferences: preferences, cache: cache)

        XCTAssertEqual(later.places, [campus], "places are kept on the phone")
        XCTAssertEqual(later.lines(for: Fixture.listing()), ["Campus: 18 min by transit · 25 min walk"])
    }

    func testThePublicPointIsUsedUnlessTheExactOneIsKnown() async {
        let estimator = StubCommute()
        let model = makeModel(estimator)
        model.add(campus)
        var listing = Fixture.listing()
        listing.latitude = nil
        listing.longitude = nil
        listing.publicLatitude = 47.5
        listing.publicLongitude = -122.1

        await model.load(for: listing)

        XCTAssertEqual(estimator.asked.first?.1, Coordinate(latitude: 47.5, longitude: -122.1))
    }

    func testAtMostTwoPlacesAndRemovingOneForgetsItsTimes() async {
        let model = makeModel(StubCommute())
        model.add(campus)
        model.add(work)
        model.add(SavedPlace(id: "p3", name: "Gym", address: "x", latitude: 0, longitude: 0))
        XCTAssertEqual(model.places.map(\.id), ["p1", "p2"])
        await model.load(for: Fixture.listing())

        model.remove(campus)

        XCTAssertEqual(model.lines(for: Fixture.listing()), ["Work: 18 min by transit · 25 min walk"])
    }

    func testAnotherAccountHasItsOwnPlaces() {
        let preferences = Preferences.ephemeral()
        let model = makeModel(StubCommute(), preferences: preferences)
        model.add(campus)

        model.reset()
        model.prepare(for: "user-2")

        XCTAssertEqual(model.places, [])
    }
}
