import SwiftUI

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
