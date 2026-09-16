import Foundation

actor LocalBalanceRepository: BalanceRepository {
    private let repaymentsKey = "loam.local.repayments"

    func fetchBalances(for userId: UUID) async throws -> BalanceSnapshot {
        let expenses = try loadExpenses()
        var net: [UUID: Int] = [:]
        for expense in expenses {
            let payerAccepted = expense.shareRecord(for: expense.paidBy)?.status == .accepted
            for share in expense.shares where share.userId != expense.paidBy && payerAccepted && share.status == .accepted {
                // A participant owes the payer their accepted share.
                if expense.paidBy == userId { net[share.userId, default: 0] += share.amountMinor }
                if share.userId == userId { net[expense.paidBy, default: 0] -= share.amountMinor }
            }
        }
        for payment in try loadRepayments() where !payment.isReversed {
            if payment.toUserId == userId { net[payment.fromUserId, default: 0] -= payment.amountMinor }
            if payment.fromUserId == userId { net[payment.toUserId, default: 0] += payment.amountMinor }
        }
        return BalanceSnapshot(balances: net.filter { $0.value != 0 }.map {
            PersonBalance(personId: $0.key, displayName: SplitPartnerOption.displayName(for: $0.key), amountMinor: $0.value)
        }.sorted { $0.displayName < $1.displayName })
    }

    func fetchHistory(for userId: UUID, personId: UUID) async throws -> [BalanceHistoryEntry] { [] }

    func createRepayment(from userId: UUID, to personId: UUID, amountMinor: Int, note: String?, paidAt: Date, operationId: UUID) async throws {
        guard amountMinor > 0 else { throw BalanceRepositoryError.invalidAmount }
        let debt = try await fetchBalances(for: userId).balances.first(where: { $0.personId == personId })?.amountMinor ?? 0
        guard debt < 0, amountMinor <= -debt else { throw BalanceRepositoryError.exceedsDebt }
        var records = try loadRepayments()
        guard !records.contains(where: { $0.id == operationId }) else { return }
        records.append(RepaymentRecord(id: operationId, fromUserId: userId, toUserId: personId, amountMinor: amountMinor, note: note, paidAt: paidAt, createdAt: Date(), reversedAt: nil))
        try save(records)
    }

    func reverseRepayment(id: UUID, operationId: UUID) async throws {
        var records = try loadRepayments()
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].isReversed else { return }
        records[index] = RepaymentRecord(id: records[index].id, fromUserId: records[index].fromUserId, toUserId: records[index].toUserId, amountMinor: records[index].amountMinor, note: records[index].note, paidAt: records[index].paidAt, createdAt: records[index].createdAt, reversedAt: Date())
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
