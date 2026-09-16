import SwiftUI

@main
struct LoamApp: App {
    @StateObject private var authSession = AuthSession()
    @StateObject private var expenseStore = ExpenseStore()
    @StateObject private var householdStore = HouseholdStore()
    @StateObject private var balanceStore = BalanceStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authSession)
                .environmentObject(expenseStore)
                .environmentObject(householdStore)
                .environmentObject(balanceStore)
                .task {
                    LegacyDemoFixtureCleanup.removeIfNeeded()
                    await authSession.bootstrap()
                }
        }
    }
}
