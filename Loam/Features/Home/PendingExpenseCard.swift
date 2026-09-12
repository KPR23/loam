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

    private var myShare: Money {
        expense.share(for: myUserId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onShowDetails) {
                HStack(alignment: .center, spacing: 12) {
                    categoryBadge

                    VStack(alignment: .leading, spacing: 2) {
                        Text(expense.displayTitle)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(HomeTheme.text)
                            .multilineTextAlignment(.leading)

                        if let note = expense.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(HomeTheme.secondary)
                                .lineLimit(2)
                        }

                        if showsCreatorLabel {
                            Text("Added by \(creatorName)")
                                .font(.caption)
                                .foregroundStyle(HomeTheme.tertiary)
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyFormatter.string(from: myShare))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(HomeTheme.text)
                        Text("of \(MoneyFormatter.string(from: expense.money))")
                            .font(.caption)
                            .foregroundStyle(HomeTheme.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows expense details")

            PendingExpenseActions(
                creatorName: creatorName,
                onAccept: onAccept,
                onAcceptWithTrust: onAcceptWithTrust,
                onReject: onReject,
                onProposeEdit: onProposeEdit
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var categoryBadge: some View {
        Image(systemName: expense.category.systemImage)
            .font(.body.weight(.semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(expense.category.color)
            .frame(width: 40, height: 40)
            .background(expense.category.color.opacity(0.14))
            .clipShape(Circle())
            .accessibilityHidden(true)
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

    var body: some View {
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
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(HomeTheme.secondary)
                .monospacedDigit()
        }
        .textCase(nil)
    }
}
