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

private struct EditExpensePresentation: Identifiable {
    let expense: ExpenseRecord

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
    @State private var expensePendingEdit: EditExpensePresentation?
    @State private var selectedExpense: ExpenseRecord?
    @State private var showAllPendingExpenses = false

    private let homePendingPreviewLimit = 2

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
        .sheet(item: $expensePendingEdit) { presentation in
            AddExpenseView(existingExpense: presentation.expense)
        }
        .sheet(isPresented: $showAllPendingExpenses) {
            if let userId = authSession.userId {
                PendingExpensesSheet(myUserId: userId)
            }
        }
        .sheet(item: $selectedExpense) { expense in
            let isPendingAcceptance = authSession.userId.map { expense.isPendingAcceptance(for: $0) } ?? false
            ExpenseDetailSheet(
                expense: expense,
                onEdit: (!isPendingAcceptance && canEdit(expense)) ? {
                    let target = expense
                    selectedExpense = nil
                    presentEdit(for: target)
                } : nil,
                onSplit: (!isPendingAcceptance && canSplit(expense)) ? {
                    let target = expense
                    selectedExpense = nil
                    presentSplit(for: target)
                } : nil,
                onDelete: isPendingAcceptance ? nil : {
                    let target = expense
                    selectedExpense = nil
                    presentDeleteConfirmation(for: target)
                },
                pendingActions: pendingDetailActions(for: expense)
            )
        }
        .alert(
            "Delete this expense?",
            isPresented: Binding(
                get: { expensePendingDelete?.isRecurring == false },
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
        .alert(
            "Delete recurring expense?",
            isPresented: Binding(
                get: { expensePendingDelete?.isRecurring == true },
                set: { if !$0 { expensePendingDelete = nil } }
            )
        ) {
            Button("Delete this occurrence only") {
                deletePendingRecurringExpense(mode: .occurrenceOnly)
            }
            Button("Delete and stop repeating", role: .destructive) {
                deletePendingRecurringExpense(mode: .stopRecurring)
            }
            Button("Cancel", role: .cancel) {
                expensePendingDelete = nil
            }
        } message: {
            if let expense = expensePendingDelete {
                Text(recurringDeleteConfirmationMessage(for: expense))
            }
        }
    }

    @ViewBuilder
    private var pendingAcceptanceSection: some View {
        if let userId = authSession.userId {
            let allPending = expenseStore.pendingAcceptanceExpenses
            if !allPending.isEmpty {
                let preview = Array(allPending.prefix(homePendingPreviewLimit))
                let remainingCount = allPending.count - preview.count

                Section {
                    ForEach(preview) { expense in
                        PendingExpenseListRow(
                            expense: expense,
                            myUserId: userId,
                            onProposeEdit: {
                                expensePendingProposeEdit = ProposeEditPresentation(
                                    expense: expense,
                                    myUserId: userId
                                )
                            },
                            onShowDetails: {
                                selectedExpense = expense
                            }
                        )
                    }

                    if remainingCount > 0 {
                        Button {
                            showAllPendingExpenses = true
                        } label: {
                            HStack {
                                Text("See all")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(HomeTheme.tertiary)
                            }
                        }
                        .tint(HomeTheme.text)
                        .accessibilityHint("Shows all expenses awaiting your approval")
                    }
                } header: {
                    PendingAcceptanceFormatting.sectionHeader(
                        expenses: allPending,
                        userId: userId,
                        previewLimit: homePendingPreviewLimit
                    )
                }
            }
        }
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
                                // Avoid `role: .destructive` — it triggers immediate row removal
                                // before the confirmation alert; tint keeps the delete styling.
                                Button {
                                    presentDeleteConfirmation(for: expense)
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
                                if canEdit(expense) {
                                    Button {
                                        presentEdit(for: expense)
                                    } label: {
                                        Label {
                                            Text("Edit")
                                                .fontWeight(.semibold)
                                        } icon: {
                                            Image(systemName: "pencil")
                                        }
                                    }
                                    .tint(HomeTheme.recurringHighlight)
                                }
                                if canSplit(expense) {
                                    Button {
                                        presentSplit(for: expense)
                                    } label: {
                                        Label {
                                            Text(expense.isShared ? "Edit split" : "Split")
                                                .fontWeight(.semibold)
                                        } icon: {
                                            Image(systemName: expense.sharedSplitSystemImage(for: authSession.userId))
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
                .font(.system(.subheadline, design: .rounded))
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
        HomeExpenseRow(
            expense: expense,
            myUserId: authSession.userId,
            highlightsRecurringIcon: expenseStore.isInitialRecurringOccurrence(expense)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedExpense = expense
        }
        .contextMenu {
            if canEdit(expense) {
                Button("Edit", systemImage: "pencil") {
                    presentEdit(for: expense)
                }
            }
            if canSplit(expense) {
                Button(
                    expense.isShared ? "Edit split" : "Split",
                    systemImage: expense.sharedSplitSystemImage(for: authSession.userId)
                ) {
                    presentSplit(for: expense)
                }
            }
            Button(role: .destructive) {
                presentDeleteConfirmation(for: expense)
            } label: {
                DestructiveMenuLabel(title: "Delete", systemImage: "trash")
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows expense details")
    }

    private func canSplit(_ expense: ExpenseRecord) -> Bool {
        SplitPartnerOption.isSplitAvailable(usesRemoteBackend: SupabaseConfig.isConfigured)
    }

    private func canEdit(_ expense: ExpenseRecord) -> Bool {
        guard let userId = authSession.userId else { return false }
        return expense.createdBy == userId
    }

    private func pendingDetailActions(for expense: ExpenseRecord) -> ExpenseDetailPendingActions? {
        guard let userId = authSession.userId, expense.isPendingAcceptance(for: userId) else {
            return nil
        }
        let creatorName = SplitPartnerOption.displayName(for: expense.createdBy)
        return ExpenseDetailPendingActions(
            creatorName: creatorName,
            onAccept: {
                selectedExpense = nil
                Task {
                    await expenseStore.respondToShare(
                        expenseId: expense.id,
                        userId: userId,
                        action: .accept
                    )
                }
            },
            onAcceptWithTrust: {
                selectedExpense = nil
                Task {
                    await expenseStore.respondToShare(
                        expenseId: expense.id,
                        userId: userId,
                        action: .acceptWithTrust
                    )
                }
            },
            onReject: {
                selectedExpense = nil
                Task {
                    await expenseStore.respondToShare(
                        expenseId: expense.id,
                        userId: userId,
                        action: .reject
                    )
                }
            },
            onProposeEdit: {
                selectedExpense = nil
                expensePendingProposeEdit = ProposeEditPresentation(expense: expense, myUserId: userId)
            }
        )
    }

    private func presentSplit(for expense: ExpenseRecord) {
        guard let userId = authSession.userId else { return }
        expensePendingSplit = SplitExpensePresentation(expense: expense, myUserId: userId)
    }

    private func presentEdit(for expense: ExpenseRecord) {
        expensePendingEdit = EditExpensePresentation(expense: expense)
    }

    private func presentDeleteConfirmation(for expense: ExpenseRecord) {
        // Defer until swipe actions finish dismissing so the row stays put until confirmed.
        Task { @MainActor in
            expensePendingDelete = expense
        }
    }

    private func deleteConfirmationMessage(for expense: ExpenseRecord) -> String {
        var message = "\(expense.displayTitle) · \(MoneyFormatter.string(from: expense.money))"
        if expense.isShared, let userId = authSession.userId {
            let partnerIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: userId)
            let partnerNames = SplitPartnerOption.displayNames(for: partnerIds)
            message += "\n\nThis will also remove the expense for \(partnerNames)."
        }
        return message
    }

    private func recurringDeleteConfirmationMessage(for expense: ExpenseRecord) -> String {
        var message = "\(expense.displayTitle) · \(MoneyFormatter.string(from: expense.money))"
        message += "\n\nChoose whether to remove only this month's charge or stop the recurring expense entirely."
        if expense.isShared, let userId = authSession.userId {
            let partnerIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: userId)
            let partnerNames = SplitPartnerOption.displayNames(for: partnerIds)
            message += "\n\nEither option removes this occurrence for \(partnerNames)."
        }
        return message
    }

    private func deletePendingRecurringExpense(mode: RecurringDeletionMode) {
        guard let expense = expensePendingDelete, let userId = authSession.userId else { return }
        Task {
            await expenseStore.delete(id: expense.id, userId: userId, recurringMode: mode)
        }
        expensePendingDelete = nil
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
