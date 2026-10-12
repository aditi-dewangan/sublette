import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// One server endpoint. Every path the app calls is declared in this file and
/// nowhere else, and is checked against docs/contract/endpoints.json.
struct Endpoint: Equatable {
    let method: HTTPMethod
    let path: String
    /// Every endpoint except health and sign-in needs a verified account.
    var requiresAuth: Bool = true
}

extension Endpoint {
    static let health = Endpoint(method: .get, path: "/health", requiresAuth: false)

    // Sign-in. These three are the only /v1 endpoints that need no account.
    static let requestCode = Endpoint(method: .post, path: "/v1/auth/request-code", requiresAuth: false)
    static let verifyCode = Endpoint(method: .post, path: "/v1/auth/verify", requiresAuth: false)
    static let refreshTokens = Endpoint(method: .post, path: "/v1/auth/refresh", requiresAuth: false)

    // The signed-in user's own account.
    static let me = Endpoint(method: .get, path: "/v1/me")
    static let updateMe = Endpoint(method: .patch, path: "/v1/me")
    static let deleteMe = Endpoint(method: .delete, path: "/v1/me")

    static let presignUpload = Endpoint(method: .post, path: "/v1/uploads/presign")
}
