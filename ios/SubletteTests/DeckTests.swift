import XCTest
@testable import Sublette

/// The deck as the server sends it (docs/contract/samples/deck_*.json).
final class DeckTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testTheDeckSampleDecodes() throws {
        let page = try decoder.decode(DeckPage.self, from: Fixture.sample("deck_listings"))

        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue((0...100).contains(item.score))
        XCTAssertEqual(item.reasons.first, "Fits your dates")
        XCTAssertEqual(item.band, .strong)
        XCTAssertEqual(item.band.fitLabel, "Great fit")
        XCTAssertTrue(item.summary.hasPrefix("Fits your dates"))
        XCTAssertFalse(item.summary.contains("%"), "the card never shows a percentage")
        XCTAssertTrue((3...4).contains(item.reasons.count))
        XCTAssertGreaterThan(item.distanceM, 0)
        XCTAssertFalse(item.listing.isOwner)
        XCTAssertNil(item.listing.address, "The deck never carries the exact address")
        XCTAssertNil(item.listing.latitude)
        XCTAssertNotNil(item.listing.publicLatitude)
    }

    func testTheDiagnosticsSampleDecodes() throws {
        let diagnostics = try decoder.decode(DeckDiagnostics.self, from: Fixture.sample("deck_diagnostics"))

        XCTAssertEqual(diagnostics.inArea, 2)
        XCTAssertEqual(diagnostics.eligible, 1)
        XCTAssertEqual(diagnostics.topMustHave?.field, "parking")
        XCTAssertEqual(diagnostics.topMustHave?.kind, .mustHave)
        XCTAssertEqual(diagnostics.blockers.count, 1)
    }

    func testANotReadyDeckIsAnErrorWithACode() throws {
        let body = try decoder.decode(APIErrorBodyProbe.self, from: Fixture.sample("error_profile_incomplete"))

        XCTAssertEqual(body.code, "profile_incomplete")
        XCTAssertEqual(body.message, "Finish your profile first.")
    }

    func testTheDeckEndpointsAskForTheLimit() {
        XCTAssertEqual(Endpoint.deckListings(limit: 20).query, [URLQueryItem(name: "limit", value: "20")])
        XCTAssertEqual(Endpoint.deckDiagnostics.method, .get)
    }
}

private struct APIErrorBodyProbe: Decodable {
    let code: String
    let message: String
}
