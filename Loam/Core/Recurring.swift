import Foundation

enum RecurringIntervalUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case week
    case month
    case year

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .week: return "Weekly"
        case .month: return "Monthly"
        case .year: return "Yearly"
        }
    }
}

struct RecurringRuleRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var ownerUserId: UUID
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var intervalUnit: RecurringIntervalUnit
    var intervalCount: Int
    var nextOccurrence: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        ownerUserId: UUID,
        amountMinor: Int,
        currency: String = "PLN",
        category: ExpenseCategory,
        title: String? = nil,
        note: String? = nil,
        intervalUnit: RecurringIntervalUnit,
        intervalCount: Int = 1,
        nextOccurrence: Date,
        isActive: Bool = true
    ) {
        self.id = id
        self.ownerUserId = ownerUserId
        self.amountMinor = amountMinor
        self.currency = currency
        self.category = category
        self.title = title
        self.note = note
        self.intervalUnit = intervalUnit
        self.intervalCount = intervalCount
        self.nextOccurrence = Calendar.current.startOfDay(for: nextOccurrence)
        self.isActive = isActive
    }

    func nextOccurrence(after date: Date) -> Date {
        let calendar = Calendar.current
        let component: Calendar.Component
        switch intervalUnit {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.date(
            byAdding: component,
            value: intervalCount,
            to: calendar.startOfDay(for: date)
        ) ?? date
    }
}

struct RecurringRuleInsertDTO: Encodable, Sendable {
    var id: UUID
    var ownerUserId: UUID
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var intervalUnit: String
    var intervalCount: Int
    var nextOccurrence: String
    var isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId = "owner_user_id"
        case amountMinor = "amount_minor"
        case currency
        case category
        case title
        case note
        case intervalUnit = "interval_unit"
        case intervalCount = "interval_count"
        case nextOccurrence = "next_occurrence"
        case isActive = "is_active"
    }

    init(from record: RecurringRuleRecord) {
        id = record.id
        ownerUserId = record.ownerUserId
        amountMinor = record.amountMinor
        currency = record.currency
        category = record.category
        title = record.title
        note = record.note
        intervalUnit = record.intervalUnit.rawValue
        intervalCount = record.intervalCount
        nextOccurrence = CalendarDateCodec.string(from: record.nextOccurrence)
        isActive = record.isActive
    }
}
