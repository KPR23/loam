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
    @State private var showAddExpense = false
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
            // Opening Activity marks its events seen; elsewhere, pick up events that arrived meanwhile.
            activityStore.isInboxVisible = tab == .activity
            Task {
                if tab == .activity {
                    await activityStore.refresh(userId: authSession.userId)
                } else {
                    await activityStore.refreshBadgeCount(userId: authSession.userId)
                }
            }
        }
        .onChange(of: pushStore.pendingRoute, initial: true) { _, route in
            if route != nil { selection = .activity }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await activityStore.refreshBadgeCount(userId: authSession.userId) } }
        }
        .task(id: authSession.userId) {
            guard let userId = authSession.userId,
                  !authSession.usesDemoMode,
                  Telemetry.isAnalyticsAvailable,
                  !Telemetry.hasAnsweredAnalyticsPrompt(for: userId)
            else { return }
            showsAnalyticsPrompt = true
        }
        .sheet(isPresented: $showAddExpense) {
            AddExpenseView()
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

    private func openAddExpense() {
        showAddExpense = true
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $selection) {
            Tab(value: AppTab.expenses) {
                HomeView(arcReloadToken: expensesReloadToken, onAddExpense: openAddExpense)
            } label: {
                tabLabel("Expenses", systemImage: "creditcard")
            }

            Tab(value: AppTab.balances) {
                BalancesView()
            } label: {
                tabLabel("Balances", systemImage: "person.2")
            }

            Tab(value: AppTab.activity) {
                ActivityView()
            } label: {
                tabLabel("Activity", systemImage: "bell")
            }
            .badge(activityStore.badgeCount)

            Tab(value: AppTab.profile) {
                ProfileView()
            } label: {
                tabLabel("Profile", systemImage: "person")
            }
        }
        .tint(accentColor.color)
        .onChange(of: selection) { _, newValue in
            if newValue == .expenses {
                expensesReloadToken += 1
            }
        }
    }

    /// The bar draws every symbol filled. Liquid Glass gives the bar its own material, so icons can stand
    /// alone; earlier systems draw no bar background, so titles stay.
    @available(iOS 18.0, *)
    @ViewBuilder
    private func tabLabel(_ title: String, systemImage: String) -> some View {
        if #available(iOS 26.0, *) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private var legacyTabView: some View {
        TabView(selection: $selection) {
            HomeView(arcReloadToken: expensesReloadToken, onAddExpense: openAddExpense)
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
                .badge(activityStore.badgeCount)

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
