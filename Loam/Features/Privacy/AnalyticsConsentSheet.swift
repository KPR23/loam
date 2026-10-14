import SwiftUI

/// Asked once per account after sign-in, before anything reaches PostHog. Both answers are
/// equally easy to give, nothing is pre-selected, and Profile > Privacy changes it later.
struct AnalyticsConsentSheet: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Help improve Loam")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("Share usage data linked to your account so we can see which screens are used and where the app gets in your way.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                point("checkmark.circle.fill", .green, "Which screens and features you use, and short screen recordings with all text and images hidden.")
                point("xmark.circle.fill", .red, "Never amounts, descriptions, notes, names or photos.")
                point("slider.horizontal.3", .secondary, "Change your mind any time in Profile under Privacy. Crash reports are always sent.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button { onAnswer(true) } label: {
                    Text("Share usage data")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                Button { onAnswer(false) } label: {
                    Text("Don’t share")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(24)
        .background(HomeTheme.background)
        .interactiveDismissDisabled()
        .presentationDetents([.large])
    }

    private func point(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(HomeTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
