import Foundation

/// One-time removal of records written by a previously shipped local fixture.
/// It never removes entries that were created by the user.
enum LegacyDemoFixtureCleanup {
    private static let didRunKey = "loam.demo.fixtures.removed"

    static func removeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: didRunKey) else { return }
        let expenseIDs = Set((301...312).compactMap { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0)) })
        let recurringID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let repaymentID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        if let data = defaults.data(forKey: "loam.local.expenses"), var values = try? decoder.decode([ExpenseRecord].self, from: data) {
            values.removeAll { expenseIDs.contains($0.id) }
            defaults.set(try? encoder.encode(values), forKey: "loam.local.expenses")
        }
        if let data = defaults.data(forKey: "loam.local.recurring"), var values = try? decoder.decode([RecurringRuleRecord].self, from: data) {
            values.removeAll { $0.id == recurringID }
            defaults.set(try? encoder.encode(values), forKey: "loam.local.recurring")
        }
        if let data = defaults.data(forKey: "loam.local.proposals"), var values = try? decoder.decode([ExpenseEditProposal].self, from: data) {
            values.removeAll { expenseIDs.contains($0.expenseId) }
            defaults.set(try? encoder.encode(values), forKey: "loam.local.proposals")
        }
        if let data = defaults.data(forKey: "loam.local.repayments"), var values = try? decoder.decode([RepaymentRecord].self, from: data) {
            values.removeAll { $0.id == repaymentID }
            defaults.set(try? encoder.encode(values), forKey: "loam.local.repayments")
        }
        defaults.removeObject(forKey: "loam.demo.seed.version")
        defaults.set(true, forKey: didRunKey)
    }
}
