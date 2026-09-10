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
                createdBy: expense.createdBy,
                householdId: expense.householdId,
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

    static func statusForShare(
        userId: UUID,
        createdBy: UUID,
        householdId: UUID?,
        usersTrustingCreator: Set<UUID>
    ) -> ExpenseShareStatus {
        guard householdId != nil else { return .accepted }
        if userId == createdBy { return .accepted }
        if usersTrustingCreator.contains(userId) { return .accepted }
        return .pending
    }
}
