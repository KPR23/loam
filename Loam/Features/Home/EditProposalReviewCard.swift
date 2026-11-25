import SwiftUI

struct EditProposalReviewCard: View {
    let proposal: ExpenseEditProposal
    let expense: ExpenseRecord
    let proposerName: String
    /// Labels this person's own share and payment as "You".
    var viewerId: UUID? = nil
    /// Shown instead of the buttons when someone else decides.
    var awaitingReviewFrom: String? = nil
    var onAccept: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(proposerName) suggested changes", systemImage: "square.and.pencil")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HomeTheme.accent)
                .labelStyle(.titleAndIcon)

            if let message = proposal.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(HomeTheme.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                if expense.amountMinor != proposal.amountMinor {
                    changeRow(
                        label: String(localized: "Amount"),
                        from: MoneyFormatter.string(from: expense.money),
                        to: MoneyFormatter.string(
                            from: Money(amountMinor: proposal.amountMinor, currencyCode: expense.currency)
                        )
                    )
                }
                if proposal.changesCategory(of: expense) {
                    changeRow(
                        label: String(localized: "Category"),
                        from: expense.spendCategory.displayName,
                        to: proposal.category.displayName
                    )
                }
                if normalizedNote(expense.title) != normalizedNote(proposal.title) {
                    changeRow(
                        label: String(localized: "Title"),
                        from: displayNote(expense.title),
                        to: displayNote(proposal.title)
                    )
                }
                if expense.spentAt != proposal.spentAt {
                    changeRow(
                        label: String(localized: "Date"),
                        from: expense.spentAt.formatted(date: .abbreviated, time: .omitted),
                        to: proposal.spentAt.formatted(date: .abbreviated, time: .omitted)
                    )
                }
                if normalizedNote(expense.note) != normalizedNote(proposal.note) {
                    changeRow(
                        label: String(localized: "Note"),
                        from: displayNote(expense.note),
                        to: displayNote(proposal.note)
                    )
                }
                if expense.location != proposal.location {
                    changeRow(
                        label: String(localized: "Location"),
                        from: expense.location?.name ?? String(localized: "None"),
                        to: proposal.location?.name ?? String(localized: "None")
                    )
                }
                if expense.paidBy != proposal.paidBy {
                    changeRow(
                        label: String(localized: "Payer"),
                        from: name(for: expense.paidBy),
                        to: name(for: proposal.paidBy)
                    )
                }
                if !sharesMatch(expense.shares, proposal.shares) {
                    changeRow(
                        label: String(localized: "Shares"),
                        from: sharesSummary(expense.shares, currency: expense.currency),
                        to: sharesSummary(proposal.shares, currency: expense.currency)
                    )
                }
            }

            if let onAccept, let onReject {
                HStack(spacing: 10) {
                    Button(action: { LoamFeedback.tap(); onReject() }) {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)

                    Button(action: { LoamFeedback.tap(); onAccept() }) {
                        Text("Apply changes")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HomeTheme.accentFill)
                }
                // List swallows taps on nested bordered buttons unless the row opts out.
                .buttonStyle(.borderless)
            } else if let awaitingReviewFrom {
                Label("Waiting for \(awaitingReviewFrom) to review", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(HomeTheme.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func changeRow(label: String, from: String, to: String) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(from)
                    .strikethrough()
                    .foregroundStyle(HomeTheme.tertiary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(HomeTheme.tertiary)
                Text(to)
                    .fontWeight(.semibold)
            }
            .font(.caption)
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(HomeTheme.secondary)
        }
    }

    private func name(for userId: UUID) -> String {
        userId == viewerId ? String(localized: "You") : SplitPartnerOption.displayName(for: userId)
    }

    private func normalizedNote(_ note: String?) -> String {
        note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func displayNote(_ note: String?) -> String {
        let trimmed = normalizedNote(note)
        return trimmed.isEmpty ? String(localized: "None") : trimmed
    }

    private func sharesMatch(_ lhs: [ExpenseShareRecord], _ rhs: [ExpenseShareRecord]) -> Bool {
        Self.sharesMatch(lhs, rhs)
    }

    fileprivate static func sharesMatch(_ lhs: [ExpenseShareRecord], _ rhs: [ExpenseShareRecord]) -> Bool {
        let left = Dictionary(uniqueKeysWithValues: lhs.map { ($0.userId, $0.amountMinor) })
        let right = Dictionary(uniqueKeysWithValues: rhs.map { ($0.userId, $0.amountMinor) })
        return left == right
    }

    fileprivate static func normalizedNote(_ note: String?) -> String {
        note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The names of the fields a proposal would change, in display order.
    static func changedFieldLabels(expense: ExpenseRecord, proposal: ExpenseEditProposal) -> [String] {
        var labels: [String] = []
        if expense.amountMinor != proposal.amountMinor { labels.append(String(localized: "Amount")) }
        if proposal.changesCategory(of: expense) { labels.append(String(localized: "Category")) }
        if normalizedNote(expense.title) != normalizedNote(proposal.title) { labels.append(String(localized: "Title")) }
        if expense.spentAt != proposal.spentAt { labels.append(String(localized: "Date")) }
        if normalizedNote(expense.note) != normalizedNote(proposal.note) { labels.append(String(localized: "Note")) }
        if expense.location != proposal.location { labels.append(String(localized: "Location")) }
        if expense.paidBy != proposal.paidBy { labels.append(String(localized: "Payer")) }
        if !sharesMatch(expense.shares, proposal.shares) { labels.append(String(localized: "Shares")) }
        return labels
    }

    private func sharesSummary(_ shares: [ExpenseShareRecord], currency: String) -> String {
        shares
            .sorted {
                name(for: $0.userId)
                    .localizedCaseInsensitiveCompare(name(for: $1.userId))
                    == .orderedAscending
            }
            .map { share in
                let label = name(for: share.userId)
                let amount = MoneyFormatter.string(
                    from: Money(amountMinor: share.amountMinor, currencyCode: currency)
                )
                return "\(label) \(amount)"
            }
            .joined(separator: ", ")
    }
}

/// Compact summary shown on Home; tap it to see the full diff in the expense's details.
struct EditProposalSummaryCard: View {
    let proposal: ExpenseEditProposal
    let expense: ExpenseRecord
    let proposerName: String
    var onAccept: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil
    var onShowDetails: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { onShowDetails?() }) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(proposerName) suggested changes", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HomeTheme.accent)
                        .labelStyle(.titleAndIcon)

                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(HomeTheme.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onAccept, let onReject {
                HStack(spacing: 10) {
                    Button(action: { LoamFeedback.tap(); onReject() }) {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)

                    Button(action: { LoamFeedback.tap(); onAccept() }) {
                        Text("Apply changes")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HomeTheme.accentFill)
                }
                // List swallows taps on nested bordered buttons unless the row opts out.
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let fields = EditProposalReviewCard.changedFieldLabels(expense: expense, proposal: proposal)
        switch fields.count {
        case 0: return String(localized: "No changes")
        case 1: return String(localized: "\(fields[0]) changed")
        default:
            let count = fields.count
            let list = fields.joined(separator: ", ")
            return String(localized: "\(count) fields changed \u{2022} \(list)")
        }
    }
}
