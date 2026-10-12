import Foundation

/// A signed pairwise balance. Positive means the other person owes the viewer.
struct PersonBalance: Identifiable, Codable, Hashable, Sendable {
    let personId: UUID
    let displayName: String
    let amountMinor: Int
    let currencyCode: String

    var id: String { "\(personId.uuidString)-\(currencyCode.uppercased())" }
    var money: Money { Money(amountMinor: abs(amountMinor), currencyCode: currencyCode) }
    var direction: String { amountMinor >= 0 ? "Owes you" : "You owe" }
}

/// What someone owes the viewer for expenses the viewer paid that they haven't accepted yet.
/// Balances leave it out until they accept.
struct AwaitingBalance: Identifiable, Codable, Hashable, Sendable {
    let personId: UUID
    let amountMinor: Int
    let currencyCode: String
    let expenseCount: Int

    var id: String { "\(personId.uuidString)-\(currencyCode.uppercased())" }
    var money: Money { Money(amountMinor: amountMinor, currencyCode: currencyCode) }
}

struct BalanceSnapshot: Codable, Hashable, Sendable {
    var balances: [PersonBalance]
    var awaiting: [AwaitingBalance] = []

    static let empty = BalanceSnapshot(balances: [])

    var owedToYou: [Money] { totals(where: { $0.amountMinor > 0 }, sign: 1) }
    var youOwe: [Money] { totals(where: { $0.amountMinor < 0 }, sign: -1) }

    var awaitingTotals: [Money] {
        Dictionary(grouping: awaiting, by: { $0.currencyCode.uppercased() })
            .map { currency, rows in Money(amountMinor: rows.reduce(0) { $0 + $1.amountMinor }, currencyCode: currency) }
            .sorted { $0.currencyCode < $1.currencyCode }
    }

    func awaiting(from personId: UUID) -> [AwaitingBalance] {
        awaiting.filter { $0.personId == personId }.sorted { $0.currencyCode < $1.currencyCode }
    }

    private func totals(where include: (PersonBalance) -> Bool, sign: Int) -> [Money] {
        Dictionary(grouping: balances.filter(include), by: { $0.currencyCode.uppercased() })
            .map { currency, balances in
                Money(
                    amountMinor: balances.reduce(0) { $0 + sign * $1.amountMinor },
                    currencyCode: currency
                )
            }
            .sorted { $0.currencyCode < $1.currencyCode }
    }
}

struct RepaymentRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fromUserId: UUID
    let toUserId: UUID
    let amountMinor: Int
    let currencyCode: String
    let note: String?
    let paidAt: Date
    let createdAt: Date
    let reversedAt: Date?

    var isReversed: Bool { reversedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, fromUserId, toUserId, amountMinor, currencyCode, note, paidAt, createdAt, reversedAt
    }

    init(id: UUID, fromUserId: UUID, toUserId: UUID, amountMinor: Int, currencyCode: String = "PLN", note: String?, paidAt: Date, createdAt: Date, reversedAt: Date?) {
        self.id = id
        self.fromUserId = fromUserId
        self.toUserId = toUserId
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.note = note
        self.paidAt = paidAt
        self.createdAt = createdAt
        self.reversedAt = reversedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fromUserId = try values.decode(UUID.self, forKey: .fromUserId)
        toUserId = try values.decode(UUID.self, forKey: .toUserId)
        amountMinor = try values.decode(Int.self, forKey: .amountMinor)
        currencyCode = try values.decodeIfPresent(String.self, forKey: .currencyCode) ?? "PLN"
        note = try values.decodeIfPresent(String.self, forKey: .note)
        paidAt = try values.decode(Date.self, forKey: .paidAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        reversedAt = try values.decodeIfPresent(Date.self, forKey: .reversedAt)
    }
}

struct BalanceHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case purchase, repayment, reversal }

    let id: UUID
    let kind: Kind
    let title: String
    /// Signed by its effect on the viewer: positive when the other person ends up owing more.
    let amountMinor: Int
    let occurredAt: Date
    let status: ExpenseShareStatus?
    /// The payer's answer on their own share; the balance counts a purchase only once both are accepted.
    let payerStatus: ExpenseShareStatus?
    /// Older servers omit these. A row without a currency shows its amount without one rather than a guess.
    let currencyCode: String?
    let categoryName: String?

    var category: ExpenseCategory? { categoryName.flatMap(ExpenseCategory.init(rawValue:)) }

    /// The server falls back to the raw category when an expense has no title.
    var displayTitle: String {
        if kind == .purchase, let category, title == category.rawValue { return category.displayName }
        return title
    }

    /// Where a purchase stands for the balance, combining both answers the way the server does.
    /// Older servers send no payer answer; the participant's answer is all there is then.
    var purchaseStatus: ExpenseShareStatus {
        let answers = [status ?? .accepted, payerStatus ?? .accepted]
        if answers.contains(.rejected) { return .rejected }
        if answers.contains(.pending) { return .pending }
        return .accepted
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, status
        case amountMinor = "amount_minor"
        case occurredAt = "occurred_at"
        case currencyCode = "currency"
        case categoryName = "category"
        case payerStatus = "payer_status"
    }

    init(id: UUID, kind: Kind, title: String, amountMinor: Int, occurredAt: Date, status: ExpenseShareStatus?, payerStatus: ExpenseShareStatus?, currencyCode: String?, categoryName: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.amountMinor = amountMinor
        self.occurredAt = occurredAt
        self.status = status
        self.payerStatus = payerStatus
        self.currencyCode = currencyCode
        self.categoryName = categoryName
    }
}
