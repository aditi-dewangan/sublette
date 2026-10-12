import Foundation

private struct StatusBody: Encodable {
    let status: String
}

/// Lister mode on the server. A protocol so screens can be tested without one.
protocol ListingsAPI: Sendable {
    func myListings(cursor: String?) async throws -> ListingPage
    func listing(id: String) async throws -> Listing
    func create(_ form: ListingForm) async throws -> Listing
    func update(id: String, _ form: ListingForm) async throws -> Listing
    func setStatus(id: String, _ status: ListingStatus) async throws -> Listing
}

struct LiveListingsAPI: ListingsAPI {
    let client: APIClient

    func myListings(cursor: String?) async throws -> ListingPage {
        try await client.send(.myListings(cursor: cursor))
    }

    func listing(id: String) async throws -> Listing {
        try await client.send(.listing(id))
    }

    func create(_ form: ListingForm) async throws -> Listing {
        try await client.send(.createListing, body: form)
    }

    func update(id: String, _ form: ListingForm) async throws -> Listing {
        try await client.send(.updateListing(id), body: form)
    }

    func setStatus(id: String, _ status: ListingStatus) async throws -> Listing {
        try await client.send(.listingStatus(id), body: StatusBody(status: status.rawValue))
    }
}
