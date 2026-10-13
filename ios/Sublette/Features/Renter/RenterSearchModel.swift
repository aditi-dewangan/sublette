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

    /// The message from the last change made from the empty deck.
    private(set) var changeMessage: String?

    /// Makes one must-have a nice-to-have (the empty deck's "relax" button).
    func relax(_ field: PreferenceField) async -> Bool {
        guard var form = profile?.form else {
            return false
        }
        form.preferences = form.preferences.map { preference in
            guard preference.field == field, preference.importance == .must else {
                return preference
            }
            return Preference(field: preference.field, value: preference.value, importance: .nice)
        }
        return await save(form)
    }

    /// Doubles the search radius, up to the largest allowed.
    func widenArea() async -> Bool {
        guard var form = profile?.form, var pin = form.pin else {
            return false
        }
        pin.radiusM = min(pin.radiusM * 2, SearchPin.maxRadiusM)
        form.pin = pin
        return await save(form)
    }

    /// "Notify me" when nothing is listed near the pin yet.
    func setNotifyNewListings(_ on: Bool) async -> Bool {
        guard var form = profile?.form else {
            return false
        }
        form.notifyNewListings = on
        return await save(form)
    }

    private func save(_ form: RenterProfileForm) async -> Bool {
        changeMessage = nil
        do {
            profile = try await api.saveRenterProfile(form)
            return true
        } catch {
            changeMessage = (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
            return false
        }
    }

    /// Shows a profile the preference flow just saved.
    func show(_ saved: RenterProfile) {
        profile = saved
        state = .loaded
    }
}
