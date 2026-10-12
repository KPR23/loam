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
    var paidBy: UUID
    var shares: [ExpenseShareRecord]
    var version: Int?
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var customCategory: CustomCategory?
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
    /// Why the server last failed to generate a due occurrence; the rule stays
    /// due and is retried until the owner fixes or stops it.
    var generationFailure: String?

    init(
        id: UUID = UUID(),
        ownerUserId: UUID,
        paidBy: UUID? = nil,
        shares: [ExpenseShareRecord]? = nil,
        version: Int = 1,
        amountMinor: Int,
        currency: String = "PLN",
        category: ExpenseCategory,
        customCategory: CustomCategory? = nil,
        title: String? = nil,
        note: String? = nil,
        location: ExpenseLocation? = nil,
        intervalUnit: RecurringIntervalUnit,
        intervalCount: Int = 1,
        startDate: Date,
        endDate: Date? = nil,
        nextOccurrence: Date? = nil,
        skippedDates: [Date] = [],
        isActive: Bool = true,
        generationFailure: String? = nil
    ) {
        let calendar = AppPreferences.calendar
        self.id = id
        self.ownerUserId = ownerUserId
        self.paidBy = paidBy ?? ownerUserId
        self.shares = shares ?? [ExpenseShareRecord(userId: ownerUserId, amountMinor: amountMinor)]
        self.version = version
        self.amountMinor = amountMinor
        self.currency = currency
        self.category = customCategory == nil ? category : .other
        self.customCategory = customCategory
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
        self.generationFailure = generationFailure
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? (customCategory?.name ?? category.displayName) : trimmed
    }

    /// Rules saved before the payer and split lived on the rule took them,
    /// with the rest of the template, from their latest occurrence.
    mutating func adoptTemplate(_ expense: ExpenseRecord) {
        amountMinor = expense.amountMinor
        currency = expense.currency
        category = expense.category
        customCategory = expense.customCategory
        title = expense.title
        note = expense.note
        location = expense.location
        paidBy = expense.paidBy
        shares = expense.shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) }
    }

    func isSkipped(_ date: Date, calendar: Calendar = AppPreferences.calendar) -> Bool {
        skippedDates.contains { calendar.isDate($0, inSameDayAs: date) }
    }

    mutating func skipOccurrence(on date: Date, calendar: Calendar = AppPreferences.calendar) {
        let day = calendar.startOfDay(for: date)
        guard !isSkipped(day, calendar: calendar) else { return }
        skippedDates.append(day)
    }

    var hasEnded: Bool {
        let calendar = AppPreferences.calendar
        return !isActive || (endDate.map { calendar.startOfDay(for: $0) < calendar.startOfDay(for: Date()) } ?? false)
    }

    var endDateDisplay: String {
        guard let endDate else { return "Never" }
        return endDate.formatted(date: .abbreviated, time: .omitted)
    }

    /// First scheduled date strictly after `date`.
    func nextOccurrence(after date: Date, calendar: Calendar = AppPreferences.calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        return occurrence(onOrAfter: calendar.date(byAdding: .day, value: 1, to: day) ?? day, calendar: calendar)
    }

    /// First scheduled date on or after `date`. Every occurrence is `startDate`
    /// plus whole intervals, so month-end rules stay on the last day
    /// (Jan 31 → Feb 28 → Mar 31) instead of drifting. Matches the server.
    func occurrence(onOrAfter date: Date, calendar: Calendar = AppPreferences.calendar) -> Date {
        let component: Calendar.Component
        switch intervalUnit {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        let step = max(1, intervalCount)
        let start = calendar.startOfDay(for: startDate)
        let day = calendar.startOfDay(for: date)
        guard day > start else { return start }

        func scheduled(_ index: Int) -> Date {
            calendar.date(byAdding: component, value: index * step, to: start) ?? start
        }
        // Estimate the index from the elapsed span, then step to the exact one.
        let elapsed = calendar.dateComponents([component], from: start, to: day).value(for: component) ?? 0
        var index = max(0, elapsed / step - 1)
        while scheduled(index) < day { index += 1 }
        return scheduled(index)
    }

    var scheduleDescription: String {
        intervalUnit.scheduleDescription(intervalCount: intervalCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId
        case paidBy, shares, version
        case amountMinor
        case currency
        case category
        case customCategory
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
        case generationFailure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        ownerUserId = try container.decode(UUID.self, forKey: .ownerUserId)
        amountMinor = try container.decode(Int.self, forKey: .amountMinor)
        paidBy = try container.decodeIfPresent(UUID.self, forKey: .paidBy) ?? ownerUserId
        shares = try container.decodeIfPresent([ExpenseShareRecord].self, forKey: .shares) ?? [ExpenseShareRecord(userId: ownerUserId, amountMinor: amountMinor)]
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        currency = try container.decode(String.self, forKey: .currency)
        category = try container.decode(ExpenseCategory.self, forKey: .category)
        customCategory = try container.decodeIfPresent(CustomCategory.self, forKey: .customCategory)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        location = try container.decodeIfPresent(ExpenseLocation.self, forKey: .location)
        intervalUnit = try container.decode(RecurringIntervalUnit.self, forKey: .intervalUnit)
        intervalCount = try container.decode(Int.self, forKey: .intervalCount)
        let decodedNext = try container.decode(Date.self, forKey: .nextOccurrence)
        let calendar = AppPreferences.calendar
        nextOccurrence = calendar.startOfDay(for: decodedNext)
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
            .map { calendar.startOfDay(for: $0) } ?? nextOccurrence
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
            .map { calendar.startOfDay(for: $0) }
        skippedDates = (try container.decodeIfPresent([Date].self, forKey: .skippedDates) ?? [])
            .map { calendar.startOfDay(for: $0) }
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        generationFailure = try container.decodeIfPresent(String.self, forKey: .generationFailure)
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
        calendar: Calendar = AppPreferences.calendar
    ) -> [Date] {
        guard rule.isActive else { return [] }

        let through = calendar.startOfDay(for: throughDate)
        // A next occurrence stored by older drifting logic snaps to the schedule.
        var cursor = rule.occurrence(onOrAfter: rule.nextOccurrence, calendar: calendar)
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

    /// Builds an occurrence using the authoritative rule, including its payer and split.
    static func occurrenceExpense(
        rule: RecurringRuleRecord,
        spentAt: Date
    ) -> ExpenseRecord {
        // Past occurrences never serve as mutable templates for future ones.
        let amountMinor = rule.amountMinor
        let currency = rule.currency
        let category = rule.category
        let title = rule.title
        let note = rule.note
        let location = rule.location
        let paidBy = rule.paidBy
        let createdBy = rule.ownerUserId
        let shares = rule.shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) }

        return ExpenseRecord(
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            customCategory: rule.customCategory,
            title: title,
            note: note,
            location: location,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: createdBy,
            recurringId: rule.id,
            shares: shares
        )
    }
}

struct RecurringRuleInsertDTO: Encodable, Sendable {
    var id: UUID
    var ownerUserId: UUID
    var paidBy: UUID
    var shares: [ProposalShareDTO]
    var version: Int?
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
    var customCategoryId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId = "owner_user_id"
        case paidBy = "paid_by"
        case shares, version
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
        case customCategoryId = "custom_category_id"
    }

    /// Like the synthesized encoding, but `custom_category_id` is always sent, as null
    /// when there is none: the server keeps the current one only when the key is missing.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ownerUserId, forKey: .ownerUserId)
        try container.encode(paidBy, forKey: .paidBy)
        try container.encode(shares, forKey: .shares)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(amountMinor, forKey: .amountMinor)
        try container.encode(currency, forKey: .currency)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encode(intervalUnit, forKey: .intervalUnit)
        try container.encode(intervalCount, forKey: .intervalCount)
        try container.encode(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(nextOccurrence, forKey: .nextOccurrence)
        try container.encode(skippedDates, forKey: .skippedDates)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(customCategoryId, forKey: .customCategoryId)
    }

    init(from record: RecurringRuleRecord) {
        id = record.id
        ownerUserId = record.ownerUserId
        paidBy = record.paidBy
        shares = record.shares.map { ProposalShareDTO(userId: $0.userId, amountMinor: $0.amountMinor) }
        version = record.version
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
        customCategoryId = record.customCategory?.id
    }
}

struct RecurringRuleDTO: Decodable, Sendable {
    var id: UUID
    var ownerUserId: UUID
    var paidBy: UUID
    var shares: [ProposalShareDTO]
    var version: Int?
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
    var failure: String?
    var customCategory: CustomCategory?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId = "owner_user_id"
        case paidBy = "paid_by"
        case shares, version
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
        case failure
        case customCategory = "custom_category"
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
            paidBy: paidBy,
            shares: shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) },
            version: version ?? 1,
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            customCategory: customCategory,
            title: title,
            note: note,
            location: location,
            intervalUnit: unit,
            intervalCount: intervalCount,
            startDate: parsedStart,
            endDate: endDate.flatMap { CalendarDateCodec.date(from: $0) },
            nextOccurrence: next,
            skippedDates: parsedSkipped,
            isActive: isActive,
            generationFailure: failure
        )
    }
}

enum RecurringDeletionMode: Sendable {
    /// Remove this occurrence only; future repeats continue.
    case occurrenceOnly
    /// Remove this occurrence and stop the recurring rule.
    case stopRecurring
}
