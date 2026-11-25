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
        case .groceries: return String(localized: "Groceries")
        case .dining: return String(localized: "Dining")
        case .transport: return String(localized: "Transport")
        case .housing: return String(localized: "Housing")
        case .utilities: return String(localized: "Utilities")
        case .health: return String(localized: "Health")
        case .entertainment: return String(localized: "Entertainment")
        case .shopping: return String(localized: "Shopping")
        case .travel: return String(localized: "Travel")
        case .other: return String(localized: "Other")
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
        case .groceries: return "2DCB5A"
        case .dining: return "FF7A00"
        case .transport: return "1A8CFF"
        case .housing: return "3D47E0"
        case .utilities: return "FFC300"
        case .health: return "FF3355"
        case .entertainment: return "C644FC"
        case .shopping: return "FF4FC4"
        case .travel: return "10C9A6"
        case .other: return "8A8F9C"
        }
    }
}
