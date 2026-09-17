import Foundation
import Supabase

actor SupabaseActivityRepository: ActivityRepository {
    private let client: SupabaseClient
    init(client: SupabaseClient) { self.client = client }

    func fetchEvents(for userId: UUID, before: ActivityEvent?) async throws -> ActivityPage {
        // The timestamp remains the primary cursor. The server index also includes
        // the immutable ID, while this conservative predicate prevents duplicates
        // on refresh even on PostgREST versions without an `or` filter builder.
        let rows: [ActivityDTO]
        if let cursor = before {
            rows = try await client.from("activity_event").select()
                .lt("occurred_at", value: cursor.occurredAt.ISO8601Format())
                .order("occurred_at", ascending: false).order("id", ascending: false).limit(51).execute().value
        } else {
            rows = try await client.from("activity_event").select()
                .order("occurred_at", ascending: false).order("id", ascending: false).limit(51).execute().value
        }
        let events = rows.compactMap(\.event)
        return ActivityPage(events: Array(events.prefix(50)), hasMore: events.count > 50)
    }

    // Remote history is written only by database mutation functions/triggers.
    func record(_ event: ActivityEvent, audience: [UUID]) async throws { _ = event; _ = audience }
}

private struct ActivityDTO: Decodable {
    let id: UUID; let occurredAt: Date; let kind: ActivityEventKind; let actorId: UUID; let actorName: String
    let recipientId: UUID?; let recipientName: String?; let recipientNames: [String]?; let expenseId: UUID?; let expenseTitle: String
    let category: ExpenseCategory; let affectedShareMinor: Int; let expenseTotalMinor: Int; let currency: String
    enum CodingKeys: String, CodingKey { case id, kind, category, currency; case occurredAt = "occurred_at"; case actorId = "actor_id"; case actorName = "actor_name"; case recipientId = "recipient_id"; case recipientName = "recipient_name"; case recipientNames = "recipient_names"; case expenseId = "expense_id"; case expenseTitle = "expense_title"; case affectedShareMinor = "affected_share_minor"; case expenseTotalMinor = "expense_total_minor" }
    var event: ActivityEvent? { ActivityEvent(id: id, occurredAt: occurredAt, kind: kind, actorId: actorId, actorName: actorName, recipientId: recipientId, recipientName: recipientName, recipientNames: recipientNames ?? [], expenseId: expenseId, expenseTitle: expenseTitle, category: category, affectedShareMinor: affectedShareMinor, expenseTotalMinor: expenseTotalMinor, currency: currency) }
}
