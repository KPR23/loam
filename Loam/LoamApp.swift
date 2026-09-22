import SwiftUI

@main
struct LoamApp: App {
    @AppStorage("loam.appearance") private var appearance: AppAppearance = .system
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue
    @AppStorage(AppPreferences.timeZoneKey) private var timeZoneIdentifier = ""
    @StateObject private var authSession = AuthSession()
    @StateObject private var expenseStore = ExpenseStore()
    @StateObject private var householdStore = HouseholdStore()
    @StateObject private var balanceStore = BalanceStore()
    @StateObject private var activityStore = ActivityStore()

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
                .task {
                    LegacyDemoFixtureCleanup.removeIfNeeded()
                    await authSession.bootstrap()
                }
        }
    }
}
