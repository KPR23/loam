import Foundation
import PostHog
import Sentry

/// Sentry reports crashes and handled errors for every user of a TestFlight or App Store
/// build. PostHog analytics and session replay run only for a signed-in user who opted in,
/// so nothing reaches PostHog without that user's consent. Consent is stored per account:
/// another account signing in on the same device starts opted out. Both tools share the
/// Supabase user ID so a crash can be matched to the user's path in PostHog.
@MainActor
enum Telemetry {
    private static let analyticsConsentKeyPrefix = "loam.analyticsConsent."

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

    static func setAnalyticsConsent(_ granted: Bool, for id: UUID) {
        UserDefaults.standard.set(granted, forKey: analyticsConsentKey(for: normalizedId(id)))
        applyAnalyticsConsent()
    }

    static func screen(_ name: String) {
        guard postHogStarted else { return }
        PostHogSDK.shared.screen(name)
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
            // PostHog records sessions; a second recorder would double the cost.
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

        config.sessionReplay = true
        // Wireframe mode with every text and image masked keeps amounts, descriptions,
        // names and avatars out of recordings. Masking happens on the device.
        config.sessionReplayConfig.screenshotMode = false
        config.sessionReplayConfig.maskAllTextInputs = true
        config.sessionReplayConfig.maskAllImages = true
        config.sessionReplayConfig.maskAllSandboxedViews = true
        // Supabase request URLs carry record IDs and filters.
        config.sessionReplayConfig.captureNetworkTelemetry = false
        config.sessionReplayConfig.captureLogs = false

        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.register(["environment": environment])
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

    var name: String {
        switch self {
        case .expenseCreated: "expense created"
        case .repaymentRecorded: "repayment recorded"
        }
    }

    var properties: [String: Any]? {
        switch self {
        case let .expenseCreated(shared, recurring, participantCount):
            ["shared": shared, "recurring": recurring, "participant_count": participantCount]
        case .repaymentRecorded:
            nil
        }
    }
}
