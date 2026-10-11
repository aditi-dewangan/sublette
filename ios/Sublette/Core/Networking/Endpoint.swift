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
}
