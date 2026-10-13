import Foundation

/// One listing in a renter's deck, with how well it fits and why.
/// The deck screens arrive in phase 5; the server side is phase 4.
struct DeckItem: Decodable, Equatable, Identifiable {
    /// As any renter sees it: the public point, never the exact address.
    let listing: Listing
    /// 0 to 100.
    let score: Int
    /// Three or four short sentences, such as "Fits your dates".
    let reasons: [String]
    /// From the renter's pin to the listing's public point.
    let distanceM: Int

    var id: String { listing.id }
}

struct DeckPage: Decodable, Equatable {
    let items: [DeckItem]
}

/// Something that keeps listings out of the deck.
struct DeckBlocker: Decodable, Equatable {
    enum Kind: String, Decodable {
        case mustHave = "must_have"
        case listerFilter = "lister_filter"
        case area
    }

    let field: String
    let kind: Kind
    let removed: Int
    /// A sentence to show as is, such as "3 listings don't have parking."
    let message: String
}

/// Why a deck is short.
struct DeckDiagnostics: Decodable, Equatable {
    let inArea: Int
    let eligible: Int
    /// The must-have that keeps out the most listings, or the radius when
    /// nothing is in the area.
    let topMustHave: DeckBlocker?
    let blockers: [DeckBlocker]
}

protocol DeckAPI: Sendable {
    func deck(limit: Int) async throws -> DeckPage
    func diagnostics() async throws -> DeckDiagnostics
}

struct LiveDeckAPI: DeckAPI {
    let client: APIClient

    func deck(limit: Int) async throws -> DeckPage {
        try await client.send(.deckListings(limit: limit))
    }

    func diagnostics() async throws -> DeckDiagnostics {
        try await client.send(.deckDiagnostics)
    }
}
