import Foundation

/// Pure split math. Share sum always equals the expense total; remainder grosze go to the payer.
enum SplitCalculator {
    struct Participant: Hashable, Sendable {
        let userId: UUID
        /// Relative weight. Equal split uses weight 1 for each included person.
        let weight: Int

        init(userId: UUID, weight: Int = 1) {
            precondition(weight > 0, "Weight must be positive")
            self.userId = userId
            self.weight = weight
        }
    }

    struct Share: Hashable, Sendable {
        let userId: UUID
        let amountMinor: Int
    }

    /// Equal split among participants. Remainder cents assigned to `paidByUserId` if they participate; otherwise first participant.
    static func equal(
        totalMinor: Int,
        participants: [UUID],
        paidByUserId: UUID
    ) -> [Share] {
        let unique = Array(Set(participants))
        precondition(!unique.isEmpty, "Need at least one participant")
        precondition(totalMinor >= 0, "Total must be non-negative")

        let weighted = unique.map { Participant(userId: $0, weight: 1) }
        return weightedSplit(totalMinor: totalMinor, participants: weighted, remainderTo: paidByUserId)
    }

    /// Custom amounts must already sum to total. Use when UI collects exact minor amounts.
    static func custom(shares: [Share]) -> [Share] {
        precondition(!shares.isEmpty, "Need at least one share")
        precondition(sharesSumEqualsTotal(shares, totalMinor: shares.reduce(0) { $0 + $1.amountMinor }))
        return shares
    }

    /// Weighted split (e.g. 2:1). Floor each share; leftover grosze go to `remainderTo` when present.
    static func weightedSplit(
        totalMinor: Int,
        participants: [Participant],
        remainderTo: UUID
    ) -> [Share] {
        precondition(!participants.isEmpty, "Need at least one participant")
        precondition(totalMinor >= 0, "Total must be non-negative")

        let weightSum = participants.reduce(0) { $0 + $1.weight }
        precondition(weightSum > 0)

        var shares = participants.map { participant in
            Share(
                userId: participant.userId,
                amountMinor: (totalMinor * participant.weight) / weightSum
            )
        }

        let allocated = shares.reduce(0) { $0 + $1.amountMinor }
        let remainder = totalMinor - allocated
        guard remainder != 0 else { return shares }

        let targetIndex = shares.firstIndex(where: { $0.userId == remainderTo }) ?? 0
        shares[targetIndex] = Share(
            userId: shares[targetIndex].userId,
            amountMinor: shares[targetIndex].amountMinor + remainder
        )
        return shares
    }

    /// Private expense: single 100% share.
    static func personal(totalMinor: Int, userId: UUID) -> [Share] {
        [Share(userId: userId, amountMinor: totalMinor)]
    }

    static func sharesSumEqualsTotal(_ shares: [Share], totalMinor: Int) -> Bool {
        shares.reduce(0) { $0 + $1.amountMinor } == totalMinor
    }
}
