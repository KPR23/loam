import SwiftUI

struct ExpenseDetailPendingActions {
    let creatorName: String
    let onAccept: () -> Void
    let onAcceptWithTrust: () -> Void
    let onReject: () -> Void
    let onProposeEdit: () -> Void
}

struct ExpenseDetailSheet: View {
    let expense: ExpenseRecord
    var onEdit: (() -> Void)?
    var onSplit: (() -> Void)?
    var onDelete: (() -> Void)?
    var pendingActions: ExpenseDetailPendingActions?

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @Environment(\.dismiss) private var dismiss

    @State private var recurringRule: RecurringRuleRecord?

    private var myUserId: UUID? { authSession.userId }

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
        canEdit || canSplit || onDelete != nil
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

                    if let location = expense.location {
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
                                Text(MoneyFormatter.string(from: shareMoney(for: share)))
                                    .monospacedDigit()
                            }
                        }
                    }
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
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
}
