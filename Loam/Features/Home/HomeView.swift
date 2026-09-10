import SwiftUI

private struct SplitExpensePresentation: Identifiable {
    let expense: ExpenseRecord
    let myUserId: UUID

    var id: UUID { expense.id }
}

private struct ProposeEditPresentation: Identifiable {
    let expense: ExpenseRecord
    let myUserId: UUID

    var id: UUID { expense.id }
}

struct HomeView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore

    var arcReloadToken: Int = 0

    @State private var showAddExpense = false
    @State private var showMonthPicker = false
    @State private var collapseProgress: CGFloat = 0
    @State private var arcReveal: Double = 0
    @State private var expensePendingDelete: ExpenseRecord?
    @State private var expensePendingSplit: SplitExpensePresentation?
    @State private var expensePendingProposeEdit: ProposeEditPresentation?
    @State private var selectedExpense: ExpenseRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MonthlySpendHero(
                        amount: expenseStore.summary.totalMine,
                        categoryBreakdown: expenseStore.summary.categoryBreakdown,
                        sharedShare: expenseStore.summary.sharedShare,
                        reloadToken: arcReloadToken,
                        collapseProgress: collapseProgress,
                        displayedReveal: $arcReveal
                    )
                    .reportHomeHeroScrollOffset()
                    .listRowInsets(EdgeInsets(top: -2, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                pendingAcceptanceSection
                incomingProposalsSection
                expenseList
            }
            .listStyle(.insetGrouped)
            .coordinateSpace(name: "homeScroll")
            .trackHomeScrollCollapse($collapseProgress)
            .contentMargins(.top, 2, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .homeTranslucentNavigationBar(collapseProgress: collapseProgress)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HomeCollapsingTopBar(
                        period: expenseStore.period,
                        amount: expenseStore.summary.totalMine,
                        collapseProgress: collapseProgress,
                        onPickMonth: { showMonthPicker = true }
                    )
                }
                if collapseProgress > 0.15 {
                    ToolbarItem(placement: .topBarTrailing) {
                        HomeTopBarCalendarButton(
                            period: expenseStore.period,
                            onPickMonth: { showMonthPicker = true }
                        )
                    }
                }
            }
            .task(id: authSession.userId) {
                await expenseStore.refresh(userId: authSession.userId)
            }
            .refreshable {
                await expenseStore.refresh(userId: authSession.userId)
            }
            .overlay(alignment: .bottomTrailing) {
                AddExpenseFAB {
                    showAddExpense = true
                }
                .padding(.trailing, 20)
                .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showAddExpense) {
            AddExpenseView()
        }
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(period: expenseStore.period) { newPeriod in
                guard let userId = authSession.userId else { return }
                Task { await expenseStore.setPeriod(newPeriod, userId: userId) }
            }
        }
        .sheet(item: $expensePendingSplit) { presentation in
            SplitExpenseSheet(expense: presentation.expense, myUserId: presentation.myUserId)
        }
        .sheet(item: $expensePendingProposeEdit) { presentation in
            ProposeEditSheet(expense: presentation.expense, myUserId: presentation.myUserId)
        }
        .sheet(item: $selectedExpense) { expense in
            ExpenseDetailSheet(
                expense: expense,
                onSplit: canSplit(expense) ? {
                    let target = expense
                    selectedExpense = nil
                    presentSplit(for: target)
                } : nil,
                onDelete: {
                    let target = expense
                    selectedExpense = nil
                    expensePendingDelete = target
                }
            )
        }
        .alert(
            "Delete this expense?",
            isPresented: Binding(
                get: { expensePendingDelete != nil },
                set: { if !$0 { expensePendingDelete = nil } }
            )
        ) {
            if let expense = expensePendingDelete, expense.isShared, canSplit(expense) {
                Button("Edit split") {
                    expensePendingDelete = nil
                    presentSplit(for: expense)
                }
            }
            Button("Delete", role: .destructive) {
                guard let expense = expensePendingDelete, let userId = authSession.userId else { return }
                Task { await expenseStore.delete(id: expense.id, userId: userId) }
                expensePendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                expensePendingDelete = nil
            }
        } message: {
            if let expense = expensePendingDelete {
                Text(deleteConfirmationMessage(for: expense))
            }
        }
    }

    @ViewBuilder
    private var pendingAcceptanceSection: some View {
        if let userId = authSession.userId, !expenseStore.pendingAcceptanceExpenses.isEmpty {
            Section {
                ForEach(expenseStore.pendingAcceptanceExpenses) { expense in
                    PendingExpenseRow(
                        expense: expense,
                        myUserId: userId,
                        creatorName: SplitPartnerOption.displayName(for: expense.createdBy),
                        onAccept: {
                            Task {
                                await expenseStore.respondToShare(
                                    expenseId: expense.id,
                                    userId: userId,
                                    action: .accept
                                )
                            }
                        },
                        onAcceptWithTrust: {
                            Task {
                                await expenseStore.respondToShare(
                                    expenseId: expense.id,
                                    userId: userId,
                                    action: .acceptWithTrust
                                )
                            }
                        },
                        onReject: {
                            Task {
                                await expenseStore.respondToShare(
                                    expenseId: expense.id,
                                    userId: userId,
                                    action: .reject
                                )
                            }
                        },
                        onProposeEdit: {
                            expensePendingProposeEdit = ProposeEditPresentation(expense: expense, myUserId: userId)
                        }
                    )
                }
            } header: {
                pendingSectionHeader(expenses: expenseStore.pendingAcceptanceExpenses)
            }
        }
    }

    private func pendingSectionHeader(expenses: [ExpenseRecord]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Awaiting your approval")
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(HomeTheme.secondary)
            Spacer()
            Text(MoneyFormatter.string(from: pendingTotal(for: expenses)))
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(HomeTheme.secondary)
                .monospacedDigit()
        }
        .textCase(nil)
    }

    private func pendingTotal(for expenses: [ExpenseRecord]) -> Money {
        guard let userId = authSession.userId else {
            return Money(amountMinor: 0, currencyCode: "PLN")
        }
        let minor = expenses.reduce(0) { partial, expense in
            partial + (expense.shareRecord(for: userId)?.amountMinor ?? 0)
        }
        let currency = expenses.first?.currency ?? "PLN"
        return Money(amountMinor: minor, currencyCode: currency)
    }

    @ViewBuilder
    private var incomingProposalsSection: some View {
        if let userId = authSession.userId {
            let proposals = expenseStore.incomingProposals(for: userId)
            if !proposals.isEmpty {
                Section {
                    ForEach(proposals) { proposal in
                        if let expense = expenseStore.expense(forProposal: proposal) {
                            EditProposalReviewCard(
                                proposal: proposal,
                                expense: expense,
                                proposerName: SplitPartnerOption.displayName(for: proposal.proposedBy),
                                onAccept: {
                                    Task {
                                        await expenseStore.respondToProposal(
                                            proposalId: proposal.id,
                                            userId: userId,
                                            accept: true
                                        )
                                    }
                                },
                                onReject: {
                                    Task {
                                        await expenseStore.respondToProposal(
                                            proposalId: proposal.id,
                                            userId: userId,
                                            accept: false
                                        )
                                    }
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    Text("Suggested edits")
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                }
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
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    expensePendingDelete = expense
                                } label: {
                                    Label {
                                        Text("Delete")
                                            .fontWeight(.semibold)
                                    } icon: {
                                        Image(systemName: "trash")
                                    }
                                }
                                .tint(.red)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if canSplit(expense) {
                                    Button {
                                        presentSplit(for: expense)
                                    } label: {
                                        Label {
                                            Text(expense.isShared ? "Edit split" : "Split")
                                                .fontWeight(.semibold)
                                        } icon: {
                                            Image(systemName: "person.2")
                                        }
                                    }
                                    .tint(HomeTheme.accent)
                                }
                            }
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
        let listedExpenses = expenseStore.expenses.filter { expense in
            guard let userId = authSession.userId else { return true }
            return !expense.isPendingAcceptance(for: userId)
        }
        let grouped = Dictionary(grouping: listedExpenses) { expense in
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
            partial + expense.acceptedShareMinor(for: userId)
        }
        let currency = expenses.first?.currency ?? "PLN"
        return Money(amountMinor: minor, currencyCode: currency)
    }

    private func expenseRow(_ expense: ExpenseRecord) -> some View {
        expenseRowContent(expense)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedExpense = expense
            }
            .contextMenu {
                if canSplit(expense) {
                    Button(expense.isShared ? "Edit split" : "Split", systemImage: "person.2") {
                        presentSplit(for: expense)
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    expensePendingDelete = expense
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows expense details")
    }

    private func expenseRowContent(_ expense: ExpenseRecord) -> some View {
        let userId = authSession.userId
        let mine = userId.map { expense.share(for: $0) } ?? expense.money

        return LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    if expense.isShared {
                        Image(systemName: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(HomeTheme.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(MoneyFormatter.string(from: mine))
                        .monospacedDigit()
                }
                if expense.isShared {
                    Text("of \(MoneyFormatter.string(from: expense.money))")
                        .font(.caption2)
                        .foregroundStyle(HomeTheme.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                expense.isShared
                    ? "Your share \(MoneyFormatter.string(from: mine)), shared expense"
                    : MoneyFormatter.string(from: mine)
            )
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                categoryLabel(expense)
                if let note = expense.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(HomeTheme.secondary)
                }
            }
        }
    }

    private func canSplit(_ expense: ExpenseRecord) -> Bool {
        expense.recurringId == nil
            && SplitPartnerOption.isSplitAvailable(usesRemoteBackend: SupabaseConfig.isConfigured)
    }

    private func presentSplit(for expense: ExpenseRecord) {
        guard let userId = authSession.userId else { return }
        expensePendingSplit = SplitExpensePresentation(expense: expense, myUserId: userId)
    }

    private func deleteConfirmationMessage(for expense: ExpenseRecord) -> String {
        var message = "\(expense.category.displayName) · \(MoneyFormatter.string(from: expense.money))"
        if expense.isShared, let userId = authSession.userId {
            let partnerIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: userId)
            let partnerNames = SplitPartnerOption.displayNames(for: partnerIds)
            message += "\n\nThis will also remove the expense for \(partnerNames)."
        }
        return message
    }

    private func categoryLabel(_ expense: ExpenseRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: expense.category.systemImage)
                .font(.callout)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(expense.category.color)
                .frame(width: 22, alignment: .center)
            Text(expense.category.displayName)
        }
    }
}

private struct AddExpenseFAB: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.primary))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add expense")
    }
}

#Preview {
    HomeView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
