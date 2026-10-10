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
    /// Removes delivered pushes whose payload `event_id` is in `eventIds`.
    func removeDelivered(eventIds: Set<UUID>) async
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

    func removeDelivered(eventIds: Set<UUID>) async {
        // Request identifiers on delivered pushes are chosen by iOS, so match on the payload.
        let identifiers = await center.deliveredNotifications().compactMap { notification -> String? in
            guard let raw = notification.request.content.userInfo["event_id"] as? String,
                  let id = UUID(uuidString: raw), eventIds.contains(id) else { return nil }
            return notification.request.identifier
        }
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllDelivered() {
        center.removeAllDeliveredNotifications()
    }
}
