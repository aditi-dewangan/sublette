import Foundation
import Observation

/// The renter's card stack: load, swipe, undo, save, and why it's empty.
@MainActor
@Observable
final class RenterDeckModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// Nothing could be loaded. Cards already shown stay shown.
        case failed(String)
        /// The server wants something finished first (profile or search).
        case notReady(String)
    }

    /// A swipe that can still be taken back: the card, and the swipe's id.
    struct Swiped: Equatable {
        let item: DeckItem
        let swipeID: String
    }

    static let pageSize = 20
    /// Fetch more when this few cards are left.
    static let refillAt = 3

    /// The first card is on top.
    private(set) var cards: [DeckItem] = []
    private(set) var state: LoadState = .idle
    private(set) var history: [Swiped] = []
    /// Loaded when the deck is empty.
    private(set) var diagnostics: DeckDiagnostics?
    private(set) var message: String?
    private(set) var isWorking = false

    let outbox: SwipeOutbox
    private let api: DeckAPI
    private let makeSwipeID: () -> String

    init(api: DeckAPI, outbox: SwipeOutbox, makeSwipeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.api = api
        self.outbox = outbox
        self.makeSwipeID = makeSwipeID
    }

    var top: DeckItem? {
        cards.first
    }

    var canUndo: Bool {
        !history.isEmpty && !isWorking
    }

    var isEmpty: Bool {
        cards.isEmpty && state == .loaded
    }

    private var userID: String?

    // MARK: - Loading

    /// Forgets another account's deck.
    func prepare(for userID: String) {
        guard userID != self.userID else {
            return
        }
        self.userID = userID
        cards = []
        history = []
        diagnostics = nil
        message = nil
        state = .idle
    }

    /// Starts again: sends any queued swipes, then loads a fresh deck.
    func reload() async {
        cards = []
        history = []
        diagnostics = nil
        await load()
    }

    func load() async {
        guard state != .loading else {
            return
        }
        state = .loading
        message = nil
        await outbox.flush()
        do {
            let page = try await api.deck(limit: Self.pageSize)
            append(page.items)
            state = .loaded
            if cards.isEmpty {
                await loadDiagnostics()
            }
        } catch let error as APIError where error.status == 409 {
            state = .notReady(error.userMessage)
        } catch let error as APIError where error == .cancelled {
            state = .idle
        } catch {
            state = .failed((error as? APIError)?.userMessage ?? APIError.unreachable.userMessage)
        }
    }

    private func append(_ items: [DeckItem]) {
        // Leave out cards already showing, already swiped here, or swiped
        // offline and not yet known to the server.
        var hidden = Set(cards.map(\.id))
        hidden.formUnion(history.map(\.item.id))
        hidden.formUnion(outbox.pendingListingIDs)
        cards += items.filter { !hidden.contains($0.id) }
    }

    private func refillIfLow() async {
        guard cards.count <= Self.refillAt, state != .loading else {
            return
        }
        do {
            append(try await api.deck(limit: Self.pageSize).items)
        } catch {
            // Offline: keep swiping what is here.
        }
        if cards.isEmpty {
            await loadDiagnostics()
        }
    }

    private func loadDiagnostics() async {
        diagnostics = try? await api.diagnostics()
    }

    // MARK: - Swiping

    func like() async {
        await swipe(.like)
    }

    func pass() async {
        await swipe(.pass)
    }

    private func swipe(_ action: SwipeAction) async {
        guard let card = top else {
            return
        }
        message = nil
        cards.removeFirst()
        let swipeID = makeSwipeID()
        history.append(Swiped(item: card, swipeID: swipeID))
        await outbox.send(SwipeRequest(listingId: card.id, renterId: nil, action: action, swipeId: swipeID))
        if let refused = outbox.message {
            message = refused
            if outbox.refusedSwipeID == swipeID {
                // Nothing was recorded, so there is nothing to undo.
                history.removeAll { $0.swipeID == swipeID }
            }
            outbox.clearMessage()
        }
        await refillIfLow()
    }

    /// Takes back the last swipe and puts its card back on top.
    func undo() async {
        guard let last = history.popLast(), !isWorking else {
            return
        }
        message = nil
        if outbox.cancel(swipeID: last.swipeID) {
            putBack(last.item)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await api.undo(swipeID: last.swipeID)
            putBack(last.item)
        } catch let error as APIError where error.serverCode == "nothing_to_undo" {
            putBack(last.item)
        } catch let error as APIError where error == .unreachable {
            history.append(last)
            message = "Undo needs a connection. Try again in a moment."
        } catch {
            message = (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
        }
    }

    private func putBack(_ item: DeckItem) {
        cards.removeAll { $0.id == item.id }
        cards.insert(item, at: 0)
        diagnostics = nil
    }

    /// Puts the top card aside in Saved. It comes back to the deck if unsaved.
    func save() async {
        guard let card = top, !isWorking else {
            return
        }
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            try await api.save(listingID: card.id)
            cards.removeAll { $0.id == card.id }
            await refillIfLow()
        } catch {
            message = (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
        }
    }
}
