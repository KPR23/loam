import Foundation

/// Where onboarding ended, kept on the device. Onboarding runs before sign-in, when analytics
/// consent can't have been given, so nothing is sent from here: `reportIfNeeded` sends one
/// summary the first time a signed-in user has opted in. Drop-offs before sign-in are never seen.
enum OnboardingProgress {
    private static let furthestKey = "loam.onboarding.furthestPage"
    private static let skippedKey = "loam.onboarding.skipped"
    private static let finishedKey = "loam.onboarding.finished"
    private static let notificationsKey = "loam.onboarding.notificationsAllowed"
    private static let reportedKey = "loam.onboarding.reported"

    private static var defaults: UserDefaults { .standard }

    static func reached(_ page: OnboardingPage) {
        let furthest = defaults.object(forKey: furthestKey) as? Int ?? -1
        if page.rawValue > furthest { defaults.set(page.rawValue, forKey: furthestKey) }
    }

    static func skipped() {
        defaults.set(true, forKey: skippedKey)
    }

    static func finished(notificationsAllowed: Bool) {
        defaults.set(true, forKey: finishedKey)
        defaults.set(notificationsAllowed, forKey: notificationsKey)
    }

    /// Sends the summary once per device, and only if onboarding was finished here.
    @MainActor
    static func reportIfNeeded() {
        guard defaults.bool(forKey: finishedKey), !defaults.bool(forKey: reportedKey) else { return }
        defaults.set(true, forKey: reportedKey)
        let page = OnboardingPage(rawValue: defaults.integer(forKey: furthestKey)) ?? .welcome
        Telemetry.capture(.onboardingFinished(
            furthestPage: String(describing: page),
            skipped: defaults.bool(forKey: skippedKey),
            notificationsAllowed: defaults.bool(forKey: notificationsKey)
        ))
    }
}
