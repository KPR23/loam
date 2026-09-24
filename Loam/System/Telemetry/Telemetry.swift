import Foundation
import PostHog
import Sentry

/// Sentry reports crashes and handled errors for every user. PostHog analytics and session
/// replay start only after the user opts in, and never before, so nothing reaches PostHog
/// without consent. Both tools share the Supabase user ID so a crash can be matched to the
/// user's path in PostHog.
@MainActor
enum Telemetry {
    static let analyticsConsentKey = "loam.analyticsConsent"

    private static var postHogStarted = false
    private static var userId: String?

    static func start() {
        startSentry()
        if UserDefaults.standard.bool(forKey: analyticsConsentKey) {
            startPostHog()
        }
    }

    /// Pass `nil` when signed out or in local demo mode, whose IDs are not real accounts.
    static func setUser(_ id: UUID?) {
        // Supabase stores UUIDs in lowercase; match it so IDs can be looked up in the database.
        userId = id?.uuidString.lowercased()
        SentrySDK.setUser(userId.map { Sentry.User(userId: $0) })
        syncPostHogIdentity()
    }

    static func setAnalyticsConsent(_ granted: Bool) {
        if granted {
            if postHogStarted {
                PostHogSDK.shared.optIn()
            } else {
                startPostHog()
            }
            syncPostHogIdentity()
        } else if postHogStarted {
            PostHogSDK.shared.optOut()
        }
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
        // The SDK remembers an earlier opt-out; the consent setting is the source of truth.
        PostHogSDK.shared.optIn()
        PostHogSDK.shared.register(["environment": environment])
        postHogStarted = true
        syncPostHogIdentity()
    }

    private static func syncPostHogIdentity() {
        guard postHogStarted, !PostHogSDK.shared.isOptOut() else { return }
        let postHog = PostHogSDK.shared
        let isIdentified = postHog.getDistinctId() != postHog.getAnonymousId()

        if let userId {
            guard postHog.getDistinctId() != userId else { return }
            // Another account signed in without signing out first.
            if isIdentified { postHog.reset() }
            postHog.identify(userId)
        } else if isIdentified {
            postHog.reset()
        }
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
