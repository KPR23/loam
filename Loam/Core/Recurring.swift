import Foundation

enum RecurringIntervalUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .day: return "Daily"
        case .week: return "Weekly"
        case .month: return "Monthly"
        case .year: return "Yearly"
        }
    }

    var singularName: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        }
    }

    var pluralName: String {
        switch self {
        case .day: return "days"
        case .week: return "weeks"
        case .month: return "months"
        case .year: return "years"
        }
    }

    func scheduleDescription(intervalCount: Int) -> String {
        let count = max(1, intervalCount)
        if count == 1 {
            return displayName
        }
        return "Every \(count) \(pluralName)"
    }
}

/// Presets shown in the add-expense repeat picker; maps to unit + count.
enum RecurringPreset: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case biweekly
    case monthly
    case quarterly
    case yearly
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Every 3 months"
        case .yearly: return "Yearly"
        case .custom: return "Custom"
        }
    }

    var interval: (unit: RecurringIntervalUnit, count: Int)? {
        switch self {
        case .daily: return (.day, 1)
        case .weekly: return (.week, 1)
        case .biweekly: return (.week, 2)
        case .monthly: return (.month, 1)
        case .quarterly: return (.month, 3)
        case .yearly: return (.year, 1)
        case .custom: return nil
        }
    }

    static func matching(unit: RecurringIntervalUnit, count: Int) -> RecurringPreset {
        for preset in allCases where preset != .custom {
            if let interval = preset.interval, interval.unit == unit, interval.count == count {
                return preset
            }
        }
        return .custom
    }
}

struct RecurringRuleRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var ownerUserId: UUID
    var householdId: UUID?
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var location: ExpenseLocation?
    var intervalUnit: RecurringIntervalUnit
    var intervalCount: Int
    var startDate: Date
    var endDate: Date?
    var nextOccurrence: Date
    var skippedDates: [Date]
    var isActive: Bool

    init(
        id: UUID = UUID(),
        ownerUserId: UUID,
        householdId: UUID? = nil,
        amountMinor: Int,
        currency: String = "PLN",
        category: ExpenseCategory,
        title: String? = nil,
        note: String? = nil,
        location: ExpenseLocation? = nil,
        intervalUnit: RecurringIntervalUnit,
        intervalCount: Int = 1,
        startDate: Date,
        endDate: Date? = nil,
        nextOccurrence: Date? = nil,
        skippedDates: [Date] = [],
        isActive: Bool = true
    ) {
        let calendar = AppPreferences.calendar
        self.id = id
        self.ownerUserId = ownerUserId
        self.householdId = householdId
        self.amountMinor = amountMinor
        self.currency = currency
        self.category = category
        self.title = title
        self.note = note
        self.location = location
        self.intervalUnit = intervalUnit
        self.intervalCount = intervalCount
        self.startDate = calendar.startOfDay(for: startDate)
        self.endDate = endDate.map { calendar.startOfDay(for: $0) }
        self.nextOccurrence = calendar.startOfDay(for: nextOccurrence ?? startDate)
        self.skippedDates = skippedDates.map { calendar.startOfDay(for: $0) }
        self.isActive = isActive
    }

    func isSkipped(_ date: Date, calendar: Calendar = .current) -> Bool {
        skippedDates.contains { calendar.isDate($0, inSameDayAs: date) }
    }

    mutating func skipOccurrence(on date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        guard !isSkipped(day, calendar: calendar) else { return }
        skippedDates.append(day)
    }

    var hasEnded: Bool {
        !isActive || (endDate.map { Calendar.current.startOfDay(for: $0) < Calendar.current.startOfDay(for: Date()) } ?? false)
    }

    var endDateDisplay: String {
        guard let endDate else { return "Never" }
        return endDate.formatted(date: .abbreviated, time: .omitted)
    }

    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date {
        let component: Calendar.Component
        switch intervalUnit {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.date(
            byAdding: component,
            value: max(1, intervalCount),
            to: calendar.startOfDay(for: date)
        ) ?? date
    }

    var scheduleDescription: String {
        intervalUnit.scheduleDescription(intervalCount: intervalCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId
        case householdId
        case amountMinor
        case currency
        case category
        case title
        case note
        case location
        case intervalUnit
        case intervalCount
        case startDate
        case endDate
        case nextOccurrence
        case skippedDates
        case isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        ownerUserId = try container.decode(UUID.self, forKey: .ownerUserId)
        householdId = try container.decodeIfPresent(UUID.self, forKey: .householdId)
        amountMinor = try container.decode(Int.self, forKey: .amountMinor)
        currency = try container.decode(String.self, forKey: .currency)
        category = try container.decode(ExpenseCategory.self, forKey: .category)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        location = try container.decodeIfPresent(ExpenseLocation.self, forKey: .location)
        intervalUnit = try container.decode(RecurringIntervalUnit.self, forKey: .intervalUnit)
        intervalCount = try container.decode(Int.self, forKey: .intervalCount)
        let decodedNext = try container.decode(Date.self, forKey: .nextOccurrence)
        nextOccurrence = Calendar.current.startOfDay(for: decodedNext)
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
            .map { Calendar.current.startOfDay(for: $0) } ?? nextOccurrence
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
            .map { Calendar.current.startOfDay(for: $0) }
        skippedDates = (try container.decodeIfPresent([Date].self, forKey: .skippedDates) ?? [])
            .map { Calendar.current.startOfDay(for: $0) }
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

/// Pure helpers for expanding a recurring rule into concrete calendar dates.
enum RecurringMaterializer {
    /// Safety cap so a bad rule cannot flood storage in one pass.
    static let maxOccurrencesPerPass = 400

    /// Due occurrence dates from `rule.nextOccurrence` through `throughDate` (inclusive).
    static func dueDates(
        for rule: RecurringRuleRecord,
        through throughDate: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        guard rule.isActive else { return [] }

        let through = calendar.startOfDay(for: throughDate)
        var cursor = calendar.startOfDay(for: rule.nextOccurrence)
        guard cursor <= through else { return [] }

        var dates: [Date] = []
        dates.reserveCapacity(min(32, maxOccurrencesPerPass))

        let endDay = rule.endDate.map { calendar.startOfDay(for: $0) }

        while cursor <= through, dates.count < maxOccurrencesPerPass {
            if let endDay, cursor > endDay { break }
            if !rule.isSkipped(cursor, calendar: calendar) {
                dates.append(cursor)
            }
            let next = rule.nextOccurrence(after: cursor, calendar: calendar)
            if next <= cursor { break }
            cursor = next
        }
        return dates
    }

    /// Builds a new expense for `spentAt`, copying split structure from `template` when present.
    static func occurrenceExpense(
        rule: RecurringRuleRecord,
        spentAt: Date,
        template: ExpenseRecord?
    ) -> ExpenseRecord {
        let amountMinor = template?.amountMinor ?? rule.amountMinor
        let currency = template?.currency ?? rule.currency
        let category = template?.category ?? rule.category
        let title = template?.title ?? rule.title
        let note = template?.note ?? rule.note
        let location = template?.location ?? rule.location
        let paidBy = template?.paidBy ?? rule.ownerUserId
        let createdBy = template?.createdBy ?? rule.ownerUserId
        let householdId = template?.householdId ?? rule.householdId

        // Acceptance/trust is applied by ExpenseStore when materializing.
        let shares: [ExpenseShareRecord]
        if let template, !template.shares.isEmpty {
            shares = template.shares.map { share in
                ExpenseShareRecord(
                    userId: share.userId,
                    amountMinor: share.amountMinor
                )
            }
        } else {
            shares = [
                ExpenseShareRecord(userId: rule.ownerUserId, amountMinor: amountMinor)
            ]
        }

        return ExpenseRecord(
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            title: title,
            note: note,
            location: location,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: createdBy,
            householdId: householdId,
            recurringId: rule.id,
            shares: shares
        )
    }
}

struct RecurringRuleInsertDTO: Encodable, Sendable {
    var id: UUID
    var ownerUserId: UUID
    var householdId: UUID?
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var location: ExpenseLocation?
    var intervalUnit: String
    var intervalCount: Int
    var startDate: String
    var endDate: String?
    var nextOccurrence: String
    var skippedDates: [String]
    var isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId = "owner_user_id"
        case householdId = "household_id"
        case amountMinor = "amount_minor"
        case currency
        case category
        case title
        case note
        case location
        case intervalUnit = "interval_unit"
        case intervalCount = "interval_count"
        case startDate = "start_date"
        case endDate = "end_date"
        case nextOccurrence = "next_occurrence"
        case skippedDates = "skipped_dates"
        case isActive = "is_active"
    }

    init(from record: RecurringRuleRecord) {
        id = record.id
        ownerUserId = record.ownerUserId
        householdId = record.householdId
        amountMinor = record.amountMinor
        currency = record.currency
        category = record.category
        title = record.title
        note = record.note
        location = record.location
        intervalUnit = record.intervalUnit.rawValue
        intervalCount = record.intervalCount
        startDate = CalendarDateCodec.string(from: record.startDate)
        endDate = record.endDate.map { CalendarDateCodec.string(from: $0) }
        nextOccurrence = CalendarDateCodec.string(from: record.nextOccurrence)
        skippedDates = record.skippedDates.map { CalendarDateCodec.string(from: $0) }
        isActive = record.isActive
    }
}

struct RecurringRuleDTO: Decodable, Sendable {
    var id: UUID
    var ownerUserId: UUID
    var householdId: UUID?
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var location: ExpenseLocation?
    var intervalUnit: String
    var intervalCount: Int
    var startDate: String?
    var endDate: String?
    var nextOccurrence: String
    var skippedDates: [String]?
    var isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId = "owner_user_id"
        case householdId = "household_id"
        case amountMinor = "amount_minor"
        case currency
        case category
        case title
        case note
        case location
        case intervalUnit = "interval_unit"
        case intervalCount = "interval_count"
        case startDate = "start_date"
        case endDate = "end_date"
        case nextOccurrence = "next_occurrence"
        case skippedDates = "skipped_dates"
        case isActive = "is_active"
    }

    func toRecord() -> RecurringRuleRecord? {
        guard let unit = RecurringIntervalUnit(rawValue: intervalUnit),
              let next = CalendarDateCodec.date(from: nextOccurrence)
        else { return nil }
        let parsedStart = startDate.flatMap { CalendarDateCodec.date(from: $0) } ?? next
        let parsedSkipped = (skippedDates ?? []).compactMap { CalendarDateCodec.date(from: $0) }
        return RecurringRuleRecord(
            id: id,
            ownerUserId: ownerUserId,
            householdId: householdId,
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            title: title,
            note: note,
            location: location,
            intervalUnit: unit,
            intervalCount: intervalCount,
            startDate: parsedStart,
            endDate: endDate.flatMap { CalendarDateCodec.date(from: $0) },
            nextOccurrence: next,
            skippedDates: parsedSkipped,
            isActive: isActive
        )
    }
}

struct RecurringRuleUpdateDTO: Encodable, Sendable {
    var nextOccurrence: String
    var endDate: String?
    var skippedDates: [String]
    var isActive: Bool
    var householdId: UUID?

    enum CodingKeys: String, CodingKey {
        case nextOccurrence = "next_occurrence"
        case endDate = "end_date"
        case skippedDates = "skipped_dates"
        case isActive = "is_active"
        case householdId = "household_id"
    }

    init(from record: RecurringRuleRecord) {
        nextOccurrence = CalendarDateCodec.string(from: record.nextOccurrence)
        endDate = record.endDate.map { CalendarDateCodec.string(from: $0) }
        skippedDates = record.skippedDates.map { CalendarDateCodec.string(from: $0) }
        isActive = record.isActive
        householdId = record.householdId
    }
}

enum RecurringDeletionMode: Sendable {
    /// Remove this occurrence only; future repeats continue.
    case occurrenceOnly
    /// Remove this occurrence and stop the recurring rule.
    case stopRecurring
}
