import Foundation
import Supabase

actor SupabaseActivityRepository: ActivityRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func fetchUnreadEvents(for userId: UUID, before cursor: UUID?) async throws -> ActivityPage {
        struct Params: Encodable {
            let beforeId: UUID?
            enum CodingKeys: String, CodingKey { case beforeId = "p_before_id" }
        }
        let rows: [ActivityDTO] = try await client.rpc("activity_inbox", params: Params(beforeId: cursor)).execute().value
        // Page on the raw rows: skipping a kind this build doesn't know must
        // not hide "Load more" or move the cursor.
        let page = rows.prefix(50)
        return ActivityPage(events: page.compactMap(\.event), hasMore: rows.count > 50, nextCursor: page.last?.id)
    }

    func fetchExpenseEvents(expenseId: UUID, userId: UUID) async throws -> [ActivityEvent] {
        _ = userId
        struct Params: Encodable {
            let expenseId: UUID
            enum CodingKeys: String, CodingKey { case expenseId = "p_expense_id" }
        }
        let rows: [ActivityDTO] = try await client.rpc("expense_activity", params: Params(expenseId: expenseId)).execute().value
        return rows.compactMap(\.event)
    }

    // Remote history is written only by database mutation functions/triggers.
    func record(_ event: ActivityEvent, audience: [UUID]) async throws { _ = event; _ = audience }

    func unreadCount(for userId: UUID) async throws -> Int {
        _ = userId
        return try await client.rpc("activity_unread_count").execute().value
    }

    func markRead(_ eventIds: [UUID], userId: UUID) async throws {
        _ = userId
        guard !eventIds.isEmpty else { return }
        struct Params: Encodable {
            let ids: [UUID]
            enum CodingKeys: String, CodingKey { case ids = "p_ids" }
        }
        try await client.rpc("mark_activity_read", params: Params(ids: eventIds)).execute()
    }
}

private struct ActivityDTO: Decodable {
    let id: UUID; let occurredAt: Date; let kind: String; let actorId: UUID; let actorName: String
    let recipientId: UUID?; let recipientName: String?; let recipientNames: [String]?; let recipientIds: [UUID]?; let expenseId: UUID?; let repaymentId: UUID?; let expenseTitle: String
    let category: ExpenseCategory; let affectedShareMinor: Int; let expenseTotalMinor: Int; let currency: String
    enum CodingKeys: String, CodingKey { case id, kind, category, currency; case occurredAt = "occurred_at"; case actorId = "actor_id"; case actorName = "actor_name"; case recipientId = "recipient_id"; case recipientName = "recipient_name"; case recipientNames = "recipient_names"; case recipientIds = "recipient_ids"; case expenseId = "expense_id"; case repaymentId = "repayment_id"; case expenseTitle = "expense_title"; case affectedShareMinor = "affected_share_minor"; case expenseTotalMinor = "expense_total_minor" }
    /// Kinds added by a newer backend are skipped instead of failing the page.
    var event: ActivityEvent? { ActivityEventKind(rawValue: kind).map { kind in ActivityEvent(id: id, occurredAt: occurredAt, kind: kind, actorId: actorId, actorName: actorName, recipientId: recipientId, recipientName: recipientName, recipientNames: recipientNames ?? [], recipientIds: recipientIds ?? [], expenseId: expenseId, repaymentId: repaymentId, expenseTitle: expenseTitle, category: category, affectedShareMinor: affectedShareMinor, expenseTotalMinor: expenseTotalMinor, currency: currency) } }
}
