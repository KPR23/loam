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
    var onSplit: (() -> Void)?
    var onDelete: (() -> Void)?
    var pendingActions: ExpenseDetailPendingActions?

    @EnvironmentObject private var authSession: AuthSession
    @Environment(\.dismiss) private var dismiss

    private var myUserId: UUID? { authSession.userId }

    private var myShare: Money {
        guard let myUserId else { return expense.money }
        return expense.share(for: myUserId)
    }

    private var canSplit: Bool {
        pendingActions == nil
            && onSplit != nil
            && expense.recurringId == nil
            && SplitPartnerOption.isSplitAvailable(usesRemoteBackend: SupabaseConfig.isConfigured)
    }

    private var hasOwnerActions: Bool {
        canSplit || onDelete != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: expense.category.systemImage)
                            .font(.system(size: 36))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(expense.category.color)
                            .frame(width: 64, height: 64)
                            .background(expense.category.color.opacity(0.12))
                            .clipShape(Circle())

                        Text(MoneyFormatter.string(from: expense.isShared ? myShare : expense.money))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()

                        if expense.isShared {
                            Text("Your share of \(MoneyFormatter.string(from: expense.money))")
                                .font(.subheadline)
                                .foregroundStyle(HomeTheme.secondary)
                        }

                        Text(expense.displayTitle)
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(HomeTheme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Details") {
                    LabeledContent("Total") {
                        Text(MoneyFormatter.string(from: expense.money))
                            .monospacedDigit()
                    }

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

                    LabeledContent("Date") {
                        Text(expense.spentAt.formatted(date: .complete, time: .omitted))
                    }

                    if expense.isShared {
                        LabeledContent("Paid by") {
                            Text(payerLabel)
                        }
                    }

                    if expense.recurringId != nil {
                        LabeledContent("Type") {
                            Label("Recurring", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    }

                    if let note = expense.note, !note.isEmpty {
                        LabeledContent("Note") {
                            Text(note)
                                .multilineTextAlignment(.trailing)
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
                            if canSplit, let onSplit {
                                Button(
                                    expense.isShared ? "Edit split" : "Split expense",
                                    systemImage: "person.2",
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
                            Image(systemName: "ellipsis.circle")
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
        }
        .presentationDetents(pendingActions == nil ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
    }

    private func pendingActionsBar(_ actions: ExpenseDetailPendingActions) -> some View {
        VStack(spacing: 0) {
            Divider()
            PendingExpenseActions(
                creatorName: actions.creatorName,
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
        householdId: UUID(),
        shares: [
            ExpenseShareRecord(userId: myId, amountMinor: 4000),
            ExpenseShareRecord(userId: partnerId, amountMinor: 4000),
        ]
    ))
    .environmentObject(AuthSession())
}
