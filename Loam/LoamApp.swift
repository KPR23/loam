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
    @StateObject private var householdStore = HouseholdStore()
    @StateObject private var balanceStore = BalanceStore()
    @StateObject private var activityStore = ActivityStore()
    @StateObject private var connectionStore = ConnectionStore()

    init() {
        guard
            let dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String,
            !dsn.isEmpty
        else {
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = Bundle.main.object(forInfoDictionaryKey: "LOAM_ENVIRONMENT") as? String ?? "production"
            options.sendDefaultPii = false
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance.colorScheme)
                .tint(accentColor.color)
                .environment(\.timeZone, AppPreferences.timeZone(for: timeZoneIdentifier))
                .environmentObject(authSession)
                .environmentObject(expenseStore)
                .environmentObject(householdStore)
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
            capture(event)
            throw error
        }
    }
}
