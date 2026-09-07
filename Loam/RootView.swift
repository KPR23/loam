import SwiftUI

struct RootView: View {
    @EnvironmentObject private var authSession: AuthSession

    var body: some View {
        Group {
            switch authSession.state {
            case .loading:
                ProgressView("Loading…")
            case .signedOut:
                AuthView()
            case .signedIn:
                HomeView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: authSession.state)
    }
}
