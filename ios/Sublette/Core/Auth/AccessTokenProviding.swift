import Foundation

/// Supplies the access token for the `Authorization` header.
protocol AccessTokenProviding: Sendable {
    /// The token to send, refreshed first if it is about to expire. Nil when signed out.
    func accessToken() async -> String?

    /// Called when the server answered 401 to a request that carried `rejected`.
    /// Returns a newer token to retry with, or nil if there is none.
    func refreshedAccessToken(afterRejecting rejected: String) async -> String?

    /// Called when the server answered 403 `account_suspended`. `message`
    /// says why and how to appeal.
    func accountSuspended(message: String) async
}

extension AccessTokenProviding {
    func refreshedAccessToken(afterRejecting rejected: String) async -> String? { nil }
    func accountSuspended(message: String) async {}
}

/// For requests made while signed out: there is never a token.
struct NoAccessToken: AccessTokenProviding {
    func accessToken() async -> String? { nil }
}
