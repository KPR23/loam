import Foundation

/// Simplifies pairwise nets into a minimal set of settlement suggestions.
enum BalanceSimplifier {
    struct NetBalance: Hashable, Sendable {
        let userId: UUID
        /// Positive = others owe this user (they overpaid). Negative = this user owes.
        let amountMinor: Int
    }

    struct Transfer: Hashable, Sendable {
        let fromUserId: UUID
        let toUserId: UUID
        let amountMinor: Int
    }

    /// Greedy match of debtors to creditors.
    static func simplify(_ nets: [NetBalance]) -> [Transfer] {
        var debtors = nets.filter { $0.amountMinor < 0 }
            .map { (id: $0.userId, amount: -$0.amountMinor) }
            .sorted { $0.amount > $1.amount }
        var creditors = nets.filter { $0.amountMinor > 0 }
            .map { (id: $0.userId, amount: $0.amountMinor) }
            .sorted { $0.amount > $1.amount }

        var transfers: [Transfer] = []
        var i = 0
        var j = 0

        while i < debtors.count && j < creditors.count {
            let pay = min(debtors[i].amount, creditors[j].amount)
            if pay > 0 {
                transfers.append(Transfer(
                    fromUserId: debtors[i].id,
                    toUserId: creditors[j].id,
                    amountMinor: pay
                ))
            }
            debtors[i].amount -= pay
            creditors[j].amount -= pay
            if debtors[i].amount == 0 { i += 1 }
            if creditors[j].amount == 0 { j += 1 }
        }

        return transfers
    }
}
