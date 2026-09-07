import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var authSession: AuthSession

    private var period = DatePeriod.currentMonth
    private let spentThisMonth = Money.zeroPLN
    private let sharedShareThisMonth = Money.zeroPLN

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    personalSummary
                    shortcuts
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign out", role: .destructive) {
                            Task { await authSession.signOut() }
                        }
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
        }
    }

    private var personalSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(period.displayTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("You spent")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(MoneyFormatter.string(from: spentThisMonth))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .accessibilityLabel("You spent \(MoneyFormatter.string(from: spentThisMonth)) this month")

            Text("of which \(MoneyFormatter.string(from: sharedShareThisMonth)) is your share of shared expenses")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var shortcuts: some View {
        VStack(spacing: 12) {
            shortcutRow(title: "Add expense", systemImage: "plus.circle.fill", subtitle: "Coming in Phase 1")
            shortcutRow(title: "Household", systemImage: "house.fill", subtitle: "Coming in Phase 2")
            shortcutRow(title: "Balances", systemImage: "arrow.left.arrow.right", subtitle: "Coming in Phase 3")
        }
    }

    private func shortcutRow(title: String, systemImage: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(0.85)
    }
}

#Preview {
    HomeView()
        .environmentObject(AuthSession())
}
