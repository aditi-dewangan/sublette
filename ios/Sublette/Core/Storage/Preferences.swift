import Foundation

/// Small things remembered between launches. Nothing secret lives here:
/// tokens are in the Keychain.
final class Preferences: @unchecked Sendable {
    // UserDefaults is safe to use from any thread.
    private let defaults: UserDefaults

    private enum Key {
        static let lastMode = "lastMode"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let cachedUser = "cachedUser"
        static let usersWhoChoseAMode = "usersWhoChoseAMode"
        static let pendingSwipes = "pendingSwipes"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Preferences that are thrown away. Used by tests and previews.
    static func ephemeral() -> Preferences {
        let name = "sublette.ephemeral.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults: defaults)
    }

    /// The mode the student last used, so the app reopens on the same side.
    var lastMode: AppMode {
        get { AppMode(rawValue: defaults.string(forKey: Key.lastMode) ?? "") ?? .renter }
        set { defaults.set(newValue.rawValue, forKey: Key.lastMode) }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }

    /// The profile from the last successful load, so the app can open while offline.
    var cachedUser: User? {
        get {
            guard let data = defaults.data(forKey: Key.cachedUser) else {
                return nil
            }
            return try? JSONDecoder().decode(User.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.cachedUser)
            } else {
                defaults.removeObject(forKey: Key.cachedUser)
            }
        }
    }

    /// Ids of accounts that have picked a starting mode on this phone.
    var usersWhoChoseAMode: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.usersWhoChoseAMode) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.usersWhoChoseAMode) }
    }

    /// Swipes made offline and not yet accepted by the server, oldest first.
    /// Kept across launches so a swipe made on the subway is sent later.
    var pendingSwipes: [PendingSwipe] {
        get {
            guard let data = defaults.data(forKey: Key.pendingSwipes) else {
                return []
            }
            return (try? JSONDecoder().decode([PendingSwipe].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Key.pendingSwipes)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.pendingSwipes)
            }
        }
    }
}

enum FirstLaunch {
    /// The Keychain outlives the app: delete Sublette and reinstall it, and the
    /// old tokens are still there. On the first launch of a fresh install,
    /// throw them away so a new owner of the phone is not signed in as the last.
    static func clearStaleTokensIfNeeded(preferences: Preferences, store: TokenStore) {
        guard !preferences.hasLaunchedBefore else {
            return
        }
        store.clear()
        preferences.hasLaunchedBefore = true
    }
}

enum Runtime {
    /// True while the app is running only to host its unit tests. Network
    /// calls made at launch are skipped then.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
