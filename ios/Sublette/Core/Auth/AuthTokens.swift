import Foundation

/// The signed-in student's tokens, as kept in the Keychain.
struct AuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accessTokenExpiresAt: Date

    init(accessToken: String, refreshToken: String, accessTokenExpiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }

    init(accessToken: String, refreshToken: String, expiresIn: Int, now: Date) {
        self.init(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(expiresIn))
        )
    }
}
