import Foundation

/// Preserves an expense's existing split when opening edit / propose-edit forms.
struct SplitFormSeed: Equatable, Sendable {
    var splitMode: SplitExpenseMode
    var myPercentage: Int
    var myExactAmountText: String
    var participantPercentages: [UUID: Int]
    var participantAmountTexts: [UUID: String]

    static func from(expense: ExpenseRecord, myUserId: UUID) -> SplitFormSeed {
        let partnerUserIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: myUserId)
        let myShare = expense.shares.first(where: { $0.userId == myUserId })?.amountMinor ?? expense.amountMinor
        let amountTexts = Dictionary(uniqueKeysWithValues: expense.shares.map {
            (
                $0.userId,
                MoneyFormatter.typingAmount(from: Money(amountMinor: $0.amountMinor, currencyCode: expense.currency))
            )
        })
        let equalPercentages = equalPercentages(for: expense.shares.map(\.userId))

        if expense.isShared, partnerUserIds.count != 1 {
            return SplitFormSeed(
                splitMode: .equal,
                myPercentage: equalPercentages[myUserId] ?? 50,
                myExactAmountText: amountTexts[myUserId] ?? "",
                participantPercentages: equalPercentages,
                participantAmountTexts: amountTexts
            )
        }

        let partnerUserId = partnerUserIds.first ?? TestPartner.userId
        let partnerShare = expense.shares.first(where: { $0.userId == partnerUserId })?.amountMinor

        if expense.isShared,
           let partnerShare,
           myShare * 2 == expense.amountMinor,
           partnerShare * 2 == expense.amountMinor {
            return SplitFormSeed(
                splitMode: .equal,
                myPercentage: 50,
                myExactAmountText: "",
                participantPercentages: equalPercentages,
                participantAmountTexts: amountTexts
            )
        }

        if expense.isShared, expense.amountMinor > 0 {
            let storedShares = expense.shares.map {
                SplitCalculator.Share(userId: $0.userId, amountMinor: $0.amountMinor)
            }
            if let pct = SplitCalculator.matchingTwoPersonPercentage(
                totalMinor: expense.amountMinor,
                myUserId: myUserId,
                partnerUserId: partnerUserId,
                paidByUserId: expense.paidBy,
                storedShares: storedShares
            ) {
                return SplitFormSeed(
                    splitMode: .percentage,
                    myPercentage: pct,
                    myExactAmountText: "",
                    participantPercentages: [myUserId: pct, partnerUserId: 100 - pct],
                    participantAmountTexts: amountTexts
                )
            }
            return SplitFormSeed(
                splitMode: .exactAmount,
                myPercentage: 50,
                myExactAmountText: MoneyFormatter.typingAmount(
                    from: Money(amountMinor: myShare, currencyCode: expense.currency)
                ),
                participantPercentages: equalPercentages,
                participantAmountTexts: amountTexts
            )
        }

        return SplitFormSeed(
            splitMode: .equal,
            myPercentage: 50,
            myExactAmountText: "",
            participantPercentages: [:],
            participantAmountTexts: [:]
        )
    }

    private static func equalPercentages(for userIds: [UUID]) -> [UUID: Int] {
        guard !userIds.isEmpty else { return [:] }
        let base = 100 / userIds.count
        var result = Dictionary(uniqueKeysWithValues: userIds.map { ($0, base) })
        result[userIds[0], default: 0] += 100 - (base * userIds.count)
        return result
    }
}
