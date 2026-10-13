import Foundation
import Observation

/// The Matches tab: matches on each side, and the renter's saved listings.
@MainActor
@Observable
final class MatchesModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var matches: [Match] = []
    private(set) var saved: [Listing] = []
    private(set) var state: LoadState = .idle
    private(set) var message: String?

    private let api: DeckAPI

    init(api: DeckAPI) {
        self.api = api
    }

    private var userID: String?

    /// Forgets another account's matches.
    func prepare(for userID: String) {
        guard userID != self.userID else {
            return
        }
        self.userID = userID
        matches = []
        saved = []
        state = .idle
    }

    func matches(as role: SwipeSide) -> [Match] {
        matches.filter { $0.role == role }
    }

    func load() async {
        guard state != .loading else {
            return
        }
        state = .loading
        do {
            async let matchPage = api.matches()
            async let savedPage = api.saved()
            matches = try await matchPage.items
            saved = try await savedPage.items
            state = .loaded
        } catch let error as APIError where error == .cancelled {
            state = .idle
        } catch {
            // Offline: whatever was loaded stays shown.
            state = .failed((error as? APIError)?.userMessage ?? APIError.unreachable.userMessage)
        }
    }

    /// Puts a saved listing back in the deck.
    func unsave(_ listing: Listing) async {
        message = nil
        do {
            try await api.unsave(listingID: listing.id)
            saved.removeAll { $0.id == listing.id }
        } catch {
            message = (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
        }
    }

    /// Shows a match made a moment ago, before the next reload.
    func show(_ match: Match) {
        matches.removeAll { $0.id == match.id }
        matches.insert(match, at: 0)
    }
}
