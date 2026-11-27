import Foundation
import PostHog
import Sentry

/// Sentry reports crashes and handled errors for every user of a TestFlight or App Store
/// build. PostHog analytics run only in App Store builds, which alone carry PostHog keys,
/// and only for a signed-in user who opted in, so nothing reaches PostHog without that
/// user's consent. Consent is stored per account: another account signing in on the same
/// device starts opted out. Both tools share the Supabase user ID, a random identifier and
/// the only identity sent: no email, name or other person properties. See docs/data-collection.md.
@MainActor
enum Telemetry {
    private static let analyticsConsentKeyPrefix = "loam.analyticsConsent."
    private static let analyticsAnsweredKeyPrefix = "loam.analyticsAnswered."

    private static var postHogStarted = false
    private static var userId: String?

    static func start() {
        // Xcode already shows a Debug build's crashes, and its debugger pauses would reach
        // Sentry as app hangs, so only TestFlight and App Store builds report.
        #if !DEBUG
        startSentry()
        #endif
        startPostHog()
    }

    /// False in builds without PostHog keys, which never send analytics.
    static var isAnalyticsAvailable: Bool {
        postHogStarted
    }

    /// Pass `nil` when signed out or in local demo mode, whose IDs are not real accounts.
    static func setUser(_ id: UUID?) {
        // Supabase stores UUIDs in lowercase; match it so IDs can be looked up in the database.
        userId = id.map(normalizedId)
        SentrySDK.setUser(userId.map { Sentry.User(userId: $0) })
        applyAnalyticsConsent()
    }

    static func hasAnalyticsConsent(for id: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: analyticsConsentKey(for: normalizedId(id)))
    }

    /// True once this account has chosen, in the first-run prompt or the Privacy setting.
    static func hasAnsweredAnalyticsPrompt(for id: UUID) -> Bool {
        let id = normalizedId(id)
        // Accounts that used the Privacy setting before the prompt existed have already chosen.
        return UserDefaults.standard.bool(forKey: analyticsAnsweredKeyPrefix + id)
            || UserDefaults.standard.object(forKey: analyticsConsentKey(for: id)) != nil
    }

    static func setAnalyticsConsent(_ granted: Bool, for id: UUID) {
        let id = normalizedId(id)
        UserDefaults.standard.set(granted, forKey: analyticsConsentKey(for: id))
        UserDefaults.standard.set(true, forKey: analyticsAnsweredKeyPrefix + id)
        applyAnalyticsConsent()
    }

    static func capture(_ event: ProductEvent) {
        guard postHogStarted else { return }
        PostHogSDK.shared.capture(event.name, properties: event.properties)
    }

    private static func startSentry() {
        guard let dsn = infoString("SENTRY_DSN") else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.sendDefaultPii = false
            options.sessionReplay.sessionSampleRate = 0
            options.sessionReplay.onErrorSampleRate = 0
        }
    }

    private static func startPostHog() {
        guard
            let token = infoString("POSTHOG_PROJECT_TOKEN"),
            let host = infoString("POSTHOG_HOST")
        else {
            return
        }

        let config = PostHogConfig(projectToken: token, host: host)
        // Nothing is sent until a signed-in user opts in. The SDK keeps the last opt-in or
        // opt-out across launches, so a consenting user's app opens are captured from launch.
        config.optOut = true
        config.personProfiles = .identifiedOnly
        config.captureApplicationLifecycleEvents = true
        // SwiftUI screens appear as generic hosting controllers; screens are named by hand.
        config.captureScreenViews = false
        // Autocapture records element text, which can include amounts and names.
        config.captureElementInteractions = false
        // Sentry owns error reporting.
        config.errorTrackingConfig.autoCapture = false

        // Session replay stays off: Loam only counts a few actions, it never watches screens.
        config.sessionReplay = false

        PostHogSDK.shared.setup(config)
        postHogStarted = true
    }

    private static func applyAnalyticsConsent() {
        guard postHogStarted else { return }
        let postHog = PostHogSDK.shared

        guard let userId, UserDefaults.standard.bool(forKey: analyticsConsentKey(for: userId)) else {
            // Drop the previous user's identity before capture stops.
            if postHog.getDistinctId() != postHog.getAnonymousId() { postHog.reset() }
            postHog.optOut()
            return
        }

        postHog.optIn()
        identify(userId)
        OnboardingProgress.reportIfNeeded()
    }

    private static func identify(_ id: String) {
        let postHog = PostHogSDK.shared
        guard postHog.getDistinctId() != id else { return }
        // Another account signed in without signing out first.
        if postHog.getDistinctId() != postHog.getAnonymousId() { postHog.reset() }
        postHog.identify(id)
    }

    private static func analyticsConsentKey(for id: String) -> String {
        analyticsConsentKeyPrefix + id
    }

    private static func normalizedId(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static var environment: String {
        infoString("LOAM_ENVIRONMENT") ?? "production"
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Product analytics events. Properties must never carry amounts, titles, notes,
/// locations, names or other personal data.
enum ProductEvent {
    case expenseCreated(shared: Bool, recurring: Bool, participantCount: Int)
    case repaymentRecorded
    case friendConnected
    /// How far onboarding got. Recorded on the device before sign-in and sent once, after opt-in.
    case onboardingFinished(furthestPage: String, skipped: Bool, notificationsAllowed: Bool)

    var name: String {
        switch self {
        case .expenseCreated: "expense created"
        case .repaymentRecorded: "repayment recorded"
        case .friendConnected: "friend connected"
        case .onboardingFinished: "onboarding finished"
        }
    }

    var properties: [String: Any]? {
        switch self {
        case let .expenseCreated(shared, recurring, participantCount):
            ["shared": shared, "recurring": recurring, "participant_count": participantCount]
        case let .onboardingFinished(furthestPage, skipped, notificationsAllowed):
            ["furthest_page": furthestPage, "skipped": skipped, "notifications_allowed": notificationsAllowed]
        case .repaymentRecorded, .friendConnected:
            nil
        }
    }
}
