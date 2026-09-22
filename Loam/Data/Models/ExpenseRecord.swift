import Foundation

struct ExpenseShareRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var userId: UUID
    var amountMinor: Int
    var status: ExpenseShareStatus
    var respondedAt: Date?
    var acceptedViaTrust: Bool

    init(
        id: UUID = UUID(),
        userId: UUID,
        amountMinor: Int,
        status: ExpenseShareStatus = .accepted,
        respondedAt: Date? = nil,
        acceptedViaTrust: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.amountMinor = amountMinor
        self.status = status
        self.respondedAt = respondedAt
        self.acceptedViaTrust = acceptedViaTrust
    }

    var countsInSummary: Bool { status.isCountedInSummary }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        amountMinor = try container.decode(Int.self, forKey: .amountMinor)
        status = try container.decodeIfPresent(ExpenseShareStatus.self, forKey: .status) ?? .accepted
        respondedAt = try container.decodeIfPresent(Date.self, forKey: .respondedAt)
        acceptedViaTrust = try container.decodeIfPresent(Bool.self, forKey: .acceptedViaTrust) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case userId
        case amountMinor
        case status
        case respondedAt
        case acceptedViaTrust
    }
}

struct ExpenseRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var location: ExpenseLocation?
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
        title: String? = nil,
        note: String? = nil,
        location: ExpenseLocation? = nil,
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
        self.title = title
        self.note = note
        self.location = location
        self.spentAt = AppPreferences.calendar.startOfDay(for: spentAt)
        self.paidBy = paidBy
        self.createdBy = createdBy
        self.householdId = householdId
        self.recurringId = recurringId
        self.shares = shares
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Prefer custom title; fall back to category name when blank.
    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? category.displayName : trimmed
    }

    var hasCustomTitle: Bool {
        !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var money: Money {
        Money(amountMinor: amountMinor, currencyCode: currency)
    }

    func share(for userId: UUID) -> Money {
        let minor = shares.first(where: { $0.userId == userId })?.amountMinor ?? 0
        return Money(amountMinor: minor, currencyCode: currency)
    }

    var isShared: Bool { householdId != nil }

    var isRecurring: Bool { recurringId != nil }

    /// You paid (`paidBy`) → branch; otherwise you were added as a participant → pull.
    /// Matches Home amount-accessory shared icons.
    func sharedSplitSystemImage(for userId: UUID?) -> String {
        if let userId, paidBy == userId {
            return "arrow.trianglehead.branch"
        }
        return "arrow.trianglehead.pull"
    }

    func shareRecord(for userId: UUID) -> ExpenseShareRecord? {
        shares.first(where: { $0.userId == userId })
    }

    func shareStatus(for userId: UUID) -> ExpenseShareStatus {
        shareRecord(for: userId)?.status ?? .accepted
    }

    func countsTowardSummary(for userId: UUID) -> Bool {
        shareRecord(for: userId)?.countsInSummary ?? false
    }

    func isPendingAcceptance(for userId: UUID) -> Bool {
        isShared && createdBy != userId && shareStatus(for: userId) == .pending
    }

    func acceptedShareMinor(for userId: UUID) -> Int {
        guard countsTowardSummary(for: userId) else { return 0 }
        return shareRecord(for: userId)?.amountMinor ?? 0
    }
}

struct CategorySpendSlice: Equatable, Sendable {
    var category: ExpenseCategory
    var amountMinor: Int
}

struct MonthSpendSummary: Sendable {
    var totalMine: Money
    var sharedShare: Money
    var categoryBreakdown: [CategorySpendSlice]

    static func zero(currency: String = "PLN") -> MonthSpendSummary {
        MonthSpendSummary(
            totalMine: Money(amountMinor: 0, currencyCode: currency),
            sharedShare: Money(amountMinor: 0, currencyCode: currency),
            categoryBreakdown: []
        )
    }
}
