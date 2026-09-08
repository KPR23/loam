import Foundation

/// Wire models for PostgREST (`snake_case`, `spent_at` as `yyyy-MM-dd`).
struct ExpenseShareDTO: Codable, Sendable, Hashable {
    var id: UUID?
    var expenseId: UUID?
    var userId: UUID
    var amountMinor: Int

    enum CodingKeys: String, CodingKey {
        case id
        case expenseId = "expense_id"
        case userId = "user_id"
        case amountMinor = "amount_minor"
    }

    func toRecord() -> ExpenseShareRecord {
        ExpenseShareRecord(
            id: id ?? UUID(),
            userId: userId,
            amountMinor: amountMinor
        )
    }
}

struct ExpenseDTO: Codable, Sendable, Hashable {
    var id: UUID?
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var note: String?
    var spentAt: String
    var paidBy: UUID
    var createdBy: UUID
    var householdId: UUID?
    var recurringId: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var expenseShare: [ExpenseShareDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case amountMinor = "amount_minor"
        case currency
        case category
        case note
        case spentAt = "spent_at"
        case paidBy = "paid_by"
        case createdBy = "created_by"
        case householdId = "household_id"
        case recurringId = "recurring_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expenseShare = "expense_share"
    }

    func toRecord() -> ExpenseRecord? {
        guard let spent = CalendarDateCodec.date(from: spentAt) else { return nil }
        let shares = (expenseShare ?? []).map { $0.toRecord() }
        return ExpenseRecord(
            id: id ?? UUID(),
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            note: note,
            spentAt: spent,
            paidBy: paidBy,
            createdBy: createdBy,
            householdId: householdId,
            recurringId: recurringId,
            shares: shares,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date()
        )
    }

}

/// Insert body without timestamps (DB defaults). Shares are inserted separately —
/// PostgREST nested inserts treat `expense_share` as a missing column when the
/// relationship isn't writable in the schema cache.
struct ExpenseInsertDTO: Encodable, Sendable {
    var id: UUID
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var note: String?
    var spentAt: String
    var paidBy: UUID
    var createdBy: UUID
    var householdId: UUID?
    var recurringId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case amountMinor = "amount_minor"
        case currency
        case category
        case note
        case spentAt = "spent_at"
        case paidBy = "paid_by"
        case createdBy = "created_by"
        case householdId = "household_id"
        case recurringId = "recurring_id"
    }

    init(from record: ExpenseRecord) {
        id = record.id
        amountMinor = record.amountMinor
        currency = record.currency
        category = record.category
        note = record.note
        spentAt = CalendarDateCodec.string(from: record.spentAt)
        paidBy = record.paidBy
        createdBy = record.createdBy
        householdId = record.householdId
        recurringId = record.recurringId
    }
}

struct ExpenseShareInsertDTO: Encodable, Sendable {
    var id: UUID
    var expenseId: UUID
    var userId: UUID
    var amountMinor: Int

    enum CodingKeys: String, CodingKey {
        case id
        case expenseId = "expense_id"
        case userId = "user_id"
        case amountMinor = "amount_minor"
    }
}

struct ExpenseUpdateDTO: Encodable, Sendable {
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var note: String?
    var spentAt: String
    var paidBy: UUID
    var householdId: UUID?
    var recurringId: UUID?
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency
        case category
        case note
        case spentAt = "spent_at"
        case paidBy = "paid_by"
        case householdId = "household_id"
        case recurringId = "recurring_id"
        case updatedAt = "updated_at"
    }

    init(from record: ExpenseRecord) {
        amountMinor = record.amountMinor
        currency = record.currency
        category = record.category
        note = record.note
        spentAt = CalendarDateCodec.string(from: record.spentAt)
        paidBy = record.paidBy
        householdId = record.householdId
        recurringId = record.recurringId
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        updatedAt = iso.string(from: Date())
    }
}
