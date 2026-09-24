import SwiftUI

struct MainTabView: View {
    enum AppTab: Hashable {
        case expenses
        case balances
        case activity
        case profile
    }

    @State private var selection: AppTab = .expenses
    @State private var expensesReloadToken = 0
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
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $selection) {
            Tab("Expenses", systemImage: "creditcard", value: AppTab.expenses) {
                HomeView(arcReloadToken: expensesReloadToken)
            }

            Tab("Balances", systemImage: "arrow.left.arrow.right", value: AppTab.balances) {
                BalancesView()
            }

            Tab("Activity", systemImage: "clock.arrow.circlepath", value: AppTab.activity) {
                ActivityView()
            }

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
                    Label("Balances", systemImage: "arrow.left.arrow.right")
                }
                .tag(AppTab.balances)

            ActivityView()
                .tabItem {
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppTab.activity)

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
}
