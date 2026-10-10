import SwiftUI

struct OnboardingPermissionList: View {
    @ObservedObject var permissions: OnboardingPermissions

    @Environment(\.openURL) private var openURL

    var body: some View {
        OnboardingPermissionRow(
            title: "Notifications",
            message: "Know when a friend adds a bill or pays you back.",
            systemImage: "bell.badge.fill",
            tint: .red,
            status: permissions.notifications,
            allow: allowNotifications,
            openSettings: openSettings
        )
        .background(HomeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func allowNotifications() {
        LoamFeedback.tap()
        Task { await permissions.requestNotifications() }
    }

    /// iOS asks only once; after a refusal, Settings is the only way to turn it on.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

#Preview {
    OnboardingPermissionList(permissions: OnboardingPermissions())
        .padding(24)
        .background(HomeTheme.background)
}
