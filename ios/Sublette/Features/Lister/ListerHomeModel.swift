import Foundation
import Observation

/// The lister's own listings, with publish, pause and filled actions.
@MainActor
@Observable
final class ListerHomeModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// The list could not be loaded. Whatever was loaded before stays shown.
        case failed(String)
    }

    private(set) var listings: [Listing] = []
    private(set) var state: LoadState = .idle
    private(set) var nextCursor: String?
    private(set) var busyListingID: String?
    /// The last action's failure, such as a publish refused because a field is missing.
    private(set) var actionMessage: String?

    private let api: ListingsAPI

    init(api: ListingsAPI) {
        self.api = api
    }

    var canLoadMore: Bool {
        nextCursor != nil && state != .loading
    }

    /// Loads the first page again.
    func load() async {
        guard state != .loading else {
            return
        }
        state = .loading
        do {
            let page = try await api.myListings(cursor: nil)
            listings = page.items
            nextCursor = page.nextCursor
            state = .loaded
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, state != .loading else {
            return
        }
        state = .loading
        do {
            let page = try await api.myListings(cursor: cursor)
            let known = Set(listings.map(\.id))
            listings += page.items.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
            state = .loaded
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Puts a created or edited listing into the list.
    func show(_ listing: Listing) {
        if let index = listings.firstIndex(where: { $0.id == listing.id }) {
            listings[index] = listing
        } else {
            listings.insert(listing, at: 0)
        }
    }

    /// Publish, pause or fill. Returns true when the server accepted it.
    @discardableResult
    func setStatus(_ status: ListingStatus, for listing: Listing) async -> Bool {
        guard busyListingID == nil else {
            return false
        }
        busyListingID = listing.id
        actionMessage = nil
        defer { busyListingID = nil }
        do {
            show(try await api.setStatus(id: listing.id, status))
            return true
        } catch {
            actionMessage = Self.message(for: error)
            return false
        }
    }

    func clearActionMessage() {
        actionMessage = nil
    }

    static func message(for error: Error) -> String {
        guard let error = error as? APIError else {
            return APIError.unreachable.userMessage
        }
        if case .cancelled = error {
            return ""
        }
        if error.serverCode == "listing_incomplete" {
            let missing = error.fieldMessages.values.sorted().first
            return missing.map { "Finish the listing first. \($0)" } ?? error.userMessage
        }
        return error.userMessage
    }
}
