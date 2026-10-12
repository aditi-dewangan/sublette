import Foundation

/// Everything that can go wrong with a request, in terms the screens can show.
enum APIError: Error, Equatable {
    /// No answer: the phone is offline, the server is down, or the request timed out.
    case unreachable
    /// The server answered with an error in its `{code, message}` shape.
    case server(status: Int, code: String, message: String, fields: [FieldError])
    /// The server answered 2xx but the body was not what the app expected.
    case decoding
    /// The request could not be built.
    case invalidRequest
    /// The task was cancelled, usually because the screen went away.
    case cancelled

    struct FieldError: Decodable, Equatable {
        let field: String
        let message: String
    }

    /// A sentence that is safe to show to the user.
    var userMessage: String {
        switch self {
        case .unreachable:
            return "Can't reach Sublette right now. Check your connection and try again."
        case .server(_, _, let message, _):
            return message
        case .decoding, .invalidRequest:
            return "Something went wrong. Please update the app or try again."
        case .cancelled:
            return ""
        }
    }
}

extension APIError {
    /// The server's own error code, such as `code_expired`. Nil for other failures.
    var serverCode: String? {
        if case .server(_, let code, _, _) = self {
            return code
        }
        return nil
    }

    /// The HTTP status, when the server answered.
    var status: Int? {
        if case .server(let status, _, _, _) = self {
            return status
        }
        return nil
    }

    /// Messages keyed by the server's field name, such as `first_name`.
    var fieldMessages: [String: String] {
        guard case .server(_, _, _, let fields) = self else {
            return [:]
        }
        return Dictionary(fields.map { ($0.field, $0.message) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The server's error body: `{"code": "...", "message": "...", "fields": [...]}`.
struct APIErrorBody: Decodable {
    let code: String
    let message: String
    let fields: [APIError.FieldError]?
}
