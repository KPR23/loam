import Foundation

actor LocalActivityRepository: ActivityRepository {
    private let key = "loam.local.activity.v1"
    private struct Stored: Codable { let event: ActivityEvent; let audience: [UUID] }

    func fetchEvents(for userId: UUID, before: ActivityEvent?) async throws -> ActivityPage {
        let visible = load().filter { $0.audience.contains(userId) }
        let unsorted = visible.map { $0.event }
        let all = unsorted.sorted { lhs, rhs in
            lhs.occurredAt == rhs.occurredAt ? lhs.id.uuidString > rhs.id.uuidString : lhs.occurredAt > rhs.occurredAt
        }
        let filtered: [ActivityEvent]
        if let before { filtered = all.filter { $0.occurredAt < before.occurredAt || ($0.occurredAt == before.occurredAt && $0.id.uuidString < before.id.uuidString) } } else { filtered = all }
        return ActivityPage(events: Array(filtered.prefix(50)), hasMore: filtered.count > 50)
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
