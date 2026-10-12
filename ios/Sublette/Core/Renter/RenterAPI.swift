import Foundation

/// Renter mode on the server. A protocol so screens can be tested without one.
protocol RenterAPI: Sendable {
    func renterProfile() async throws -> RenterProfile
    func saveRenterProfile(_ form: RenterProfileForm) async throws -> RenterProfile
}

struct LiveRenterAPI: RenterAPI {
    let client: APIClient

    func renterProfile() async throws -> RenterProfile {
        try await client.send(.renterProfile)
    }

    func saveRenterProfile(_ form: RenterProfileForm) async throws -> RenterProfile {
        try await client.send(.saveRenterProfile, body: form)
    }
}
