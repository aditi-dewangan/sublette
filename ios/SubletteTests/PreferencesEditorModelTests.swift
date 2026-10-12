import XCTest
@testable import Sublette

@MainActor
final class PreferencesEditorModelTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEditor(
        profile: RenterProfile? = nil,
        api: StubRenterAPI = StubRenterAPI(),
        campus: StubCampusLocator = StubCampusLocator(),
        startAt step: PreferencesEditorModel.Step = .dates
    ) -> PreferencesEditorModel {
        PreferencesEditorModel(
            profile: profile,
            schoolName: "University of Washington",
            api: api,
            campusLocator: campus,
            startAt: step,
            today: today
        )
    }

    private func savedSample() throws -> RenterProfile {
        try APIClient.makeDecoder().decode(RenterProfile.self, from: Fixture.sample("renter_profile"))
    }

    // MARK: - Starting out

    func testANewSearchStartsAtDatesWithNothingChosen() {
        let editor = makeEditor()

        XCTAssertEqual(editor.step, .dates)
        XCTAssertFalse(editor.isEditing)
        XCTAssertGreaterThan(editor.startDate, today)
        XCTAssertGreaterThan(editor.endDate, editor.startDate)
        XCTAssertTrue(editor.spaceTypes.isEmpty)
        XCTAssertNil(editor.center)
        XCTAssertEqual(editor.liveWith, .noPreference)
    }

    func testEditingASavedSearchSendsBackExactlyWhatWasSaved() throws {
        let saved = try savedSample()

        let editor = makeEditor(profile: saved)

        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.form, saved.form)
    }

    func testTheFlowCanOpenOnAnyStep() {
        XCTAssertEqual(makeEditor(startAt: .area).step, .area)
    }

    // MARK: - Each step

    func testDatesMustBeInOrder() {
        let editor = makeEditor()
        editor.endDate = editor.startDate

        editor.next()

        XCTAssertEqual(editor.step, .dates)
        XCTAssertNotNil(editor.fieldErrors["end_date"])
    }

    func testABudgetIsNeeded() {
        let editor = makeEditor(startAt: .budget)
        editor.budgetText = "abc"

        editor.next()
        XCTAssertEqual(editor.step, .budget)
        XCTAssertNotNil(editor.fieldErrors["max_rent_cents"])

        editor.budgetText = "1,100"
        editor.next()
        XCTAssertEqual(editor.step, .spaceType)
        XCTAssertEqual(editor.form.maxRentCents, 110_000)
    }

    func testAtLeastOneSpaceTypeIsNeeded() {
        let editor = makeEditor(startAt: .spaceType)

        editor.next()
        XCTAssertNotNil(editor.fieldErrors["space_type"])

        editor.spaceTypes = [.entireUnit, .privateRoom]
        editor.next()
        XCTAssertEqual(editor.step, .preferences)
    }

    func testChoosingEverySpaceTypeIsTheSameAsNoPreference() {
        let editor = makeEditor()
        editor.spaceTypes = Set(SpaceType.allCases)

        XCTAssertEqual(editor.form.preferences.first?.importance, .off)
    }

    func testSpaceTypesAreSentInAFixedOrder() {
        let editor = makeEditor()
        editor.spaceTypes = [.sharedRoom, .entireUnit]

        XCTAssertEqual(editor.form.preferences.first?.value, .spaceTypes([.entireUnit, .sharedRoom]))
    }

    func testEachFlagIsSentWithItsImportance() {
        let editor = makeEditor()
        editor.setImportance(.must, of: .smokeFree)
        editor.setImportance(.nice, of: .laundry)

        let sent = Dictionary(uniqueKeysWithValues: editor.form.preferences.map { ($0.field, $0.importance) })

        XCTAssertEqual(sent[.smokeFree], .must)
        XCTAssertEqual(sent[.laundry], .nice)
        XCTAssertEqual(sent[.parking], .off)
    }

    func testNoPreferenceOnWhoYouLiveWithSendsNothing() {
        let editor = makeEditor()

        XCTAssertNil(editor.form.preferences.first { $0.field == .housemateGender })

        editor.liveWith = .women
        editor.liveWithImportance = .nice
        XCTAssertEqual(
            editor.form.preferences.first { $0.field == .housemateGender },
            Preference(field: .housemateGender, value: .gender(.women), importance: .nice)
        )
    }

    // MARK: - The map

    func testThePinIsNeededToSave() async {
        let api = StubRenterAPI()
        let editor = makeEditor(api: api)
        editor.budgetText = "900"
        editor.spaceTypes = [.privateRoom]

        let saved = await editor.save()

        XCTAssertNil(saved)
        XCTAssertEqual(editor.step, .area)
        XCTAssertNotNil(editor.fieldErrors["pin"])
        XCTAssertTrue(api.saved.isEmpty)
    }

    func testMyCampusMovesThePinAndTheMap() async {
        let campus = StubCampusLocator()
        let editor = makeEditor(campus: campus, startAt: .area)

        await editor.useMyCampus()

        XCTAssertEqual(campus.searches, ["University of Washington"])
        XCTAssertEqual(editor.center, Coordinate(latitude: 47.6553, longitude: -122.3035))
        XCTAssertEqual(editor.recenterCount, 1)
        XCTAssertNil(editor.campusMessage)
    }

    func testWhenMapsIsDownThePinCanStillBePlacedByHand() async {
        let campus = StubCampusLocator()
        campus.result = .failure(AddressLookupError.unavailable)
        let editor = makeEditor(campus: campus, startAt: .area)

        await editor.useMyCampus()

        XCTAssertNil(editor.center)
        XCTAssertEqual(editor.campusMessage, "Maps can't be reached right now. Move the map yourself, or try again.")

        editor.mapMoved(to: Coordinate(latitude: 42.34, longitude: -71.09))
        XCTAssertEqual(editor.form.pin?.latitude, 42.34)
    }

    func testWhenMapsDoesNotKnowTheSchoolTheRenterIsTold() async {
        let campus = StubCampusLocator()
        campus.result = .failure(AddressLookupError.notFound)
        let editor = makeEditor(campus: campus, startAt: .area)

        await editor.useMyCampus()

        XCTAssertEqual(
            editor.campusMessage,
            "Couldn't find University of Washington on the map. Move the map to your campus instead."
        )
    }

    func testTheRadiusIsShownInMiles() {
        let editor = makeEditor()
        editor.radiusM = 4_828

        XCTAssertEqual(editor.radiusText, "3.0 miles")
    }

    // MARK: - Saving

    func testSavingSendsEverythingInOneRequest() async throws {
        let api = StubRenterAPI()
        let editor = makeEditor(api: api)
        editor.budgetText = "1100"
        editor.spaceTypes = [.privateRoom]
        editor.mapMoved(to: Coordinate(latitude: 47.6, longitude: -122.3))

        let saved = await editor.save()

        XCTAssertEqual(api.saved.count, 1)
        XCTAssertEqual(saved?.complete, true)
        XCTAssertEqual(api.saved.first?.pin?.radiusM, SearchPin.defaultRadiusM)
    }

    func testAServerRefusalGoesBackToTheStepWithTheProblem() async {
        let api = StubRenterAPI()
        api.saveResult = .failure(APIError.server(
            status: 422,
            code: "validation_error",
            message: "Some fields are missing or invalid.",
            fields: [.init(field: "preferences.0.value", message: "Choose one or more.")]
        ))
        let editor = makeEditor(api: api, startAt: .area)
        editor.budgetText = "1100"
        editor.spaceTypes = [.privateRoom]
        editor.mapMoved(to: Coordinate(latitude: 47.6, longitude: -122.3))

        let saved = await editor.save()

        XCTAssertNil(saved)
        XCTAssertEqual(editor.step, .spaceType, "preferences.0 is the space type")
        XCTAssertEqual(editor.errorMessage, "Some fields are missing or invalid.")
    }

    func testOfflineKeepsEveryAnswerAndSaysSo() async {
        let api = StubRenterAPI()
        api.saveResult = .failure(APIError.unreachable)
        let editor = makeEditor(api: api, startAt: .area)
        editor.budgetText = "1100"
        editor.spaceTypes = [.privateRoom]
        editor.mapMoved(to: Coordinate(latitude: 47.6, longitude: -122.3))

        let saved = await editor.save()

        XCTAssertNil(saved)
        XCTAssertEqual(editor.errorMessage, APIError.unreachable.userMessage)
        XCTAssertEqual(editor.budgetText, "1100")
        XCTAssertEqual(editor.step, .area)
    }

    func testServerFieldNamesMapToSteps() {
        let preferences = [
            Preference(field: .spaceType, value: .spaceTypes([.privateRoom]), importance: .must),
            Preference(field: .laundry, value: .yes, importance: .nice),
        ]
        func step(_ field: String) -> PreferencesEditorModel.Step {
            PreferencesEditorModel.step(forField: field, preferences: preferences)
        }

        XCTAssertEqual(step("end_date"), .dates)
        XCTAssertEqual(step("max_rent_cents"), .budget)
        XCTAssertEqual(step("preferences.0.value"), .spaceType)
        XCTAssertEqual(step("preferences.1.importance"), .preferences)
        XCTAssertEqual(step("pin.radius_m"), .area)
    }
}

@MainActor
final class RenterSearchModelTests: XCTestCase {
    func testLoadsTheSavedSearch() async {
        let api = StubRenterAPI()
        api.loadResults = [.success(PreviewData.renterProfile)]
        let search = RenterSearchModel(api: api)

        await search.load()

        XCTAssertEqual(search.profile, PreviewData.renterProfile)
        XCTAssertEqual(search.state, .loaded)
        XCTAssertFalse(search.needsSetUp)
    }

    func testANewRenterNeedsToSetUpASearch() async {
        let search = RenterSearchModel(api: StubRenterAPI())

        await search.load()

        XCTAssertTrue(search.needsSetUp)
    }

    func testOfflineKeepsWhatWasShownAndOffersARetry() async {
        let api = StubRenterAPI()
        api.loadResults = [.success(PreviewData.renterProfile), .failure(APIError.unreachable)]
        let search = RenterSearchModel(api: api)
        await search.load()

        await search.load()

        XCTAssertEqual(search.profile, PreviewData.renterProfile)
        XCTAssertEqual(search.state, .failed(APIError.unreachable.userMessage))
    }

    func testAnotherAccountNeverSeesTheLastOnesSearch() async {
        let api = StubRenterAPI()
        api.loadResults = [.success(PreviewData.renterProfile)]
        let search = RenterSearchModel(api: api)
        search.prepare(for: "user-1")
        await search.load()

        search.prepare(for: "user-2")

        XCTAssertNil(search.profile)
        XCTAssertEqual(search.state, .idle)
    }
}

final class ModeTabTests: XCTestCase {
    func testEachModeHasItsOwnTabs() {
        XCTAssertEqual(ModeTab.tabs(for: .renter), [.deck, .map, .matches, .profile])
        XCTAssertEqual(ModeTab.tabs(for: .lister), [.listings, .matches, .profile])
    }

    func testEachModeHasItsOwnAccent() {
        XCTAssertEqual(AppMode.renter.accent, Brand.yellow)
        XCTAssertEqual(AppMode.lister.accent, Brand.orange)
        XCTAssertEqual(AppMode.renter.textOnAccent, Brand.ink)
        XCTAssertEqual(AppMode.lister.textOnAccent, Brand.ink)
    }
}
