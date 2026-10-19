import Foundation
import Observation

/// The Matches tab: matches on each side with their chats, and the renter's
/// saved listings. Live events keep it current while the app is open.
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
    /// The chat on screen, which gets this chat's live events too.
    private(set) var activeChat: ChatModel?

    private let api: DeckAPI
    private let chatAPI: ChatAPI
    private let preferences: Preferences

    init(api: DeckAPI, chatAPI: ChatAPI, preferences: Preferences) {
        self.api = api
        self.chatAPI = chatAPI
        self.preferences = preferences
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
        activeChat = nil
        state = .idle
    }

    func matches(as role: SwipeSide) -> [Match] {
        matches.filter { $0.role == role }
    }

    /// For the badge on the Matches tab.
    func unreadCount(as role: SwipeSide) -> Int {
        matches(as: role).reduce(0) { $0 + $1.unreadCount }
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
        upsert(match, toTop: true)
    }

    /// Something arrived over the live connection.
    func handle(_ event: LiveEvent) {
        switch event {
        case .ready:
            Task { await load() }
        case .message(_, let match):
            upsert(match, toTop: true)
        case .match(let match, _):
            upsert(match, toTop: false)
        case .unknown:
            break
        }
        activeChat?.receive(event)
    }

    /// The chat for `match`, which becomes the one on screen.
    func openChat(_ match: Match) -> ChatModel {
        if let activeChat, activeChat.match.id == match.id {
            return activeChat
        }
        let chat = ChatModel(match: match, api: chatAPI, preferences: preferences, userID: userID ?? "")
        chat.onMatchChanged = { [weak self] changed in
            self?.upsert(changed, toTop: false)
        }
        activeChat = chat
        return chat
    }

    func closeChat(_ chat: ChatModel) {
        if activeChat === chat {
            activeChat = nil
        }
    }

    /// A match by id, from the list or else from the server (a notification
    /// can name a match this phone hasn't loaded yet).
    func match(id: String) async -> Match? {
        if let known = matches.first(where: { $0.id == id }) {
            return known
        }
        do {
            let fetched = try await chatAPI.match(id: id)
            upsert(fetched, toTop: true)
            return fetched
        } catch {
            message = (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
            return nil
        }
    }

    private func upsert(_ match: Match, toTop: Bool) {
        if let index = matches.firstIndex(where: { $0.id == match.id }) {
            if toTop {
                matches.remove(at: index)
                matches.insert(match, at: 0)
            } else {
                matches[index] = match
            }
        } else {
            matches.insert(match, at: 0)
        }
    }
}
