import Foundation
import Observation

/// The lister's deck: pick a listing, then like or pass on the renters who liked it.
@MainActor
@Observable
final class ListerDeckModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct Swiped: Equatable {
        let renter: InterestedRenter
        let swipeID: String
    }

    /// Listings renters can still match with: live or paused.
    private(set) var listings: [Listing] = []
    private(set) var selectedListingID: String?
    /// The first renter is on top.
    private(set) var renters: [InterestedRenter] = []
    private(set) var state: LoadState = .idle
    private(set) var history: [Swiped] = []
    private(set) var message: String?
    private(set) var isWorking = false

    let outbox: SwipeOutbox
    private let deckAPI: DeckAPI
    private let listingsAPI: ListingsAPI
    private let makeSwipeID: () -> String

    init(
        deckAPI: DeckAPI,
        listingsAPI: ListingsAPI,
        outbox: SwipeOutbox,
        makeSwipeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.deckAPI = deckAPI
        self.listingsAPI = listingsAPI
        self.outbox = outbox
        self.makeSwipeID = makeSwipeID
    }

    var selectedListing: Listing? {
        listings.first { $0.id == selectedListingID }
    }

    var top: InterestedRenter? {
        renters.first
    }

    var canUndo: Bool {
        !history.isEmpty && !isWorking
    }

    private var userID: String?

    /// Forgets another account's listings and renters.
    func prepare(for userID: String) {
        guard userID != self.userID else {
            return
        }
        self.userID = userID
        listings = []
        selectedListingID = nil
        renters = []
        history = []
        message = nil
        state = .idle
    }

    /// Loads the lister's listings, keeps the one picked if it is still there,
    /// and loads its renters.
    func load() async {
        guard state != .loading else {
            return
        }
        state = .loading
        message = nil
        await outbox.flush()
        do {
            let page = try await listingsAPI.myListings(cursor: nil)
            listings = page.items.filter { $0.status == .active || $0.status == .paused }
            if selectedListing == nil {
                selectedListingID = listings.first?.id
            }
            try await loadRenters()
            state = .loaded
        } catch let error as APIError where error == .cancelled {
            state = .idle
        } catch {
            state = .failed((error as? APIError)?.userMessage ?? APIError.unreachable.userMessage)
        }
    }

    func select(_ listingID: String) async {
        guard listingID != selectedListingID else {
            return
        }
        selectedListingID = listingID
        renters = []
        history = []
        message = nil
        do {
            try await loadRenters()
        } catch {
            message = (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
        }
    }

    private func loadRenters() async throws {
        guard let listingID = selectedListingID else {
            renters = []
            return
        }
        let page = try await deckAPI.interestedRenters(listingID: listingID)
        let hidden = outbox.pendingRenterIDs(listingID: listingID)
            .union(history.map(\.renter.id))
        renters = page.items.filter { !hidden.contains($0.id) }
    }

    func like() async {
        await swipe(.like)
    }

    func pass() async {
        await swipe(.pass)
    }

    private func swipe(_ action: SwipeAction) async {
        guard let renter = top, let listingID = selectedListingID else {
            return
        }
        message = nil
        renters.removeFirst()
        let swipeID = makeSwipeID()
        history.append(Swiped(renter: renter, swipeID: swipeID))
        await outbox.send(SwipeRequest(listingId: listingID, renterId: renter.id, action: action, swipeId: swipeID))
        if let refused = outbox.message {
            message = refused
            if outbox.refusedSwipeID == swipeID {
                history.removeAll { $0.swipeID == swipeID }
            }
            outbox.clearMessage()
        }
    }

    func undo() async {
        guard let last = history.popLast(), !isWorking else {
            return
        }
        message = nil
        if outbox.cancel(swipeID: last.swipeID) {
            renters.insert(last.renter, at: 0)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await deckAPI.undo(swipeID: last.swipeID)
            renters.insert(last.renter, at: 0)
        } catch let error as APIError where error.serverCode == "nothing_to_undo" {
            renters.insert(last.renter, at: 0)
        } catch let error as APIError where error == .unreachable {
            history.append(last)
            message = "Undo needs a connection. Try again in a moment."
        } catch {
            message = (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
        }
    }
}
