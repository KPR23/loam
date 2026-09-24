import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore

    var arcReloadToken: Int = 0

    @State private var showAddExpense = false
    @State private var showMonthPicker = false
    @State private var collapseProgress: CGFloat = 0
    @State private var arcReveal: Double = 0
    @State private var actionRequest: ExpenseActionRequest?
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
            // Keep the last expense row scrollable above the floating + button.
            .contentMargins(.bottom, AddExpenseFABLayout.listBottomContentInset, for: .scrollContent)
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
                .padding(.trailing, AddExpenseFABLayout.trailingPadding)
                .padding(.bottom, AddExpenseFABLayout.bottomPadding)
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
        .sheet(isPresented: $showAllPendingExpenses) {
            if let userId = authSession.userId {
                PendingExpensesSheet(myUserId: userId)
            }
        }
        .expenseActionsHost(selectedExpense: $selectedExpense, request: $actionRequest)
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
                                actionRequest = .proposeEdit(expense)
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
                                viewerId: userId,
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

        if !expenseStore.failingRecurringRules.isEmpty {
            Section {
                ForEach(expenseStore.failingRecurringRules) { rule in
                    Label {
                        Text("\u{201C}\(rule.displayTitle)\u{201D} didn't repeat: \(rule.generationFailure ?? ""). Edit or stop it to continue.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
        let calendar = AppPreferences.calendar
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
        let calendar = AppPreferences.calendar
        let style = Date.FormatStyle(timeZone: calendar.timeZone)
        let dayMonth = date.formatted(style.day().month(.abbreviated))

        let prefix: String
        if calendar.isDateInToday(date) {
            prefix = "Today"
        } else if calendar.isDateInYesterday(date) {
            prefix = "Yesterday"
        } else {
            prefix = date.formatted(style.weekday(.wide))
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

    private func presentSplit(for expense: ExpenseRecord) {
        actionRequest = .split(expense)
    }

    private func presentEdit(for expense: ExpenseRecord) {
        actionRequest = .edit(expense)
    }

    private func presentDeleteConfirmation(for expense: ExpenseRecord) {
        actionRequest = .delete(expense)
    }
}

private enum AddExpenseFABLayout {
    static let diameter: CGFloat = 56
    static let trailingPadding: CGFloat = 20
    static let bottomPadding: CGFloat = 12
    /// Extra gap so the last row isn’t tucked under the FAB when scrolled to the end.
    static let listClearance: CGFloat = 20

    static var listBottomContentInset: CGFloat {
        diameter + bottomPadding + listClearance
    }
}

private struct AddExpenseFAB: View {
    let action: () -> Void

    var body: some View {
        Button {
            LoamFeedback.tap()
            action()
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: AddExpenseFABLayout.diameter, height: AddExpenseFABLayout.diameter)
                .background(Circle().fill(Color.primary))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(LoamPressStyle())
        .accessibilityLabel("Add expense")
    }
}

#Preview {
    HomeView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
