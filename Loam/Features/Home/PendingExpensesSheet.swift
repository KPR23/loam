import SwiftUI

private struct PendingProposeEditPresentation: Identifiable {
    let expense: ExpenseRecord
    let myUserId: UUID

    var id: UUID { expense.id }
}

private enum PendingBulkDeclineTarget: Identifiable {
    case all
    case creator(id: UUID, name: String)

    var id: String {
        switch self {
        case .all:
            return "all"
        case .creator(let id, _):
            return id.uuidString
        }
    }
}

struct PendingExpensesSheet: View {
    let myUserId: UUID

    @EnvironmentObject private var expenseStore: ExpenseStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedExpense: ExpenseRecord?
    @State private var expensePendingProposeEdit: PendingProposeEditPresentation?
    @State private var bulkDeclineTarget: PendingBulkDeclineTarget?
    @State private var isProcessingBulk = false

    private var expenses: [ExpenseRecord] {
        expenseStore.pendingAcceptanceExpenses
    }

    private var creatorGroups: [(id: UUID, name: String, expenses: [ExpenseRecord])] {
        var order: [UUID] = []
        var grouped: [UUID: [ExpenseRecord]] = [:]
        for expense in expenses {
            if grouped[expense.createdBy] == nil {
                order.append(expense.createdBy)
                grouped[expense.createdBy] = []
            }
            grouped[expense.createdBy]?.append(expense)
        }
        return order.map { creatorId in
            (
                id: creatorId,
                name: SplitPartnerOption.displayName(for: creatorId),
                expenses: grouped[creatorId] ?? []
            )
        }
    }

    private var hasMultipleCreators: Bool {
        creatorGroups.count > 1
    }

    var body: some View {
        NavigationStack {
            List {
                if hasMultipleCreators {
                    ForEach(creatorGroups, id: \.id) { group in
                        Section {
                            ForEach(group.expenses) { expense in
                                pendingRow(for: expense, showsCreatorLabel: false)
                            }
                        } header: {
                            personSectionHeader(
                                creatorId: group.id,
                                creatorName: group.name,
                                count: group.expenses.count
                            )
                        }
                    }
                } else {
                    Section {
                        ForEach(expenses) { expense in
                            pendingRow(for: expense, showsCreatorLabel: true)
                        }
                    } header: {
                        summaryHeader
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle("Awaiting approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isProcessingBulk {
                        ProgressView()
                    } else {
                        bulkActionsMenu
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
            .onChange(of: expenses.count) { _, count in
                if count == 0 {
                    dismiss()
                }
            }
        }
        .sheet(item: $selectedExpense) { expense in
            ExpenseDetailSheet(
                expense: expense,
                pendingActions: detailActions(for: expense)
            )
        }
        .sheet(item: $expensePendingProposeEdit) { presentation in
            ProposeEditSheet(expense: presentation.expense, myUserId: presentation.myUserId)
        }
        .alert(
            declineAlertTitle,
            isPresented: Binding(
                get: { bulkDeclineTarget != nil },
                set: { if !$0 { bulkDeclineTarget = nil } }
            )
        ) {
            Button("Decline all", role: .destructive) {
                guard let target = bulkDeclineTarget else { return }
                bulkDeclineTarget = nil
                Task { await performBulkDecline(target) }
            }
            Button("Cancel", role: .cancel) {
                bulkDeclineTarget = nil
            }
        } message: {
            Text(declineAlertMessage)
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(expenses.count) pending")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(HomeTheme.secondary)
                .textCase(nil)
            Spacer()
            Text(MoneyFormatter.string(from: pendingTotal(for: expenses)))
                .font(.subheadline)
                .foregroundStyle(HomeTheme.tertiary)
                .monospacedDigit()
                .textCase(nil)
        }
    }

    @ViewBuilder
    private var bulkActionsMenu: some View {
        Menu {
            if hasMultipleCreators {
                ForEach(creatorGroups, id: \.id) { group in
                    Section(group.name) {
                        creatorBulkMenuItems(
                            creatorId: group.id,
                            creatorName: group.name
                        )
                    }
                }
                Divider()
                Button("Accept everything", systemImage: "checkmark") {
                    Task { await performBulkAccept(creatorId: nil, withTrust: false) }
                }
                Button("Decline everything", systemImage: "xmark", role: .destructive) {
                    bulkDeclineTarget = .all
                }
            } else if let onlyCreator = creatorGroups.first {
                creatorBulkMenuItems(
                    creatorId: onlyCreator.id,
                    creatorName: onlyCreator.name
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(isProcessingBulk || expenses.isEmpty)
        .accessibilityLabel("Bulk approval actions")
    }

    @ViewBuilder
    private func creatorBulkMenuItems(creatorId: UUID, creatorName: String) -> some View {
        Button("Accept all from \(creatorName)", systemImage: "checkmark") {
            Task { await performBulkAccept(creatorId: creatorId, withTrust: false) }
        }
        Button("Accept all & always trust \(creatorName)", systemImage: "hand.thumbsup") {
            Task { await performBulkAccept(creatorId: creatorId, withTrust: true) }
        }
        Button("Decline all from \(creatorName)", systemImage: "xmark", role: .destructive) {
            bulkDeclineTarget = .creator(id: creatorId, name: creatorName)
        }
    }

    private func personSectionHeader(
        creatorId: UUID,
        creatorName: String,
        count: Int
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            (
                Text(creatorName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(HomeTheme.secondary)
                + Text(" · ")
                    .font(.subheadline)
                    .foregroundColor(HomeTheme.tertiary)
                + Text("\(count)")
                    .font(.subheadline)
                    .foregroundColor(HomeTheme.tertiary)
            )

            Spacer(minLength: 8)

            if count > 1 {
                Menu {
                    creatorBulkMenuItems(creatorId: creatorId, creatorName: creatorName)
                } label: {
                    Text("For all")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HomeTheme.text)
                }
                .disabled(isProcessingBulk)
                .accessibilityLabel("Actions for all expenses from \(creatorName)")
            }
        }
        .textCase(nil)
    }

    private func pendingRow(for expense: ExpenseRecord, showsCreatorLabel: Bool) -> some View {
        PendingExpenseRow(
            expense: expense,
            myUserId: myUserId,
            creatorName: SplitPartnerOption.displayName(for: expense.createdBy),
            showsCreatorLabel: showsCreatorLabel,
            onAccept: {
                respond(to: expense, action: .accept)
            },
            onAcceptWithTrust: {
                respond(to: expense, action: .acceptWithTrust)
            },
            onReject: {
                respond(to: expense, action: .reject)
            },
            onProposeEdit: {
                expensePendingProposeEdit = PendingProposeEditPresentation(
                    expense: expense,
                    myUserId: myUserId
                )
            },
            onShowDetails: {
                selectedExpense = expense
            }
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(role: .destructive) {
                respond(to: expense, action: .reject)
            } label: {
                Label("Decline", systemImage: "xmark")
            }
            .tint(.red)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                respond(to: expense, action: .accept)
            } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .tint(.green)
        }
    }

    private func respond(to expense: ExpenseRecord, action: ExpenseShareResponseAction) {
        Task {
            await expenseStore.respondToShare(
                expenseId: expense.id,
                userId: myUserId,
                action: action
            )
        }
    }

    private func detailActions(for expense: ExpenseRecord) -> ExpenseDetailPendingActions? {
        guard expense.isPendingAcceptance(for: myUserId) else { return nil }
        let creatorName = SplitPartnerOption.displayName(for: expense.createdBy)
        return ExpenseDetailPendingActions(
            creatorName: creatorName,
            onAccept: {
                selectedExpense = nil
                Task {
                    await expenseStore.respondToShare(
                        expenseId: expense.id,
                        userId: myUserId,
                        action: .accept
                    )
                }
            },
            onAcceptWithTrust: {
                selectedExpense = nil
                Task {
                    await expenseStore.respondToShare(
                        expenseId: expense.id,
                        userId: myUserId,
                        action: .acceptWithTrust
                    )
                }
            },
            onReject: {
                selectedExpense = nil
                Task {
                    await expenseStore.respondToShare(
                        expenseId: expense.id,
                        userId: myUserId,
                        action: .reject
                    )
                }
            },
            onProposeEdit: {
                selectedExpense = nil
                expensePendingProposeEdit = PendingProposeEditPresentation(
                    expense: expense,
                    myUserId: myUserId
                )
            }
        )
    }

    private func performBulkAccept(creatorId: UUID?, withTrust: Bool) async {
        let ids = targetExpenseIds(creatorId: creatorId)
        guard !ids.isEmpty else { return }
        isProcessingBulk = true
        defer { isProcessingBulk = false }
        await expenseStore.respondToShares(
            expenseIds: ids,
            userId: myUserId,
            action: withTrust ? .acceptWithTrust : .accept
        )
    }

    private func performBulkDecline(_ target: PendingBulkDeclineTarget) async {
        let ids: [UUID]
        switch target {
        case .all:
            ids = expenses.map(\.id)
        case .creator(let id, _):
            ids = targetExpenseIds(creatorId: id)
        }
        guard !ids.isEmpty else { return }
        isProcessingBulk = true
        defer { isProcessingBulk = false }
        await expenseStore.respondToShares(
            expenseIds: ids,
            userId: myUserId,
            action: .reject
        )
    }

    private func targetExpenseIds(creatorId: UUID?) -> [UUID] {
        guard let creatorId else { return expenses.map(\.id) }
        return expenses.filter { $0.createdBy == creatorId }.map(\.id)
    }

    private func pendingTotal(for expenses: [ExpenseRecord]) -> Money {
        let minor = expenses.reduce(0) { partial, expense in
            partial + (expense.shareRecord(for: myUserId)?.amountMinor ?? 0)
        }
        let currency = expenses.first?.currency ?? "PLN"
        return Money(amountMinor: minor, currencyCode: currency)
    }

    private var declineAlertTitle: String {
        switch bulkDeclineTarget {
        case .creator(_, let name):
            return "Decline all from \(name)?"
        case .all, .none:
            return "Decline all pending expenses?"
        }
    }

    private var declineAlertMessage: String {
        switch bulkDeclineTarget {
        case .creator(_, let name):
            return "This declines every pending expense added by \(name)."
        case .all, .none:
            return "This declines every expense waiting for your approval."
        }
    }
}
