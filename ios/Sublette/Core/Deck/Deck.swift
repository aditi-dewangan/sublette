import Foundation

/// One listing in a renter's deck, with how well it fits and why.
/// The deck screens arrive in phase 5; the server side is phase 4.
struct DeckItem: Decodable, Equatable, Identifiable {
    /// As any renter sees it: the public point, never the exact address.
    let listing: Listing
    /// 0 to 100. Orders the deck and colors the map; never shown as a number.
    let score: Int
    /// strong, partial or other: shown as "Great fit", "Good fit" or nothing.
    let band: ScoreBand
    /// Why it fits, in one or two plain sentences.
    let summary: String
    /// The same, in three or four short pieces, such as "Fits your dates".
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
    /// Listings in the circle already swiped on or saved.
    let seen: Int
    /// The must-have that keeps out the most listings, or the radius when
    /// nothing is in the area.
    let topMustHave: DeckBlocker?
    let blockers: [DeckBlocker]
}

enum SwipeAction: String, Codable, Equatable {
    case like
    case pass
}

/// Which side swiped: a renter on a listing, or a lister on a renter.
enum SwipeSide: String, Codable, Equatable {
    case renter
    case lister
}

/// A like or pass as the server recorded it.
struct Swipe: Decodable, Equatable {
    let id: String
    /// The id the app made up for this swipe.
    let swipeId: String?
    let side: SwipeSide
    let action: SwipeAction
    let listingId: String
    let renterId: String
    let createdAt: Date
}

/// What one side of a match sees about the other.
struct Person: Codable, Equatable {
    let id: String
    let firstName: String?
    let photoUrl: String?
    let schoolName: String
    let verified: Bool
    /// Sublets this person finished through Sublette.
    var completedSublets: Int = 0
}

struct Match: Decodable, Equatable, Identifiable {
    let id: String
    /// The signed-in student's side of this match.
    let role: SwipeSide
    var listing: Listing
    let renter: Person
    let lister: Person
    let createdAt: Date
    /// The steps to a sublet, shared by both people.
    var checklist: Checklist = .empty
    var filled: Filled = .none
    /// Messages from the other person not yet opened.
    var unreadCount: Int = 0
    var lastMessage: ChatMessage?

    /// The person on the other side.
    var other: Person {
        role == .renter ? lister : renter
    }
}

struct SwipeResult: Decodable, Equatable {
    let swipe: Swipe
    /// Set when this swipe made a match (or already had).
    let match: Match?
    /// False when the server already had this exact swipe.
    let created: Bool
}

struct MatchPage: Decodable, Equatable {
    let items: [Match]
}

struct SavedPage: Decodable, Equatable {
    let items: [Listing]
}

/// What a lister sees about a renter who liked their listing. Never the pin.
struct RenterCard: Decodable, Equatable {
    let id: String
    let firstName: String?
    let photoUrl: String?
    let year: Year?
    let program: String?
    let bio: String?
    let schoolName: String
    let verified: Bool
}

struct InterestedRenter: Decodable, Equatable, Identifiable {
    let renter: RenterCard
    let startDate: String
    let endDate: String
    let likedAt: Date
    /// How the renter meets the lister's filters, such as "No pets".
    let fits: [String]

    var id: String { renter.id }
}

struct InterestedRenterPage: Decodable, Equatable {
    let items: [InterestedRenter]
}

/// A swipe as the app sends it. `swipeId` is made up on the phone, so a swipe
/// sent again after a lost answer or a spell offline counts once.
struct SwipeRequest: Codable, Equatable {
    let listingId: String
    var renterId: String?
    let action: SwipeAction
    let swipeId: String
}

private struct UndoRequest: Encodable {
    let swipeId: String
}

protocol DeckAPI: Sendable {
    func deck(limit: Int) async throws -> DeckPage
    func diagnostics() async throws -> DeckDiagnostics
    func swipe(_ request: SwipeRequest) async throws -> SwipeResult
    func undo(swipeID: String) async throws -> Swipe
    func save(listingID: String) async throws
    func unsave(listingID: String) async throws
    func saved() async throws -> SavedPage
    func interestedRenters(listingID: String) async throws -> InterestedRenterPage
    func matches() async throws -> MatchPage
}

struct LiveDeckAPI: DeckAPI {
    let client: APIClient

    func deck(limit: Int) async throws -> DeckPage {
        try await client.send(.deckListings(limit: limit))
    }

    func diagnostics() async throws -> DeckDiagnostics {
        try await client.send(.deckDiagnostics)
    }

    func swipe(_ request: SwipeRequest) async throws -> SwipeResult {
        try await client.send(.swipe, body: request)
    }

    func undo(swipeID: String) async throws -> Swipe {
        try await client.send(.undoSwipe, body: UndoRequest(swipeId: swipeID))
    }

    func save(listingID: String) async throws {
        try await client.sendNoContent(.saveListing(listingID))
    }

    func unsave(listingID: String) async throws {
        try await client.sendNoContent(.unsaveListing(listingID))
    }

    func saved() async throws -> SavedPage {
        try await client.send(.savedListings)
    }

    func interestedRenters(listingID: String) async throws -> InterestedRenterPage {
        try await client.send(.interestedRenters(listingID))
    }

    func matches() async throws -> MatchPage {
        try await client.send(.matches)
    }
}
