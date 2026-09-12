import Foundation

struct ExpenseEditProposal: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var expenseId: UUID
    var proposedBy: UUID
    var status: ExpenseProposalStatus
    var amountMinor: Int
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var spentAt: Date
    var paidBy: UUID
    var shares: [ExpenseShareRecord]
    var message: String?
    var createdAt: Date
    var respondedAt: Date?

    init(
        id: UUID = UUID(),
        expenseId: UUID,
        proposedBy: UUID,
        status: ExpenseProposalStatus = .pending,
        amountMinor: Int,
        category: ExpenseCategory,
        title: String? = nil,
        note: String? = nil,
        spentAt: Date,
        paidBy: UUID,
        shares: [ExpenseShareRecord],
        message: String? = nil,
        createdAt: Date = Date(),
        respondedAt: Date? = nil
    ) {
        self.id = id
        self.expenseId = expenseId
        self.proposedBy = proposedBy
        self.status = status
        self.amountMinor = amountMinor
        self.category = category
        self.title = title
        self.note = note
        self.spentAt = Calendar.current.startOfDay(for: spentAt)
        self.paidBy = paidBy
        self.shares = shares
        self.message = message
        self.createdAt = createdAt
        self.respondedAt = respondedAt
    }

    func toExpenseRecord(currency: String, householdId: UUID?, createdBy: UUID) -> ExpenseRecord {
        ExpenseRecord(
            id: expenseId,
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            title: title,
            note: note,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: createdBy,
            householdId: householdId,
            shares: shares
        )
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? category.displayName : trimmed
    }
}

struct ExpenseEditProposalDTO: Codable, Sendable {
    var id: UUID?
    var expenseId: UUID
    var proposedBy: UUID
    var status: ExpenseProposalStatus
    var amountMinor: Int
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var spentAt: String
    var paidBy: UUID
    var shares: [ProposalShareDTO]
    var message: String?
    var createdAt: Date?
    var respondedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case expenseId = "expense_id"
        case proposedBy = "proposed_by"
        case status
        case amountMinor = "amount_minor"
        case category
        case title
        case note
        case spentAt = "spent_at"
        case paidBy = "paid_by"
        case shares
        case message
        case createdAt = "created_at"
        case respondedAt = "responded_at"
    }

    func toRecord() -> ExpenseEditProposal? {
        guard let spent = CalendarDateCodec.date(from: spentAt) else { return nil }
        return ExpenseEditProposal(
            id: id ?? UUID(),
            expenseId: expenseId,
            proposedBy: proposedBy,
            status: status,
            amountMinor: amountMinor,
            category: category,
            title: title,
            note: note,
            spentAt: spent,
            paidBy: paidBy,
            shares: shares.map {
                ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor)
            },
            message: message,
            createdAt: createdAt ?? Date(),
            respondedAt: respondedAt
        )
    }
}

struct ProposalShareDTO: Codable, Sendable {
    var userId: UUID
    var amountMinor: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case amountMinor = "amount_minor"
    }
}
