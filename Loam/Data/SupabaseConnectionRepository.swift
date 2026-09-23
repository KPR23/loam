import Foundation
import Supabase

actor SupabaseConnectionRepository: ConnectionRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func listConnections() async throws -> [SplitPartnerOption] {
        struct Row: Decodable { let userId: UUID; let displayName: String; enum CodingKeys: String, CodingKey { case userId = "user_id", displayName = "display_name" } }
        let rows: [Row] = try await client.rpc("list_connections").execute().value
        return rows.map { SplitPartnerOption(userId: $0.userId, displayName: $0.displayName) }
    }
    func createInvitation() async throws -> ConnectionInvitation {
        struct Row: Decodable { let code: String; let expiresAt: Date; enum CodingKeys: String, CodingKey { case code, expiresAt = "expires_at" } }
        let rows: [Row] = try await client.rpc("create_connection_invitation").execute().value
        guard let row = rows.first else { throw ConnectionError.unavailable }
        return ConnectionInvitation(code: row.code, expiresAt: row.expiresAt)
    }
    func activeInvitation() async throws -> ConnectionInvitation? {
        struct Row: Decodable { let code: String; let expiresAt: Date; enum CodingKeys: String, CodingKey { case code, expiresAt = "expires_at" } }
        let rows: [Row] = try await client.rpc("active_connection_invitation").execute().value
        return rows.first.map { ConnectionInvitation(code: $0.code, expiresAt: $0.expiresAt) }
    }
    func revokeInvitation() async throws { _ = try await client.rpc("revoke_connection_invitation").execute() }
    func preview(code: String) async throws -> String {
        struct Params: Encodable { let pCode: String; enum CodingKeys: String, CodingKey { case pCode = "p_code" } }
        struct Row: Decodable { let inviterName: String; enum CodingKeys: String, CodingKey { case inviterName = "inviter_name" } }
        let rows: [Row] = try await client.rpc("preview_connection_code", params: Params(pCode: code)).execute().value
        guard let name = rows.first?.inviterName else { throw ConnectionError.unavailable }
        return name
    }
    func redeem(code: String) async throws -> SplitPartnerOption {
        struct Params: Encodable { let pCode: String; enum CodingKeys: String, CodingKey { case pCode = "p_code" } }
        struct Row: Decodable { let userId: UUID; let displayName: String; enum CodingKeys: String, CodingKey { case userId = "user_id", displayName = "display_name" } }
        let rows: [Row] = try await client.rpc("redeem_connection_code", params: Params(pCode: code)).execute().value
        guard let row = rows.first else { throw ConnectionError.unavailable }
        return SplitPartnerOption(userId: row.userId, displayName: row.displayName)
    }
}

enum ConnectionError: LocalizedError { case unavailable
    var errorDescription: String? { "That code is unavailable. Check it and try again." }
}
