import XCTest
@testable import Sublette

final class APIClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.example.test")!

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient(
        baseURL: URL? = nil,
        tokens: AccessTokenProviding = NoAccessToken()
    ) -> APIClient {
        APIClient(
            baseURL: baseURL ?? self.baseURL,
            session: StubURLProtocol.makeSession(),
            tokens: tokens
        )
    }

    private let healthyJSON = """
        {"status": "ok", "version": "0.1.0", "environment": "staging",
         "database": {"reachable": true, "postgis": "3.4.2"}}
        """

    // MARK: - Success

    func testHealthDecodesTheServerResponse() async throws {
        StubURLProtocol.respond(status: 200, json: healthyJSON)

        let status = try await makeClient().health()

        XCTAssertEqual(status.status, "ok")
        XCTAssertEqual(status.version, "0.1.0")
        XCTAssertEqual(status.environment, "staging")
        XCTAssertTrue(status.database.reachable)
        XCTAssertEqual(status.database.postgis, "3.4.2")
    }

    func testHealthRequestGoesToTheHealthPath() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(self.healthyJSON.utf8))
        }

        _ = try await makeClient().health()

        XCTAssertEqual(seen?.url?.absoluteString, "https://api.example.test/health")
        XCTAssertEqual(seen?.httpMethod, "GET")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testBaseURLWithTrailingSlashDoesNotDoubleTheSlash() {
        let client = makeClient(baseURL: URL(string: "https://api.example.test/"))

        XCTAssertEqual(
            client.url(for: .health)?.absoluteString,
            "https://api.example.test/health"
        )
    }

    func testSnakeCaseKeysAreDecoded() async throws {
        struct Listing: Decodable, Equatable {
            let rentCents: Int
            let startDate: String
        }
        StubURLProtocol.respond(status: 200, json: #"{"rent_cents": 120000, "start_date": "2027-01-04"}"#)

        let listing: Listing = try await makeClient().send(
            Endpoint(method: .get, path: "/v1/test")
        )

        XCTAssertEqual(listing, Listing(rentCents: 120_000, startDate: "2027-01-04"))
    }

    // MARK: - Server errors use the {code, message} shape

    func testServerErrorCarriesCodeAndMessage() async {
        StubURLProtocol.respond(
            status: 403,
            json: #"{"code": "forbidden", "message": "Only the owner can see this."}"#
        )

        await assertThrows(
            .server(status: 403, code: "forbidden", message: "Only the owner can see this.", fields: [])
        ) {
            _ = try await self.makeClient().health()
        }
    }

    func testValidationErrorCarriesFieldMessages() async {
        StubURLProtocol.respond(
            status: 422,
            json: """
                {"code": "validation_error", "message": "Some fields are missing or invalid.",
                 "fields": [{"field": "rent_cents", "message": "Input should be greater than 0"}]}
                """
        )

        await assertThrows(
            .server(
                status: 422,
                code: "validation_error",
                message: "Some fields are missing or invalid.",
                fields: [.init(field: "rent_cents", message: "Input should be greater than 0")]
            )
        ) {
            _ = try await self.makeClient().health()
        }
    }

    func testDatabaseDownHealthSurfacesTheServerMessage() async {
        StubURLProtocol.respond(
            status: 503,
            json: """
                {"status": "degraded", "version": "0.1.0", "environment": "staging",
                 "database": {"reachable": false},
                 "code": "database_unreachable",
                 "message": "The server is running but cannot reach its database."}
                """
        )

        await assertThrows(
            .server(
                status: 503,
                code: "database_unreachable",
                message: "The server is running but cannot reach its database.",
                fields: []
            )
        ) {
            _ = try await self.makeClient().health()
        }
    }

    func testErrorPageThatIsNotJSONStillBecomesAServerError() async {
        StubURLProtocol.respond(status: 502, json: "<html><body>Bad Gateway</body></html>")

        await assertThrows(
            .server(
                status: 502,
                code: "http_502",
                message: "The server had a problem (502). Please try again.",
                fields: []
            )
        ) {
            _ = try await self.makeClient().health()
        }
    }

    func testSuccessWithAnUnexpectedBodyIsADecodingError() async {
        StubURLProtocol.respond(status: 200, json: #"{"hello": "world"}"#)

        await assertThrows(.decoding) {
            _ = try await self.makeClient().health()
        }
    }

    // MARK: - Dependency unavailable: the server

    func testServerDownBecomesUnreachable() async {
        StubURLProtocol.fail(with: .cannotConnectToHost)

        await assertThrows(.unreachable) {
            _ = try await self.makeClient().health()
        }
    }

    func testPhoneOfflineBecomesUnreachable() async {
        StubURLProtocol.fail(with: .notConnectedToInternet)

        await assertThrows(.unreachable) {
            _ = try await self.makeClient().health()
        }
    }

    func testTimeoutBecomesUnreachable() async {
        StubURLProtocol.fail(with: .timedOut)

        await assertThrows(.unreachable) {
            _ = try await self.makeClient().health()
        }
    }

    func testHostThatDoesNotExistBecomesUnreachable() async {
        StubURLProtocol.fail(with: .cannotFindHost)

        await assertThrows(.unreachable) {
            _ = try await self.makeClient().health()
        }
    }

    // MARK: - Auth header

    func testTokenIsSentWhenTheEndpointRequiresAuth() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }
        struct Empty: Decodable {}

        let _: Empty = try await makeClient(tokens: FixedToken(value: "abc123")).send(
            Endpoint(method: .get, path: "/v1/me")
        )

        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
    }

    func testTokenIsNotSentToAPublicEndpoint() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(self.healthyJSON.utf8))
        }

        _ = try await makeClient(tokens: FixedToken(value: "abc123")).health()

        XCTAssertNotNil(seen)
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
    }

    func testNoHeaderWhenThereIsNoToken() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }
        struct Empty: Decodable {}

        let _: Empty = try await makeClient().send(Endpoint(method: .get, path: "/v1/me"))

        XCTAssertNotNil(seen)
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: APIError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: () async throws -> Void
    ) async {
        do {
            try await work()
            XCTFail("Expected \(expected), but nothing was thrown", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private struct FixedToken: AccessTokenProviding {
    let value: String

    func accessToken() async -> String? { value }
}
