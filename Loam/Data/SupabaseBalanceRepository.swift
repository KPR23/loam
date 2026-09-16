import Foundation
import Supabase

actor SupabaseBalanceRepository: BalanceRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func fetchBalances(for userId: UUID) async throws -> BalanceSnapshot {
        _ = userId // The RPC always uses auth.uid().
        struct Row: Decodable { let personId: UUID; let displayName: String; let amountMinor: Int
            enum CodingKeys: String, CodingKey { case personId = "person_id", displayName = "display_name", amountMinor = "amount_minor" } }
        let rows: [Row] = try await client.rpc("balance_snapshot").execute().value
        return BalanceSnapshot(balances: rows.map { PersonBalance(personId: $0.personId, displayName: $0.displayName, amountMinor: $0.amountMinor) })
    }

    func fetchHistory(for userId: UUID, personId: UUID) async throws -> [BalanceHistoryEntry] {
        _ = userId
        struct Params: Encodable { let pPersonId: UUID; enum CodingKeys: String, CodingKey { case pPersonId = "p_person_id" } }
        return try await client.rpc("balance_history", params: Params(pPersonId: personId)).execute().value
    }

    func createRepayment(from userId: UUID, to personId: UUID, amountMinor: Int, note: String?, paidAt: Date, operationId: UUID) async throws {
        _ = userId
        struct Params: Encodable { let pToUserId: UUID; let pAmountMinor: Int; let pNote: String?; let pPaidAt: String; let pOperationId: UUID
            enum CodingKeys: String, CodingKey { case pToUserId = "p_to_user_id", pAmountMinor = "p_amount_minor", pNote = "p_note", pPaidAt = "p_paid_at", pOperationId = "p_operation_id" } }
        _ = try await client.rpc("create_repayment", params: Params(pToUserId: personId, pAmountMinor: amountMinor, pNote: note, pPaidAt: CalendarDateCodec.string(from: paidAt), pOperationId: operationId)).execute()
    }

    func reverseRepayment(id: UUID, operationId: UUID) async throws {
        struct Params: Encodable { let pRepaymentId: UUID; let pOperationId: UUID
            enum CodingKeys: String, CodingKey { case pRepaymentId = "p_repayment_id", pOperationId = "p_operation_id" } }
        _ = try await client.rpc("reverse_repayment", params: Params(pRepaymentId: id, pOperationId: operationId)).execute()
    }
}
