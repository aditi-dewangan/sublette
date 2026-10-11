import Foundation

/// Supplies the access token for the `Authorization` header.
///
/// Phase 1 adds the real implementation, backed by the Keychain.
protocol AccessTokenProviding: Sendable {
    func accessToken() async -> String?
}

/// Used until sign-in exists: there is never a token.
struct NoAccessToken: AccessTokenProviding {
    func accessToken() async -> String? { nil }
}
