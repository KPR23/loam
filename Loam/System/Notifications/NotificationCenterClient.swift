import UIKit
import UserNotifications

enum NotificationPermission: Equatable, Sendable {
    /// Not asked yet this launch, so the UI shouldn't claim either way.
    case unknown
    case notDetermined
    case denied
    case allowed
}

/// The slice of UserNotifications and UIApplication the store needs, so tests can stand in for the system.
@MainActor
protocol NotificationCenterClient {
    func permission() async -> NotificationPermission
    func requestPermission() async -> Bool
    func registerForRemoteNotifications()
    func setBadge(_ count: Int) async
    func removeDelivered(identifiers: [String])
    func removeAllDelivered()
}

@MainActor
struct SystemNotificationCenter: NotificationCenterClient {
    // Used as a default argument, which is evaluated outside the main actor.
    nonisolated init() {}

    private var center: UNUserNotificationCenter { .current() }

    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .denied
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }

    func removeDelivered(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllDelivered() {
        center.removeAllDeliveredNotifications()
    }
}
