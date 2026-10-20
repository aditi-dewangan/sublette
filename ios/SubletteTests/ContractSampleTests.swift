import XCTest
@testable import Sublette

/// Decodes the real server responses in docs/contract/samples.
///
/// The server's own tests keep those files equal to what it sends. If a field
/// is renamed or retyped there, the sample changes and these tests fail until
/// the Swift model follows.
final class ContractSampleTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testSessionForANewUser() throws {
        let session = try decoder.decode(
            SessionResponse.self, from: Fixture.sample("session_new_user")
        )

        XCTAssertEqual(session.accessToken, "sample.access_token")
        XCTAssertEqual(session.refreshToken, "sample.refresh_token")
        XCTAssertEqual(session.expiresIn, 900)
        XCTAssertEqual(session.user.email, "aditi@uw.edu")
        XCTAssertEqual(session.user.school.name, "University of Washington")
        XCTAssertTrue(session.user.verified)
        XCTAssertFalse(session.user.profileComplete)
        XCTAssertNil(session.user.firstName)
        XCTAssertNil(session.user.year)
        XCTAssertNil(session.user.smokes)
        XCTAssertNil(session.user.photoUrl)
    }

    func testUserWithACompleteProfile() throws {
        let user = try decoder.decode(User.self, from: Fixture.sample("user_complete"))

        XCTAssertEqual(user.firstName, "Aditi")
        XCTAssertEqual(user.year, .junior)
        XCTAssertEqual(user.program, "Informatics")
        XCTAssertEqual(user.bio, "Winter internship in Austin. Tidy, quiet, plant person.")
        XCTAssertEqual(user.gender, .woman)
        XCTAssertEqual(user.smokes, false)
        XCTAssertEqual(user.hasPets, false)
        XCTAssertTrue(user.profileComplete)
        XCTAssertEqual(user.photoUrl?.hasSuffix(".jpg"), true)
    }

    func testEveryYearAndGenderTheServerAllowsIsKnownToTheApp() {
        // Matches `Year` and `Gender` in backend/app/schemas/user.py.
        XCTAssertEqual(
            Year.allCases.map(\.rawValue),
            ["freshman", "sophomore", "junior", "senior", "graduate", "other"]
        )
        XCTAssertEqual(Gender.allCases.map(\.rawValue), ["woman", "man", "nonbinary"])
    }

    func testTokens() throws {
        let tokens = try decoder.decode(TokenResponse.self, from: Fixture.sample("tokens"))

        XCTAssertEqual(
            tokens,
            TokenResponse(
                accessToken: "sample.access_token",
                refreshToken: "sample.refresh_token",
                expiresIn: 900
            )
        )
    }

    func testRequestCode() throws {
        let response = try decoder.decode(
            CodeRequestResponse.self, from: Fixture.sample("request_code")
        )

        XCTAssertEqual(response, CodeRequestResponse(expiresIn: 600, resendIn: 30))
    }

    func testPresignedUpload() throws {
        let upload = try decoder.decode(PresignedUpload.self, from: Fixture.sample("presign"))

        XCTAssertEqual(upload.method, "PUT")
        // Header names must survive decoding untouched.
        XCTAssertEqual(upload.headers, ["Content-Type": "image/jpeg"])
        XCTAssertEqual(upload.maxBytes, 10_485_760)
        XCTAssertTrue(upload.key.hasPrefix("profiles/"))
        XCTAssertNotNil(URL(string: upload.uploadUrl))
        XCTAssertNotNil(URL(string: upload.publicUrl))
    }

    @MainActor
    func testErrors() throws {
        let notEdu = try decoder.decode(APIErrorBody.self, from: Fixture.sample("error_not_edu"))
        XCTAssertEqual(notEdu.code, "not_edu_email")
        XCTAssertEqual(notEdu.message, OnboardingModel.notEduMessage)
        XCTAssertEqual(notEdu.fields?.first?.field, "email")

        let wrongCode = try decoder.decode(
            APIErrorBody.self, from: Fixture.sample("error_code_invalid")
        )
        XCTAssertEqual(wrongCode.code, "code_invalid")
        XCTAssertNil(wrongCode.fields)

        let validation = try decoder.decode(
            APIErrorBody.self, from: Fixture.sample("error_validation")
        )
        XCTAssertEqual(validation.code, "validation_error")
        XCTAssertEqual(validation.fields?.map(\.field), ["first_name", "year"])

        let signedOut = try decoder.decode(
            APIErrorBody.self, from: Fixture.sample("error_not_signed_in")
        )
        XCTAssertEqual(signedOut.code, "not_signed_in")
    }
}

/// What the app sends must be what the server reads.
final class RequestEncodingTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try APIClient.makeEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testProfileUpdateUsesTheServersFieldNames() throws {
        let body = try json(
            ProfileUpdate(
                firstName: "Aditi",
                year: .junior,
                program: "Informatics",
                bio: "Hello",
                gender: .woman,
                smokes: false,
                hasPets: true
            )
        )

        XCTAssertEqual(
            Set(body.keys),
            [
                "first_name", "year", "program", "bio", "gender", "smokes", "has_pets",
                // Lifestyle (issue #20), sent as null when skipped.
                "sleep_schedule", "tidiness", "guests", "home_daytime", "home_vibe",
            ]
        )
        XCTAssertEqual(body["first_name"] as? String, "Aditi")
        XCTAssertEqual(body["year"] as? String, "junior")
        XCTAssertEqual(body["gender"] as? String, "woman")
        XCTAssertEqual(body["smokes"] as? Bool, false)
        XCTAssertEqual(body["has_pets"] as? Bool, true)
    }

    func testClearedOptionalAnswersAreSentAsNull() throws {
        let body = try json(
            ProfileUpdate(
                firstName: "Aditi",
                year: .junior,
                program: "Informatics",
                bio: nil,
                gender: nil,
                smokes: false,
                hasPets: false
            )
        )

        // Present and null, not left out: leaving a field out means "keep it".
        XCTAssertTrue(body["bio"] is NSNull)
        XCTAssertTrue(body["gender"] is NSNull)
    }

    func testPhotoKeyIsSentAndCanBeNull() throws {
        XCTAssertEqual(
            try json(PhotoKeyUpdate(photoKey: "profiles/u/a.jpg"))["photo_key"] as? String,
            "profiles/u/a.jpg"
        )
        XCTAssertTrue(try json(PhotoKeyUpdate(photoKey: nil))["photo_key"] is NSNull)
    }
}
