import Foundation
import SwiftUI

/// Owns notification permission, this device's APNs registration and the
/// per-category switches. Preferences live on the server so the push sender can
/// honour them; the app only mirrors them for the settings screen.
@MainActor
final class PushNotificationStore: ObservableObject {
    static let shared = PushNotificationStore()

    @Published private(set) var permission: NotificationPermission = .unknown
    @Published private(set) var preferences = NotificationPreferences()
    @Published private(set) var preferencesState: PreferencesState = .idle
    @Published var lastError: String?
    /// Set when a push is tapped; Activity consumes it.
    @Published var pendingRoute: NotificationRoute?

    enum PreferencesState: Equatable { case idle, loading, loaded, failed }

    private let center: NotificationCenterClient
    private let makeRepository: () -> NotificationRepository?
    private let environment: PushEnvironment
    private var userId: UUID?
    private var deviceToken: String?
    /// "user:token" last accepted by the backend, so repeat launches don't re-register.
    private var registeredKey: String?
    /// Orders saves so a slow earlier one can't overwrite a newer switch.
    private var saveGeneration = 0

    init(
        center: NotificationCenterClient = SystemNotificationCenter(),
        environment: PushEnvironment = .current,
        repository: @escaping () -> NotificationRepository? = {
            SupabaseClientProvider.shared.map { SupabaseNotificationRepository(client: $0) }
        }
    ) {
        self.center = center
        self.environment = environment
        self.makeRepository = repository
    }

    // MARK: - Account lifecycle

    /// Pass `nil` when signed out or in demo mode, which never receives pushes.
    func activate(userId: UUID?) async {
        guard userId != self.userId else {
            await refreshPermission()
            return
        }
        self.userId = userId
        registeredKey = nil
        preferences = NotificationPreferences()
        preferencesState = .idle
        guard userId != nil else {
            await center.setBadge(0)
            center.removeAllDelivered()
            return
        }
        await refreshPermission()
        await loadPreferences()
    }

    /// Call before the session ends so the backend stops pushing to this phone for the account.
    /// Best effort: offline sign-out leaves the token until the next account registers it.
    func deviceWillSignOut() async {
        guard let token = deviceToken, userId != nil, let repository = makeRepository() else { return }
        try? await repository.unregisterDevice(token: token)
        registeredKey = nil
    }

    // MARK: - Permission and registration

    func refreshPermission() async {
        permission = await center.permission()
        guard permission == .allowed, userId != nil else { return }
        // Tokens can change (restore, reinstall), so ask iOS again each time.
        center.registerForRemoteNotifications()
        await syncRegistration()
    }

    /// Shows the system prompt (once; iOS ignores repeats). Returns whether pushes are now allowed.
    @discardableResult
    func requestPermission() async -> Bool {
        _ = await center.requestPermission()
        await refreshPermission()
        return permission == .allowed
    }

    func didRegister(deviceToken data: Data) async {
        deviceToken = Self.hex(data)
        await syncRegistration()
    }

    func didFailToRegister() {
        #if !DEBUG
        // The simulator can't register; in release builds this means a signing or network problem.
        LoamErrorCapture.capture("push.register_failed")
        #endif
    }

    private func syncRegistration() async {
        guard permission == .allowed, let userId, let token = deviceToken else { return }
        let key = "\(userId.uuidString):\(token)"
        guard key != registeredKey, let repository = makeRepository() else { return }
        do {
            try await repository.registerDevice(token: token, environment: environment)
            if self.userId == userId { registeredKey = key }
        } catch {
            // Retried on the next foreground.
            LoamErrorCapture.capture("push.register_device_failed")
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Preferences

    func loadPreferences() async {
        guard let userId, let repository = makeRepository() else { return }
        preferencesState = .loading
        do {
            let loaded = try await repository.fetchPreferences()
            guard self.userId == userId else { return }
            preferences = loaded
            preferencesState = .loaded
        } catch {
            guard self.userId == userId else { return }
            preferencesState = .failed
        }
    }

    func setPreference(_ category: NotificationCategory, enabled: Bool) async {
        guard let userId, let repository = makeRepository(), preferences[category] != enabled else { return }
        let previous = preferences
        preferences[category] = enabled
        saveGeneration += 1
        let generation = saveGeneration
        let snapshot = preferences
        do {
            try await repository.savePreferences(snapshot)
        } catch {
            guard self.userId == userId, generation == saveGeneration else { return }
            preferences = previous
            lastError = "Couldn't save your notification settings. Try again."
        }
    }

    // MARK: - Badge and delivered notifications

    func updateBadge(unreadCount: Int) async {
        guard userId != nil, permission == .allowed else { return }
        await center.setBadge(unreadCount)
    }

    /// Clears the banners for events the user has dealt with. The backend uses the event ID as the collapse ID.
    func clearDelivered(eventIds: [UUID]) {
        center.removeDelivered(identifiers: eventIds.map { $0.uuidString })
    }

    // MARK: - Taps

    func open(userInfo: [AnyHashable: Any]) {
        guard let route = NotificationRoute(userInfo: userInfo) else { return }
        pendingRoute = route
    }

    /// Returns the route if it belongs to the signed-in account; stale ones are dropped.
    func consumeRoute(for accountId: UUID?) -> NotificationRoute? {
        guard let route = pendingRoute else { return nil }
        pendingRoute = nil
        if let owner = route.userId, owner != accountId { return nil }
        return route
    }
}

extension Notification.Name {
    /// Posted when a push arrives while the app is open, so Activity can refresh.
    static let loamPushReceived = Notification.Name("loam.pushReceived")
}
