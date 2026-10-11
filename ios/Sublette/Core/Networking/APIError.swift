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

/// The server's error body: `{"code": "...", "message": "...", "fields": [...]}`.
struct APIErrorBody: Decodable {
    let code: String
    let message: String
    let fields: [APIError.FieldError]?
}
