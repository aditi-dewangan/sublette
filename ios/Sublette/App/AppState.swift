import Observation

/// State shared by the whole app. In phase 0 that is only the current mode.
@MainActor
@Observable
final class AppState {
    var mode: AppMode

    init(mode: AppMode = .renter) {
        self.mode = mode
    }

    func toggleMode() {
        mode = (mode == .renter) ? .lister : .renter
    }
}
