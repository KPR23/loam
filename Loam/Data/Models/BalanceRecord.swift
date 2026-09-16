import Foundation

/// A signed pairwise balance. Positive means the other person owes the viewer.
struct PersonBalance: Identifiable, Codable, Hashable, Sendable {
    let personId: UUID
    let displayName: String
    let amountMinor: Int

    var id: UUID { personId }
    var money: Money { Money(amountMinor: abs(amountMinor), currencyCode: "PLN") }
    var direction: String { amountMinor >= 0 ? "Owes you" : "You owe" }
}

struct BalanceSnapshot: Codable, Hashable, Sendable {
    var balances: [PersonBalance]

    static let empty = BalanceSnapshot(balances: [])

    var owedToYouMinor: Int { balances.reduce(0) { $0 + max(0, $1.amountMinor) } }
    var youOweMinor: Int { balances.reduce(0) { $0 + max(0, -$1.amountMinor) } }
}

struct RepaymentRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fromUserId: UUID
    let toUserId: UUID
    let amountMinor: Int
    let note: String?
    let paidAt: Date
    let createdAt: Date
    let reversedAt: Date?

    var isReversed: Bool { reversedAt != nil }
}

struct BalanceHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case purchase, repayment, reversal }

    let id: UUID
    let kind: Kind
    let title: String
    let amountMinor: Int
    let occurredAt: Date
    let status: ExpenseShareStatus?
}
