import Foundation

enum ExpenseShareStatus: String, Codable, Hashable, Sendable {
    case pending
    case accepted
    case rejected

    var isCountedInSummary: Bool {
        self == .accepted
    }
}

enum ExpenseShareResponseAction: String, Codable, Sendable {
    case accept
    case reject
    case acceptWithTrust = "accept_with_trust"
}

enum ExpenseProposalStatus: String, Codable, Hashable, Sendable {
    case pending
    case accepted
    case rejected
    case withdrawn
}
