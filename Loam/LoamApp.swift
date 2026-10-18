import SwiftUI
import Sentry
import Foundation

@main
struct LoamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("loam.appearance") private var appearance: AppAppearance = .system
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue
    @AppStorage(AppPreferences.timeZoneKey) private var timeZoneIdentifier = ""
    @AppStorage(AppPreferences.defaultCurrencyKey) private var defaultCurrency = AppPreferences.fallbackCurrencyCode
    // Shared with the Siri actions, which can run before any screen exists.
    @StateObject private var authSession = AppServices.shared.authSession
    @StateObject private var expenseStore = AppServices.shared.expenseStore
    @StateObject private var balanceStore = AppServices.shared.balanceStore
    @StateObject private var connectionStore = AppServices.shared.connectionStore
    @StateObject private var navigator = AppServices.shared.navigator
    @StateObject private var appLock = AppServices.shared.appLock
    @StateObject private var activityStore = ActivityStore()
    @StateObject private var subscriptionStore = SubscriptionStore()
    @StateObject private var pushStore = PushNotificationStore.shared
    @StateObject private var toastCenter = ToastCenter.shared

    init() {
        #if DEBUG
        if LaunchEnvironment.resetsLocalData {
            UITestStorage.setAsideAndClear()
        } else if !LaunchEnvironment.isAutomatedTest {
            UITestStorage.restore()
        }
        #endif
        // Test runs must never report to Sentry or PostHog, or reach RevenueCat.
        if !LaunchEnvironment.isAutomatedTest {
            Telemetry.start()
            SubscriptionStore.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            if LaunchEnvironment.isUnitTestHost {
                // Unit tests own every store and UserDefaults key; a live app
                // session would race them and reach the staging backend.
                Color.clear
            } else {
                rootView
            }
        }
    }

    private var rootView: some View {
        RootView()
            .preferredColorScheme(appearance.colorScheme)
            .tint(accentColor.color)
            .environment(\.timeZone, AppPreferences.timeZone(for: timeZoneIdentifier))
            .environmentObject(authSession)
            .environmentObject(expenseStore)
            .environmentObject(balanceStore)
            .environmentObject(activityStore)
            .environmentObject(connectionStore)
            .environmentObject(subscriptionStore)
            .environmentObject(pushStore)
            .environmentObject(appLock)
            .background(
                AppLockWindowInstaller(
                    isLocked: showsAppLock,
                    coversOnBackground: appLock.isEnabled && authSession.state == .signedIn
                ) {
                    AppLockView(isPresented: showsAppLock && scenePhase == .active)
                        .preferredColorScheme(appearance.colorScheme)
                        .tint(accentColor.color)
                        .environmentObject(appLock)
                }
            )
            .background(
                ToastWindowInstaller(center: toastCenter) { onFrameChange in
                    ToastOverlay(center: toastCenter, onFrameChange: onFrameChange)
                        .preferredColorScheme(appearance.colorScheme)
                        .tint(accentColor.color)
                }
            )
            .environmentObject(navigator)
            .task {
                LegacyDemoFixtureCleanup.removeIfNeeded()
                await authSession.bootstrapIfNeeded()
                // Analytics resume at launch as the last account left them; a launch that
                // ends signed out changes no user ID, so settle it here.
                Telemetry.setUser(accountId)
            }
            .task(id: authSession.userId) {
                await connectionStore.refresh(userId: authSession.userId)
            }
            .task(id: authSession.userId) {
                await CustomCategoryStore.shared.load(userId: authSession.userId)
            }
            .onChange(of: connectionStore.connections, initial: true) { _, _ in
                // Lets Siri recognize friends' names in phrases like "Settle up with Julia".
                LoamShortcuts.updateAppShortcutParameters()
            }
            .task(id: accountId) {
                await subscriptionStore.identify(userId: accountId)
            }
            .task(id: accountId) {
                await pushStore.activate(userId: accountId)
            }
            .task(id: pushBadge) {
                await pushStore.updateBadge(unreadCount: activityStore.badgeCount)
            }
            .onReceive(NotificationCenter.default.publisher(for: .loamPushReceived)) { _ in
                Task { await activityStore.refresh(userId: authSession.userId) }
            }
            .onChange(of: authSession.userId) { _, _ in
                Telemetry.setUser(accountId)
            }
            .onChange(of: defaultCurrency) { _, _ in
                // Totals follow the new currency; expenses keep the one they were added in.
                expenseStore.recomputeSummary()
            }
            .onChange(of: timeZoneIdentifier) { oldIdentifier, _ in
                Task {
                    await expenseStore.timeZoneDidChange(
                        from: AppPreferences.timeZone(for: oldIdentifier),
                        userId: authSession.userId
                    )
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    // A change still waiting on Undo is saved before iOS can suspend the app.
                    toastCenter.expireCurrent()
                    appLock.appDidEnterBackground()
                }
                if phase == .active {
                    appLock.refreshMethod()
                    Task {
                        await authSession.refreshDeletionStatus()
                        await connectionStore.refresh(userId: authSession.userId)
                        await subscriptionStore.identify(userId: accountId)
                        await pushStore.refreshPermission()
                    }
                }
            }
    }

    /// The badge follows the Activity count once iOS allows it.
    private var pushBadge: String { "\(activityStore.badgeCount)-\(pushStore.permission == .allowed)-\(accountId?.uuidString ?? "")" }

    /// The lock guards a signed-in session; sign-in and onboarding stay reachable.
    private var showsAppLock: Bool { appLock.isLocked && authSession.state == .signedIn }

    /// Demo IDs are not real accounts, so their purchases and telemetry stay anonymous.
    private var accountId: UUID? {
        authSession.usesDemoMode ? nil : authSession.userId
    }
}

enum LaunchEnvironment {
    /// Hosted unit tests load the app binary; XCTest sets this for the host process only.
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// UI tests launch the app with this argument so test runs never report to Sentry.
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")

    /// UI tests pass this to start from empty demo storage (Debug builds only).
    static let resetsLocalData = ProcessInfo.processInfo.arguments.contains("-resetLocalData")

    static var isAutomatedTest: Bool { isUnitTestHost || isUITesting }
}

#if DEBUG
/// UI tests start from empty demo storage. The simulator's own data is set
/// aside first and put back on the next normal launch, so running the UI
/// tests never costs a developer their demo expenses or preferences.
enum UITestStorage {
    static let defaultBackupURL = URL.applicationSupportDirectory.appending(path: "ui-test-defaults-backup.plist")

    static func setAsideAndClear(
        defaults: UserDefaults = .standard,
        domain: String = Bundle.main.bundleIdentifier ?? "",
        backupURL: URL = defaultBackupURL
    ) {
        // Later launches in the same test run must not replace the real data with test data.
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            let saved = defaults.persistentDomain(forName: domain) ?? [:]
            try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0).write(to: backupURL)) != nil else {
                return
            }
        }
        defaults.removePersistentDomain(forName: domain)
    }

    static func restore(
        defaults: UserDefaults = .standard,
        domain: String = Bundle.main.bundleIdentifier ?? "",
        backupURL: URL = defaultBackupURL
    ) {
        guard let data = try? Data(contentsOf: backupURL),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        defaults.setPersistentDomain(saved, forName: domain)
        try? FileManager.default.removeItem(at: backupURL)
    }
}
#endif

/// Sends stable operation labels only; never pass backend errors or user content here.
enum LoamErrorCapture {
    static func capture(_ event: String) {
        let error = NSError(
            domain: "Loam.ManualCapture.\(event)",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: event]
        )
        SentrySDK.capture(error: error)
    }

    @discardableResult
    static func withCapture<Value>(
        _ event: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            if !isCancellation(error) {
                capture(event)
            }
            throw error
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
