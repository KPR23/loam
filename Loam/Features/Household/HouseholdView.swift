import SwiftUI

struct HouseholdView: View {
    @EnvironmentObject private var expenseStore: ExpenseStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryCard

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shared expenses")
                            .font(.headline)

                        if sharedExpenses.isEmpty {
                            Text("No shared expenses this month. Household splitting arrives with invites.")
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
        }
    }

    private var sharedExpenses: [ExpenseRecord] {
        expenseStore.expenses.filter(\.isShared)
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
        HStack(spacing: 14) {
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
            }

            Spacer()

            Text(MoneyFormatter.string(from: expense.money))
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(14)
        .background(HomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: HomeTheme.rowRadius, style: .continuous))
    }
}

#Preview {
    HouseholdView()
        .environmentObject(ExpenseStore())
}
