import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore

    var arcReloadToken: Int = 0
    @State private var showAddExpense = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MonthlySpendHero(
                        amount: expenseStore.summary.totalMine,
                        progress: MonthlyBudgetPlaceholder.progress,
                        sharedShare: expenseStore.summary.sharedShare,
                        reloadToken: arcReloadToken
                    )
                    expenseList
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle(expenseStore.period.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HomeTheme.background, for: .navigationBar)
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
            .sheet(isPresented: $showAddExpense) {
                AddExpenseView()
            }
            .task(id: authSession.userId) {
                await expenseStore.refresh(userId: authSession.userId)
            }
            .refreshable {
                await expenseStore.refresh(userId: authSession.userId)
            }
        }
    }

    @ViewBuilder
    private var expenseList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This month")
                .font(.headline)

            if expenseStore.isLoading && expenseStore.expenses.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if expenseStore.expenses.isEmpty {
                Text("No expenses yet. Add one in a few taps.")
                    .font(.subheadline)
                    .foregroundStyle(HomeTheme.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(expenseStore.expenses) { expense in
                    expenseRow(expense)
                }
            }

            if let error = expenseStore.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if SupabaseConfig.isConfigured {
                Text("Synced with Supabase")
                    .font(.caption2)
                    .foregroundStyle(HomeTheme.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }

    private func expenseRow(_ expense: ExpenseRecord) -> some View {
        let mine = authSession.userId.map { expense.share(for: $0) } ?? expense.money

        return HStack(spacing: 14) {
            Image(systemName: expense.category.systemImage)
                .font(.title3)
                .foregroundStyle(HomeTheme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.category.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(HomeTheme.text)
                HStack(spacing: 6) {
                    Text(expense.spentAt, format: .dateTime.month(.abbreviated).day())
                    if let note = expense.note, !note.isEmpty {
                        Text("·")
                        Text(note)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(HomeTheme.secondary)
            }

            Spacer()

            Text(MoneyFormatter.string(from: mine))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(HomeTheme.text)
        }
        .padding(14)
        .background(HomeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: HomeTheme.rowRadius, style: .continuous))
        .contextMenu {
            Button("Delete", role: .destructive) {
                guard let userId = authSession.userId else { return }
                Task { await expenseStore.delete(id: expense.id, userId: userId) }
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
