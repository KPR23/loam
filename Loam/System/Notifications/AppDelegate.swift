import UIKit
import UserNotifications

/// SwiftUI has no hooks for APNs registration or notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Tests must never touch the system notification center.
        if !LaunchEnvironment.isAutomatedTest {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().setNotificationCategories(WalletPaymentNotifier.categories)
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await PushNotificationStore.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushNotificationStore.shared.didFailToRegister() }
    }

    /// Shows pushes as banners even while the app is open, and tells Activity to refresh.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { NotificationCenter.default.post(name: .loamPushReceived, object: nil) }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let action = response.actionIdentifier
        let walletInfo = content.userInfo.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String, let value = entry.value as? String { result[key] = value }
        }
        // Wallet payment buttons run here in the background; everything else is a push tap.
        let handled = await WalletPaymentNotifier.shared.handle(category: category, action: action, userInfo: walletInfo)
        guard !handled, action == UNNotificationDefaultActionIdentifier else { return }
        let strings = content.userInfo.compactMapValues { $0 as? String }
        await MainActor.run { PushNotificationStore.shared.open(userInfo: strings) }
    }
}
