import SwiftUI
import UIKit

enum HomeTheme {
    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let text = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(.tertiaryLabel)

    /// Native iOS system blue accent, shared by tabs, actions, and controls.
    static let accent = Color.accentColor

    /// Blue tint for the first recurring expense indicator on Home.
    static let recurringHighlight = Color(red: 0.15, green: 0.50, blue: 0.98)

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

/// Menu / context-menu SF Symbols stay accent-tinted even with `role: .destructive`.
/// Bake systemRed into an always-original image so UIMenu cannot recolor the icon.
struct DestructiveMenuLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: Self.redSymbol(systemImage))
        }
    }

    private static func redSymbol(_ name: String) -> UIImage {
        let image = UIImage(systemName: name) ?? UIImage()
        return image.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
    }
}
