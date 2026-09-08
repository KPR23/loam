import Foundation

struct ExpenseShareRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var userId: UUID
    var amountMinor: Int

    init(id: UUID = UUID(), userId: UUID, amountMinor: Int) {
        self.id = id
        self.userId = userId
        self.amountMinor = amountMinor
    }
}

struct ExpenseRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var note: String?
    /// Calendar day only — time component ignored for month aggregation.
    var spentAt: Date
    var paidBy: UUID
    var createdBy: UUID
    var householdId: UUID?
    var recurringId: UUID?
    var shares: [ExpenseShareRecord]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        amountMinor: Int,
        currency: String = "PLN",
        category: ExpenseCategory,
        note: String? = nil,
        spentAt: Date = Date(),
        paidBy: UUID,
        createdBy: UUID,
        householdId: UUID? = nil,
        recurringId: UUID? = nil,
        shares: [ExpenseShareRecord],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.amountMinor = amountMinor
        self.currency = currency
        self.category = category
        self.note = note
        self.spentAt = Calendar.current.startOfDay(for: spentAt)
        self.paidBy = paidBy
        self.createdBy = createdBy
        self.householdId = householdId
        self.recurringId = recurringId
        self.shares = shares
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var money: Money {
        Money(amountMinor: amountMinor, currencyCode: currency)
    }

    func share(for userId: UUID) -> Money {
        let minor = shares.first(where: { $0.userId == userId })?.amountMinor ?? 0
        return Money(amountMinor: minor, currencyCode: currency)
    }

    var isShared: Bool { householdId != nil }
}

struct MonthSpendSummary: Sendable {
    var totalMine: Money
    var sharedShare: Money

    static func zero(currency: String = "PLN") -> MonthSpendSummary {
        MonthSpendSummary(
            totalMine: Money(amountMinor: 0, currencyCode: currency),
            sharedShare: Money(amountMinor: 0, currencyCode: currency)
        )
    }
}
