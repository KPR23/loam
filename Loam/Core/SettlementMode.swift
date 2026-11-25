import Foundation

enum SettlementMode: String, Codable, CaseIterable, Sendable {
    case shared
    case ledger

    var displayName: String {
        switch self {
        case .shared: return String(localized: "Shared pot")
        case .ledger: return String(localized: "Settle up")
        }
    }

    var detail: String {
        switch self {
        case .shared:
            return String(localized: "One shared pot — no balances between people.")
        case .ledger:
            return String(localized: "Separate wallets — track who owes whom.")
        }
    }
}
