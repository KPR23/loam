import SwiftUI
import Sentry
import Foundation

@main
struct LoamApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("loam.appearance") private var appearance: AppAppearance = .system
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue
    @AppStorage(AppPreferences.timeZoneKey) private var timeZoneIdentifier = ""
    @StateObject private var authSession = AuthSession()
    @StateObject private var expenseStore = ExpenseStore()
    @StateObject private var balanceStore = BalanceStore()
    @StateObject private var activityStore = ActivityStore()
    @StateObject private var connectionStore = ConnectionStore()

    init() {
        #if DEBUG
        if LaunchEnvironment.resetsLocalData, let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        #endif
        // Test runs must never report to Sentry or PostHog.
        if !LaunchEnvironment.isAutomatedTest {
            Telemetry.start()
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
            .task {
                LegacyDemoFixtureCleanup.removeIfNeeded()
                await authSession.bootstrap()
            }
            .task(id: authSession.userId) {
                await connectionStore.refresh(userId: authSession.userId)
            }
            .onChange(of: authSession.userId) { _, userId in
                Telemetry.setUser(authSession.usesDemoMode ? nil : userId)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await authSession.refreshDeletionStatus()
                        await connectionStore.refresh(userId: authSession.userId)
                    }
                }
            }
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
