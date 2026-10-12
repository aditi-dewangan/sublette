import Foundation

// MARK: - What the server sends

struct CodeRequestResponse: Decodable, Equatable {
    /// Seconds until the code stops working.
    let expiresIn: Int
    /// Seconds before another code can be requested.
    let resendIn: Int
}

struct TokenResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String
    /// Seconds until the access token expires.
    let expiresIn: Int
}

struct SessionResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: User
}

struct PresignedUpload: Decodable, Equatable {
    /// Sent back to the server once the upload has finished.
    let key: String
    let uploadUrl: String
    let method: String
    let headers: [String: String]
    let publicUrl: String
    let maxBytes: Int
}

// MARK: - What the app sends

private struct RequestCodeBody: Encodable {
    let email: String
}

private struct VerifyBody: Encodable {
    let email: String
    let code: String
}

private struct RefreshBody: Encodable {
    let refreshToken: String
}

private struct PresignBody: Encodable {
    let purpose: String
    let contentType: String
}

/// Every editable profile answer. All of them are sent on every save, so an
/// optional answer that was cleared goes to the server as an explicit `null`.
struct ProfileUpdate: Encodable, Equatable {
    var firstName: String
    var year: Year
    var program: String
    var bio: String?
    var gender: Gender?
    var smokes: Bool
    var hasPets: Bool

    private enum CodingKeys: String, CodingKey {
        case firstName, year, program, bio, gender, smokes, hasPets
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(year, forKey: .year)
        try container.encode(program, forKey: .program)
        // Unlike the synthesized version, these write `null` when there is no value.
        try container.encode(bio, forKey: .bio)
        try container.encode(gender, forKey: .gender)
        try container.encode(smokes, forKey: .smokes)
        try container.encode(hasPets, forKey: .hasPets)
    }
}

struct PhotoKeyUpdate: Encodable, Equatable {
    /// The uploaded photo's key, or nil to remove the photo.
    var photoKey: String?

    private enum CodingKeys: String, CodingKey {
        case photoKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(photoKey, forKey: .photoKey)
    }
}

// MARK: - The account calls

/// Everything the app asks the server about accounts. A protocol so that
/// screens can be tested, and previewed, without a server.
protocol AccountAPI: Sendable {
    func requestCode(email: String) async throws -> CodeRequestResponse
    func verify(email: String, code: String) async throws -> SessionResponse
    func me() async throws -> User
    func updateProfile(_ update: ProfileUpdate) async throws -> User
    func setPhoto(key: String?) async throws -> User
    func deleteAccount() async throws
    func presignProfilePhoto(contentType: String) async throws -> PresignedUpload
    func presignListingPhoto(contentType: String) async throws -> PresignedUpload
}

/// Trades a refresh token for new tokens.
protocol TokenRefreshing: Sendable {
    func refresh(using refreshToken: String) async throws -> TokenResponse
}

struct LiveAccountAPI: AccountAPI, TokenRefreshing {
    /// Sends no token. Used for sign-in, before there is one.
    let openClient: APIClient
    /// Sends the signed-in student's token.
    let signedInClient: APIClient

    func requestCode(email: String) async throws -> CodeRequestResponse {
        try await openClient.send(.requestCode, body: RequestCodeBody(email: email))
    }

    func verify(email: String, code: String) async throws -> SessionResponse {
        try await openClient.send(.verifyCode, body: VerifyBody(email: email, code: code))
    }

    func refresh(using refreshToken: String) async throws -> TokenResponse {
        try await openClient.send(.refreshTokens, body: RefreshBody(refreshToken: refreshToken))
    }

    func me() async throws -> User {
        try await signedInClient.send(.me)
    }

    func updateProfile(_ update: ProfileUpdate) async throws -> User {
        try await signedInClient.send(.updateMe, body: update)
    }

    func setPhoto(key: String?) async throws -> User {
        try await signedInClient.send(.updateMe, body: PhotoKeyUpdate(photoKey: key))
    }

    func deleteAccount() async throws {
        try await signedInClient.sendNoContent(.deleteMe)
    }

    func presignProfilePhoto(contentType: String) async throws -> PresignedUpload {
        try await signedInClient.send(
            .presignUpload,
            body: PresignBody(purpose: "profile_photo", contentType: contentType)
        )
    }

    func presignListingPhoto(contentType: String) async throws -> PresignedUpload {
        try await signedInClient.send(
            .presignUpload,
            body: PresignBody(purpose: "listing_photo", contentType: contentType)
        )
    }
}
