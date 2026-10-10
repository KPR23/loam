import Foundation
import Supabase

actor SupabaseConnectionRepository: ConnectionRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listConnections() async throws -> [SplitPartnerOption] {
        struct Row: Decodable { let userId: UUID; let displayName: String; enum CodingKeys: String, CodingKey { case userId = "user_id", displayName = "display_name" } }
        struct PlaceholderRow: Decodable { let userId: UUID; enum CodingKeys: String, CodingKey { case userId = "user_id" } }
        let rows: [Row] = try await client.rpc("list_connections").execute().value
        let placeholders: [PlaceholderRow] = try await client.rpc("list_placeholder_friends").execute().value
        let placeholderIds = Set(placeholders.map(\.userId))
        return rows.map {
            SplitPartnerOption(userId: $0.userId, displayName: $0.displayName, isPlaceholder: placeholderIds.contains($0.userId))
        }
    }
    func createPlaceholderFriend(name: String) async throws -> SplitPartnerOption {
        struct Params: Encodable { let pName: String; enum CodingKeys: String, CodingKey { case pName = "p_name" } }
        struct Row: Decodable { let userId: UUID; let displayName: String; enum CodingKeys: String, CodingKey { case userId = "user_id", displayName = "display_name" } }
        do {
            let rows: [Row] = try await client.rpc("create_placeholder_friend", params: Params(pName: name)).execute().value
            guard let row = rows.first else { throw ConnectionError.unavailable }
            return SplitPartnerOption(userId: row.userId, displayName: row.displayName, isPlaceholder: true)
        } catch let error as PostgrestError {
            throw ConnectionError.rejected(error.message)
        }
    }
    func createInvitation() async throws -> ConnectionInvitation {
        struct Row: Decodable { let code: String?; let expiresAt: Date?; let errorCode: String?; enum CodingKeys: String, CodingKey { case code, expiresAt = "expires_at", errorCode = "error_code" } }
        let rows: [Row] = try await client.rpc("create_connection_invitation").execute().value
        if rows.first?.errorCode == "pro_required" { throw ConnectionError.proRequired }
        guard let row = rows.first, let code = row.code, let expiresAt = row.expiresAt else { throw ConnectionError.unavailable }
        return ConnectionInvitation(code: code, expiresAt: expiresAt)
    }
    func activeInvitation() async throws -> ConnectionInvitation? {
        struct Row: Decodable { let code: String; let expiresAt: Date; enum CodingKeys: String, CodingKey { case code, expiresAt = "expires_at" } }
        let rows: [Row] = try await client.rpc("active_connection_invitation").execute().value
        return rows.first.map { ConnectionInvitation(code: $0.code, expiresAt: $0.expiresAt) }
    }
    func revokeInvitation() async throws { _ = try await client.rpc("revoke_connection_invitation").execute() }
    func preview(code: String) async throws -> String {
        struct Params: Encodable { let pCode: String; enum CodingKeys: String, CodingKey { case pCode = "p_code" } }
        struct Row: Decodable { let inviterName: String?; let errorCode: String?; enum CodingKeys: String, CodingKey { case inviterName = "inviter_name", errorCode = "error_code" } }
        let rows: [Row] = try await client.rpc("preview_connection_code", params: Params(pCode: code)).execute().value
        if rows.first?.errorCode == "rate_limited" { throw ConnectionError.rateLimited }
        guard let name = rows.first?.inviterName else { throw ConnectionError.unavailable }
        return name
    }
    func removeConnection(userId: UUID) async throws {
        struct Params: Encodable { let pUserId: UUID; enum CodingKeys: String, CodingKey { case pUserId = "p_user_id" } }
        do {
            try await client.rpc("remove_connection", params: Params(pUserId: userId)).execute()
        } catch let error as PostgrestError {
            // The server explains why, for example that money is still owed.
            throw ConnectionError.rejected(error.message)
        }
    }
    func redeem(code: String) async throws -> SplitPartnerOption {
        struct Params: Encodable { let pCode: String; enum CodingKeys: String, CodingKey { case pCode = "p_code" } }
        struct Row: Decodable { let userId: UUID?; let displayName: String?; let errorCode: String?; enum CodingKeys: String, CodingKey { case userId = "user_id", displayName = "display_name", errorCode = "error_code" } }
        let rows: [Row] = try await client.rpc("redeem_connection_code", params: Params(pCode: code)).execute().value
        if rows.first?.errorCode == "rate_limited" { throw ConnectionError.rateLimited }
        guard let row = rows.first, let id = row.userId, let name = row.displayName else { throw ConnectionError.unavailable }
        return SplitPartnerOption(userId: id, displayName: name)
    }
}

enum ConnectionError: LocalizedError { case unavailable, rateLimited, proRequired, rejected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "That code is unavailable. Check it and try again."
        case .rateLimited: "Too many attempts. Try again in 15 minutes."
        case .proRequired: "Loam Pro is needed to invite more people."
        case let .rejected(message): message
        }
    }
}
