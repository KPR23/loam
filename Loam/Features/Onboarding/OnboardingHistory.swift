import Foundation

/// Versions before onboarding kept no flag, so this looks for traces only earlier use leaves.
/// Keep it cheap and synchronous: it runs before the first signed-out screen is chosen.
enum OnboardingHistory {
    /// Not signs of use: onboarding's own flag, and a cleanup flag set on the very first launch.
    private static let launchKeys: Set<String> = [
        OnboardingView.completedKey,
        "loam.demo.fixtures.removed",
    ]

    static func hasUsedLoam(
        defaults: UserDefaults = .standard,
        domain: String = Bundle.main.bundleIdentifier ?? "",
        hasStoredSession: () -> Bool = { SupabaseClientProvider.shared?.auth.currentSession != nil }
    ) -> Bool {
        // A session that couldn't be restored (expired while offline, say) stays in the keychain.
        if hasStoredSession() { return true }
        // Demo data, settings, split partners and analytics consent are all written through use.
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        return saved.keys.contains { key in
            key.hasPrefix("loam.") && !launchKeys.contains(key)
        }
    }
}
