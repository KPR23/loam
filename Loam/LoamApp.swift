import SwiftUI

@main
struct LoamApp: App {
    @StateObject private var authSession = AuthSession()
    @StateObject private var expenseStore = ExpenseStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authSession)
                .environmentObject(expenseStore)
                .task {
                    await authSession.bootstrap()
                }
        }
    }
}
