import Foundation

actor LocalBalanceRepository: BalanceRepository {
    private let repaymentsKey = "loam.local.repayments"

    private struct BalanceKey: Hashable {
        let personId: UUID
        let currencyCode: String
    }

    func fetchBalances(for userId: UUID) async throws -> BalanceSnapshot {
        let expenses = try loadExpenses()
        var net: [BalanceKey: Int] = [:]
        for expense in expenses {
            let payerAccepted = expense.shareRecord(for: expense.paidBy)?.status == .accepted
            for share in expense.shares where share.userId != expense.paidBy && payerAccepted && share.status == .accepted {
                // A participant owes the payer their accepted share.
                let payerKey = BalanceKey(personId: share.userId, currencyCode: expense.currency.uppercased())
                let debtorKey = BalanceKey(personId: expense.paidBy, currencyCode: expense.currency.uppercased())
                if expense.paidBy == userId { net[payerKey, default: 0] += share.amountMinor }
                if share.userId == userId { net[debtorKey, default: 0] -= share.amountMinor }
            }
        }
        for payment in try loadRepayments() where !payment.isReversed {
            if payment.toUserId == userId {
                net[BalanceKey(personId: payment.fromUserId, currencyCode: payment.currencyCode.uppercased()), default: 0] -= payment.amountMinor
            }
            if payment.fromUserId == userId {
                net[BalanceKey(personId: payment.toUserId, currencyCode: payment.currencyCode.uppercased()), default: 0] += payment.amountMinor
            }
        }
        return BalanceSnapshot(balances: net.filter { $0.value != 0 }.map {
            PersonBalance(personId: $0.key.personId, displayName: SplitPartnerOption.displayName(for: $0.key.personId), amountMinor: $0.value, currencyCode: $0.key.currencyCode)
        }.sorted {
            $0.displayName == $1.displayName
                ? $0.currencyCode < $1.currencyCode
                : $0.displayName < $1.displayName
        })
    }

    /// Mirrors the `balance_history` RPC: every share and repayment between the two people, newest first.
    func fetchHistory(for userId: UUID, personId: UUID) async throws -> [BalanceHistoryEntry] {
        var entries: [BalanceHistoryEntry] = []
        for expense in try loadExpenses() {
            for share in expense.shares where (expense.paidBy == userId && share.userId == personId) || (expense.paidBy == personId && share.userId == userId) {
                entries.append(BalanceHistoryEntry(
                    id: expense.id,
                    kind: .purchase,
                    title: expense.title ?? expense.category.rawValue,
                    amountMinor: expense.paidBy == userId ? share.amountMinor : -share.amountMinor,
                    occurredAt: expense.spentAt,
                    status: share.status,
                    currencyCode: expense.currency.uppercased(),
                    categoryName: expense.category.rawValue
                ))
            }
        }
        for payment in try loadRepayments() where (payment.fromUserId == userId && payment.toUserId == personId) || (payment.toUserId == userId && payment.fromUserId == personId) {
            entries.append(BalanceHistoryEntry(
                id: payment.id,
                kind: payment.isReversed ? .reversal : .repayment,
                title: payment.note ?? "Repayment",
                amountMinor: payment.toUserId == userId ? -payment.amountMinor : payment.amountMinor,
                occurredAt: payment.paidAt,
                status: nil,
                currencyCode: payment.currencyCode.uppercased(),
                categoryName: nil
            ))
        }
        return entries.sorted { $0.occurredAt > $1.occurredAt }
    }

    func createRepayment(from userId: UUID, to personId: UUID, amountMinor: Int, currencyCode: String, note: String?, paidAt: Date, operationId: UUID) async throws {
        guard amountMinor > 0 else { throw BalanceRepositoryError.invalidAmount }
        let debt = try await fetchBalances(for: userId).balances.first(where: {
            $0.personId == personId && $0.currencyCode.caseInsensitiveCompare(currencyCode) == .orderedSame
        })?.amountMinor ?? 0
        guard debt < 0, amountMinor <= -debt else { throw BalanceRepositoryError.exceedsDebt }
        var records = try loadRepayments()
        guard !records.contains(where: { $0.id == operationId }) else { return }
        records.append(RepaymentRecord(id: operationId, fromUserId: userId, toUserId: personId, amountMinor: amountMinor, currencyCode: currencyCode.uppercased(), note: note, paidAt: paidAt, createdAt: Date(), reversedAt: nil))
        try save(records)
    }

    func reverseRepayment(id: UUID, operationId: UUID) async throws {
        var records = try loadRepayments()
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].isReversed else { return }
        records[index] = RepaymentRecord(id: records[index].id, fromUserId: records[index].fromUserId, toUserId: records[index].toUserId, amountMinor: records[index].amountMinor, currencyCode: records[index].currencyCode, note: records[index].note, paidAt: records[index].paidAt, createdAt: records[index].createdAt, reversedAt: Date())
        try save(records)
    }

    private func loadExpenses() throws -> [ExpenseRecord] {
        guard let data = UserDefaults.standard.data(forKey: "loam.local.expenses") else { return [] }
        return try JSONDecoder().decode([ExpenseRecord].self, from: data)
    }
    private func loadRepayments() throws -> [RepaymentRecord] {
        guard let data = UserDefaults.standard.data(forKey: repaymentsKey) else { return [] }
        return try JSONDecoder().decode([RepaymentRecord].self, from: data)
    }
    private func save(_ records: [RepaymentRecord]) throws { UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: repaymentsKey) }
}
