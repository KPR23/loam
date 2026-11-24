import Foundation

enum ExpenseShareAcceptance {
    /// Assigns acceptance status when creating or updating shares.
    static func sharesWithAcceptance(
        calculatedShares: [SplitCalculator.Share],
        expense: ExpenseRecord,
        usersTrustingCreator: Set<UUID> = []
    ) -> [ExpenseShareRecord] {
        calculatedShares.map { share in
            let existing = expense.shares.first(where: { $0.userId == share.userId })
            let status = statusForShare(
                userId: share.userId,
                amountMinor: share.amountMinor,
                createdBy: expense.createdBy,
                paidBy: expense.paidBy,
                usersTrustingCreator: usersTrustingCreator
            )
            return ExpenseShareRecord(
                id: existing?.id ?? UUID(),
                userId: share.userId,
                amountMinor: share.amountMinor,
                status: status,
                respondedAt: status == .accepted ? Date() : nil,
                acceptedViaTrust: status == .accepted
                    && share.userId != expense.createdBy
                    && usersTrustingCreator.contains(share.userId)
            )
        }
    }

    /// Mirrors `save_expense_as`: while the payer and currency are unchanged,
    /// a participant whose own amount is unchanged keeps their answer,
    /// including a rejection. Trust only applies to new or changed amounts.
    /// `forced` users (the creator, a proposer whose change is applied) keep
    /// the status already assigned. A kept pending answer on a share that now
    /// owes nothing is accepted, as `accept_zero_share` does on the server.
    static func preservingResponses(
        _ shares: [ExpenseShareRecord],
        from previous: ExpenseRecord,
        paidBy: UUID,
        currency: String,
        forced: Set<UUID>
    ) -> [ExpenseShareRecord] {
        guard previous.paidBy == paidBy, previous.currency == currency else { return shares }
        return shares.map { share in
            guard !forced.contains(share.userId),
                  let old = previous.shares.first(where: { $0.userId == share.userId }),
                  old.amountMinor == share.amountMinor
            else { return share }
            var kept = share
            kept.status = old.status
            kept.respondedAt = old.respondedAt
            kept.acceptedViaTrust = old.acceptedViaTrust
            if kept.status == .pending, owesNothing(userId: kept.userId, amountMinor: kept.amountMinor, paidBy: paidBy) {
                kept.status = .accepted
                kept.respondedAt = Date()
                kept.acceptedViaTrust = false
            }
            return kept
        }
    }

    static func statusForShare(
        userId: UUID,
        amountMinor: Int,
        createdBy: UUID,
        paidBy: UUID,
        usersTrustingCreator: Set<UUID>
    ) -> ExpenseShareStatus {
        if userId == createdBy { return .accepted }
        if usersTrustingCreator.contains(userId) { return .accepted }
        if owesNothing(userId: userId, amountMinor: amountMinor, paidBy: paidBy) { return .accepted }
        return .pending
    }

    /// A participant who didn't pay and whose share is 0 has nothing to pay
    /// back, so there is nothing for them to accept. The payer still answers
    /// with a 0 share, because they are the one being owed.
    static func owesNothing(userId: UUID, amountMinor: Int, paidBy: UUID) -> Bool {
        amountMinor == 0 && userId != paidBy
    }
}
