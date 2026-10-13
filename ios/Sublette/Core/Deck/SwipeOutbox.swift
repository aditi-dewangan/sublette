import Foundation
import Observation

/// A swipe waiting to reach the server, and whose it is.
struct PendingSwipe: Codable, Equatable, Identifiable {
    let userID: String
    let request: SwipeRequest

    var id: String { request.swipeId }
}

/// Sends swipes in the order they were made, and keeps them while offline.
///
/// Every swipe carries an id made on the phone. Sending one again (after a
/// lost answer, a relaunch, or a spell offline) is recognised by the server,
/// so nothing is ever recorded twice and no match is made twice.
@MainActor
@Observable
final class SwipeOutbox {
    /// Oldest first. Saved to the phone after every change.
    private(set) var pending: [PendingSwipe]
    /// True after a send failed for lack of a connection; false after one works.
    private(set) var isOffline = false
    /// The last swipe the server refused, in words to show.
    private(set) var message: String?
    /// Which swipe that was.
    private(set) var refusedSwipeID: String?
    /// The newest match a swipe made, for the "It's a match" screen.
    var latestMatch: Match?

    private let api: DeckAPI
    private let preferences: Preferences
    private var userID: String?
    private var isFlushing = false

    init(api: DeckAPI, preferences: Preferences) {
        self.api = api
        self.preferences = preferences
        self.pending = preferences.pendingSwipes
    }

    /// Drops swipes left by another account on this phone.
    func prepare(for userID: String) {
        self.userID = userID
        let mine = pending.filter { $0.userID == userID }
        if mine != pending {
            pending = mine
            save()
        }
    }

    /// Ids of listings with a swipe still on the phone, so a reload doesn't show them again.
    var pendingListingIDs: Set<String> {
        Set(pending.filter { $0.request.renterId == nil }.map(\.request.listingId))
    }

    /// Ids of renters with a lister swipe still on the phone, for one listing.
    func pendingRenterIDs(listingID: String) -> Set<String> {
        Set(pending.compactMap { $0.request.listingId == listingID ? $0.request.renterId : nil })
    }

    /// Queues a swipe and tries to send everything queued.
    func send(_ request: SwipeRequest) async {
        guard let userID else {
            return
        }
        pending.append(PendingSwipe(userID: userID, request: request))
        save()
        await flush()
    }

    /// Takes a swipe back before it was sent. True when it was still waiting.
    func cancel(swipeID: String) -> Bool {
        guard let index = pending.firstIndex(where: { $0.id == swipeID }) else {
            return false
        }
        pending.remove(at: index)
        save()
        return true
    }

    func clearMessage() {
        message = nil
        refusedSwipeID = nil
    }

    /// Sends queued swipes in order. Stops at the first one that can't get
    /// through, so order is kept, and leaves it queued for next time.
    func flush() async {
        guard !isFlushing else {
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        while let next = pending.first(where: { $0.userID == userID }) {
            do {
                let result = try await api.swipe(next.request)
                isOffline = false
                remove(next)
                if let match = result.match, result.created {
                    latestMatch = match
                }
            } catch let error as APIError where Self.isWorthRetrying(error) {
                if error != .cancelled {
                    isOffline = true
                }
                return
            } catch {
                // The server said no (the listing closed, or it was already
                // swiped the other way). Sending it again won't change that.
                isOffline = false
                remove(next)
                refusedSwipeID = next.id
                message = (error as? APIError)?.userMessage ?? APIError.decoding.userMessage
            }
        }
    }

    /// No connection, the request was cut short, or the server is having a
    /// moment: keep the swipe and try later.
    nonisolated static func isWorthRetrying(_ error: APIError) -> Bool {
        switch error {
        case .unreachable, .cancelled:
            return true
        case .server(let status, _, _, _):
            return status >= 500 || status == 429 || status == 401
        case .decoding, .invalidRequest:
            return false
        }
    }

    private func remove(_ swipe: PendingSwipe) {
        pending.removeAll { $0.id == swipe.id }
        save()
    }

    private func save() {
        preferences.pendingSwipes = pending
    }
}
