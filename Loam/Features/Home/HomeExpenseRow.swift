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
    /// Changed offline and not on the server yet.
    var isWaitingToSync: Bool = false

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
                Button {
                    LoamFeedback.tap()
                    onTap()
                } label: {
                    rowContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LoamPressStyle())
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

                if FeatureFlags.merchant,
                   let placeName = expense.location?.name,
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
                HStack(spacing: 6) {
                    if isWaitingToSync {
                        amountAccessoryIcon("icloud.and.arrow.up", color: .orange)
                    }
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
                                expense.sharedSplitSystemImage(for: myUserId),
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

    private var categoryIcon: some View {
        CategoryIconTile(systemImage: expense.spendCategory.systemImage, color: expense.spendCategory.color)
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
            let share = MoneyFormatter.string(from: myShare)
            if let myUserId, expense.paidBy == myUserId {
                parts.append(String(localized: "Your share \(share), you paid shared expense"))
            } else {
                parts.append(String(localized: "Your share \(share), shared expense"))
            }
        } else {
            parts.append(MoneyFormatter.string(from: myShare))
        }
        if expense.isRecurring {
            parts.append(String(localized: "recurring"))
        }
        if isWaitingToSync {
            parts.append(String(localized: "waiting to sync"))
        }
        return parts.joined(separator: ", ")
    }
}
