import SwiftUI

/// Shared expense row for Home list + pending acceptance preview.
struct HomeExpenseRow: View {
    struct AcceptanceActions {
        let creatorName: String
        let onAccept: () -> Void
        let onAcceptWithTrust: () -> Void
        let onReject: () -> Void
        let onProposeEdit: () -> Void
    }

    let expense: ExpenseRecord
    let myUserId: UUID?
    var showsCreatorLabel: Bool = false
    var creatorName: String? = nil
    var acceptance: AcceptanceActions? = nil
    var onTap: (() -> Void)? = nil
    /// When true, the recurring glyph uses `HomeTheme.recurringHighlight` (seed occurrence of that series only).
    var highlightsRecurringIcon: Bool = false

    private var myShare: Money {
        guard let myUserId else { return expense.money }
        return expense.share(for: myUserId)
    }

    private var showsShareBreakdown: Bool {
        expense.isShared || acceptance != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let onTap {
                Button(action: onTap) {
                    rowContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows expense details")
            } else {
                rowContent
            }

            if let acceptance {
                PendingExpenseActions(
                    creatorName: acceptance.creatorName,
                    onAccept: acceptance.onAccept,
                    onAcceptWithTrust: acceptance.onAcceptWithTrust,
                    onReject: acceptance.onReject,
                    onProposeEdit: acceptance.onProposeEdit
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            categoryIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.displayTitle)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(HomeTheme.text)
                    .multilineTextAlignment(.leading)

                if let placeName = expense.location?.name,
                   placeName.caseInsensitiveCompare(expense.displayTitle) != .orderedSame {
                    Text(placeName)
                        .font(.caption)
                        .foregroundStyle(HomeTheme.secondary)
                        .lineLimit(1)
                }

                if let note = expense.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(HomeTheme.secondary)
                        .lineLimit(2)
                }

                if showsCreatorLabel, let creatorName, !creatorName.isEmpty {
                    Text("Added by \(creatorName)")
                        .font(.caption)
                        .foregroundStyle(HomeTheme.tertiary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    if acceptance == nil {
                        if expense.isRecurring {
                            amountAccessoryIcon(
                                "arrow.trianglehead.counterclockwise",
                                color: highlightsRecurringIcon
                                    ? HomeTheme.recurringHighlight
                                    : HomeTheme.secondary
                            )
                        }
                        if expense.isShared {
                            amountAccessoryIcon(
                                sharedExpenseSystemImage,
                                color: HomeTheme.secondary
                            )
                        }
                    }

                    Text(MoneyFormatter.string(from: myShare))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(HomeTheme.text)
                }

                if showsShareBreakdown {
                    Text("of \(MoneyFormatter.string(from: expense.money))")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(HomeTheme.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(amountAccessibilityLabel)
        }
    }

    /// You paid (`paidBy`) → branch; otherwise you were added as a participant → pull.
    private var sharedExpenseSystemImage: String {
        if let myUserId, expense.paidBy == myUserId {
            return "arrow.trianglehead.branch"
        }
        return "arrow.trianglehead.pull"
    }

    private var categoryIcon: some View {
        Image(systemName: expense.category.systemImage)
            .font(.system(size: 20, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(expense.category.color)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    /// Shared size/weight/spacing chrome for every glyph beside the amount.
    private func amountAccessoryIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var amountAccessibilityLabel: String {
        var parts: [String] = []
        if showsShareBreakdown {
            if let myUserId, expense.paidBy == myUserId {
                parts.append("Your share \(MoneyFormatter.string(from: myShare)), you paid shared expense")
            } else {
                parts.append("Your share \(MoneyFormatter.string(from: myShare)), shared expense")
            }
        } else {
            parts.append(MoneyFormatter.string(from: myShare))
        }
        if expense.isRecurring {
            parts.append("recurring")
        }
        return parts.joined(separator: ", ")
    }
}
