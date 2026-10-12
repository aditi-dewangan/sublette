import XCTest
@testable import Sublette

/// The real server's listing responses, and what the app sends back.
final class ListingContractTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testTheOwnersViewIncludesTheExactAddress() throws {
        let listing = try decoder.decode(Listing.self, from: Fixture.sample("listing_owner"))

        XCTAssertTrue(listing.isOwner)
        XCTAssertEqual(listing.status, .active)
        XCTAssertNotNil(listing.address)
        XCTAssertNotNil(listing.latitude)
        XCTAssertNotNil(listing.longitude)
        XCTAssertEqual(listing.rentCents, 120_000)
        XCTAssertEqual(listing.depositCents, 50_000)
        XCTAssertEqual(listing.spaceType, .privateRoom)
        XCTAssertEqual(listing.bathroom, .shared)
        XCTAssertEqual(listing.genderPreference, .anyone)
        XCTAssertEqual(listing.minStayDays, 60)
        XCTAssertEqual(listing.landlordConsent, true)
        XCTAssertEqual(listing.photos.count, 4)
        XCTAssertEqual(listing.lister.schoolName, "University of Washington")
        XCTAssertNotNil(CalendarDate.date(from: listing.startDate))
    }

    func testEveryoneElseGetsOnlyThePublicPoint() throws {
        let listing = try decoder.decode(Listing.self, from: Fixture.sample("listing_public"))

        XCTAssertFalse(listing.isOwner)
        XCTAssertNil(listing.address)
        XCTAssertNil(listing.latitude)
        XCTAssertNil(listing.longitude)
        XCTAssertNotNil(listing.publicLatitude)
        XCTAssertNotNil(listing.publicLongitude)
    }

    func testADraftWithMostAnswersMissingStillDecodes() throws {
        let listing = try decoder.decode(Listing.self, from: Fixture.sample("listing_draft"))

        XCTAssertEqual(listing.status, .draft)
        XCTAssertEqual(listing.rentCents, 90_000)
        XCTAssertNil(listing.spaceType)
        XCTAssertNil(listing.petsAllowed)
        XCTAssertEqual(listing.photos, [])
    }

    func testMyListingsPage() throws {
        let page = try decoder.decode(ListingPage.self, from: Fixture.sample("my_listings"))

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.nextCursor, "sample-cursor")
    }

    func testAnIncompleteListingNamesEveryMissingField() throws {
        let body = try decoder.decode(APIErrorBody.self, from: Fixture.sample("error_listing_incomplete"))

        XCTAssertEqual(body.code, "listing_incomplete")
        let fields = Set(body.fields?.map(\.field) ?? [])
        XCTAssertTrue(fields.isSuperset(of: ["photo_keys", "address", "latitude", "landlord_consent"]))
        // Every field the server names maps to a step the editor can jump to.
        for field in fields {
            XCTAssertNotEqual(ListingEditorModel.step(forField: field), .preview, field)
        }
    }

    func testEveryChoiceTheServerAllowsIsKnownToTheApp() {
        // Matches backend/app/schemas/listings.py.
        XCTAssertEqual(SpaceType.allCases.map(\.rawValue), ["entire_unit", "private_room", "shared_room"])
        XCTAssertEqual(Bathroom.allCases.map(\.rawValue), ["private", "shared"])
        XCTAssertEqual(GenderPreference.allCases.map(\.rawValue), ["any", "women", "men"])
        XCTAssertEqual(
            ListingStatus.allCases.map(\.rawValue),
            ["draft", "active", "paused", "filled", "expired"]
        )
    }

    func testTheFormUsesTheServersFieldNamesAndSendsNullForUnanswered() throws {
        var form = ListingForm()
        form.rentCents = 120_000
        form.photoKeys = ["listings/u/a.jpg"]
        let data = try APIClient.makeEncoder().encode(form)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(body.keys),
            [
                "address", "latitude", "longitude", "rent_cents", "deposit_cents",
                "utilities_included", "start_date", "end_date", "space_type", "bedrooms",
                "bathroom", "furnished", "laundry", "parking", "housemates_staying",
                "housemates_note", "pets_allowed", "smoking_allowed", "gender_preference",
                "same_school_only", "min_stay_days", "landlord_consent", "photo_keys",
            ]
        )
        XCTAssertEqual(body["rent_cents"] as? Int, 120_000)
        XCTAssertEqual(body["gender_preference"] as? String, "any")
        XCTAssertEqual(body["photo_keys"] as? [String], ["listings/u/a.jpg"])
        XCTAssertTrue(body["address"] is NSNull)
        XCTAssertTrue(body["landlord_consent"] is NSNull)
        XCTAssertTrue(body["space_type"] is NSNull)
    }

    func testAFormBuiltFromAListingKeepsEveryAnswer() {
        let listing = Fixture.listing()
        let form = ListingForm(listing: listing)

        XCTAssertEqual(form.address, listing.address)
        XCTAssertEqual(form.rentCents, 120_000)
        XCTAssertEqual(form.genderPreference, .women)
        XCTAssertEqual(form.minStayDays, 56)
        XCTAssertEqual(form.photoKeys, listing.photos.map(\.key))
    }

    func testListingPathsAndTheCursorQuery() {
        let client = APIClient(baseURL: URL(string: "https://api.example.test")!)

        XCTAssertEqual(client.url(for: .listing("abc"))?.absoluteString, "https://api.example.test/v1/listings/abc")
        XCTAssertEqual(
            client.url(for: .listingStatus("abc"))?.absoluteString,
            "https://api.example.test/v1/listings/abc/status"
        )
        XCTAssertEqual(
            client.url(for: .myListings(cursor: nil))?.absoluteString,
            "https://api.example.test/v1/me/listings"
        )
        XCTAssertEqual(
            client.url(for: .myListings(cursor: "MjAyNy0wMS0wNHwx=="))?.absoluteString,
            "https://api.example.test/v1/me/listings?cursor=MjAyNy0wMS0wNHwx%3D%3D"
        )
    }
}

final class ListingFormattingTests: XCTestCase {
    func testMoneyIsReadTheWayStudentsTypeIt() {
        XCTAssertEqual(Money.cents(from: "1200"), 120_000)
        XCTAssertEqual(Money.cents(from: "1,200"), 120_000)
        XCTAssertEqual(Money.cents(from: " $1,200.50 "), 120_050)
        XCTAssertEqual(Money.cents(from: "0"), 0)
        XCTAssertNil(Money.cents(from: ""))
        XCTAssertNil(Money.cents(from: "twelve hundred"))
        XCTAssertNil(Money.cents(from: "-5"))
    }

    func testMoneyIsShownInDollars() {
        XCTAssertEqual(Money.dollars(120_000), "$1,200")
        XCTAssertEqual(Money.editableDollars(120_000), "1200")
        XCTAssertEqual(Money.editableDollars(120_050), "1200.50")
        XCTAssertEqual(Money.editableDollars(nil), "")
    }

    func testCalendarDatesRoundTrip() throws {
        let date = try XCTUnwrap(CalendarDate.date(from: "2027-01-14"))

        XCTAssertEqual(CalendarDate.string(from: date), "2027-01-14")
        XCTAssertNil(CalendarDate.date(from: "14/01/2027"))
        XCTAssertNil(CalendarDate.date(from: nil))
    }

    func testSummaries() {
        let listing = Fixture.listing()

        XCTAssertEqual(listing.spaceSummary, "Private room · Shared bathroom · 3 bedrooms")
        XCTAssertEqual(listing.amenities, ["Furnished", "In-unit laundry", "Utilities included"])
        XCTAssertEqual(listing.title, "4500 University Way NE")
        XCTAssertNotNil(listing.dateSummary)
    }
}
