import SwiftUI

struct MainTabView: View {
    enum AppTab: Hashable {
        case expenses
        case household
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

            Tab("Household", systemImage: "house", value: AppTab.household) {
                HouseholdView()
            }

            Tab("Profile", systemImage: "person", value: AppTab.profile) {
                ProfileView()
            }
        }
        .tint(.blue)
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
        .tint(.blue)
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
}
