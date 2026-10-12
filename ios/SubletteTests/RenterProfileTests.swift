import XCTest
@testable import Sublette

/// The renter profile as the server sends and receives it.
final class RenterProfileTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testTheSavedSampleDecodesEveryPreference() throws {
        let profile = try decoder.decode(RenterProfile.self, from: Fixture.sample("renter_profile"))

        XCTAssertEqual(profile.startDate, "2027-06-15")
        XCTAssertEqual(profile.endDate, "2027-09-01")
        XCTAssertEqual(profile.flexibilityDays, 7)
        XCTAssertEqual(profile.maxRentCents, 110_000)
        XCTAssertTrue(profile.complete)
        XCTAssertNotNil(profile.updatedAt)
        XCTAssertEqual(profile.pin, SearchPin(latitude: 47.6553117, longitude: -122.3035993, radiusM: 3217))
        XCTAssertEqual(profile.preference(.spaceType)?.value, .spaceTypes([.privateRoom, .entireUnit]))
        XCTAssertEqual(profile.preference(.spaceType)?.importance, .must)
        XCTAssertEqual(profile.preference(.furnished)?.value, .yes)
        XCTAssertEqual(profile.preference(.parking)?.importance, .off)
        XCTAssertEqual(profile.preference(.housemateCount)?.value, .count(2))
        XCTAssertEqual(profile.preference(.housemateGender)?.value, .gender(.women))
        XCTAssertEqual(profile.preferences.count, PreferenceField.allCases.count)
    }

    func testTheEmptySampleDecodes() throws {
        let profile = try decoder.decode(RenterProfile.self, from: Fixture.sample("renter_profile_empty"))

        XCTAssertEqual(profile, .empty)
    }

    func testEveryPreferenceFieldTheServerKnowsIsKnownToTheApp() {
        // Matches FIELDS in backend/app/services/preferences.py, in order.
        XCTAssertEqual(
            PreferenceField.allCases.map(\.rawValue),
            [
                "space_type", "private_bathroom", "furnished", "laundry", "parking",
                "pet_free", "smoke_free", "housemate_count", "housemate_gender",
            ]
        )
        XCTAssertEqual(Importance.allCases.map(\.rawValue), ["must", "nice", "off"])
        XCTAssertEqual(HousemateGender.allCases.map(\.rawValue), ["women", "men"])
        XCTAssertEqual(HouseholdGender.allCases.map(\.rawValue), ["women", "men", "mixed"])
    }

    func testSavingSendsWhatTheServerReturnsBack() throws {
        let sample = try Fixture.sample("renter_profile")
        let profile = try decoder.decode(RenterProfile.self, from: sample)

        let sent = try JSONSerialization.jsonObject(with: APIClient.makeEncoder().encode(profile.form)) as? [String: Any]
        let original = try JSONSerialization.jsonObject(with: sample) as? [String: Any]

        // Same keys and values as the server's answer, without the two it adds.
        var expected = try XCTUnwrap(original)
        expected.removeValue(forKey: "complete")
        expected.removeValue(forKey: "updated_at")
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(sent)), NSDictionary(dictionary: expected))
    }

    func testAFlagIsSentAsTrueNotOne() throws {
        let form = RenterProfileForm(
            flexibilityDays: 0,
            preferences: [Preference(field: .laundry, value: .yes, importance: .nice)]
        )

        let text = String(decoding: try APIClient.makeEncoder().encode(form), as: UTF8.self)

        XCTAssertTrue(text.contains("\"value\":true"), text)
    }

    func testAFlagThatIsNotTrueIsRefused() {
        let json = Data(#"{"field":"laundry","value":false,"importance":"nice"}"#.utf8)

        XCTAssertThrowsError(try decoder.decode(Preference.self, from: json))
    }

    func testListingsSayWhoLivesThere() throws {
        let listing = try decoder.decode(Listing.self, from: Fixture.sample("listing_owner"))

        XCTAssertEqual(listing.householdGender, .mixed)
    }

    func testListerGenderPreferenceIsNoPreferenceWomenOrMen() {
        XCTAssertEqual(GenderPreference.allCases.map(\.title), ["No preference", "Women", "Men"])
    }
}
