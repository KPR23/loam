import SwiftUI

enum HomeTheme {
    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let text = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(.tertiaryLabel)

    /// Monochrome brand accent — neutral chrome; color lives in charts & categories.
    static let accent = Color.primary

    /// Arc palette — lime → amber → coral.
    static let tileEmpty = Color(.quaternaryLabel).opacity(0.45)
    static let tileFirstThird = Color(red: 102 / 255, green: 194 / 255, blue: 64 / 255)
    static let tileSecondThird = Color(red: 0.96, green: 0.68, blue: 0.18)
    static let tileFinalThird = Color(red: 0.96, green: 0.40, blue: 0.32)

    static let rowRadius: CGFloat = 14
}
