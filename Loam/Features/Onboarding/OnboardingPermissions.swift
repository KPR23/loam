import CoreLocation
import UserNotifications

/// Asks for the two optional permissions onboarding offers. Only the system prompts
/// happen here; once signed in, the push store registers the device if alerts are allowed.
@MainActor
final class OnboardingPermissions: NSObject, ObservableObject {
    enum Status: Sendable {
        case notDetermined, allowed, denied
    }

    @Published private(set) var notifications: Status = .notDetermined
    @Published private(set) var location: Status = .notDetermined

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        location = Self.status(locationManager.authorizationStatus)
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = Self.status(settings.authorizationStatus)
        location = Self.status(locationManager.authorizationStatus)
    }

    func requestNotifications() async {
        // Same options as the push store, so its later request is a no-op.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await refresh()
    }

    /// The answer arrives through the delegate.
    func requestLocation() {
        locationManager.requestWhenInUseAuthorization()
    }

    private nonisolated static func status(_ status: UNAuthorizationStatus) -> Status {
        switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        default: .notDetermined
        }
    }

    private nonisolated static func status(_ status: CLAuthorizationStatus) -> Status {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }
}

extension OnboardingPermissions: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = Self.status(manager.authorizationStatus)
        Task { @MainActor in location = status }
    }
}
