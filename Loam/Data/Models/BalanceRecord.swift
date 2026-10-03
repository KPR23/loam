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

struct BalanceSnapshot: Codable, Hashable, Sendable {
    var balances: [PersonBalance]

    static let empty = BalanceSnapshot(balances: [])

    var owedToYou: [Money] { totals(where: { $0.amountMinor > 0 }, sign: 1) }
    var youOwe: [Money] { totals(where: { $0.amountMinor < 0 }, sign: -1) }

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
    let amountMinor: Int
    let occurredAt: Date
    let status: ExpenseShareStatus?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, status
        case amountMinor = "amount_minor"
        case occurredAt = "occurred_at"
    }
}
