import Observation

/// State shared by the whole app: which mode it is in.
@MainActor
@Observable
final class AppState {
    /// Renter or Lister. Change it with `setMode`, which also remembers it.
    private(set) var mode: AppMode

    /// Ids of accounts that have picked a starting mode on this phone.
    private(set) var usersWhoChoseAMode: Set<String>

    private let preferences: Preferences

    init(preferences: Preferences, mode: AppMode? = nil) {
        self.preferences = preferences
        self.mode = mode ?? preferences.lastMode
        self.usersWhoChoseAMode = preferences.usersWhoChoseAMode
    }

    /// Switches mode and remembers it for the next launch.
    func setMode(_ newMode: AppMode) {
        mode = newMode
        preferences.lastMode = newMode
    }

    func toggleMode() {
        setMode(mode == .renter ? .lister : .renter)
    }

    func hasChosenStartingMode(userID: String) -> Bool {
        usersWhoChoseAMode.contains(userID)
    }

    /// The last onboarding step: the student picks which side to start on.
    func chooseStartingMode(_ mode: AppMode, userID: String) {
        setMode(mode)
        usersWhoChoseAMode.insert(userID)
        preferences.usersWhoChoseAMode = usersWhoChoseAMode
    }
}
