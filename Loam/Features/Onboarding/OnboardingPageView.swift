import SwiftUI

struct OnboardingPageView: View {
    var page: OnboardingPage
    var isCurrent: Bool
    @ObservedObject var permissions: OnboardingPermissions

    var body: some View {
        // Centered on tall phones; scrolls instead of clipping at large text sizes.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    switch page {
                    case .welcome:
                        LoamArcMark()
                        OnboardingPageHeader(page: page)
                    case .month:
                        OnboardingMonthPreview(isCurrent: isCurrent)
                        OnboardingPageHeader(page: page)
                    case .split:
                        OnboardingSplitPreview(isCurrent: isCurrent)
                        OnboardingPageHeader(page: page)
                    case .permissions:
                        OnboardingPageHeader(page: page)
                        OnboardingPermissionList(permissions: permissions)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }
}

#Preview {
    OnboardingPageView(page: .split, isCurrent: true, permissions: OnboardingPermissions())
        .background(HomeTheme.background)
}
