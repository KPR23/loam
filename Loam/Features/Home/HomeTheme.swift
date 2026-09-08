import SwiftUI

enum HomeTheme {
    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let text = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(.tertiaryLabel)

    /// Arc palette — one solid colour per third of the budget.
    static let tileEmpty = Color(.quaternaryLabel).opacity(0.45)
    static let tileFirstThird = Color(red: 0.14, green: 0.72, blue: 0.48)
    static let tileSecondThird = Color(red: 0.96, green: 0.68, blue: 0.18)
    static let tileFinalThird = Color(red: 0.96, green: 0.40, blue: 0.32)

    static let accent = tileFirstThird
    static let rowRadius: CGFloat = 14
}
