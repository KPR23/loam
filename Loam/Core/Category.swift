import Foundation
import SwiftUI

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
        case .groceries: return "cart.fill"
        case .dining: return "fork.knife.circle.fill"
        case .transport: return "bus.fill"
        case .housing: return "house.fill"
        case .utilities: return "bolt.fill"
        case .health: return "heart.fill"
        case .entertainment: return "ticket.fill"
        case .shopping: return "bag.fill"
        case .travel: return "airplane.circle.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .groceries: return Color(red: 102 / 255, green: 194 / 255, blue: 64 / 255)
        case .dining: return Color(red: 0.96, green: 0.40, blue: 0.32)
        case .transport: return Color(red: 0.15, green: 0.50, blue: 0.98)
        case .housing: return Color(red: 0.88, green: 0.45, blue: 0.18)
        case .utilities: return Color(red: 0.96, green: 0.68, blue: 0.18)
        case .health: return Color(red: 0.96, green: 0.22, blue: 0.34)
        case .entertainment: return Color(red: 0.68, green: 0.24, blue: 0.96)
        case .shopping: return Color(red: 0.98, green: 0.24, blue: 0.58)
        case .travel: return Color(red: 0.12, green: 0.78, blue: 0.88)
        case .other: return Color(red: 0.42, green: 0.38, blue: 0.98)
        }
    }
}
