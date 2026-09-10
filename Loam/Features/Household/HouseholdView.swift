import SwiftUI

struct HouseholdView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var householdStore: HouseholdStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryCard

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shared expenses")
                            .font(.headline)

                        if sharedExpenses.isEmpty {
                            Text("No shared expenses this month. Split an expense with Julia or Philip from the add screen.")
                                .font(.subheadline)
                                .foregroundStyle(HomeTheme.secondary)
                        } else {
                            ForEach(sharedExpenses) { expense in
                                sharedRow(expense)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle("Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HomeTheme.background, for: .navigationBar)
            .task(id: authSession.userId) {
                await expenseStore.refresh(userId: authSession.userId)
                await householdStore.refresh(userId: authSession.userId)
            }
            .refreshable {
                await expenseStore.refresh(userId: authSession.userId)
            }
        }
    }

    private var sharedExpenses: [ExpenseRecord] {
        guard let userId = authSession.userId else {
            return expenseStore.expenses.filter(\.isShared)
        }
        return expenseStore.expenses.filter { $0.isShared && $0.countsTowardSummary(for: userId) }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(expenseStore.period.displayTitle)
                .font(.footnote)
                .foregroundStyle(HomeTheme.secondary)

            Text(MoneyFormatter.string(from: expenseStore.summary.sharedShare))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Text("your share of the household budget")
                .font(.subheadline)
                .foregroundStyle(HomeTheme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(HomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: HomeTheme.rowRadius, style: .continuous))
    }

    private func sharedRow(_ expense: ExpenseRecord) -> some View {
        let mine = authSession.userId.map { expense.share(for: $0) } ?? expense.money
        let paidByMe = expense.paidBy == authSession.userId

        return HStack(spacing: 14) {
            Image(systemName: expense.category.systemImage)
                .font(.title3)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(expense.category.color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.category.displayName)
                    .font(.body.weight(.medium))
                Text(expense.spentAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(HomeTheme.secondary)
                Text(paidByMe ? "You paid" : "\(payerName(for: expense)) paid")
                    .font(.caption2)
                    .foregroundStyle(HomeTheme.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormatter.string(from: mine))
                    .font(.body.weight(.semibold).monospacedDigit())
                Text("of \(MoneyFormatter.string(from: expense.money))")
                    .font(.caption2)
                    .foregroundStyle(HomeTheme.secondary)
            }
        }
        .padding(14)
        .background(HomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: HomeTheme.rowRadius, style: .continuous))
    }

    private func payerName(for expense: ExpenseRecord) -> String {
        SplitPartnerOption.displayName(for: expense.paidBy)
    }
}

#Preview {
    HouseholdView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
        .environmentObject(HouseholdStore())
}
