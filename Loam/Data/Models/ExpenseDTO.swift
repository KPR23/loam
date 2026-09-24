import Foundation

/// Wire models for PostgREST (`snake_case`, `spent_at` as `yyyy-MM-dd`).
struct ExpenseShareDTO: Codable, Sendable, Hashable {
    var id: UUID?
    var expenseId: UUID?
    var userId: UUID
    var amountMinor: Int
    var status: ExpenseShareStatus?
    var respondedAt: Date?
    var acceptedViaTrust: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case expenseId = "expense_id"
        case userId = "user_id"
        case amountMinor = "amount_minor"
        case status
        case respondedAt = "responded_at"
        case acceptedViaTrust = "accepted_via_trust"
    }

    func toRecord() -> ExpenseShareRecord {
        ExpenseShareRecord(
            id: id ?? UUID(),
            userId: userId,
            amountMinor: amountMinor,
            status: status ?? .accepted,
            respondedAt: respondedAt,
            acceptedViaTrust: acceptedViaTrust ?? false
        )
    }
}

struct ExpenseDTO: Codable, Sendable, Hashable {
    var id: UUID?
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var location: ExpenseLocation?
    var spentAt: String
    var paidBy: UUID
    var createdBy: UUID
    var version: Int?
    var recurringId: UUID?
    var createdAt: Date?
    var updatedAt: Date?
    var expenseShare: [ExpenseShareDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case amountMinor = "amount_minor"
        case currency
        case category
        case title
        case note
        case location
        case spentAt = "spent_at"
        case paidBy = "paid_by"
        case createdBy = "created_by"
        case recurringId = "recurring_id"
        case version
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
            title: title,
            note: note,
            location: location,
            spentAt: spent,
            paidBy: paidBy,
            createdBy: createdBy,
            version: version ?? 1,
            recurringId: recurringId,
            shares: shares,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date()
        )
    }

}

/// Complete transaction payload. Consent fields are assigned by the server.
struct ExpenseInsertDTO: Encodable, Sendable {
    var id: UUID
    var amountMinor: Int
    var currency: String
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var location: ExpenseLocation?
    var spentAt: String
    var paidBy: UUID
    var recurringId: UUID?
    var shares: [ProposalShareDTO]
    enum CodingKeys: String, CodingKey {
        case id, currency, category, title, note, location, shares
        case amountMinor = "amount_minor", spentAt = "spent_at", paidBy = "paid_by", recurringId = "recurring_id"
    }
    init(from record: ExpenseRecord) {
        id = record.id; amountMinor = record.amountMinor; currency = record.currency
        category = record.category; title = record.title; note = record.note; location = record.location
        spentAt = CalendarDateCodec.string(from: record.spentAt); paidBy = record.paidBy; recurringId = record.recurringId
        shares = record.shares.map { ProposalShareDTO(userId: $0.userId, amountMinor: $0.amountMinor) }
    }
}
