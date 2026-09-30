import SwiftUI

struct ExpenseDetailPendingActions {
    let creatorName: String
    let onAccept: () -> Void
    let onAcceptWithTrust: () -> Void
    let onReject: () -> Void
    let onProposeEdit: () -> Void
}

struct ExpenseDetailSheet: View {
    /// The expense as it was when the sheet opened; `expense` follows later changes.
    private let initialExpense: ExpenseRecord
    var onEdit: (() -> Void)?
    var onSplit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onProposeEdit: (() -> Void)?
    var pendingActions: ExpenseDetailPendingActions?

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var activityStore: ActivityStore
    @Environment(\.dismiss) private var dismiss

    @State private var recurringRule: RecurringRuleRecord?
    @State private var history: [ActivityEvent] = []
    @State private var historyState: HistoryState = .loading
    @State private var respondingProposalId: UUID?

    private enum HistoryState: Equatable {
        case loading, loaded, failed
    }

    init(
        expense: ExpenseRecord,
        onEdit: (() -> Void)? = nil,
        onSplit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onProposeEdit: (() -> Void)? = nil,
        pendingActions: ExpenseDetailPendingActions? = nil
    ) {
        self.initialExpense = expense
        self.onEdit = onEdit
        self.onSplit = onSplit
        self.onDelete = onDelete
        self.onProposeEdit = onProposeEdit
        self.pendingActions = pendingActions
    }

    /// Reflects accepted proposals, responses and edits while the sheet is open.
    private var expense: ExpenseRecord {
        expenseStore.knownExpense(id: initialExpense.id) ?? initialExpense
    }

    private var myUserId: UUID? { authSession.userId }

    private var isOwner: Bool {
        myUserId == expense.createdBy
    }

    private var proposals: [ExpenseEditProposal] {
        guard let myUserId else { return [] }
        return expenseStore.visibleProposals(forExpense: expense.id, userId: myUserId)
    }

    /// Changes whenever something the history could show has changed.
    private var historyReloadKey: String {
        let responses = expense.shares
            .map { "\($0.userId.uuidString):\($0.status.rawValue)" }
            .sorted()
            .joined(separator: ",")
        let proposalIds = proposals.map(\.id.uuidString).joined(separator: ",")
        return "\(expense.id)|\(expense.version ?? 0)|\(responses)|\(proposalIds)"
    }

    private var myShare: Money {
        guard let myUserId else { return expense.money }
        return expense.share(for: myUserId)
    }

    private var canEdit: Bool {
        pendingActions == nil && onEdit != nil
    }

    private var canSplit: Bool {
        pendingActions == nil
            && onSplit != nil
            && SplitPartnerOption.isSplitAvailable(usesRemoteBackend: SupabaseConfig.isConfigured)
    }

    private var hasOwnerActions: Bool {
        canEdit || canSplit || onDelete != nil || onProposeEdit != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(expense.category.color.opacity(0.12))
                            Image(systemName: expense.category.systemImage)
                                .font(.system(size: 28, weight: .medium))
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(expense.category.color)
                        }
                        .frame(width: 64, height: 64)

                        Text(MoneyFormatter.string(from: expense.isShared ? myShare : expense.money))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .padding(.top, 16)

                        if expense.isShared {
                            Text("Your share of \(MoneyFormatter.string(from: expense.money))")
                                .font(.subheadline)
                                .foregroundStyle(HomeTheme.secondary)
                                .padding(.top, 4)
                        }

                        Text(expense.category.displayName)
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(HomeTheme.secondary)
                            .padding(.top, expense.isShared ? 10 : 8)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                if !proposals.isEmpty {
                    statusSection
                }

                Section("Details") {
                    if expense.hasCustomTitle {
                        LabeledContent("Title") {
                            Text(expense.displayTitle)
                                .font(.system(.body, design: .rounded))
                        }
                    }

                    LabeledContent("Category") {
                        HStack(spacing: 6) {
                            Image(systemName: expense.category.systemImage)
                            Text(expense.category.displayName)
                                .font(.system(.body, design: .rounded))
                        }
                        .foregroundStyle(expense.category.color)
                    }

                    if FeatureFlags.merchant, let location = expense.location {
                        LabeledContent("Location") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(location.name)
                                    .font(.system(.body, design: .rounded))
                                if let subtitle = location.displaySubtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    LabeledContent("Date") {
                        Text(expense.spentAt.formatted(date: .complete, time: .omitted))
                    }

                    LabeledContent("Total") {
                        Text(MoneyFormatter.string(from: expense.money))
                            .monospacedDigit()
                    }

                    if expense.isShared {
                        LabeledContent("Paid by") {
                            Text(payerLabel)
                        }
                    }

                    if let note = expense.note, !note.isEmpty {
                        LabeledContent("Note") {
                            Text(note)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                if let recurringRule {
                    Section {
                        LabeledContent("Frequency") {
                            Text(recurringRule.scheduleDescription)
                        }

                        LabeledContent("Started") {
                            Text(recurringRule.startDate.formatted(date: .complete, time: .omitted))
                        }

                        LabeledContent("Ends") {
                            Text(recurringRule.endDateDisplay)
                        }

                        if recurringRule.isActive, !recurringRule.hasEnded {
                            LabeledContent("Next charge") {
                                Text(recurringRule.nextOccurrence.formatted(date: .complete, time: .omitted))
                            }
                        }

                        LabeledContent("Status") {
                            recurringStatusLabel(for: recurringRule)
                        }
                    } header: {
                        Text("Recurring")
                    } footer: {
                        if let failure = recurringRule.generationFailure, recurringRule.isActive, !recurringRule.hasEnded {
                            Text("The next charge couldn't be added: \(failure). It will be retried.")
                        }
                    }
                } else if expense.isRecurring {
                    Section("Recurring") {
                        LabeledContent("Type") {
                            Label("Recurring", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    }
                }

                if expense.isShared {
                    Section("Split") {
                        ForEach(sortedShares) { share in
                            LabeledContent(shareLabel(for: share.userId)) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(MoneyFormatter.string(from: shareMoney(for: share)))
                                        .monospacedDigit()
                                    if share.userId != expense.createdBy {
                                        responseLabel(for: share.status, compact: true)
                                    }
                                }
                            }
                        }
                    }

                    historySection
                }
            }
            .navigationTitle("Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hasOwnerActions {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if canEdit, let onEdit {
                                Button("Edit", systemImage: "pencil", action: onEdit)
                            }
                            if canSplit, let onSplit {
                                Button(
                                    expense.isShared ? "Edit split" : "Split expense",
                                    systemImage: expense.sharedSplitSystemImage(for: myUserId),
                                    action: onSplit
                                )
                            }
                            if let onProposeEdit {
                                Button("Suggest changes", systemImage: "square.and.pencil", action: onProposeEdit)
                            }
                            if onDelete != nil {
                                Button(role: .destructive) {
                                    onDelete?()
                                } label: {
                                    DestructiveMenuLabel(title: "Delete", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("Expense actions")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let pendingActions {
                    pendingActionsBar(pendingActions)
                }
            }
            .task(id: expense.recurringId) {
                guard expense.isRecurring else {
                    recurringRule = nil
                    return
                }
                recurringRule = await expenseStore.fetchRecurringRule(for: expense)
            }
            .task(id: initialExpense.id) {
                guard let myUserId else { return }
                await expenseStore.reloadForDetail(expenseId: initialExpense.id, userId: myUserId)
            }
            .task(id: historyReloadKey) {
                await loadHistory()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Status

    private enum StatusRole {
        case proposed
        case awaitingDecision
        case share(ExpenseShareStatus)
    }

    private struct StatusRow: Identifiable {
        let id: UUID
        let role: StatusRole
    }

    /// Suggested changes still waiting for the owner, then who proposed them,
    /// who still has to decide, and anyone else whose share would change.
    @ViewBuilder
    private var statusSection: some View {
        Section {
            ForEach(proposals) { proposal in
                proposalCard(proposal)

                ForEach(statusRows(for: proposal)) { row in
                    HStack(spacing: 10) {
                        AvatarView(userId: row.id, size: 26)
                        Text(shareLabel(for: row.id))
                            .font(.system(.body, design: .rounded))
                        Spacer(minLength: 8)
                        statusRoleLabel(row.role)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Status")
        } footer: {
            Text(statusFooter)
        }
    }

    /// The proposer, then the owner who has to decide, then anyone else
    /// (excluding both) whose current share amount this proposal would change.
    private func statusRows(for proposal: ExpenseEditProposal) -> [StatusRow] {
        var rows: [StatusRow] = [StatusRow(id: proposal.proposedBy, role: .proposed)]
        if proposal.proposedBy != expense.createdBy {
            rows.append(StatusRow(id: expense.createdBy, role: .awaitingDecision))
        }
        let exclude: Set<UUID> = [proposal.proposedBy, expense.createdBy]
        let currentAmounts = Dictionary(uniqueKeysWithValues: expense.shares.map { ($0.userId, $0.amountMinor) })
        let statusByUser = Dictionary(uniqueKeysWithValues: expense.shares.map { ($0.userId, $0.status) })
        for share in proposal.shares where !exclude.contains(share.userId) {
            guard currentAmounts[share.userId] != share.amountMinor else { continue }
            rows.append(StatusRow(id: share.userId, role: .share(statusByUser[share.userId] ?? .pending)))
        }
        return rows
    }

    @ViewBuilder
    private func statusRoleLabel(_ role: StatusRole) -> some View {
        switch role {
        case .proposed:
            responseLabel("Proposed changes", systemImage: "square.and.pencil", color: HomeTheme.accent)
        case .awaitingDecision:
            responseLabel("Awaiting response", systemImage: "clock.fill", color: .orange)
        case .share(let status):
            responseLabel(for: status)
        }
    }

    private func proposalCard(_ proposal: ExpenseEditProposal) -> some View {
        let proposerIsMe = proposal.proposedBy == myUserId
        let ownerName = SplitPartnerOption.displayName(for: expense.createdBy)
        let isResponding = respondingProposalId == proposal.id
        return EditProposalReviewCard(
            proposal: proposal,
            expense: expense,
            proposerName: proposerIsMe ? "You" : SplitPartnerOption.displayName(for: proposal.proposedBy),
            viewerId: myUserId,
            awaitingReviewFrom: isOwner ? nil : ownerName,
            onAccept: isOwner && !isResponding ? { respond(to: proposal, accept: true) } : nil,
            onReject: isOwner && !isResponding ? { respond(to: proposal, accept: false) } : nil
        )
    }

    private func respond(to proposal: ExpenseEditProposal, accept: Bool) {
        guard let myUserId else { return }
        respondingProposalId = proposal.id
        Task {
            await expenseStore.respondToProposal(proposalId: proposal.id, userId: myUserId, accept: accept)
            respondingProposalId = nil
        }
    }

    /// The owner and the proposer are forced onto the new amounts once a
    /// proposal is applied, so only participants whose share would actually
    /// change need to answer again.
    private var affectedShares: [ExpenseShareRecord] {
        let owner = expense.createdBy
        let proposers = Set(proposals.map(\.proposedBy))
        let currentAmounts = Dictionary(uniqueKeysWithValues: expense.shares.map { ($0.userId, $0.amountMinor) })
        var affectedIds: Set<UUID> = []
        for proposal in proposals {
            for share in proposal.shares where share.userId != owner && !proposers.contains(share.userId) {
                if currentAmounts[share.userId] != share.amountMinor {
                    affectedIds.insert(share.userId)
                }
            }
        }
        return sortedShares.filter { affectedIds.contains($0.userId) }
    }

    private var statusFooter: String {
        let shares = affectedShares
        guard !shares.isEmpty else { return "Everyone else's share stays the same." }
        let accepted = shares.filter { $0.status == .accepted }.count
        let declined = shares.filter { $0.status == .rejected }.count
        let waiting = shares.count - accepted - declined
        var parts: [String] = []
        if accepted > 0 { parts.append("\(accepted) accepted") }
        if declined > 0 { parts.append("\(declined) declined") }
        if waiting > 0 { parts.append("\(waiting) awaiting a response") }
        return "This change affects \(parts.joined(separator: ", "))."
    }

    @ViewBuilder
    private func responseLabel(for status: ExpenseShareStatus, compact: Bool = false) -> some View {
        switch status {
        case .accepted:
            responseLabel("Accepted", systemImage: "checkmark.circle.fill", color: .green, compact: compact)
        case .rejected:
            responseLabel("Declined", systemImage: "xmark.circle.fill", color: .red, compact: compact)
        case .pending:
            responseLabel("Awaiting", systemImage: "clock.fill", color: .orange, compact: compact)
        }
    }

    private func responseLabel(_ title: String, systemImage: String, color: Color, compact: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        Section("History") {
            if !history.isEmpty {
                ForEach(Array(history.reversed())) { event in
                    historyRow(event)
                }
            } else if historyState == .loading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if historyState == .failed {
                Text("History isn't available right now.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No history yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func historyRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.symbolName)
                .font(.body)
                .foregroundStyle(event.kind.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.sentence(viewerId: myUserId ?? event.actorId))
                    .font(.system(.subheadline, design: .rounded))
                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func loadHistory() async {
        guard let myUserId else { return }
        if history.isEmpty { historyState = .loading }
        do {
            history = try await activityStore.history(forExpense: expense.id, userId: myUserId)
            historyState = .loaded
        } catch {
            // A newer load replaces a cancelled one.
            guard !Task.isCancelled else { return }
            historyState = .failed
        }
    }

    @ViewBuilder
    private func recurringStatusLabel(for rule: RecurringRuleRecord) -> some View {
        let isActive = rule.isActive && !rule.hasEnded
        let isFailing = isActive && rule.generationFailure != nil
        Label {
            Text(isFailing ? "Needs attention" : isActive ? "Active" : "Inactive")
        } icon: {
            Image(systemName: isFailing ? "exclamationmark.triangle.fill" : isActive ? "checkmark.circle.fill" : "xmark.circle.fill")
        }
        .font(.body.weight(.medium))
        .foregroundStyle(isFailing ? Color.orange : isActive ? Color.green : Color.red)
        .labelStyle(.titleAndIcon)
    }

    private func pendingActionsBar(_ actions: ExpenseDetailPendingActions) -> some View {
        VStack(spacing: 0) {
            Divider()
            PendingExpenseActions(
                creatorName: actions.creatorName,
                menuOpensUpward: true,
                onAccept: actions.onAccept,
                onAcceptWithTrust: actions.onAcceptWithTrust,
                onReject: actions.onReject,
                onProposeEdit: actions.onProposeEdit
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
    }

    private var payerLabel: String {
        guard let myUserId else {
            return SplitPartnerOption.displayName(for: expense.paidBy)
        }
        return expense.paidBy == myUserId
            ? "You"
            : SplitPartnerOption.displayName(for: expense.paidBy)
    }

    private var sortedShares: [ExpenseShareRecord] {
        expense.shares.sorted { lhs, rhs in
            if let myUserId {
                if lhs.userId == myUserId { return true }
                if rhs.userId == myUserId { return false }
            }
            return shareLabel(for: lhs.userId).localizedCaseInsensitiveCompare(shareLabel(for: rhs.userId)) == .orderedAscending
        }
    }

    private func shareLabel(for userId: UUID) -> String {
        guard let myUserId else {
            return SplitPartnerOption.displayName(for: userId)
        }
        return userId == myUserId ? "You" : SplitPartnerOption.displayName(for: userId)
    }

    private func shareMoney(for share: ExpenseShareRecord) -> Money {
        Money(amountMinor: share.amountMinor, currencyCode: expense.currency)
    }
}

#Preview("Personal") {
    let userId = UUID()
    ExpenseDetailSheet(expense: ExpenseRecord(
        amountMinor: 4200,
        category: .groceries,
        note: "Weekly shop",
        paidBy: userId,
        createdBy: userId,
        shares: [ExpenseShareRecord(userId: userId, amountMinor: 4200)]
    ))
    .environmentObject(AuthSession())
    .environmentObject(ExpenseStore())
    .environmentObject(ActivityStore())
}

#Preview("Shared") {
    let myId = UUID()
    let partnerId = UUID()
    ExpenseDetailSheet(expense: ExpenseRecord(
        amountMinor: 8000,
        category: .dining,
        note: "Dinner out",
        paidBy: partnerId,
        createdBy: myId,
        shares: [
            ExpenseShareRecord(userId: myId, amountMinor: 4000),
            ExpenseShareRecord(userId: partnerId, amountMinor: 4000),
        ]
    ))
    .environmentObject(AuthSession())
    .environmentObject(ExpenseStore())
    .environmentObject(ActivityStore())
}


/// An action on an expense started outside its detail screen (swipe actions,
/// context menus). Handled by `expenseActionsHost`.
enum ExpenseActionRequest: Equatable {
    case edit(ExpenseRecord)
    case split(ExpenseRecord)
    case proposeEdit(ExpenseRecord)
    case delete(ExpenseRecord)
}

private enum ExpenseActionSheet: Identifiable {
    case edit(ExpenseRecord)
    case split(ExpenseRecord, myUserId: UUID)
    case proposeEdit(ExpenseRecord, myUserId: UUID)

    var id: String {
        switch self {
        case let .edit(expense): "edit-\(expense.id)"
        case let .split(expense, _): "split-\(expense.id)"
        case let .proposeEdit(expense, _): "propose-\(expense.id)"
        }
    }
}

extension View {
    /// Presents the expense detail screen for `selectedExpense` with every
    /// action the signed-in person can take on it, and handles `request`s
    /// started elsewhere on the screen. Home and Activity share this so an
    /// expense offers the same actions wherever it is opened.
    func expenseActionsHost(
        selectedExpense: Binding<ExpenseRecord?>,
        request: Binding<ExpenseActionRequest?> = .constant(nil)
    ) -> some View {
        modifier(ExpenseActionsHost(selectedExpense: selectedExpense, request: request))
    }
}

private struct ExpenseActionsHost: ViewModifier {
    @Binding var selectedExpense: ExpenseRecord?
    @Binding var request: ExpenseActionRequest?

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore

    @State private var sheet: ExpenseActionSheet?
    @State private var expensePendingDelete: ExpenseRecord?

    init(selectedExpense: Binding<ExpenseRecord?>, request: Binding<ExpenseActionRequest?>) {
        _selectedExpense = selectedExpense
        _request = request
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $selectedExpense) { expense in
                ExpenseDetailSheet(
                    expense: expense,
                    onEdit: isOwner(of: expense) ? { dismissDetail(then: .edit(expense)) } : nil,
                    onSplit: isOwner(of: expense) ? { dismissDetail(then: .split(expense)) } : nil,
                    onDelete: isOwner(of: expense) ? { dismissDetail(then: .delete(expense)) } : nil,
                    onProposeEdit: canPropose(expense) ? { dismissDetail(then: .proposeEdit(expense)) } : nil,
                    pendingActions: pendingActions(for: expense)
                )
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case let .edit(expense):
                    AddExpenseView(existingExpense: expense)
                case let .split(expense, myUserId):
                    SplitExpenseSheet(expense: expense, myUserId: myUserId)
                case let .proposeEdit(expense, myUserId):
                    ProposeEditSheet(expense: expense, myUserId: myUserId)
                }
            }
            .onChange(of: request) { _, newValue in
                guard let newValue else { return }
                request = nil
                handle(newValue)
            }
            .alert(
                "Delete this expense?",
                isPresented: Binding(
                    get: { expensePendingDelete?.isRecurring == false },
                    set: { if !$0 { expensePendingDelete = nil } }
                )
            ) {
                if let expense = expensePendingDelete, expense.isShared, isOwner(of: expense) {
                    Button("Edit split") {
                        expensePendingDelete = nil
                        handle(.split(expense))
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

    private func dismissDetail(then action: ExpenseActionRequest) {
        selectedExpense = nil
        handle(action)
    }

    private func handle(_ action: ExpenseActionRequest) {
        guard let userId = authSession.userId else { return }
        // Forms start from the latest loaded version so saving doesn't conflict.
        let latest: (ExpenseRecord) -> ExpenseRecord = { expenseStore.knownExpense(id: $0.id) ?? $0 }
        switch action {
        case let .edit(expense):
            sheet = .edit(latest(expense))
        case let .split(expense):
            sheet = .split(latest(expense), myUserId: userId)
        case let .proposeEdit(expense):
            sheet = .proposeEdit(latest(expense), myUserId: userId)
        case let .delete(expense):
            // Defer until swipe actions and sheets finish dismissing so the row
            // stays put until confirmed.
            Task { @MainActor in
                expensePendingDelete = expense
            }
        }
    }

    private func isOwner(of expense: ExpenseRecord) -> Bool {
        guard let userId = authSession.userId else { return false }
        return expense.createdBy == userId
    }

    /// Participants who already answered can still suggest changes; pending
    /// participants get the same option from the pending actions bar.
    private func canPropose(_ expense: ExpenseRecord) -> Bool {
        guard let userId = authSession.userId,
              expense.createdBy != userId,
              expense.shareRecord(for: userId) != nil else { return false }
        return !expense.isPendingAcceptance(for: userId)
    }

    private func pendingActions(for expense: ExpenseRecord) -> ExpenseDetailPendingActions? {
        guard let userId = authSession.userId, expense.isPendingAcceptance(for: userId) else {
            return nil
        }
        return ExpenseDetailPendingActions(
            creatorName: SplitPartnerOption.displayName(for: expense.createdBy),
            onAccept: {
                selectedExpense = nil
                Task { await expenseStore.respondToShare(expenseId: expense.id, userId: userId, action: .accept) }
            },
            onAcceptWithTrust: {
                selectedExpense = nil
                Task { await expenseStore.respondToShare(expenseId: expense.id, userId: userId, action: .acceptWithTrust) }
            },
            onReject: {
                selectedExpense = nil
                Task { await expenseStore.respondToShare(expenseId: expense.id, userId: userId, action: .reject) }
            },
            onProposeEdit: {
                dismissDetail(then: .proposeEdit(expense))
            }
        )
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
