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
        precondition(shares.allSatisfy { $0.amountMinor >= 0 }, "Shares must be non-negative")
        precondition(Set(shares.map(\.userId)).count == shares.count, "Participants must be unique")
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

    /// Percentage split (must sum to 100). Remainder grosze go to `paidByUserId`.
    static func percentage(
        totalMinor: Int,
        userPercentages: [(userId: UUID, percent: Int)],
        paidByUserId: UUID
    ) -> [Share] {
        precondition(!userPercentages.isEmpty, "Need at least one participant")
        let percentSum = userPercentages.reduce(0) { $0 + $1.percent }
        precondition(percentSum == 100, "Percentages must sum to 100")

        let participants = userPercentages.map { Participant(userId: $0.userId, weight: $0.percent) }
        return weightedSplit(totalMinor: totalMinor, participants: participants, remainderTo: paidByUserId)
    }

    /// Builds shares for a split using the selected mode.
    static func split(
        totalMinor: Int,
        mode: SplitExpenseMode,
        myUserId: UUID,
        partnerUserIds: [UUID],
        paidByUserId: UUID,
        myPercentage: Int = 50,
        myExactAmountMinor: Int? = nil,
        participantPercentages: [UUID: Int] = [:],
        participantExactAmountMinors: [UUID: Int] = [:]
    ) -> [Share] {
        let partners = Array(Set(partnerUserIds))
        precondition(!partners.isEmpty, "Need at least one partner")
        let participantIds = Set([myUserId] + partners)

        if mode == .percentage {
            let percentages = participantPercentages.filter { participantIds.contains($0.key) }
            if percentages.count == participantIds.count,
               percentages.values.allSatisfy({ $0 > 0 }),
               percentages.values.reduce(0, +) == 100 {
                return percentage(
                    totalMinor: totalMinor,
                    userPercentages: percentages.map { ($0.key, $0.value) },
                    paidByUserId: paidByUserId
                )
            }
        }

        if mode == .exactAmount {
            let amounts = participantExactAmountMinors.filter { participantIds.contains($0.key) }
            if amounts.count == participantIds.count,
               amounts.values.allSatisfy({ $0 >= 0 }),
               amounts.values.reduce(0, +) == totalMinor {
                return custom(shares: amounts.map { Share(userId: $0.key, amountMinor: $0.value) })
            }
        }

        if partners.count == 1 {
            return twoPersonSplit(
                totalMinor: totalMinor,
                mode: mode,
                myUserId: myUserId,
                partnerUserId: partners[0],
                paidByUserId: paidByUserId,
                myPercentage: myPercentage,
                myExactAmountMinor: myExactAmountMinor
            )
        }

        switch mode {
        case .equal:
            return equal(
                totalMinor: totalMinor,
                participants: [myUserId] + partners,
                paidByUserId: paidByUserId
            )
        case .percentage:
            let myShare = (totalMinor * myPercentage) / 100
            let partnerShares = equal(
                totalMinor: totalMinor - myShare,
                participants: partners,
                paidByUserId: paidByUserId
            )
            return [Share(userId: myUserId, amountMinor: myShare)] + partnerShares
        case .exactAmount:
            guard let mine = myExactAmountMinor else {
                preconditionFailure("Exact amount mode requires myExactAmountMinor")
            }
            precondition(mine >= 0 && mine <= totalMinor, "Exact shares must be non-negative")
            let partnerShares = equal(
                totalMinor: totalMinor - mine,
                participants: partners,
                paidByUserId: paidByUserId
            )
            return [Share(userId: myUserId, amountMinor: mine)] + partnerShares
        }
    }

    /// Builds shares for a two-person split using the selected mode.
    static func twoPersonSplit(
        totalMinor: Int,
        mode: SplitExpenseMode,
        myUserId: UUID,
        partnerUserId: UUID,
        paidByUserId: UUID,
        myPercentage: Int = 50,
        myExactAmountMinor: Int? = nil
    ) -> [Share] {
        let participants = [myUserId, partnerUserId]

        switch mode {
        case .equal:
            return equal(totalMinor: totalMinor, participants: participants, paidByUserId: paidByUserId)
        case .percentage:
            let partnerPercentage = 100 - myPercentage
            return percentage(
                totalMinor: totalMinor,
                userPercentages: [
                    (myUserId, myPercentage),
                    (partnerUserId, partnerPercentage),
                ],
                paidByUserId: paidByUserId
            )
        case .exactAmount:
            guard let mine = myExactAmountMinor else {
                preconditionFailure("Exact amount mode requires myExactAmountMinor")
            }
            let partnerShare = totalMinor - mine
            precondition(mine >= 0 && partnerShare >= 0, "Exact shares must be non-negative")
            return custom(shares: [
                Share(userId: myUserId, amountMinor: mine),
                Share(userId: partnerUserId, amountMinor: partnerShare),
            ])
        }
    }

    /// Private expense: single 100% share.
    static func personal(totalMinor: Int, userId: UUID) -> [Share] {
        [Share(userId: userId, amountMinor: totalMinor)]
    }

    static func sharesSumEqualsTotal(_ shares: [Share], totalMinor: Int) -> Bool {
        shares.reduce(0) { $0 + $1.amountMinor } == totalMinor
    }

    /// Returns my percentage only when stored shares round-trip through percentage mode.
    static func matchingTwoPersonPercentage(
        totalMinor: Int,
        myUserId: UUID,
        partnerUserId: UUID,
        paidByUserId: UUID,
        storedShares: [Share]
    ) -> Int? {
        guard totalMinor > 0 else { return nil }
        guard let myShare = storedShares.first(where: { $0.userId == myUserId })?.amountMinor else {
            return nil
        }

        let pct = Int(round(Double(myShare) / Double(totalMinor) * 100))
        guard pct > 0, pct < 100 else { return nil }

        let recomputed = twoPersonSplit(
            totalMinor: totalMinor,
            mode: .percentage,
            myUserId: myUserId,
            partnerUserId: partnerUserId,
            paidByUserId: paidByUserId,
            myPercentage: pct
        )

        let storedByUser = Dictionary(uniqueKeysWithValues: storedShares.map { ($0.userId, $0.amountMinor) })
        let matches = recomputed.allSatisfy { storedByUser[$0.userId] == $0.amountMinor }
            && storedByUser.count == recomputed.count

        return matches ? pct : nil
    }
}
