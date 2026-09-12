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
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onShowDetails) {
                HStack(alignment: .center, spacing: 12) {
                    categoryBadge

                    VStack(alignment: .leading, spacing: 2) {
                        Text(expense.displayTitle)
                            .font(.body.weight(.medium))
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
            .font(.subheadline.weight(.semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(expense.category.color)
            .frame(width: 32, height: 32)
            .background(expense.category.color.opacity(0.14))
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
