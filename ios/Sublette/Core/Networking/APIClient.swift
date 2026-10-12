import Foundation

/// Talks to the Sublette server: JSON in snake_case, errors as `{code, message}`.
///
/// All stored properties are immutable after `init`, which is what makes
/// `@unchecked Sendable` safe here.
final class APIClient: @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession
    private let tokens: AccessTokenProviding
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        baseURL: URL,
        session: URLSession = APIClient.makeSession(timeout: AppConfiguration.defaultRequestTimeout),
        tokens: AccessTokenProviding = NoAccessToken()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokens = tokens

        self.decoder = APIClient.makeDecoder()
        self.encoder = APIClient.makeEncoder()
    }

    /// Reads the server's JSON: snake_case keys, times as `2027-01-04T17:00:00Z`.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes JSON the way the server expects it.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A session that gives up after `timeout` seconds, so a server that is
    /// down shows an error instead of a spinner that never ends.
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(30, timeout * 2)
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Sends a request with no body and decodes the answer.
    func send<Response: Decodable>(
        _ endpoint: Endpoint,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await perform(endpoint, body: nil)
        return try decode(data)
    }

    /// Sends a request with a JSON body and decodes the answer.
    func send<Body: Encodable, Response: Decodable>(
        _ endpoint: Endpoint,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let encoded: Data
        do {
            encoded = try encoder.encode(body)
        } catch {
            throw APIError.invalidRequest
        }
        let data = try await perform(endpoint, body: encoded)
        return try decode(data)
    }

    /// Sends a request whose answer has no body worth reading, such as a 204.
    func sendNoContent(_ endpoint: Endpoint) async throws {
        _ = try await perform(endpoint, body: nil)
    }

    func url(for endpoint: Endpoint) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return URL(string: base + endpoint.path)
    }

    // MARK: - Private

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func perform(_ endpoint: Endpoint, body: Data?) async throws -> Data {
        guard let url = url(for: endpoint) else {
            throw APIError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var token: String?
        if endpoint.requiresAuth {
            token = await tokens.accessToken()
        }
        var answer = try await transport(request, token: token)

        // The server rejected the token. Ask once for a newer one and try again.
        if answer.response.statusCode == 401, endpoint.requiresAuth, let rejected = token,
           let fresh = await tokens.refreshedAccessToken(afterRejecting: rejected) {
            answer = try await transport(request, token: fresh)
        }

        guard (200..<300).contains(answer.response.statusCode) else {
            throw serverError(status: answer.response.statusCode, data: answer.data)
        }
        return answer.data
    }

    private func transport(
        _ request: URLRequest,
        token: String?
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = request
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch is CancellationError {
            throw APIError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw APIError.cancelled
        } catch {
            // Offline, DNS failure, connection refused, timeout, TLS failure:
            // to the user these are all "can't reach the server".
            throw APIError.unreachable
        }

        guard let http = result.1 as? HTTPURLResponse else {
            throw APIError.unreachable
        }
        return (result.0, http)
    }

    private func serverError(status: Int, data: Data) -> APIError {
        if let body = try? decoder.decode(APIErrorBody.self, from: data) {
            return .server(
                status: status,
                code: body.code,
                message: body.message,
                fields: body.fields ?? []
            )
        }
        // A proxy or load balancer answered instead of our server (an HTML 502 page, say).
        return .server(
            status: status,
            code: "http_\(status)",
            message: "The server had a problem (\(status)). Please try again.",
            fields: []
        )
    }
}

extension APIClient: HealthChecking {
    func health() async throws -> HealthStatus {
        try await send(.health)
    }
}
