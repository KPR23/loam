import UserNotifications

/// Asks for the optional permission onboarding offers. Only the system prompt
/// happens here; once signed in, the push store registers the device if alerts are allowed.
@MainActor
final class OnboardingPermissions: ObservableObject {
    enum Status {
        case notDetermined, allowed, denied
    }

    @Published private(set) var notifications: Status = .notDetermined

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = Self.status(settings.authorizationStatus)
    }

    func requestNotifications() async {
        // Same options as the push store, so its later request is a no-op.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await refresh()
    }

    private static func status(_ status: UNAuthorizationStatus) -> Status {
        switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        default: .notDetermined
        }
    }
}
