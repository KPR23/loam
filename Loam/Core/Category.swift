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

    /// Shown name, icon and color: the member's customization when Pro is active, else the built-in one.
    var displayName: String {
        CategoryCustomizer.shared.appliedStyle(for: self)?.name ?? defaultDisplayName
    }

    var systemImage: String {
        CategoryCustomizer.shared.appliedStyle(for: self)?.symbol ?? defaultSystemImage
    }

    var color: Color {
        CategoryCustomizer.shared.appliedStyle(for: self)?.colorHex.flatMap(Color.init(hex:)) ?? defaultColor
    }

    var defaultDisplayName: String {
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

    var defaultSystemImage: String {
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

    var defaultColor: Color {
        Color(hex: defaultColorHex) ?? .gray
    }

    /// Built-in colors as hex; `CategoryStyleOptions.colors` offers the same set in the editor.
    var defaultColorHex: String {
        switch self {
        case .groceries: return "33C571"
        case .dining: return "FF7303"
        case .transport: return "219FFB"
        case .housing: return "5D6BFF"
        case .utilities: return "FFB300"
        case .health: return "FF4D5E"
        case .entertainment: return "9768FE"
        case .shopping: return "FF5CAD"
        case .travel: return "14C4C4"
        case .other: return "98A2B3"
        }
    }
}
