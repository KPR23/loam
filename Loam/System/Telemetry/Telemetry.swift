import Foundation
import Sentry

/// Sentry reports crashes and handled errors, tagged with the Supabase user ID so a
/// report can be traced back to the account it came from.
@MainActor
enum Telemetry {
    private static var userId: String?

    static func start() {
        startSentry()
    }

    /// Pass `nil` when signed out or in local demo mode, whose IDs are not real accounts.
    static func setUser(_ id: UUID?) {
        // Supabase stores UUIDs in lowercase; match it so IDs can be looked up in the database.
        userId = id?.uuidString.lowercased()
        SentrySDK.setUser(userId.map { Sentry.User(userId: $0) })
    }

    private static func startSentry() {
        guard let dsn = infoString("SENTRY_DSN") else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.sendDefaultPii = false
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
