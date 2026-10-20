import Observation

/// State shared by the whole app: which mode it is in.
@MainActor
@Observable
final class AppState {
    /// Renter or Lister. Change it with `setMode`, which also remembers it.
    private(set) var mode: AppMode

    /// The tab on screen. Each mode starts on its own first tab.
    var tab: ModeTab

    /// A chat to open in the Matches tab, as when a notification is tapped.
    private(set) var chatToOpen: String?

    /// Ids of accounts that have picked a starting mode on this phone.
    private(set) var usersWhoChoseAMode: Set<String>

    private let preferences: Preferences

    init(preferences: Preferences, mode: AppMode? = nil) {
        self.preferences = preferences
        let mode = mode ?? preferences.lastMode
        self.mode = mode
        self.tab = ModeTab.tabs(for: mode)[0]
        self.usersWhoChoseAMode = preferences.usersWhoChoseAMode
    }

    /// Switches mode and remembers it for the next launch.
    func setMode(_ newMode: AppMode) {
        if newMode != mode || !ModeTab.tabs(for: newMode).contains(tab) {
            tab = ModeTab.tabs(for: newMode)[0]
        }
        mode = newMode
        preferences.lastMode = newMode
    }

    /// Switches to the side `role` is on, its Matches tab, and the chat.
    func openChat(matchID: String, role: SwipeSide) {
        setMode(role == .renter ? .renter : .lister)
        tab = .matches
        chatToOpen = matchID
    }

    func chatOpened() {
        chatToOpen = nil
    }

    /// "A new place fits your search".
    func openDeck() {
        setMode(.renter)
        tab = .deck
    }

    /// A listing to show on the renter's map, as when an alert is tapped.
    private(set) var listingToOpen: String?

    func openListing(_ id: String) {
        setMode(.renter)
        tab = .map
        listingToOpen = id
    }

    func listingOpened() {
        listingToOpen = nil
    }

    /// "N renters liked your place this week".
    func openRenters() {
        setMode(.lister)
        tab = .renters
    }

    /// "Your listing expired": the lister's own listings.
    func openListings() {
        setMode(.lister)
        tab = .listings
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
