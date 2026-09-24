import Foundation

actor LocalActivityRepository: ActivityRepository {
    private let key = "loam.local.activity.v1"
    private struct Stored: Codable { let event: ActivityEvent; let audience: [UUID] }

    func fetchEvents(for userId: UUID, before cursor: UUID?) async throws -> ActivityPage {
        let visible = load().filter { $0.audience.contains(userId) }
        let unsorted = visible.map { $0.event }
        let all = unsorted.sorted { lhs, rhs in
            lhs.occurredAt == rhs.occurredAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.occurredAt > rhs.occurredAt
        }
        let filtered: [ActivityEvent]
        if let cursor {
            guard let index = all.firstIndex(where: { $0.id == cursor }) else { return ActivityPage(events: [], hasMore: false, nextCursor: nil) }
            filtered = Array(all[(index + 1)...])
        } else { filtered = all }
        let page = Array(filtered.prefix(50))
        return ActivityPage(events: page, hasMore: filtered.count > 50, nextCursor: page.last?.id)
    }

    func fetchExpenseEvents(expenseId: UUID, userId: UUID) async throws -> [ActivityEvent] {
        load()
            .filter { $0.audience.contains(userId) && $0.event.expenseId == expenseId }
            .map(\.event)
            .sorted { $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt < $1.occurredAt }
    }

    func record(_ event: ActivityEvent, audience: [UUID]) async throws {
        guard !audience.isEmpty else { return }
        var values = load(); values.append(Stored(event: event, audience: Array(Set(audience))))
        UserDefaults.standard.set(try JSONEncoder().encode(values), forKey: key)
    }

    private func load() -> [Stored] {
        guard let data = UserDefaults.standard.data(forKey: key), let values = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return values
    }
}
