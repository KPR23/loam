import SwiftUI

struct MainTabView: View {
    enum AppTab: Hashable {
        case expenses
        case household
        case profile
        case add
    }

    @State private var selection: AppTab = .expenses
    @State private var lastContentTab: AppTab = .expenses
    @State private var expensesReloadToken = 0
    @State private var showAddExpense = false

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        .sheet(isPresented: $showAddExpense) {
            AddExpenseView()
        }
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $selection) {
            Tab("Expenses", systemImage: "creditcard", value: AppTab.expenses) {
                HomeView(arcReloadToken: expensesReloadToken)
                    .toolbar {
                        if !Self.hasNativeAddTab {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showAddExpense = true
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .accessibilityLabel("Add expense")
                            }
                        }
                    }
            }

            Tab("Household", systemImage: "house", value: AppTab.household) {
                HouseholdView()
            }

            Tab("Profile", systemImage: "person", value: AppTab.profile) {
                ProfileView()
            }

            if #available(iOS 26.0, *) {
                Tab(value: AppTab.add, role: .search) {
                    Color.clear
                        .accessibilityHidden(true)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add expense")
            }
        }
        .tint(HomeTheme.accent)
        .onChange(of: selection) { _, newValue in
            handleTabChange(newValue)
        }
    }

    private var legacyTabView: some View {
        TabView(selection: $selection) {
            HomeView(arcReloadToken: expensesReloadToken)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAddExpense = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add expense")
                    }
                }
                .tabItem {
                Label("Expenses", systemImage: "creditcard")
            }
            .tag(AppTab.expenses)

            HouseholdView()
                .tabItem {
                    Label("Household", systemImage: "house")
                }
                .tag(AppTab.household)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person")
                }
                .tag(AppTab.profile)
        }
        .tint(HomeTheme.accent)
        .onChange(of: selection) { _, newValue in
            handleTabChange(newValue)
        }
    }

    private func handleTabChange(_ newValue: AppTab) {
        if newValue == .add {
            showAddExpense = true
            selection = lastContentTab
            return
        }

        lastContentTab = newValue

        if newValue == .expenses {
            expensesReloadToken += 1
        }
    }

    private static var hasNativeAddTab: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
