import UIKit
import UserNotifications

/// Receives the system's notification callbacks and hands them to `NotificationsModel`.
/// A callback that comes before the model is attached (a tap that launched the
/// app) waits until it is.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var notifications: NotificationsModel? {
        didSet { deliverWaiting() }
    }

    /// The chat on screen, so its own messages don't show a banner.
    @MainActor var openChatID: (() -> String?)?

    @MainActor private var waitingToken: Data?
    @MainActor private var waitingTap: [AnyHashable: Any]?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            if let notifications {
                await notifications.didRegister(deviceToken: deviceToken)
            } else {
                waitingToken = deviceToken
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No push entitlement (a personal team) or no network. Chat still works
        // while the app is open.
        print("Push registration failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            if let notifications {
                notifications.didTap(userInfo: userInfo)
            } else {
                waitingTap = userInfo
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        let show = await MainActor.run {
            notifications?.showsBanner(userInfo: userInfo, openChatID: openChatID?()) ?? true
        }
        return show ? [.banner, .list, .sound] : []
    }

    @MainActor private func deliverWaiting() {
        guard let notifications else {
            return
        }
        if let tap = waitingTap {
            waitingTap = nil
            notifications.didTap(userInfo: tap)
        }
        if let token = waitingToken {
            waitingToken = nil
            Task { await notifications.didRegister(deviceToken: token) }
        }
    }
}

/// The real system calls.
struct SystemNotificationPermissions: NotificationPermissions {
    func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
