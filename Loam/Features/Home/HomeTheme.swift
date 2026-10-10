import SwiftUI
import UIKit

enum AppAccentColor: String, CaseIterable, Identifiable {
    case blue, purple, pink, orange, green, black

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        // The system's default label color: black in light mode, white in dark mode.
        case .black: .primary
        }
    }

    private var uiColor: UIColor {
        switch self {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .orange: .systemOrange
        case .green: .systemGreen
        case .black: .label
        }
    }

    /// A compact, original-color image so menu actions do not inherit the selected tint.
    var menuDot: UIImage {
        let dotSize: CGFloat = 12
        // The trailing transparent space remains intact in Picker's selected-value label.
        let size = CGSize(width: 22, height: dotSize)
        return UIGraphicsImageRenderer(size: size).image { _ in
            uiColor.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: dotSize, height: dotSize)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}

enum HomeTheme {
    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let text = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(.tertiaryLabel)

    /// The user-selected accent, shared by tabs, actions, and controls.
    static var accent: Color {
        let rawValue = UserDefaults.standard.string(forKey: "loam.accentColor")
        return (AppAccentColor(rawValue: rawValue ?? "") ?? .blue).color
    }

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
        Button {
            LoamFeedback.tap()
            action()
        } label: {
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

/// Feedback belongs to deliberate actions, never view appearance or background refreshes.
@MainActor
enum LoamFeedback {
    static func tap() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Native buttons retain their activation/accessibility behavior; only the label animates.
struct LoamPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.8),
                       value: configuration.isPressed)
    }
}

/// The full-width capsule for a screen's one main action, matching the paywall's purchase button.
struct LoamPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(Color(.systemBackground))
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.primary, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.8),
                       value: configuration.isPressed)
    }
}

/// Keep the action's width stable while communicating an in-flight save.
struct SavingActionLabel: View {
    let title: String
    let isSaving: Bool

    var body: some View {
        Text(title)
            .opacity(isSaving ? 0 : 1)
            .overlay {
                if isSaving { ProgressView().accessibilityHidden(true) }
            }
            .accessibilityLabel(isSaving ? "Saving" : title)
    }
}

/// A list's empty state: says what belongs here, how it gets there, and offers the first step.
struct LoamEmptyState<Action: View>: View {
    let title: String
    let message: String
    let systemImage: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(HomeTheme.accent)
                .frame(width: 64, height: 64)
                .background(HomeTheme.accent.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(HomeTheme.text)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(HomeTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            action
                .labelStyle(.prominentButton)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 8)
    }
}

/// List rows tint a `Label`'s icon with the accent, which hides it on a prominent button
/// filled with that accent; laying the label out by hand keeps the button's foreground.
struct ProminentButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == ProminentButtonLabelStyle {
    /// For a `Label` on a prominent button inside a List row.
    static var prominentButton: ProminentButtonLabelStyle { ProminentButtonLabelStyle() }
}

extension LoamEmptyState where Action == EmptyView {
    init(title: String, message: String, systemImage: String) {
        self.init(title: title, message: message, systemImage: systemImage) { EmptyView() }
    }
}
