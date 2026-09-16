import SwiftUI

struct MainTabView: View {
    enum AppTab: Hashable {
        case expenses
        case balances
        case profile
    }

    @State private var selection: AppTab = .expenses
    @State private var expensesReloadToken = 0

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $selection) {
            Tab("Expenses", systemImage: "creditcard", value: AppTab.expenses) {
                HomeView(arcReloadToken: expensesReloadToken)
            }

            Tab("Balances", systemImage: "scale.3d", value: AppTab.balances) {
                BalancesView()
            }

            Tab("Profile", systemImage: "person", value: AppTab.profile) {
                ProfileView()
            }
        }
        .tint(HomeTheme.accent)
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
                    Label("Balances", systemImage: "scale.3d")
                }
                .tag(AppTab.balances)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person")
                }
                .tag(AppTab.profile)
        }
        .tint(HomeTheme.accent)
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
        .environmentObject(HouseholdStore())
        .environmentObject(BalanceStore())
}
