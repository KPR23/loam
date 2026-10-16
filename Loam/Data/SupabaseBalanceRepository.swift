import Foundation
import Supabase

actor SupabaseBalanceRepository: BalanceRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func fetchBalances(for userId: UUID) async throws -> BalanceSnapshot {
        _ = userId // The RPC always uses auth.uid().
        struct Row: Decodable { let personId: UUID; let displayName: String; let amountMinor: Int; let currency: String
            enum CodingKeys: String, CodingKey { case personId = "person_id", displayName = "display_name", amountMinor = "amount_minor", currency } }
        async let awaiting = fetchAwaiting()
        let rows: [Row] = try await client.rpc("balance_snapshot").execute().value
        return BalanceSnapshot(
            balances: rows.map { PersonBalance(personId: $0.personId, displayName: $0.displayName, amountMinor: $0.amountMinor, currencyCode: $0.currency) },
            awaiting: await awaiting
        )
    }

    /// Optional extra: balances still load when it fails.
    private func fetchAwaiting() async -> [AwaitingBalance] {
        struct Row: Decodable { let personId: UUID; let amountMinor: Int; let currency: String; let expenseCount: Int
            enum CodingKeys: String, CodingKey { case personId = "person_id", amountMinor = "amount_minor", currency, expenseCount = "expense_count" } }
        guard let rows: [Row] = try? await client.rpc("awaiting_acceptance_snapshot").execute().value else { return [] }
        return rows.map { AwaitingBalance(personId: $0.personId, amountMinor: $0.amountMinor, currencyCode: $0.currency, expenseCount: $0.expenseCount) }
    }

    func fetchHistory(for userId: UUID, personId: UUID) async throws -> [BalanceHistoryEntry] {
        _ = userId
        struct Params: Encodable { let pPersonId: UUID; enum CodingKeys: String, CodingKey { case pPersonId = "p_person_id" } }
        return try await client.rpc("balance_history", params: Params(pPersonId: personId)).execute().value
    }

    func createRepayment(from userId: UUID, to personId: UUID, amountMinor: Int, currencyCode: String, note: String?, paidAt: Date, operationId: UUID) async throws {
        _ = userId
        let params = CreateRepaymentParams(
            toUserId: personId,
            amountMinor: amountMinor,
            currency: currencyCode.uppercased(),
            note: note,
            paidAt: CalendarDateCodec.string(from: paidAt),
            operationId: operationId
        )
        _ = try await client.rpc("create_repayment", params: params).execute()
    }

    func createReceivedRepayment(from personId: UUID, to userId: UUID, amountMinor: Int, currencyCode: String, note: String?, paidAt: Date, operationId: UUID) async throws {
        _ = userId
        let params = CreateReceivedRepaymentParams(
            fromUserId: personId,
            amountMinor: amountMinor,
            currency: currencyCode.uppercased(),
            note: note,
            paidAt: CalendarDateCodec.string(from: paidAt),
            operationId: operationId
        )
        _ = try await client.rpc("create_received_repayment", params: params).execute()
    }

    func reverseRepayment(id: UUID, operationId: UUID) async throws {
        struct Params: Encodable { let pRepaymentId: UUID; let pOperationId: UUID
            enum CodingKeys: String, CodingKey { case pRepaymentId = "p_repayment_id", pOperationId = "p_operation_id" } }
        _ = try await client.rpc("reverse_repayment", params: Params(pRepaymentId: id, pOperationId: operationId)).execute()
    }
}

struct CreateRepaymentParams: Encodable, Sendable {
    let toUserId: UUID
    let amountMinor: Int
    let currency: String
    let note: String?
    let paidAt: String
    let operationId: UUID

    enum CodingKeys: String, CodingKey {
        case toUserId = "p_to_user_id"
        case amountMinor = "p_amount_minor"
        case currency = "p_currency"
        case note = "p_note"
        case paidAt = "p_paid_at"
        case operationId = "p_operation_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toUserId, forKey: .toUserId)
        try container.encode(amountMinor, forKey: .amountMinor)
        try container.encode(currency, forKey: .currency)
        if let note {
            try container.encode(note, forKey: .note)
        } else {
            // PostgREST resolves RPC overloads from the JSON key set. Omitting
            // this optional key makes it search for a four-argument function.
            try container.encodeNil(forKey: .note)
        }
        try container.encode(paidAt, forKey: .paidAt)
        try container.encode(operationId, forKey: .operationId)
    }
}

/// Same shape as `CreateRepaymentParams`, with the payer named instead of the recipient.
struct CreateReceivedRepaymentParams: Encodable, Sendable {
    let fromUserId: UUID
    let amountMinor: Int
    let currency: String
    let note: String?
    let paidAt: String
    let operationId: UUID

    enum CodingKeys: String, CodingKey {
        case fromUserId = "p_from_user_id"
        case amountMinor = "p_amount_minor"
        case currency = "p_currency"
        case note = "p_note"
        case paidAt = "p_paid_at"
        case operationId = "p_operation_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fromUserId, forKey: .fromUserId)
        try container.encode(amountMinor, forKey: .amountMinor)
        try container.encode(currency, forKey: .currency)
        try container.encode(note, forKey: .note)
        try container.encode(paidAt, forKey: .paidAt)
        try container.encode(operationId, forKey: .operationId)
    }
}
