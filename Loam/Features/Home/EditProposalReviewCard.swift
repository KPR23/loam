import SwiftUI

struct EditProposalReviewCard: View {
    let proposal: ExpenseEditProposal
    let expense: ExpenseRecord
    let proposerName: String
    let onAccept: () -> Void
    let onReject: () -> Void

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
                        label: "Amount",
                        from: MoneyFormatter.string(from: expense.money),
                        to: MoneyFormatter.string(
                            from: Money(amountMinor: proposal.amountMinor, currencyCode: expense.currency)
                        )
                    )
                }
                if expense.category != proposal.category {
                    changeRow(
                        label: "Category",
                        from: expense.category.displayName,
                        to: proposal.category.displayName
                    )
                }
                if normalizedNote(expense.title) != normalizedNote(proposal.title) {
                    changeRow(
                        label: "Title",
                        from: displayNote(expense.title),
                        to: displayNote(proposal.title)
                    )
                }
                if expense.spentAt != proposal.spentAt {
                    changeRow(
                        label: "Date",
                        from: expense.spentAt.formatted(date: .abbreviated, time: .omitted),
                        to: proposal.spentAt.formatted(date: .abbreviated, time: .omitted)
                    )
                }
                if normalizedNote(expense.note) != normalizedNote(proposal.note) {
                    changeRow(
                        label: "Note",
                        from: displayNote(expense.note),
                        to: displayNote(proposal.note)
                    )
                }
                if expense.location != proposal.location {
                    changeRow(
                        label: "Location",
                        from: expense.location?.name ?? "None",
                        to: proposal.location?.name ?? "None"
                    )
                }
                if expense.paidBy != proposal.paidBy {
                    changeRow(
                        label: "Payer",
                        from: SplitPartnerOption.displayName(for: expense.paidBy),
                        to: SplitPartnerOption.displayName(for: proposal.paidBy)
                    )
                }
                if !sharesMatch(expense.shares, proposal.shares) {
                    changeRow(
                        label: "Shares",
                        from: sharesSummary(expense.shares, currency: expense.currency),
                        to: sharesSummary(proposal.shares, currency: expense.currency)
                    )
                }
            }

            HStack(spacing: 10) {
                Button(action: { LoamFeedback.tap(); onReject() }) {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: { LoamFeedback.tap(); onAccept() }) {
                    Text("Apply changes")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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

    private func normalizedNote(_ note: String?) -> String {
        note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func displayNote(_ note: String?) -> String {
        let trimmed = normalizedNote(note)
        return trimmed.isEmpty ? "None" : trimmed
    }

    private func sharesMatch(_ lhs: [ExpenseShareRecord], _ rhs: [ExpenseShareRecord]) -> Bool {
        let left = Dictionary(uniqueKeysWithValues: lhs.map { ($0.userId, $0.amountMinor) })
        let right = Dictionary(uniqueKeysWithValues: rhs.map { ($0.userId, $0.amountMinor) })
        return left == right
    }

    private func sharesSummary(_ shares: [ExpenseShareRecord], currency: String) -> String {
        shares
            .sorted {
                SplitPartnerOption.displayName(for: $0.userId)
                    .localizedCaseInsensitiveCompare(SplitPartnerOption.displayName(for: $1.userId))
                    == .orderedAscending
            }
            .map { share in
                let name = SplitPartnerOption.displayName(for: share.userId)
                let amount = MoneyFormatter.string(
                    from: Money(amountMinor: share.amountMinor, currencyCode: currency)
                )
                return "\(name) \(amount)"
            }
            .joined(separator: ", ")
    }
}
