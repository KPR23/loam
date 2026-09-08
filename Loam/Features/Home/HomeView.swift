import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore

    @State private var showAddExpense = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    personalSummary
                    addShortcut
                    expenseList
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

    private var personalSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(expenseStore.period.displayTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("You spent")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(MoneyFormatter.string(from: expenseStore.summary.totalMine))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .accessibilityLabel(
                    "You spent \(MoneyFormatter.string(from: expenseStore.summary.totalMine)) this month"
                )

            Text(
                "of which \(MoneyFormatter.string(from: expenseStore.summary.sharedShare)) is your share of shared expenses"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var addShortcut: some View {
        Button {
            showAddExpense = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                Text("Add expense")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.tertiary)
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.category.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(expense.spentAt, format: .dateTime.month(.abbreviated).day())
                    if let note = expense.note, !note.isEmpty {
                        Text("·")
                        Text(note)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(MoneyFormatter.string(from: mine))
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
