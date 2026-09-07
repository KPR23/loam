import Foundation

enum ExpenseCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case groceries
    case dining
    case transport
    case housing
    case utilities
    case health
    case entertainment
    case shopping
    case travel
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groceries: return "Groceries"
        case .dining: return "Dining"
        case .transport: return "Transport"
        case .housing: return "Housing"
        case .utilities: return "Utilities"
        case .health: return "Health"
        case .entertainment: return "Entertainment"
        case .shopping: return "Shopping"
        case .travel: return "Travel"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .groceries: return "cart"
        case .dining: return "fork.knife"
        case .transport: return "bus"
        case .housing: return "house"
        case .utilities: return "bolt"
        case .health: return "heart"
        case .entertainment: return "ticket"
        case .shopping: return "bag"
        case .travel: return "airplane"
        case .other: return "ellipsis.circle"
        }
    }
}
