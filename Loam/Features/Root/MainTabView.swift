import SwiftUI

struct MainTabView: View {
    enum Tab: Hashable {
        case expenses
        case household
        case profile
    }

    @State private var selection: Tab = .expenses
    @State private var expensesReloadToken = 0

    var body: some View {
        TabView(selection: $selection) {
            HomeView(arcReloadToken: expensesReloadToken)
                .tabItem {
                    Label("Expenses", systemImage: "creditcard")
                }
                .tag(Tab.expenses)

            HouseholdView()
                .tabItem {
                    Label("Household", systemImage: "house")
                }
                .tag(Tab.household)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person")
                }
                .tag(Tab.profile)
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
}
