import XCTest
@testable import Sublette

@MainActor
final class ProfileFormModelTests: XCTestCase {
    private func makeForm(
        user: User = Fixture.newUser,
        test: TestSession,
        uploader: StubUploader = StubUploader()
    ) -> ProfileFormModel {
        ProfileFormModel(user: user, api: test.api, uploader: uploader, session: test.session)
    }

    private func fillIn(_ form: ProfileFormModel) {
        form.firstName = "  Aditi "
        form.year = .junior
        form.program = " Informatics "
        form.smokes = false
        form.hasPets = true
    }

    // MARK: - What is required

    func testAnEmptyFormCannotBeSaved() async {
        let test = TestSession()
        let form = makeForm(test: test)

        XCTAssertFalse(form.canSave)
        let saved = await form.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(test.api.updates, [])
    }

    func testEachRequiredAnswerIsNeeded() {
        let form = makeForm(test: TestSession())
        fillIn(form)
        XCTAssertTrue(form.canSave)

        form.firstName = "   "
        XCTAssertFalse(form.canSave)
        form.firstName = "Aditi"

        form.year = nil
        XCTAssertFalse(form.canSave)
        form.year = .senior

        form.program = ""
        XCTAssertFalse(form.canSave)
        form.program = "Design"

        form.smokes = nil
        XCTAssertFalse(form.canSave)
        form.smokes = true

        form.hasPets = nil
        XCTAssertFalse(form.canSave)
        form.hasPets = false

        XCTAssertTrue(form.canSave)
    }

    func testPhotoBioAndGenderAreOptional() {
        let form = makeForm(test: TestSession())
        fillIn(form)

        XCTAssertEqual(form.bio, "")
        XCTAssertNil(form.gender)
        XCTAssertNil(form.photoUrl)
        XCTAssertTrue(form.canSave)
    }

    func testABioOverTheLimitCannotBeSaved() {
        let form = makeForm(test: TestSession())
        fillIn(form)

        form.bio = String(repeating: "a", count: 160)
        XCTAssertEqual(form.bioCharactersLeft, 0)
        XCTAssertTrue(form.canSave)

        form.bio = String(repeating: "a", count: 161)
        XCTAssertEqual(form.bioCharactersLeft, -1)
        XCTAssertFalse(form.canSave)
    }

    // MARK: - Saving

    func testSavingSendsTrimmedAnswersAndUpdatesTheSession() async {
        let test = TestSession()
        await test.session.completeSignIn(Fixture.session(user: Fixture.newUser))
        test.api.updateResult = .success(Fixture.completeUser)
        let form = makeForm(test: test)
        fillIn(form)
        form.bio = "  "

        let saved = await form.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(
            test.api.updates,
            [
                ProfileUpdate(
                    firstName: "Aditi",
                    year: .junior,
                    program: "Informatics",
                    bio: nil,
                    gender: nil,
                    smokes: false,
                    hasPets: true
                ),
            ]
        )
        XCTAssertEqual(test.session.user, Fixture.completeUser)
        XCTAssertNil(form.errorMessage)
        XCTAssertFalse(form.isSaving)
    }

    func testAnExistingProfileFillsTheForm() {
        var user = Fixture.completeUser
        user.gender = .woman
        user.photoUrl = "https://photos.example.test/a.jpg"

        let form = makeForm(user: user, test: TestSession())

        XCTAssertEqual(form.firstName, "Aditi")
        XCTAssertEqual(form.year, .junior)
        XCTAssertEqual(form.program, "Informatics")
        XCTAssertEqual(form.bio, "Tidy, quiet, plant person.")
        XCTAssertEqual(form.gender, .woman)
        XCTAssertEqual(form.smokes, false)
        XCTAssertEqual(form.hasPets, false)
        XCTAssertEqual(form.photoUrl, "https://photos.example.test/a.jpg")
        XCTAssertTrue(form.canSave)
    }

    func testEachServerValidationErrorIsKeptForItsField() async {
        let test = TestSession()
        test.api.updateResult = .failure(
            APIError.server(
                status: 422,
                code: "validation_error",
                message: "Some fields are missing or invalid.",
                fields: [
                    .init(field: "first_name", message: "This can't be empty."),
                    .init(field: "program", message: "Keep this to 100 characters or fewer."),
                ]
            )
        )
        let form = makeForm(test: test)
        fillIn(form)

        let saved = await form.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(form.errorMessage, "Some fields are missing or invalid.")
        XCTAssertEqual(form.fieldErrors["first_name"], "This can't be empty.")
        XCTAssertEqual(form.fieldErrors["program"], "Keep this to 100 characters or fewer.")
        XCTAssertNil(form.fieldErrors["year"])
    }

    func testServerDownWhileSavingKeepsTheAnswersAndSaysSo() async {
        let test = TestSession()
        test.api.updateResult = .failure(APIError.unreachable)
        let form = makeForm(test: test)
        fillIn(form)

        let saved = await form.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(form.errorMessage, APIError.unreachable.userMessage)
        XCTAssertEqual(form.firstName, "  Aditi ")
        XCTAssertTrue(form.canSave, "The student can try again")
    }

    // MARK: - Photo

    func testAPhotoIsUploadedThenAttached() async {
        let test = TestSession()
        var withPhoto = Fixture.completeUser
        withPhoto.photoUrl = "https://photos.example.test/profiles/user-1/abc.jpg"
        test.api.setPhotoResult = .success(withPhoto)
        let uploader = StubUploader()
        let form = makeForm(user: Fixture.completeUser, test: test, uploader: uploader)

        await form.setPhoto(jpeg: Data([1, 2, 3]))

        XCTAssertEqual(uploader.uploads, [Data([1, 2, 3])])
        XCTAssertEqual(test.api.photoKeys, ["profiles/user-1/abc.jpg"])
        XCTAssertEqual(form.photoUrl, withPhoto.photoUrl)
        XCTAssertEqual(test.session.user, withPhoto)
        XCTAssertNil(form.photoMessage)
        XCTAssertFalse(form.isUploadingPhoto)
    }

    // Dependency unavailable: photo storage.

    func testStorageDownDoesNotBlockTheProfile() async {
        let test = TestSession()
        test.api.updateResult = .success(Fixture.completeUser)
        let uploader = StubUploader()
        uploader.result = .failure(APIError.unreachable)
        let form = makeForm(test: test, uploader: uploader)
        fillIn(form)

        await form.setPhoto(jpeg: Data([1, 2, 3]))

        XCTAssertEqual(form.photoMessage, "Couldn't upload the photo. You can add one later.")
        XCTAssertNil(form.photoUrl)
        XCTAssertEqual(test.api.photoKeys, [], "No key is attached when the upload failed")
        XCTAssertNil(form.errorMessage)

        // The rest of the profile still saves.
        let saved = await form.save()
        XCTAssertTrue(saved)
    }

    func testUploadsSwitchedOffShowsTheServersMessage() async {
        let uploader = StubUploader()
        uploader.result = .failure(
            Fixture.serverError(
                503,
                "uploads_unavailable",
                "Photo uploads aren't available right now. You can add a photo later."
            )
        )
        let form = makeForm(test: TestSession(), uploader: uploader)

        await form.setPhoto(jpeg: Data([1]))

        XCTAssertEqual(
            form.photoMessage,
            "Photo uploads aren't available right now. You can add a photo later."
        )
    }

    func testAPhotoThatUploadedButCouldNotBeAttachedIsReported() async {
        let test = TestSession()
        test.api.setPhotoResult = .failure(APIError.unreachable)
        let form = makeForm(test: test)

        await form.setPhoto(jpeg: Data([1]))

        XCTAssertEqual(form.photoMessage, PhotoUploader.failureMessage)
        XCTAssertNil(form.photoUrl)
    }

    func testRemovingThePhotoSendsNull() async {
        let test = TestSession()
        var withPhoto = Fixture.completeUser
        withPhoto.photoUrl = "https://photos.example.test/a.jpg"
        test.api.setPhotoResult = .success(Fixture.completeUser)
        let form = makeForm(user: withPhoto, test: test)

        await form.removePhoto()

        XCTAssertEqual(test.api.photoKeys, [nil])
        XCTAssertNil(form.photoUrl)
    }

    func testAnUnreadableFileIsReported() {
        let form = makeForm(test: TestSession())

        form.photoCouldNotBeRead()

        XCTAssertEqual(form.photoMessage, "That photo couldn't be read. Try a different one.")
    }
}
