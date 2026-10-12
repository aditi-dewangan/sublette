import XCTest
@testable import Sublette

@MainActor
final class ListingEditorModelTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEditor(
        listing: Listing? = nil,
        api: StubListingsAPI = StubListingsAPI(),
        uploader: StubUploader = StubUploader(),
        locator: StubLocator = StubLocator()
    ) -> ListingEditorModel {
        ListingEditorModel(
            listing: listing,
            schoolName: "University of Washington",
            api: api,
            uploader: uploader,
            locator: locator,
            today: today
        )
    }

    /// Answers every question, the way a lister would.
    private func fillIn(_ editor: ListingEditorModel) async {
        await editor.addPhotos([Data([1]), Data([2]), Data([3]), Data([4])])
        editor.address = "4500 University Way NE"
        await editor.locateAddress()
        editor.confirmCandidate()
        editor.rentText = "1,200"
        editor.spaceType = .privateRoom
        editor.bathroom = .shared
        editor.petsAllowed = false
        editor.smokingAllowed = false
        editor.landlordConsent = true
    }

    // MARK: - Starting out

    func testANewListingStartsAtPhotosWithSensibleDates() {
        let editor = makeEditor()

        XCTAssertEqual(editor.step, .photos)
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(editor.stayDays, 84, "Twelve weeks, about a quarter")
        XCTAssertGreaterThan(editor.startDate, today)
    }

    func testEditingFillsInEveryAnswer() {
        let editor = makeEditor(listing: Fixture.listing())

        XCTAssertTrue(editor.isEditing)
        XCTAssertTrue(editor.isPublished)
        XCTAssertEqual(editor.photos.map(\.key), Fixture.listing().photos.map(\.key))
        XCTAssertEqual(editor.rentText, "1200")
        XCTAssertEqual(editor.depositText, "500")
        XCTAssertEqual(editor.spaceType, .privateRoom)
        XCTAssertEqual(editor.genderPreference, .women)
        XCTAssertEqual(editor.minStayWeeks, 8)
        XCTAssertEqual(editor.landlordConsent, true)
        XCTAssertEqual(CalendarDate.string(from: editor.startDate), "2027-01-14")
        XCTAssertEqual(editor.form, ListingForm(listing: Fixture.listing()))
    }

    // MARK: - Each step checks its own answers

    func testFewerThanFourPhotosCannotMoveOn() async {
        let editor = makeEditor()
        await editor.addPhotos([Data([1]), Data([2]), Data([3])])

        editor.next()

        XCTAssertEqual(editor.step, .photos)
        XCTAssertEqual(editor.fieldErrors["photo_keys"], "Add at least 4 photos.")

        await editor.addPhotos([Data([4])])
        XCTAssertNil(editor.fieldErrors["photo_keys"], "The error clears once there are enough")
        editor.next()
        XCTAssertEqual(editor.step, .address)
    }

    func testTheAddressMustBeConfirmedOnTheMap() async {
        let locator = StubLocator()
        let editor = makeEditor(locator: locator)
        editor.step = .address

        editor.next()
        XCTAssertEqual(editor.fieldErrors["address"], "Enter the address.")

        editor.address = "4500 University Way NE"
        editor.next()
        XCTAssertEqual(editor.fieldErrors["latitude"], "Confirm the address on the map.")

        await editor.locateAddress()
        XCTAssertEqual(locator.lookups, ["4500 University Way NE"])
        XCTAssertNotNil(editor.candidate)
        editor.confirmCandidate()
        editor.next()
        XCTAssertEqual(editor.step, .rentAndDates)
        XCTAssertEqual(editor.form.latitude, 47.6588)
    }

    func testChangingTheAddressAfterConfirmingAsksForTheMapAgain() async {
        let editor = makeEditor()
        editor.address = "4500 University Way NE"
        await editor.locateAddress()
        editor.confirmCandidate()

        editor.address = "1410 NE Campus Pkwy"
        editor.addressEdited()

        XCTAssertNil(editor.form.latitude)
        XCTAssertNil(editor.candidate)
    }

    func testRentAndDatesAreChecked() {
        let editor = makeEditor()
        editor.step = .rentAndDates

        editor.next()
        XCTAssertEqual(editor.fieldErrors["rent_cents"], "Enter the monthly rent.")

        editor.rentText = "0"
        editor.next()
        XCTAssertEqual(editor.fieldErrors["rent_cents"], "Enter the monthly rent.")

        editor.rentText = "1200"
        editor.depositText = "a lot"
        editor.next()
        XCTAssertNotNil(editor.fieldErrors["deposit_cents"])

        editor.depositText = ""
        editor.endDate = editor.startDate
        editor.next()
        XCTAssertEqual(editor.fieldErrors["end_date"], "The end date must be after the start date.")

        editor.endDate = editor.startDate.addingTimeInterval(86_400 * 30)
        editor.next()
        XCTAssertEqual(editor.step, .space)
        XCTAssertEqual(editor.form.rentCents, 120_000)
        XCTAssertEqual(editor.form.depositCents, 0)
    }

    func testTheSpaceAndHouseholdQuestionsMustBeAnswered() {
        let editor = makeEditor()
        editor.step = .space
        editor.next()
        XCTAssertEqual(Set(editor.fieldErrors.keys), ["space_type", "bathroom"])

        editor.spaceType = .entireUnit
        editor.bathroom = .own
        editor.next()
        XCTAssertEqual(editor.step, .household)

        editor.next()
        XCTAssertEqual(Set(editor.fieldErrors.keys), ["pets_allowed", "smoking_allowed"])
        editor.petsAllowed = true
        editor.smokingAllowed = false
        editor.housematesNote = String(repeating: "a", count: 141)
        editor.next()
        XCTAssertEqual(Set(editor.fieldErrors.keys), ["housemates_note"])
        editor.housematesNote = "Quiet."
        editor.next()
        XCTAssertEqual(editor.step, .whoCanTakeIt)
    }

    func testAMinimumStayLongerThanTheDatesIsCaught() {
        let editor = makeEditor()
        editor.step = .whoCanTakeIt
        editor.minStayWeeks = 13  // the default dates are 12 weeks

        editor.next()

        XCTAssertNotNil(editor.fieldErrors["min_stay_days"])
        editor.minStayWeeks = 12
        editor.next()
        XCTAssertEqual(editor.step, .landlordConsent)
    }

    func testLandlordConsentMustBeAnsweredButNoIsAnAnswer() {
        let editor = makeEditor()
        editor.step = .landlordConsent

        editor.next()
        XCTAssertNotNil(editor.fieldErrors["landlord_consent"])

        editor.landlordConsent = false
        editor.next()
        XCTAssertEqual(editor.step, .preview)
    }

    func testAGenderPreferenceIsSentOnlyForASharedHome() {
        let editor = makeEditor()
        editor.genderPreference = .women

        editor.spaceType = .sharedRoom
        XCTAssertEqual(editor.form.genderPreference, .women)

        editor.spaceType = .entireUnit
        XCTAssertEqual(editor.form.genderPreference, .anyone)
    }

    func testBackGoesToThePreviousStepAndClearsErrors() {
        let editor = makeEditor()
        editor.step = .space
        editor.next()
        XCTAssertFalse(editor.fieldErrors.isEmpty)

        editor.back()

        XCTAssertEqual(editor.step, .rentAndDates)
        XCTAssertTrue(editor.fieldErrors.isEmpty)
    }

    // MARK: - Photos

    func testPhotosUploadInOrderAndCanBeReorderedAndRemoved() async {
        let uploader = StubUploader()
        let editor = makeEditor(uploader: uploader)

        await editor.addPhotos([Data([1]), Data([2]), Data([3])])
        XCTAssertEqual(editor.photos.map(\.key), [
            "listings/user-1/photo-1.jpg", "listings/user-1/photo-2.jpg", "listings/user-1/photo-3.jpg",
        ])

        // Drag the third photo to the front, the way a list reports it.
        editor.movePhotos(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(editor.form.photoKeys.first, "listings/user-1/photo-3.jpg")

        // Drag the first photo to the end.
        editor.movePhotos(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(editor.form.photoKeys.last, "listings/user-1/photo-3.jpg")

        editor.removePhotos(at: IndexSet(integer: 0))
        XCTAssertEqual(editor.photos.count, 2)
        XCTAssertFalse(editor.form.photoKeys.contains("listings/user-1/photo-1.jpg"))
    }

    func testNoMoreThanTwelvePhotos() async {
        let editor = makeEditor()

        await editor.addPhotos((0..<15).map { Data([UInt8($0)]) })

        XCTAssertEqual(editor.photos.count, 12)
        XCTAssertFalse(editor.canAddPhotos)
    }

    // Dependency unavailable: photo storage.

    func testAPhotoThatFailsIsSkippedAndTheOthersStillGoUp() async {
        let uploader = StubUploader()
        uploader.listingResults = [.success("a"), .failure(APIError.unreachable), .success("c")]
        let editor = makeEditor(uploader: uploader)

        await editor.addPhotos([Data([1]), Data([2]), Data([3])])

        XCTAssertEqual(editor.photos.map(\.key), ["a", "c"])
        XCTAssertEqual(editor.photoMessage, "One photo couldn't be uploaded. Try adding it again.")
        XCTAssertEqual(editor.uploadingPhotos, 0)
    }

    func testUploadsSwitchedOffShowsTheServersMessage() async {
        let uploader = StubUploader()
        let off = Fixture.serverError(
            503, "uploads_unavailable", "Photo uploads aren't available right now. You can add a photo later."
        )
        uploader.listingResults = [.failure(off), .failure(off)]
        let editor = makeEditor(uploader: uploader)

        await editor.addPhotos([Data([1]), Data([2])])

        XCTAssertEqual(editor.photos, [])
        XCTAssertEqual(editor.photoMessage, "Photo uploads aren't available right now. You can add a photo later.")
    }

    // MARK: - Dependency unavailable: Apple's address lookup

    func testAnAddressThatCannotBeFoundSaysSo() async {
        let locator = StubLocator()
        locator.result = .failure(AddressLookupError.notFound)
        let editor = makeEditor(locator: locator)
        editor.address = "Nowhere at all"

        await editor.locateAddress()

        XCTAssertEqual(editor.addressMessage, "Couldn't find that address. Check the street and city.")
        XCTAssertNil(editor.candidate)
        XCTAssertFalse(editor.isLocating)
    }

    func testTheLookupServiceBeingDownSaysSoAndKeepsEverythingElse() async {
        let locator = StubLocator()
        locator.result = .failure(AddressLookupError.unavailable)
        let editor = makeEditor(locator: locator)
        editor.address = "4500 University Way NE"
        editor.rentText = "1200"

        await editor.locateAddress()

        XCTAssertEqual(
            editor.addressMessage,
            "Couldn't look up the address right now. Check your connection and try again."
        )
        XCTAssertEqual(editor.address, "4500 University Way NE")
        XCTAssertEqual(editor.rentText, "1200")

        locator.result = .success(
            LocatedAddress(coordinate: Coordinate(latitude: 1, longitude: 2), formatted: "Somewhere")
        )
        await editor.locateAddress()
        XCTAssertNil(editor.addressMessage)
        XCTAssertNotNil(editor.candidate)
    }

    func testLookingUpAnEmptyAddressAsksForOne() async {
        let locator = StubLocator()
        let editor = makeEditor(locator: locator)

        await editor.locateAddress()

        XCTAssertEqual(editor.addressMessage, "Enter the address first.")
        XCTAssertEqual(locator.lookups, [])
    }

    // MARK: - Saving and publishing

    func testPublishingANewListingCreatesItThenMakesItLive() async {
        let api = StubListingsAPI()
        let editor = makeEditor(api: api)
        await fillIn(editor)
        XCTAssertTrue(editor.problems(on: .preview).isEmpty)

        let saved = await editor.publish()

        XCTAssertEqual(saved?.status, .active)
        XCTAssertEqual(api.created.count, 1)
        XCTAssertEqual(api.created.first?.rentCents, 120_000)
        XCTAssertEqual(api.created.first?.photoKeys.count, 4)
        XCTAssertEqual(api.statusChanges.map { $0.status }, [.active])
        XCTAssertNil(editor.errorMessage)
    }

    func testSavingADraftDoesNotPublish() async {
        let api = StubListingsAPI()
        let editor = makeEditor(api: api)
        editor.rentText = "900"

        let saved = await editor.saveDraft()

        XCTAssertEqual(saved?.status, .draft)
        XCTAssertEqual(api.statusChanges.count, 0)
    }

    func testAfterTheFirstSaveTheSameListingIsUpdatedNotDuplicated() async {
        let api = StubListingsAPI()
        let editor = makeEditor(api: api)

        await editor.saveDraft()
        await editor.saveDraft()

        XCTAssertEqual(api.created.count, 1)
        XCTAssertEqual(api.updated.map { $0.id }, ["new-1"])
    }

    func testEditingALiveListingSavesWithoutChangingItsStatus() async {
        let api = StubListingsAPI()
        api.updateResult = .success(Fixture.listing(status: .active))
        let editor = makeEditor(listing: Fixture.listing(), api: api)
        editor.rentText = "1100"

        let saved = await editor.publish()

        XCTAssertEqual(saved?.status, .active)
        XCTAssertEqual(api.updated.first?.form.rentCents, 110_000)
        XCTAssertEqual(api.statusChanges.count, 0)
    }

    func testTheServersFieldErrorsShowOnTheirStep() async {
        let api = StubListingsAPI()
        api.statusResult = .failure(
            APIError.server(
                status: 422,
                code: "listing_incomplete",
                message: "Finish the listing before publishing it.",
                fields: [
                    .init(field: "landlord_consent", message: "Say whether your landlord has approved subletting."),
                    .init(field: "rent_cents", message: "Enter the monthly rent."),
                ]
            )
        )
        let editor = makeEditor(api: api)
        editor.step = .preview

        let saved = await editor.publish()

        XCTAssertNil(saved)
        XCTAssertEqual(editor.errorMessage, "Finish the listing before publishing it.")
        XCTAssertEqual(editor.step, .rentAndDates, "Jumps to the first step with a problem")
        XCTAssertEqual(editor.fieldErrors["rent_cents"], "Enter the monthly rent.")
        XCTAssertNotNil(editor.fieldErrors["landlord_consent"])
        // The draft was saved, so the next try updates it rather than making another.
        XCTAssertTrue(editor.isEditing)
    }

    func testServerDownWhileSavingKeepsEveryAnswer() async {
        let api = StubListingsAPI()
        api.createResult = .failure(APIError.unreachable)
        let editor = makeEditor(api: api)
        await fillIn(editor)
        editor.step = .preview

        let saved = await editor.publish()

        XCTAssertNil(saved)
        XCTAssertEqual(editor.errorMessage, APIError.unreachable.userMessage)
        XCTAssertEqual(editor.step, .preview)
        XCTAssertEqual(editor.photos.count, 4)
        XCTAssertEqual(editor.rentText, "1,200")
        XCTAssertFalse(editor.isSaving)
    }

    func testThePreviewShowsTheAnswersWithoutTheAddress() async {
        let editor = makeEditor()
        await fillIn(editor)

        let preview = editor.previewListing

        XCTAssertNil(preview.address)
        XCTAssertNil(preview.latitude)
        XCTAssertEqual(preview.rentCents, 120_000)
        XCTAssertEqual(preview.photos.count, 4)
        XCTAssertEqual(preview.lister.schoolName, "University of Washington")
    }

    func testEveryFieldTheServerCanNameHasAStep() {
        let fields = [
            "photo_keys", "address", "latitude", "longitude", "rent_cents", "deposit_cents",
            "utilities_included", "start_date", "end_date", "space_type", "bedrooms", "bathroom",
            "furnished", "laundry", "parking", "housemates_staying", "housemates_note",
            "pets_allowed", "smoking_allowed", "gender_preference", "same_school_only",
            "min_stay_days", "landlord_consent",
        ]
        for field in fields {
            XCTAssertNotEqual(ListingEditorModel.step(forField: field), .preview, field)
        }
    }
}

@MainActor
final class ListerHomeModelTests: XCTestCase {
    func testLoadsTheListersListings() async {
        let api = StubListingsAPI()
        api.pages = [.success(ListingPage(items: [Fixture.listing(id: "a"), Fixture.listing(id: "b")], nextCursor: nil))]
        let model = ListerHomeModel(api: api)

        await model.load()

        XCTAssertEqual(model.listings.map(\.id), ["a", "b"])
        XCTAssertEqual(model.state, .loaded)
        XCTAssertFalse(model.canLoadMore)
    }

    func testMorePagesAreLoadedWithTheCursor() async {
        let api = StubListingsAPI()
        api.pages = [
            .success(ListingPage(items: [Fixture.listing(id: "a")], nextCursor: "next")),
            .success(ListingPage(items: [Fixture.listing(id: "a"), Fixture.listing(id: "b")], nextCursor: nil)),
        ]
        let model = ListerHomeModel(api: api)

        await model.load()
        XCTAssertTrue(model.canLoadMore)
        await model.loadMore()

        XCTAssertEqual(api.requestedCursors, [nil, "next"])
        XCTAssertEqual(model.listings.map(\.id), ["a", "b"], "No duplicates")
        XCTAssertFalse(model.canLoadMore)
    }

    // Dependency unavailable: the server.

    func testOfflineKeepsWhatWasLoadedAndSaysWhy() async {
        let api = StubListingsAPI()
        api.pages = [
            .success(ListingPage(items: [Fixture.listing(id: "a")], nextCursor: nil)),
            .failure(APIError.unreachable),
        ]
        let model = ListerHomeModel(api: api)
        await model.load()

        await model.load()

        XCTAssertEqual(model.listings.map(\.id), ["a"])
        XCTAssertEqual(model.state, .failed(APIError.unreachable.userMessage))
    }

    func testAStatusChangeUpdatesTheList() async {
        let api = StubListingsAPI()
        api.pages = [.success(ListingPage(items: [Fixture.listing(id: "a")], nextCursor: nil))]
        let model = ListerHomeModel(api: api)
        await model.load()

        let worked = await model.setStatus(.paused, for: model.listings[0])

        XCTAssertTrue(worked)
        XCTAssertEqual(model.listings.first?.status, .paused)
        XCTAssertNil(model.busyListingID)
    }

    func testARefusedPublishSaysWhatIsMissing() async {
        let api = StubListingsAPI()
        api.statusResult = .failure(
            APIError.server(
                status: 422,
                code: "listing_incomplete",
                message: "Finish the listing before publishing it.",
                fields: [.init(field: "photo_keys", message: "Add at least 4 photos.")]
            )
        )
        let model = ListerHomeModel(api: api)
        model.show(Fixture.listing(id: "a", status: .draft))

        let worked = await model.setStatus(.active, for: model.listings[0])

        XCTAssertFalse(worked)
        XCTAssertEqual(model.actionMessage, "Finish the listing first. Add at least 4 photos.")
        XCTAssertEqual(model.listings.first?.status, .draft)
    }

    func testShowAddsANewListingAtTheTopAndReplacesAnEditedOne() {
        let model = ListerHomeModel(api: StubListingsAPI())
        model.show(Fixture.listing(id: "a"))
        model.show(Fixture.listing(id: "b"))

        var edited = Fixture.listing(id: "a")
        edited.rentCents = 99_900
        model.show(edited)

        XCTAssertEqual(model.listings.map(\.id), ["b", "a"])
        XCTAssertEqual(model.listings.last?.rentCents, 99_900)
    }

    // MARK: - Who lives there

    func testWhoLivesThereIsAskedOnlyWhenSomeoneStays() {
        let editor = makeEditor()
        editor.petsAllowed = false
        editor.smokingAllowed = false

        editor.housematesStaying = 0
        XCTAssertNil(editor.problems(on: .household)["household_gender"])
        XCTAssertNil(editor.form.householdGender)

        editor.housematesStaying = 2
        XCTAssertEqual(editor.problems(on: .household)["household_gender"], "Say who the housemates staying are.")

        editor.householdGender = .women
        XCTAssertNil(editor.problems(on: .household)["household_gender"])
        XCTAssertEqual(editor.form.householdGender, .women)
    }

    func testWhoLivesThereIsClearedWhenNobodyStays() {
        let editor = makeEditor(listing: Fixture.listing())
        XCTAssertEqual(editor.householdGender, .women)

        editor.housematesStaying = 0

        XCTAssertNil(editor.form.householdGender)
    }

    func testTheServersHouseholdErrorOpensTheHouseholdStep() {
        XCTAssertEqual(ListingEditorModel.step(forField: "household_gender"), .household)
    }
}
