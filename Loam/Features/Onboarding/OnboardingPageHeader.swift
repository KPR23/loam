import SwiftUI

struct OnboardingPageHeader: View {
    var page: OnboardingPage

    var body: some View {
        VStack(spacing: 12) {
            Text(page.title)
                .font(.system(.largeTitle, design: .rounded).bold())
                .foregroundStyle(HomeTheme.text)
                .accessibilityAddTraits(.isHeader)
            Text(page.message)
                .font(.body)
                .foregroundStyle(HomeTheme.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    OnboardingPageHeader(page: .month)
        .padding(24)
}
