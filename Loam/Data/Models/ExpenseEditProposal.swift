import Foundation

struct ExpenseEditProposal: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var expenseId: UUID
    var baseVersion: Int?
    var proposedBy: UUID
    var status: ExpenseProposalStatus
    var amountMinor: Int
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var location: ExpenseLocation?
    var spentAt: Date
    var paidBy: UUID
    var shares: [ExpenseShareRecord]
    var message: String?
    var createdAt: Date
    var respondedAt: Date?
    /// Moves the expense out of its custom category into Other. `category` alone can't say
    /// so: `.other` also means keeping the custom category. Optional so older saved proposals decode.
    var clearsCustomCategory: Bool?

    init(
        id: UUID = UUID(),
        expenseId: UUID,
        proposedBy: UUID,
        baseVersion: Int = 1,
        status: ExpenseProposalStatus = .pending,
        amountMinor: Int,
        category: ExpenseCategory,
        title: String? = nil,
        note: String? = nil,
        location: ExpenseLocation? = nil,
        spentAt: Date,
        paidBy: UUID,
        shares: [ExpenseShareRecord],
        message: String? = nil,
        createdAt: Date = Date(),
        respondedAt: Date? = nil,
        clearsCustomCategory: Bool = false
    ) {
        self.id = id
        self.expenseId = expenseId
        self.proposedBy = proposedBy
        self.baseVersion = baseVersion
        self.status = status
        self.amountMinor = amountMinor
        self.category = category
        self.title = title
        self.note = note
        self.location = location
        self.spentAt = AppPreferences.calendar.startOfDay(for: spentAt)
        self.paidBy = paidBy
        self.shares = shares
        self.message = message
        self.createdAt = createdAt
        self.respondedAt = respondedAt
        self.clearsCustomCategory = clearsCustomCategory
    }

    /// Whether accepting it changes the expense's category.
    func changesCategory(of expense: ExpenseRecord) -> Bool {
        expense.category != category || (clearsCustomCategory == true && expense.customCategory != nil)
    }

    func toExpenseRecord(currency: String, createdBy: UUID) -> ExpenseRecord {
        ExpenseRecord(
            id: expenseId,
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            title: title,
            note: note,
            location: location,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: createdBy,
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
    var baseVersion: Int?
    var proposedBy: UUID
    var status: ExpenseProposalStatus
    var amountMinor: Int
    var category: ExpenseCategory
    var title: String?
    var note: String?
    var location: ExpenseLocation?
    var spentAt: String
    var paidBy: UUID
    var shares: [ProposalShareDTO]
    var message: String?
    var createdAt: Date?
    var respondedAt: Date?
    var clearsCustomCategory: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case expenseId = "expense_id"
        case baseVersion = "base_version"
        case proposedBy = "proposed_by"
        case status
        case amountMinor = "amount_minor"
        case category
        case title
        case note
        case location
        case spentAt = "spent_at"
        case paidBy = "paid_by"
        case shares
        case message
        case createdAt = "created_at"
        case respondedAt = "responded_at"
        case clearsCustomCategory = "clears_custom_category"
    }

    func toRecord() -> ExpenseEditProposal? {
        guard let spent = CalendarDateCodec.date(from: spentAt) else { return nil }
        return ExpenseEditProposal(
            id: id ?? UUID(),
            expenseId: expenseId,
            proposedBy: proposedBy,
            baseVersion: baseVersion ?? 1,
            status: status,
            amountMinor: amountMinor,
            category: category,
            title: title,
            note: note,
            location: location,
            spentAt: spent,
            paidBy: paidBy,
            shares: shares.map {
                ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor)
            },
            message: message,
            createdAt: createdAt ?? Date(),
            respondedAt: respondedAt,
            clearsCustomCategory: clearsCustomCategory ?? false
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
