import SwiftUI

struct PendingExpenseRow: View {
    let expense: ExpenseRecord
    let myUserId: UUID
    let creatorName: String
    var showsCreatorLabel: Bool = true
    let onAccept: () -> Void
    let onAcceptWithTrust: () -> Void
    let onReject: () -> Void
    let onProposeEdit: () -> Void
    let onShowDetails: () -> Void

    var body: some View {
        HomeExpenseRow(
            expense: expense,
            myUserId: myUserId,
            showsCreatorLabel: showsCreatorLabel,
            creatorName: creatorName,
            acceptance: .init(
                creatorName: creatorName,
                onAccept: onAccept,
                onAcceptWithTrust: onAcceptWithTrust,
                onReject: onReject,
                onProposeEdit: onProposeEdit
            ),
            onTap: onShowDetails
        )
    }
}

/// Wired list row for Home preview and the See-all sheet — one place for insets + store actions.
struct PendingExpenseListRow: View {
    @EnvironmentObject private var expenseStore: ExpenseStore

    let expense: ExpenseRecord
    let myUserId: UUID
    var showsCreatorLabel: Bool = true
    let onProposeEdit: () -> Void
    let onShowDetails: () -> Void

    /// The suggestion this person already sent stays visible until the owner answers.
    private var hasSentProposal: Bool {
        expenseStore.visibleProposals(forExpense: expense.id, userId: myUserId)
            .contains { $0.proposedBy == myUserId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PendingExpenseRow(
                expense: expense,
                myUserId: myUserId,
                creatorName: SplitPartnerOption.displayName(for: expense.createdBy),
                showsCreatorLabel: showsCreatorLabel,
                onAccept: { respond(.accept) },
                onAcceptWithTrust: { respond(.acceptWithTrust) },
                onReject: { respond(.reject) },
                onProposeEdit: onProposeEdit,
                onShowDetails: onShowDetails
            )

            if hasSentProposal {
                Label(
                    "You suggested changes · waiting for \(SplitPartnerOption.displayName(for: expense.createdBy))",
                    systemImage: "square.and.pencil"
                )
                .font(.footnote)
                .foregroundStyle(HomeTheme.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                respond(.accept)
            } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                respond(.reject)
            } label: {
                Label("Decline", systemImage: "xmark")
            }
            .tint(.red)
        }
    }

    private func respond(_ action: ExpenseShareResponseAction) {
        Task {
            await expenseStore.respondToShare(
                expenseId: expense.id,
                userId: myUserId,
                action: action
            )
        }
    }
}

enum PendingAcceptanceFormatting {
    static func total(for expenses: [ExpenseRecord], userId: UUID) -> Money {
        let minor = expenses.reduce(0) { partial, expense in
            partial + (expense.shareRecord(for: userId)?.amountMinor ?? 0)
        }
        let currency = expenses.first?.currency ?? "PLN"
        return Money(amountMinor: minor, currencyCode: currency)
    }

    static func sectionHeader(
        expenses: [ExpenseRecord],
        userId: UUID,
        previewLimit: Int? = nil
    ) -> some View {
        let showCount = previewLimit.map { expenses.count > $0 } ?? false
        return HStack(alignment: .firstTextBaseline) {
            Text(showCount
                 ? "Awaiting your approval · \(expenses.count)"
                 : "Awaiting your approval")
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(HomeTheme.secondary)
            Spacer()
            Text(MoneyFormatter.string(from: total(for: expenses, userId: userId)))
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.regular)
                .foregroundStyle(HomeTheme.secondary)
                .monospacedDigit()
        }
        .textCase(nil)
    }
}
