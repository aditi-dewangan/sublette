import Foundation
import Observation
import UserNotifications

/// What a tapped notification asks the app to open.
enum NotificationTarget: Equatable {
    case chat(matchID: String, role: SwipeSide)
    /// "A new place fits your search": the renter's deck.
    case deck
    /// "Your listing expired": the lister's listings, to renew it.
    case listings
    /// A price drop or a liked place closing soon: its card on the map.
    case listing(id: String)
    /// "N renters liked your place this week": the lister's Renters tab.
    case renters

    /// Reads the fields the server puts in every push: kind, match_id, role.
    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo["kind"] as? String {
        case "message", "match":
            guard let matchID = userInfo["match_id"] as? String,
                  let role = (userInfo["role"] as? String).flatMap(SwipeSide.init(rawValue:)) else {
                return nil
            }
            self = .chat(matchID: matchID, role: role)
        case "listing":
            self = .deck
        case "listing_expired":
            self = .listings
        case "price_drop", "expiring":
            guard let listingID = userInfo["listing_id"] as? String else {
                return nil
            }
            self = .listing(id: listingID)
        case "digest":
            self = .deck
        case "likes":
            self = .renters
        default:
            return nil
        }
    }
}

/// The parts of the system's notification APIs the app uses, so tests can stand in.
protocol NotificationPermissions: Sendable {
    func status() async -> UNAuthorizationStatus
    func request() async -> Bool
    @MainActor func registerForRemoteNotifications()
}

/// Push notifications for the signed-in account.
///
/// Permission is asked for at the first match, not at launch: that is when a
/// notification is worth having. Once allowed, the phone's token is sent to
/// the server at every sign-in and withdrawn at sign-out.
@MainActor
@Observable
final class NotificationsModel {
    /// Set when a tapped notification should open something.
    var target: NotificationTarget?

    @ObservationIgnored private let api: ChatAPI
    @ObservationIgnored private let permissions: NotificationPermissions
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let simulatorID: String?
    @ObservationIgnored private var signedIn = false

    /// `simulatorID` is set when running in the simulator: it is sent instead
    /// of an Apple token (see `PushEnvironment.simulator`).
    init(api: ChatAPI, permissions: NotificationPermissions, preferences: Preferences, simulatorID: String? = nil) {
        self.api = api
        self.permissions = permissions
        self.preferences = preferences
        self.simulatorID = simulatorID
    }

    /// The simulator's own id, in a Debug build running in the simulator.
    static var currentSimulatorID: String? {
        #if targetEnvironment(simulator) && DEBUG
        return ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
        #else
        return nil
        #endif
    }

    /// After sign-in or launch: if notifications are already allowed, get a
    /// fresh token for this account. Never asks.
    func didSignIn() async {
        signedIn = true
        if await permissions.status() == .authorized {
            await register()
        }
    }

    /// At the first match: asks, once. iOS shows the question only one time.
    func askAtFirstMatch() async {
        guard await permissions.status() == .notDetermined else {
            return
        }
        if await permissions.request() {
            await register()
        }
    }

    /// Apple gave the phone a token.
    func didRegister(deviceToken: Data) async {
        await send(token: deviceToken.map { String(format: "%02x", $0) }.joined(), environment: .current)
    }

    private func register() async {
        if let simulatorID {
            await send(token: simulatorID.replacingOccurrences(of: "-", with: "").lowercased(), environment: .simulator)
        } else {
            permissions.registerForRemoteNotifications()
        }
    }

    private func send(token: String, environment: PushEnvironment) async {
        guard signedIn else {
            return
        }
        do {
            try await api.registerDevice(DeviceRequest(token: token, environment: environment))
            preferences.deviceToken = token
        } catch {
            // Tried again at the next launch.
        }
    }

    /// Before the tokens are thrown away, so this phone stops getting the
    /// account's notifications.
    func willSignOut() async {
        signedIn = false
        guard let token = preferences.deviceToken else {
            return
        }
        preferences.deviceToken = nil
        try? await api.unregisterDevice(token: token)
    }

    func didTap(userInfo: [AnyHashable: Any]) {
        target = NotificationTarget(userInfo: userInfo)
    }

    /// While the app is open, a message for the chat on screen needs no banner.
    func showsBanner(userInfo: [AnyHashable: Any], openChatID: String?) -> Bool {
        if case .chat(let matchID, _) = NotificationTarget(userInfo: userInfo),
           userInfo["kind"] as? String == "message", matchID == openChatID {
            return false
        }
        return true
    }
}
