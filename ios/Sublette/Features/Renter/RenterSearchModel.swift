import Foundation
import Observation

/// The renter's saved search, shared by the Deck tab and the preference flow.
@MainActor
@Observable
final class RenterSearchModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// Loading failed. Whatever was loaded before stays shown.
        case failed(String)
    }

    /// Nil until the first load finishes.
    private(set) var profile: RenterProfile?
    private(set) var state: LoadState = .idle

    /// Whose profile is held, so a different account never sees it.
    private(set) var userID: String?

    private let api: RenterAPI

    init(api: RenterAPI) {
        self.api = api
    }

    var needsSetUp: Bool {
        profile.map { !$0.complete } ?? false
    }

    /// Forgets the profile if it belonged to another account.
    func prepare(for userID: String) {
        guard userID != self.userID else {
            return
        }
        self.userID = userID
        profile = nil
        state = .idle
    }

    func load() async {
        guard state != .loading else {
            return
        }
        state = .loading
        do {
            profile = try await api.renterProfile()
            state = .loaded
        } catch let error as APIError where error == .cancelled {
            state = profile == nil ? .idle : .loaded
        } catch {
            // Offline is not signed out: keep whatever is shown and offer a retry.
            state = .failed((error as? APIError)?.userMessage ?? APIError.unreachable.userMessage)
        }
    }

    /// Shows a profile the preference flow just saved.
    func show(_ saved: RenterProfile) {
        profile = saved
        state = .loaded
    }
}
