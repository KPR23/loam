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
    func redeem(code: String) async throws -> SplitPartnerOption {
        struct Params: Encodable { let pCode: String; enum CodingKeys: String, CodingKey { case pCode = "p_code" } }
        struct Row: Decodable { let userId: UUID?; let displayName: String?; let errorCode: String?; enum CodingKeys: String, CodingKey { case userId = "user_id", displayName = "display_name", errorCode = "error_code" } }
        let rows: [Row] = try await client.rpc("redeem_connection_code", params: Params(pCode: code)).execute().value
        if rows.first?.errorCode == "rate_limited" { throw ConnectionError.rateLimited }
        guard let row = rows.first, let id = row.userId, let name = row.displayName else { throw ConnectionError.unavailable }
        return SplitPartnerOption(userId: id, displayName: name)
    }
}

enum ConnectionError: LocalizedError { case unavailable, rateLimited, proRequired
    var errorDescription: String? {
        switch self {
        case .unavailable: "That code is unavailable. Check it and try again."
        case .rateLimited: "Too many attempts. Try again in 15 minutes."
        case .proRequired: "Loam Pro is needed to invite more people."
        }
    }
}
