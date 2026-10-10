import SwiftUI

/// Shown once before the first sign-in: what Loam does, then the optional permissions.
struct OnboardingView: View {
    static let completedKey = "loam.onboardingCompleted"

    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var permissions = OnboardingPermissions()
    @State private var page: OnboardingPage = .welcome

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page != .permissions {
                    Button("Skip", action: skip)
                        .font(.body.weight(.medium))
                        .tint(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .transition(.opacity)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 16)

            TabView(selection: $page) {
                ForEach(OnboardingPage.allCases) { item in
                    OnboardingPageView(page: item, isCurrent: item == page, permissions: permissions)
                        .tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 24) {
                OnboardingPageIndicator(current: page)

                Button(action: advance) {
                    Text(page.actionTitle)
                        .contentTransition(.opacity)
                }
                .buttonStyle(LoamPrimaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(HomeTheme.background)
        .animation(reduceMotion ? nil : .snappy, value: page)
        .task { await permissions.refresh() }
    }

    private func advance() {
        LoamFeedback.tap()
        if let next = page.next {
            page = next
        } else {
            onFinish()
        }
    }

    /// Skipping the story still lands on permissions, which people can then decline in one tap.
    private func skip() {
        LoamFeedback.tap()
        page = .permissions
    }
}

#Preview {
    OnboardingView {}
}
