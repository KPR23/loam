import SwiftUI

struct MainTabView: View {
    enum AppTab: Hashable {
        case expenses
        case balances
        case activity
        case profile

        var screenName: String {
            switch self {
            case .expenses: "Expenses"
            case .balances: "Balances"
            case .activity: "Activity"
            case .profile: "Profile"
            }
        }
    }

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var activityStore: ActivityStore
    @EnvironmentObject private var pushStore: PushNotificationStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .expenses
    @State private var expensesReloadToken = 0
    @State private var showsAnalyticsPrompt = false
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: selection, initial: true) { _, tab in
            Telemetry.screen(tab.screenName)
            // Activity marks itself read; elsewhere, pick up events that arrived meanwhile.
            if tab != .activity { Task { await activityStore.refreshUnreadCount(userId: authSession.userId) } }
        }
        .onChange(of: pushStore.pendingRoute, initial: true) { _, route in
            if route != nil { selection = .activity }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await activityStore.refreshUnreadCount(userId: authSession.userId) } }
        }
        .task(id: authSession.userId) {
            guard let userId = authSession.userId,
                  !authSession.usesDemoMode,
                  Telemetry.isAnalyticsAvailable,
                  !Telemetry.hasAnsweredAnalyticsPrompt(for: userId)
            else { return }
            showsAnalyticsPrompt = true
        }
        .sheet(isPresented: $showsAnalyticsPrompt) {
            AnalyticsConsentSheet { granted in
                if let userId = authSession.userId {
                    Telemetry.setAnalyticsConsent(granted, for: userId)
                }
                showsAnalyticsPrompt = false
            }
        }
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $selection) {
            Tab("Expenses", systemImage: "creditcard", value: AppTab.expenses) {
                HomeView(arcReloadToken: expensesReloadToken)
            }

            Tab("Balances", systemImage: "person.2", value: AppTab.balances) {
                BalancesView()
            }

            Tab("Activity", systemImage: "bell", value: AppTab.activity) {
                ActivityView()
            }
            .badge(activityStore.unreadCount)

            Tab("Profile", systemImage: "person", value: AppTab.profile) {
                ProfileView()
            }
        }
        .tint(accentColor.color)
        .onChange(of: selection) { _, newValue in
            if newValue == .expenses {
                expensesReloadToken += 1
            }
        }
    }

    private var legacyTabView: some View {
        TabView(selection: $selection) {
            HomeView(arcReloadToken: expensesReloadToken)
                .tabItem {
                    Label("Expenses", systemImage: "creditcard")
                }
                .tag(AppTab.expenses)

            BalancesView()
                .tabItem {
                    Label("Balances", systemImage: "person.2")
                }
                .tag(AppTab.balances)

            ActivityView()
                .tabItem {
                    Label("Activity", systemImage: "bell")
                }
                .tag(AppTab.activity)
                .badge(activityStore.unreadCount)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person")
                }
                .tag(AppTab.profile)
        }
        .tint(accentColor.color)
        .onChange(of: selection) { _, newValue in
            if newValue == .expenses {
                expensesReloadToken += 1
            }
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
        .environmentObject(BalanceStore())
        .environmentObject(ActivityStore())
        .environmentObject(PushNotificationStore.shared)
}
