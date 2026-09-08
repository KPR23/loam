import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore

    var arcReloadToken: Int = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MonthlySpendHero(
                        amount: expenseStore.summary.totalMine,
                        progress: MonthlyBudgetPlaceholder.progress,
                        sharedShare: expenseStore.summary.sharedShare,
                        reloadToken: arcReloadToken
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                expenseList
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle(expenseStore.period.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HomeTheme.background, for: .navigationBar)
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
        if expenseStore.isLoading && expenseStore.expenses.isEmpty {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } else if expenseStore.expenses.isEmpty {
            Section {
                Text("No expenses yet. Add one in a few taps.")
                    .foregroundStyle(HomeTheme.secondary)
            }
        } else {
            ForEach(expensesByDay, id: \.date) { section in
                Section {
                    ForEach(section.expenses) { expense in
                        expenseRow(expense)
                    }
                } header: {
                    daySectionHeader(date: section.date, expenses: section.expenses)
                }
            }
        }

        if let error = expenseStore.lastError {
            Section {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var expensesByDay: [(date: Date, expenses: [ExpenseRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: expenseStore.expenses) { expense in
            calendar.startOfDay(for: expense.spentAt)
        }
        return grouped
            .map { date, expenses in
                (
                    date: date,
                    expenses: expenses.sorted { $0.createdAt > $1.createdAt }
                )
            }
            .sorted { $0.date > $1.date }
    }

    private func daySectionHeader(date: Date, expenses: [ExpenseRecord]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(daySectionTitle(for: date))
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(HomeTheme.secondary)
            Spacer()
            Text(MoneyFormatter.string(from: dayTotal(for: expenses)))
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(HomeTheme.secondary)
                .monospacedDigit()
        }
        .textCase(nil)
    }

    private func daySectionTitle(for date: Date) -> String {
        let calendar = Calendar.current
        let dayMonth = date.formatted(.dateTime.day().month(.abbreviated))

        let prefix: String
        if calendar.isDateInToday(date) {
            prefix = "Today"
        } else if calendar.isDateInYesterday(date) {
            prefix = "Yesterday"
        } else {
            prefix = date.formatted(.dateTime.weekday(.wide))
        }

        return "\(prefix), \(dayMonth)"
    }

    private func dayTotal(for expenses: [ExpenseRecord]) -> Money {
        guard let userId = authSession.userId else {
            return expenses.first?.money ?? Money(amountMinor: 0, currencyCode: "PLN")
        }
        let minor = expenses.reduce(0) { partial, expense in
            partial + (expense.shares.first(where: { $0.userId == userId })?.amountMinor ?? 0)
        }
        let currency = expenses.first?.currency ?? "PLN"
        return Money(amountMinor: minor, currencyCode: currency)
    }

    private func expenseRow(_ expense: ExpenseRecord) -> some View {
        let mine = authSession.userId.map { expense.share(for: $0) } ?? expense.money

        return LabeledContent {
            Text(MoneyFormatter.string(from: mine))
                .monospacedDigit()
        } label: {
            if let note = expense.note, !note.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    categoryLabel(expense)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(HomeTheme.secondary)
                }
            } else {
                categoryLabel(expense)
            }
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                guard let userId = authSession.userId else { return }
                Task { await expenseStore.delete(id: expense.id, userId: userId) }
            }
        }
    }

    private func categoryLabel(_ expense: ExpenseRecord) -> some View {
        Label {
            Text(expense.category.displayName)
        } icon: {
            Image(systemName: expense.category.systemImage)
                .font(.callout)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(expense.category.color)
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
