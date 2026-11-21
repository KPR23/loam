import SwiftUI

struct MainTabView: View {
    enum AppTab: Hashable {
        case expenses
        case balances
        case activity
        case profile
        /// The Add expense form, set apart at the end of the tab bar on iOS 26 and later.
        case addExpense

        var screenName: String {
            switch self {
            case .expenses: "Expenses"
            case .balances: "Balances"
            case .activity: "Activity"
            case .profile: "Profile"
            case .addExpense: "Add expense"
            }
        }
    }

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var activityStore: ActivityStore
    @EnvironmentObject private var pushStore: PushNotificationStore
    @EnvironmentObject private var navigator: AppNavigator
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .expenses
    @State private var showAddExpense = false
    /// The tab to return to when the Add expense tab is cancelled.
    @State private var lastContentTab: AppTab = .expenses
    /// A new value gives the Add expense tab a fresh, empty form.
    @State private var addExpenseFormID = UUID()
    /// Set when code, not a tab bar tap, opens the Add expense tab, so the open isn't counted twice.
    @State private var addExpenseOpenedInCode = false
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
        .tint(accentColor.color)
        .onChange(of: selection) { _, newValue in
            if newValue == .expenses {
                expensesReloadToken += 1
            }
            if newValue == .addExpense {
                if !addExpenseOpenedInCode {
                    Telemetry.capture(.addExpenseOpened(source: .tabBar))
                }
                addExpenseOpenedInCode = false
            } else {
                lastContentTab = newValue
            }
        }
        // Opening Add expense gets a firmer tap than moving between tabs.
        .sensoryFeedback(trigger: selection) { _, newValue in
            newValue == .addExpense ? .impact(weight: .medium) : .selection
        }
        .overlay(alignment: .top) { SplitwiseImportOverlay() }
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
        .onChange(of: navigator.pendingScreen, initial: true) { _, screen in
            guard let screen else { return }
            navigator.pendingScreen = nil
            show(screen)
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
        if Self.usesAddExpenseTab {
            guard selection != .addExpense else { return }
            addExpenseOpenedInCode = true
            selection = .addExpense
        } else {
            showAddExpense = true
        }
    }

    /// Cancel goes back to the tab the form was opened from; Save goes to Expenses to show the new expense.
    /// Either way the next visit starts with an empty form. A save finishes asynchronously, so if something else
    /// (say, a notification) has moved to another tab meanwhile, that tab stays.
    private func closeAddExpenseTab(saved: Bool) {
        if selection == .addExpense {
            selection = saved ? .expenses : lastContentTab
        }
        addExpenseFormID = UUID()
    }

    /// A screen Siri was asked to open.
    private func show(_ screen: LoamScreen) {
        switch screen {
        case .expenses: selection = .expenses
        case .balances: selection = .balances
        case .activity: selection = .activity
        case .profile: selection = .profile
        case .newExpense:
            if !Self.usesAddExpenseTab { selection = .expenses }
            Telemetry.capture(.addExpenseOpened(source: .siri))
            openAddExpense()
        }
    }

    /// From iOS 26 the tab bar sets one tab apart at its trailing end, and Loam gives that slot to Add expense.
    /// Earlier systems draw a role tab inline with the others, so they keep the button in Home's list.
    static var usesAddExpenseTab: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// iOS 27 has a `.prominent` role for the separated slot. On iOS 26 only the search role gets it, so the Add
    /// tab borrows that role, which means Loam can't also have a real search tab there. Xcode 26 can't build
    /// against the iOS 27 SDK, so the compiler check keeps it building there.
    @available(iOS 26.0, *)
    private var addExpenseTabRole: TabRole {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        return .search
    }

    @available(iOS 18.0, *)
    @ViewBuilder
    private var modernTabView: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $selection) {
                mainTabs
                Tab(value: AppTab.addExpense, role: addExpenseTabRole) {
                    AddExpenseView(onClose: closeAddExpenseTab)
                        .id(addExpenseFormID)
                } label: {
                    tabLabel("Add expense", systemImage: "plus")
                }
            }
        } else {
            TabView(selection: $selection) { mainTabs }
        }
    }

    @available(iOS 18.0, *)
    @TabContentBuilder<AppTab>
    private var mainTabs: some TabContent<AppTab> {
        Tab(value: AppTab.expenses) {
            HomeView(
                arcReloadToken: expensesReloadToken,
                showsAddExpenseButton: !Self.usesAddExpenseTab,
                onAddExpense: openAddExpense
            )
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
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
        .environmentObject(BalanceStore())
        .environmentObject(ActivityStore())
        .environmentObject(PushNotificationStore.shared)
        .environmentObject(AppLock())
        .environmentObject(AppNavigator())
}
