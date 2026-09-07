import Foundation

enum SettlementMode: String, Codable, CaseIterable, Sendable {
    case shared
    case ledger

    var displayName: String {
        switch self {
        case .shared: return "Shared pot"
        case .ledger: return "Settle up"
        }
    }

    var detail: String {
        switch self {
        case .shared:
            return "One shared pot — no balances between people."
        case .ledger:
            return "Separate wallets — track who owes whom."
        }
    }
}
