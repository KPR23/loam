import Foundation

/// On-device store for demo mode and offline Phase 1. Swapped for Supabase when configured.
actor LocalExpenseRepository: ExpenseRepository {
    private let defaultsKey = "loam.local.expenses"
    private let recurringDefaultsKey = "loam.local.recurring"
    private var cache: [ExpenseRecord]?
    private var recurringCache: [RecurringRuleRecord]?

    func fetchExpenses(for userId: UUID, in period: DatePeriod) async throws -> [ExpenseRecord] {
        let all = try load()
        let (start, endExclusive) = period.dateRange
        return all
            .filter { expense in
                expense.shares.contains(where: { $0.userId == userId })
                    && expense.spentAt >= start
                    && expense.spentAt < endExclusive
            }
            .sorted { $0.spentAt > $1.spentAt || ($0.spentAt == $1.spentAt && $0.createdAt > $1.createdAt) }
    }

    func create(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        try validate(expense)
        var all = try load()
        all.append(expense)
        try save(all)
        return expense
    }

    func createRecurringRule(_ rule: RecurringRuleRecord) async throws -> RecurringRuleRecord {
        var all = try loadRecurring()
        all.append(rule)
        try saveRecurring(all)
        return rule
    }

    func update(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        try validate(expense)
        var all = try load()
        guard let index = all.firstIndex(where: { $0.id == expense.id }) else {
            throw ExpenseRepositoryError.notFound
        }
        var updated = expense
        updated.updatedAt = Date()
        all[index] = updated
        try save(all)
        return updated
    }

    func delete(id: UUID) async throws {
        var all = try load()
        let before = all.count
        all.removeAll { $0.id == id }
        guard all.count < before else { throw ExpenseRepositoryError.notFound }
        try save(all)
    }

    private func validate(_ expense: ExpenseRecord) throws {
        let sum = expense.shares.reduce(0) { $0 + $1.amountMinor }
        guard sum == expense.amountMinor else {
            throw ExpenseRepositoryError.invalidShares
        }
    }

    private func load() throws -> [ExpenseRecord] {
        if let cache { return cache }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            cache = []
            return []
        }
        let decoded = try JSONDecoder().decode([ExpenseRecord].self, from: data)
        cache = decoded
        return decoded
    }

    private func save(_ expenses: [ExpenseRecord]) throws {
        let data = try JSONEncoder().encode(expenses)
        UserDefaults.standard.set(data, forKey: defaultsKey)
        cache = expenses
    }

    private func loadRecurring() throws -> [RecurringRuleRecord] {
        if let recurringCache { return recurringCache }
        guard let data = UserDefaults.standard.data(forKey: recurringDefaultsKey) else {
            recurringCache = []
            return []
        }
        let decoded = try JSONDecoder().decode([RecurringRuleRecord].self, from: data)
        recurringCache = decoded
        return decoded
    }

    private func saveRecurring(_ rules: [RecurringRuleRecord]) throws {
        let data = try JSONEncoder().encode(rules)
        UserDefaults.standard.set(data, forKey: recurringDefaultsKey)
        recurringCache = rules
    }
}
