import Foundation

/// Preserves an expense's existing split when opening edit / propose-edit forms.
struct SplitFormSeed: Equatable, Sendable {
    var splitMode: SplitExpenseMode
    var myPercentage: Int
    var myExactAmountText: String

    static func from(expense: ExpenseRecord, myUserId: UUID) -> SplitFormSeed {
        let partnerUserIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: myUserId)
        let myShare = expense.shares.first(where: { $0.userId == myUserId })?.amountMinor ?? expense.amountMinor

        if expense.isShared, partnerUserIds.count != 1 {
            return SplitFormSeed(splitMode: .equal, myPercentage: 50, myExactAmountText: "")
        }

        let partnerUserId = partnerUserIds.first ?? TestPartner.userId
        let partnerShare = expense.shares.first(where: { $0.userId == partnerUserId })?.amountMinor

        if expense.isShared,
           let partnerShare,
           myShare * 2 == expense.amountMinor,
           partnerShare * 2 == expense.amountMinor {
            return SplitFormSeed(splitMode: .equal, myPercentage: 50, myExactAmountText: "")
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
                return SplitFormSeed(splitMode: .percentage, myPercentage: pct, myExactAmountText: "")
            }
            return SplitFormSeed(
                splitMode: .exactAmount,
                myPercentage: 50,
                myExactAmountText: MoneyFormatter.typingAmount(
                    from: Money(amountMinor: myShare, currencyCode: expense.currency)
                )
            )
        }

        return SplitFormSeed(splitMode: .equal, myPercentage: 50, myExactAmountText: "")
    }
}
