import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @ObservedObject private var offlineSync = OfflineSync.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var arcReloadToken: Int = 0
    /// Off on iOS 26 and later, where Add expense has its own button at the end of the tab bar.
    var showsAddExpenseButton = true
    var onAddExpense: () -> Void = {}

    @State private var showMonthPicker = false
    @State private var collapseProgress: CGFloat = 0
    @State private var isTopBarCollapsed = false
    @State private var arcReveal: Double = 0
    @State private var actionRequest: ExpenseActionRequest?
    @State private var selectedExpense: ExpenseRecord?
    @State private var showAllPendingExpenses = false
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var searchResults: [ExpenseRecord] = []
    @State private var isSearching = false
    @State private var lastSearchedQuery = ""
    @FocusState private var isSearchFieldFocused: Bool

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
                        isAmountHidden: isTopBarCollapsed,
                        displayedReveal: $arcReveal
                    )
                    .reportHomeHeroScrollOffset()
                    .listRowInsets(EdgeInsets(top: -2, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    // The hero's top inset (-2) cancels the 2pt content margin, leaving no gap above the graph;
                    // the button adds 14pt below so it doesn't crowd the graph.
                    if showsAddExpenseButton && !showsCurrentMonthEmptyState {
                        addExpenseButton
                            .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
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
            // Search takes the whole screen, so the top bar steps aside while it's open.
            .toolbar(isSearchPresented ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HomeCollapsingTopBar(
                        period: expenseStore.period,
                        amount: expenseStore.summary.totalMine,
                        isCollapsed: isTopBarCollapsed
                    )
                }
                // Adjacent trailing items share one glass capsule on iOS 26, so calendar and search read as a group.
                ToolbarItem(placement: .topBarTrailing) {
                    HomeTopBarCalendarButton(
                        period: expenseStore.period,
                        onPickMonth: { showMonthPicker = true }
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HomeTopBarSearchButton(onSearch: openSearch)
                }
            }
            .onChange(of: collapseProgress) { _, progress in
                let collapsed = HomeTopBarCollapse.isCollapsed(after: progress, was: isTopBarCollapsed)
                guard collapsed != isTopBarCollapsed else { return }
                withAnimation(HomeTopBarCollapse.animation(reduceMotion: reduceMotion)) {
                    isTopBarCollapsed = collapsed
                }
            }
            // The top bar's search button opens this; pulling the list down only refreshes.
            .overlay {
                if isSearchPresented { searchOverlay }
            }
            .task(id: SearchTrigger(text: searchText, revision: expenseStore.searchRevision)) {
                await runSearch()
            }
            .task(id: authSession.userId) {
                await expenseStore.refresh(userId: authSession.userId)
            }
            .refreshable {
                await expenseStore.refresh(userId: authSession.userId)
            }
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

    private struct SearchTrigger: Equatable {
        let text: String
        let revision: Int
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits for a pause in typing, then searches; a newer keystroke cancels this task.
    private func runSearch() async {
        let query = trimmedSearchText
        guard query.count >= 2 else {
            searchResults = []
            lastSearchedQuery = ""
            isSearching = false
            return
        }
        isSearching = true
        // Typing waits for a pause; a refresh after a delete, edit or undo runs at once.
        if query != lastSearchedQuery {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        let found = await expenseStore.search(query, userId: authSession.userId)
        guard !Task.isCancelled else { return }
        searchResults = found
        lastSearchedQuery = query
        isSearching = false
    }

    private var searchResultsByDay: [(date: Date, expenses: [ExpenseRecord])] {
        let calendar = AppPreferences.calendar
        return Dictionary(grouping: searchResults) { calendar.startOfDay(for: $0.spentAt) }
            .map { (date: $0.key, expenses: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.date > $1.date }
    }

    private func openSearch() {
        guard !isSearchPresented else { return }
        withAnimation(reduceMotion ? nil : .snappy) { isSearchPresented = true }
    }

    private func closeSearch() {
        isSearchFieldFocused = false
        isSearchPresented = false
        searchText = ""
        searchResults = []
    }

    private var searchOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(HomeTheme.secondary)
                    TextField("Search expenses", text: $searchText)
                        .focused($isSearchFieldFocused)
                        // Tapping the search button means "I want to type", so the keyboard comes up straight away.
                        .onAppear { isSearchFieldFocused = true }
                        .submitLabel(.search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(HomeTheme.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(HomeTheme.surface, in: Capsule())

                Button("Cancel", action: closeSearch)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            searchResultsView
        }
        .background(HomeTheme.background.ignoresSafeArea())
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var searchResultsView: some View {
        List {
            ForEach(searchResultsByDay, id: \.date) { section in
                Section {
                    ForEach(section.expenses) { expenseRow($0) }
                } header: {
                    Text(section.date.formatted(
                        Date.FormatStyle(timeZone: AppPreferences.calendar.timeZone).day().month(.abbreviated).year()
                    ))
                    .font(.subheadline)
                    .foregroundStyle(HomeTheme.secondary)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if trimmedSearchText.count < 2 {
                ContentUnavailableView("Search expenses", systemImage: "magnifyingglass",
                    description: Text("Find an expense by its title, note or place."))
            } else if searchResults.isEmpty && !isSearching {
                ContentUnavailableView.search(text: trimmedSearchText)
            }
        }
    }

    /// Matches Record repayment on Balances: a full-width accent capsule with subheadline text.
    private var addExpenseButton: some View {
        Button {
            onAddExpense()
        } label: {
            Label("Add expense", systemImage: "plus")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(HomeTheme.accentFill)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 20)
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
                .listRowBackground(HomeTheme.surface)
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
                            EditProposalSummaryCard(
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
                                },
                                onShowDetails: {
                                    selectedExpense = expense
                                }
                            )
                        }
                    }
                } header: {
                    Text("Suggested edits")
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                }
                .listRowBackground(HomeTheme.surface)
            }
        }
    }

    @ViewBuilder
    private var expenseList: some View {
        if expenseStore.isLoading && expenseStore.expenses.isEmpty {
            Section {
                SkeletonRows()
            }
            .listRowBackground(HomeTheme.surface)
        } else if expenseStore.expenses.isEmpty {
            Section {
                emptyState
            }
            .listRowBackground(HomeTheme.surface)
        } else {
            ForEach(expensesByDay, id: \.date) { section in
                Section {
                    ForEach(section.expenses) { expense in
                        expenseRow(expense)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canDelete(expense) {
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
                                    .tint(HomeTheme.accentFill)
                                }
                            }
                    }
                } header: {
                    daySectionHeader(date: section.date, expenses: section.expenses)
                }
                .listRowBackground(HomeTheme.surface)
            }
        }

        if let note = conversionNote {
            Section {
                Label(note, systemImage: "arrow.left.arrow.right")
                    .font(.footnote)
                    .foregroundStyle(HomeTheme.secondary)
                    .listRowBackground(Color.clear)
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
            .listRowBackground(HomeTheme.surface)
        }
    }

    private var showsCurrentMonthEmptyState: Bool {
        expenseStore.period == .currentMonth
            && expenseStore.expenses.isEmpty
            && !expenseStore.isLoading
    }

    @ViewBuilder
    private var emptyState: some View {
        if expenseStore.period == .currentMonth {
            LoamEmptyState(
                title: String(localized: "No expenses this month yet"),
                message: String(localized: "Log what you spend and Loam totals your month by category. Split any expense with a friend to keep track of who owes whom."),
                systemImage: "creditcard"
            ) {
                Button {
                    onAddExpense()
                } label: {
                    Label("Add an expense", systemImage: "plus")
                        .fontWeight(.semibold)
                }
            }
        } else {
            LoamEmptyState(
                title: String(localized: "No expenses in \(expenseStore.period.displayTitle)"),
                message: String(localized: "Nothing was logged this month. Tap the month at the top to see another one."),
                systemImage: "calendar"
            )
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
        DaySectionTitle.string(for: date)
    }

    /// In the default currency, like the month total, so a day mixing currencies adds up.
    private func dayTotal(for expenses: [ExpenseRecord]) -> Money {
        guard let userId = authSession.userId else {
            return expenses.first?.money ?? Money(amountMinor: 0, currencyCode: AppPreferences.defaultCurrencyCode)
        }
        return ExpenseStore.makeSummary(expenses: expenses, userId: userId, rates: ExchangeRateStore.shared.rates).totalMine
    }

    /// Warns that totals leave out expenses in another currency whose rates haven't loaded.
    /// How conversion works is explained once, in the default currency picker.
    private var conversionNote: String? {
        let summary = expenseStore.summary
        guard summary.unconvertedCount > 0 else { return nil }
        let count = summary.unconvertedCount
        let currency = summary.totalMine.currencyCode
        return String(localized: "\(count) expenses in another currency aren't counted in \(currency) totals until exchange rates load.")
    }

    private func expenseRow(_ expense: ExpenseRecord) -> some View {
        HomeExpenseRow(
            expense: expense,
            myUserId: authSession.userId,
            highlightsRecurringIcon: expenseStore.isInitialRecurringOccurrence(expense),
            isWaitingToSync: offlineSync.pendingExpenseIds.contains(expense.id)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedExpense = expense
        }
        .contextMenu {
            // Someone else's expense offers no other actions, so the menu would otherwise be empty.
            if !isCreator(of: expense) {
                Button("View details", systemImage: "info.circle") {
                    selectedExpense = expense
                }
            }
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
            if canDelete(expense) {
                Button(role: .destructive) {
                    presentDeleteConfirmation(for: expense)
                } label: {
                    DestructiveMenuLabel(title: "Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows expense details")
    }

    // Only the creator can change or delete an expense; the server rejects anyone else.
    private func isCreator(of expense: ExpenseRecord) -> Bool {
        guard let userId = authSession.userId else { return false }
        return expense.createdBy == userId
    }

    private func canSplit(_ expense: ExpenseRecord) -> Bool {
        isCreator(of: expense)
            && SplitPartnerOption.isSplitAvailable(usesRemoteBackend: SupabaseConfig.isConfigured)
    }

    private func canEdit(_ expense: ExpenseRecord) -> Bool {
        isCreator(of: expense)
    }

    private func canDelete(_ expense: ExpenseRecord) -> Bool {
        isCreator(of: expense)
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

#Preview {
    HomeView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
