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
    /// What the server last confirmed; a failed save falls back to it.
    private var savedPreferences = NotificationPreferences()
    /// Bumped whenever the account changes, so work started for an earlier account can tell it is stale.
    private var session = 0
    /// The session whose save loop is running, if any.
    private var savingSession: Int?
    /// The registration request in flight; sign-out waits for it so it can't land after the unregister.
    private var registration: Task<Void, Never>?
    private var isSigningOut = false

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
        session += 1
        isSigningOut = false
        registeredKey = nil
        preferences = NotificationPreferences()
        savedPreferences = preferences
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
        // No new registrations from here on, and any running one finishes before the token is removed.
        isSigningOut = true
        while let running = registration { await running.value }
        guard let token = deviceToken, userId != nil, let repository = makeRepository() else { return }
        try? await repository.unregisterDevice(token: token)
        registeredKey = nil
    }

    /// The sign-out didn't happen, so the account keeps its device.
    func signOutFailed() async {
        isSigningOut = false
        await refreshPermission()
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
        // One request at a time; whoever waited re-checks, since the running one may have done the job.
        while let running = registration { await running.value }
        guard !isSigningOut, permission == .allowed, let userId, let token = deviceToken else { return }
        let key = "\(userId.uuidString):\(token)"
        guard key != registeredKey, let repository = makeRepository() else { return }
        let current = session
        let environment = environment
        let task = Task { @MainActor [weak self] in
            do {
                try await repository.registerDevice(token: token, environment: environment)
                if self?.session == current { self?.registeredKey = key }
            } catch {
                // Retried on the next foreground.
                LoamErrorCapture.capture("push.register_device_failed")
            }
        }
        registration = task
        await task.value
        registration = nil
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Preferences

    func loadPreferences() async {
        guard userId != nil, let repository = makeRepository() else { return }
        let current = session
        preferencesState = .loading
        do {
            let loaded = try await repository.fetchPreferences()
            guard session == current else { return }
            // A save in flight owns the switches; its result is newer than this read.
            if savingSession != current {
                preferences = loaded
                savedPreferences = loaded
            }
            preferencesState = .loaded
        } catch {
            guard session == current else { return }
            preferencesState = .failed
        }
    }

    func setPreference(_ category: NotificationCategory, enabled: Bool) async {
        guard userId != nil, let repository = makeRepository(), preferences[category] != enabled else { return }
        preferences[category] = enabled
        // One save at a time per account, so an older request can't land after a newer one.
        // The running loop picks up switches flipped while it waits on the network.
        let current = session
        guard savingSession != current else { return }
        savingSession = current
        defer { if savingSession == current { savingSession = nil } }
        while session == current, preferences != savedPreferences {
            let snapshot = preferences
            do {
                try await repository.savePreferences(snapshot)
                // The account may have changed while saving; its state is not ours to touch.
                guard session == current else { return }
                savedPreferences = snapshot
            } catch {
                guard session == current else { return }
                preferences = savedPreferences
                lastError = "Couldn't save your notification settings. Try again."
                return
            }
        }
    }

    // MARK: - Badge and delivered notifications

    func updateBadge(unreadCount: Int) async {
        guard userId != nil, permission == .allowed else { return }
        await center.setBadge(unreadCount)
    }

    /// Clears the banners for events the user has dealt with, matched on the payload's `event_id`.
    func clearDelivered(eventIds: [UUID]) async {
        guard !eventIds.isEmpty else { return }
        await center.removeDelivered(eventIds: Set(eventIds))
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
