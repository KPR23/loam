import SwiftUI

enum HomeTheme {
    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let text = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(.tertiaryLabel)

    /// Monochrome brand accent — neutral chrome; color lives in charts & categories.
    static let accent = Color.primary

    /// Unfilled arc tiles.
    static let tileEmpty = Color(.quaternaryLabel).opacity(0.45)

    static let rowRadius: CGFloat = 14
}

/// Trailing close control for browse/list sheets (X top-right).
/// Forms should use `ToolbarItem(placement: .cancellationAction) { Button("Cancel") }` instead.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
    }
}
