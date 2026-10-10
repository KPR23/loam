import Foundation
import Supabase

protocol NotificationRepository: Sendable {
    func registerDevice(token: String, environment: PushEnvironment) async throws
    func unregisterDevice(token: String) async throws
    func fetchPreferences() async throws -> NotificationPreferences
    func savePreferences(_ preferences: NotificationPreferences) async throws
}

/// Which APNs host the build's tokens belong to; Debug builds are signed for the sandbox.
enum PushEnvironment: String, Sendable {
    case sandbox
    case production

    static var current: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

struct SupabaseNotificationRepository: NotificationRepository {
    let client: SupabaseClient

    func registerDevice(token: String, environment: PushEnvironment) async throws {
        struct Params: Encodable {
            let token: String
            let environment: String
            enum CodingKeys: String, CodingKey { case token = "p_token", environment = "p_environment" }
        }
        try await client.rpc("register_push_device", params: Params(token: token, environment: environment.rawValue)).execute()
    }

    func unregisterDevice(token: String) async throws {
        struct Params: Encodable {
            let token: String
            enum CodingKeys: String, CodingKey { case token = "p_token" }
        }
        try await client.rpc("unregister_push_device", params: Params(token: token)).execute()
    }

    func fetchPreferences() async throws -> NotificationPreferences {
        let rows: [NotificationPreferences] = try await client.rpc("notification_preferences").execute().value
        // No row means the account is inactive; defaults keep every switch on.
        return rows.first ?? NotificationPreferences()
    }

    func savePreferences(_ preferences: NotificationPreferences) async throws {
        struct Params: Encodable {
            let preferences: NotificationPreferences
            enum CodingKeys: String, CodingKey {
                case requests = "p_requests", replies = "p_replies", changes = "p_changes", repayments = "p_repayments"
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(preferences.requests, forKey: .requests)
                try container.encode(preferences.replies, forKey: .replies)
                try container.encode(preferences.changes, forKey: .changes)
                try container.encode(preferences.repayments, forKey: .repayments)
            }
        }
        try await client.rpc("set_notification_preferences", params: Params(preferences: preferences)).execute()
    }
}
