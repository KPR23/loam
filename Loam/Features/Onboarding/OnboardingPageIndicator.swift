import SwiftUI

/// The current page stretches into a capsule; the dots don't take taps, swiping does.
struct OnboardingPageIndicator: View {
    var current: OnboardingPage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases) { page in
                Capsule()
                    .fill(page == current ? HomeTheme.text : HomeTheme.tertiary)
                    .frame(width: page == current ? 22 : 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }
}

#Preview {
    OnboardingPageIndicator(current: .month)
}
