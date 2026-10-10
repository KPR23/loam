import SwiftUI

struct OnboardingPermissionRow: View {
    var title: String
    var message: String
    var systemImage: String
    var tint: Color
    var status: OnboardingPermissions.Status
    var allow: () -> Void
    var openSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(HomeTheme.text)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(HomeTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Group {
                switch status {
                case .notDetermined:
                    Button("Allow", action: allow)
                        .accessibilityLabel("Allow \(title)")
                case .allowed:
                    Label("On", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .foregroundStyle(.green)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("\(title) on")
                        .transition(.scale.combined(with: .opacity))
                case .denied:
                    Button("Settings", action: openSettings)
                        .accessibilityLabel("Turn on \(title) in Settings")
                }
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(HomeTheme.text)
        }
        .padding(16)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: status)
    }
}

#Preview {
    OnboardingPermissionRow(
        title: "Notifications",
        message: "Know when a friend adds a bill or pays you back.",
        systemImage: "bell.badge.fill",
        tint: .red,
        status: .notDetermined,
        allow: {},
        openSettings: {}
    )
}
