import XCTest
@testable import Sublette

/// A token source the test controls.
private final class ScriptedTokens: AccessTokenProviding, @unchecked Sendable {
    var current: String?
    var replacement: String?
    private(set) var rejected: [String] = []

    init(current: String?, replacement: String?) {
        self.current = current
        self.replacement = replacement
    }

    func accessToken() async -> String? {
        current
    }

    func refreshedAccessToken(afterRejecting rejected: String) async -> String? {
        self.rejected.append(rejected)
        current = replacement
        return replacement
    }
}

/// What the client does when the server rejects the access token.
final class AuthorizedRequestTests: XCTestCase {
    private struct Empty: Decodable {}

    private let expiredJSON = #"{"code": "token_expired", "message": "Your session has expired. Please sign in again."}"#

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient(_ tokens: AccessTokenProviding) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.test")!,
            session: StubURLProtocol.makeSession(),
            tokens: tokens
        )
    }

    private func response(_ request: URLRequest, _ status: Int, _ json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (response, Data(json.utf8))
    }

    func testARejectedTokenIsRefreshedAndTheRequestIsSentAgain() async throws {
        let tokens = ScriptedTokens(current: "old", replacement: "new")
        var seen: [String?] = []
        StubURLProtocol.handler = { request in
            let header = request.value(forHTTPHeaderField: "Authorization")
            seen.append(header)
            if header == "Bearer new" {
                return self.response(request, 200, "{}")
            }
            return self.response(request, 401, self.expiredJSON)
        }

        let _: Empty = try await makeClient(tokens).send(.me)

        XCTAssertEqual(seen, ["Bearer old", "Bearer new"])
        XCTAssertEqual(tokens.rejected, ["old"])
    }

    func testWithNoNewerTokenThe401IsReported() async {
        let tokens = ScriptedTokens(current: "old", replacement: nil)
        var requests = 0
        StubURLProtocol.handler = { request in
            requests += 1
            return self.response(request, 401, self.expiredJSON)
        }

        do {
            let _: Empty = try await makeClient(tokens).send(.me)
            XCTFail("Expected a 401")
        } catch {
            XCTAssertEqual((error as? APIError)?.status, 401)
            XCTAssertEqual((error as? APIError)?.serverCode, "token_expired")
        }
        XCTAssertEqual(requests, 1)
    }

    func testTheRequestIsRetriedOnlyOnce() async {
        let tokens = ScriptedTokens(current: "old", replacement: "also-rejected")
        var requests = 0
        StubURLProtocol.handler = { request in
            requests += 1
            return self.response(request, 401, self.expiredJSON)
        }

        do {
            let _: Empty = try await makeClient(tokens).send(.me)
            XCTFail("Expected a 401")
        } catch {
            XCTAssertEqual((error as? APIError)?.status, 401)
        }
        XCTAssertEqual(requests, 2, "One retry, then give up; never a loop")
        XCTAssertEqual(tokens.rejected, ["old"])
    }

    func testSignInEndpointsNeverTriggerARefresh() async {
        let tokens = ScriptedTokens(current: "old", replacement: "new")
        var headers: [String?] = []
        StubURLProtocol.handler = { request in
            headers.append(request.value(forHTTPHeaderField: "Authorization"))
            return self.response(request, 401, self.expiredJSON)
        }

        do {
            let _: Empty = try await makeClient(tokens).send(.requestCode)
            XCTFail("Expected a 401")
        } catch {
            XCTAssertEqual((error as? APIError)?.status, 401)
        }
        XCTAssertEqual(headers, [nil], "No token is sent to a sign-in endpoint")
        XCTAssertEqual(tokens.rejected, [])
    }

    func testServerDownIsNotMistakenForARejectedToken() async {
        let tokens = ScriptedTokens(current: "old", replacement: "new")
        StubURLProtocol.fail(with: .cannotConnectToHost)

        do {
            let _: Empty = try await makeClient(tokens).send(.me)
            XCTFail("Expected unreachable")
        } catch {
            XCTAssertEqual(error as? APIError, .unreachable)
        }
        XCTAssertEqual(tokens.rejected, [], "Being offline must not use up or replace the token")
    }

    func testNoContentRequestSucceedsOnAnEmpty204() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return self.response(request, 204, "")
        }

        try await makeClient(ScriptedTokens(current: "old", replacement: nil)).sendNoContent(.deleteMe)

        XCTAssertEqual(seen?.httpMethod, "DELETE")
        XCTAssertEqual(seen?.url?.path, "/v1/me")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer old")
    }

    func testNoContentRequestStillReportsServerErrors() async {
        StubURLProtocol.respond(
            status: 503,
            json: #"{"code": "service_unavailable", "message": "Sublette is having trouble right now. Try again in a minute."}"#
        )

        do {
            try await makeClient(ScriptedTokens(current: "old", replacement: nil)).sendNoContent(.deleteMe)
            XCTFail("Expected a 503")
        } catch {
            XCTAssertEqual((error as? APIError)?.serverCode, "service_unavailable")
            XCTAssertEqual(
                (error as? APIError)?.userMessage,
                "Sublette is having trouble right now. Try again in a minute."
            )
        }
    }

    func testARequestWithABodyIsSentAsJSON() async throws {
        struct Body: Encodable {
            let refreshToken: String
        }
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return self.response(request, 200, "{}")
        }

        let _: Empty = try await makeClient(NoAccessToken()).send(
            .refreshTokens, body: Body(refreshToken: "r")
        )

        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.path, "/v1/auth/refresh")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testFieldMessagesAreKeyedByTheServersFieldNames() {
        let error = APIError.server(
            status: 422,
            code: "validation_error",
            message: "Some fields are missing or invalid.",
            fields: [
                .init(field: "first_name", message: "This can't be empty."),
                .init(field: "first_name", message: "A second message for the same field."),
                .init(field: "year", message: "Choose one of the options."),
            ]
        )

        XCTAssertEqual(
            error.fieldMessages,
            ["first_name": "This can't be empty.", "year": "Choose one of the options."]
        )
        XCTAssertEqual(APIError.unreachable.fieldMessages, [:])
        XCTAssertNil(APIError.unreachable.status)
        XCTAssertNil(APIError.decoding.serverCode)
    }
}

/// Uploading a photo straight to storage with a presigned link.
final class PhotoUploaderTests: XCTestCase {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeUploader(_ api: StubAccountAPI) -> PhotoUploader {
        PhotoUploader(api: api, session: StubURLProtocol.makeSession())
    }

    func testThePhotoIsPutToTheLinkWithItsHeaders() async throws {
        let api = StubAccountAPI()
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let key = try await makeUploader(api).uploadProfilePhoto(jpeg)

        XCTAssertEqual(key, "profiles/user-1/abc.jpg")
        XCTAssertEqual(seen?.httpMethod, "PUT")
        XCTAssertEqual(seen?.url?.absoluteString, Fixture.presign.uploadUrl)
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"), "Storage never sees the student's token")
    }

    // MARK: - Dependency unavailable: photo storage

    func testUploadsSwitchedOffOnTheServerIsReportedAndNothingIsSent() async {
        let api = StubAccountAPI()
        let unavailable = Fixture.serverError(
            503,
            "uploads_unavailable",
            "Photo uploads aren't available right now. You can add a photo later."
        )
        api.presignResult = .failure(unavailable)
        var requests = 0
        StubURLProtocol.handler = { _ in
            requests += 1
            throw URLError(.unknown)
        }

        do {
            _ = try await makeUploader(api).uploadProfilePhoto(jpeg)
            XCTFail("Expected the upload to fail")
        } catch {
            XCTAssertEqual(error as? APIError, unavailable)
        }
        XCTAssertEqual(requests, 0)
    }

    func testStorageUnreachableBecomesUnreachable() async {
        StubURLProtocol.fail(with: .cannotConnectToHost)

        do {
            _ = try await makeUploader(StubAccountAPI()).uploadProfilePhoto(jpeg)
            XCTFail("Expected the upload to fail")
        } catch {
            XCTAssertEqual(error as? APIError, .unreachable)
        }
    }

    func testStorageRefusingTheUploadIsReported() async {
        StubURLProtocol.respond(status: 403, json: "<Error>SignatureDoesNotMatch</Error>")

        do {
            _ = try await makeUploader(StubAccountAPI()).uploadProfilePhoto(jpeg)
            XCTFail("Expected the upload to fail")
        } catch {
            XCTAssertEqual((error as? APIError)?.status, 403)
            XCTAssertEqual((error as? APIError)?.serverCode, "upload_failed")
            XCTAssertEqual((error as? APIError)?.userMessage, PhotoUploader.failureMessage)
        }
    }

    func testAPhotoOverTheLimitIsNotSent() async {
        let api = StubAccountAPI()
        api.presignResult = .success(
            PresignedUpload(
                key: "k",
                uploadUrl: "https://storage.example.test/k",
                method: "PUT",
                headers: [:],
                publicUrl: "https://photos.example.test/k",
                maxBytes: 3
            )
        )
        var requests = 0
        StubURLProtocol.handler = { _ in
            requests += 1
            throw URLError(.unknown)
        }

        do {
            _ = try await makeUploader(api).uploadProfilePhoto(jpeg)
            XCTFail("Expected the upload to fail")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidRequest)
        }
        XCTAssertEqual(requests, 0)
    }
}
