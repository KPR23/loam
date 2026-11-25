import Foundation

enum SplitExpenseMode: String, CaseIterable, Identifiable, Sendable {
    case equal
    case percentage
    case exactAmount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .equal: String(localized: "Split equally")
        case .percentage: String(localized: "By percentage")
        case .exactAmount: String(localized: "By exact amount")
        }
    }

    var systemImage: String {
        switch self {
        case .equal: "equal.circle"
        case .percentage: "percent"
        case .exactAmount: "number"
        }
    }
}
