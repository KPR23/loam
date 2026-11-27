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
                Text("Share a few usage counts tied to a random account ID so we can see how people get started and what they use.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                point("checkmark.circle.fill", .green, "When you open the app, how onboarding went, and actions like adding an expense, repaying or connecting a friend.")
                point("xmark.circle.fill", .red, "Never amounts, descriptions, notes, names or photos.")
                point("slider.horizontal.3", .secondary, "Change your mind any time in Settings. Crash reports (device model, iOS and app version, never your expenses) are sent unless you turn them off there.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Link("Read the privacy policy", destination: LegalPages.privacyPolicy)
                .font(.subheadline)

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

    private func point(_ symbol: String, _ color: Color, _ text: LocalizedStringKey) -> some View {
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
