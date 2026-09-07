import SwiftUI

@main
struct LoamApp: App {
    @StateObject private var authSession = AuthSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authSession)
                .task {
                    await authSession.bootstrap()
                }
        }
    }
}
