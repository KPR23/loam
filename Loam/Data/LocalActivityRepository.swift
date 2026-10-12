import Foundation

actor LocalActivityRepository: ActivityRepository {
    private let key = "loam.local.activity.v1"
    private struct Stored: Codable {
        let event: ActivityEvent
        let audience: [UUID]
        var readBy: [UUID]
        var seenBy: [UUID]

        init(event: ActivityEvent, audience: [UUID], readBy: [UUID]) {
            self.event = event; self.audience = audience; self.readBy = readBy; self.seenBy = readBy
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            event = try values.decode(ActivityEvent.self, forKey: .event)
            audience = try values.decode([UUID].self, forKey: .audience)
            // History recorded before the inbox existed starts out read.
            readBy = try values.decodeIfPresent([UUID].self, forKey: .readBy) ?? audience
            seenBy = try values.decodeIfPresent([UUID].self, forKey: .seenBy) ?? readBy
        }

        func countsTowardBadge(for userId: UUID) -> Bool {
            audience.contains(userId) && !readBy.contains(userId) && !seenBy.contains(userId)
        }

        /// Only people who can see the event can read it.
        mutating func markRead(by users: [UUID]) {
            for userId in users where audience.contains(userId) && !readBy.contains(userId) {
                readBy.append(userId)
            }
        }

        /// Same rule as the server: a newer event about the same expense or repayment replaces this one.
        func isReplaced(by newer: ActivityEvent) -> Bool {
            if let id = event.expenseId, id == newer.expenseId { return true }
            if let id = event.repaymentId, id == newer.repaymentId { return true }
            return false
        }
    }

    func fetchUnreadEvents(for userId: UUID, before cursor: UUID?) async throws -> ActivityPage {
        let visible: [Stored] = load().filter { $0.audience.contains(userId) }
        let unread: Set<UUID> = Set(visible.filter { !$0.readBy.contains(userId) }.map { $0.event.id })
        let all: [ActivityEvent] = visible.map { $0.event }.sorted(by: Self.newestFirst)
        let older: ArraySlice<ActivityEvent>
        if let cursor {
            // The cursor row may have been read since; its position still counts.
            guard let index = all.firstIndex(where: { $0.id == cursor }) else { return ActivityPage(events: [], hasMore: false, nextCursor: nil) }
            older = all[(index + 1)...]
        } else { older = all[...] }
        let filtered = older.filter { unread.contains($0.id) }
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
        let audience = Array(Set(audience))
        var values = load()
        for index in values.indices where values[index].isReplaced(by: event) {
            values[index].markRead(by: audience)
        }
        values.append(Stored(event: event, audience: audience, readBy: audience.contains(event.actorId) ? [event.actorId] : []))
        try save(values)
    }

    func unseenCount(for userId: UUID) async throws -> Int {
        min(load().filter { $0.countsTowardBadge(for: userId) }.count, 100)
    }

    func markSeen(through: Date, userId: UUID) async throws {
        var values = load()
        for index in values.indices where values[index].countsTowardBadge(for: userId) && values[index].event.occurredAt <= through {
            values[index].seenBy.append(userId)
        }
        try save(values)
    }

    func markRead(_ eventIds: [UUID], userId: UUID) async throws {
        let ids = Set(eventIds)
        var values = load()
        for index in values.indices where ids.contains(values[index].event.id) {
            values[index].markRead(by: [userId])
        }
        try save(values)
    }

    private static func newestFirst(_ lhs: ActivityEvent, _ rhs: ActivityEvent) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private func load() -> [Stored] {
        guard let data = UserDefaults.standard.data(forKey: key), let values = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return values
    }

    private func save(_ values: [Stored]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(values), forKey: key)
    }
}
