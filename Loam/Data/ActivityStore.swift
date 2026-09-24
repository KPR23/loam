import Foundation

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false
    @Published var lastError: String?
    private var accountId: UUID?

    func refresh(userId: UUID?) async {
        guard let userId else { accountId = nil; events = []; canLoadMore = false; lastError = nil; return }
        accountId = userId; isLoading = true; lastError = nil
        defer { isLoading = false }
        do { let page = try await ActivityRepositoryFactory.make().fetchEvents(for: userId, before: nil); guard accountId == userId else { return }; events = coalesceSharedEvents(page.events); canLoadMore = page.hasMore } catch { guard accountId == userId else { return }; lastError = error.localizedDescription }
    }

    func loadMore(userId: UUID) async {
        guard !isLoading, canLoadMore, let last = events.last else { return }; isLoading = true
        defer { isLoading = false }
        do { let page = try await ActivityRepositoryFactory.make().fetchEvents(for: userId, before: last); guard accountId == userId else { return }; events = coalesceSharedEvents(events + page.events); canLoadMore = page.hasMore } catch { lastError = error.localizedDescription }
    }

    func recordLocal(_ event: ActivityEvent, audience: [UUID]) async {
        guard ExpenseRepositoryFactory.usesLocalStorage else { return }
        try? await ActivityRepositoryFactory.make().record(event, audience: audience)
        if let accountId, audience.contains(accountId) { await refresh(userId: accountId) }
    }

    /// History for one expense's detail screen, oldest first.
    func history(forExpense expenseId: UUID, userId: UUID) async throws -> [ActivityEvent] {
        let events = try await ActivityRepositoryFactory.make().fetchExpenseEvents(expenseId: expenseId, userId: userId)
        return coalesceSharedEvents(events)
    }

    private func coalesceSharedEvents(_ input: [ActivityEvent]) -> [ActivityEvent] {
        var result: [ActivityEvent] = []
        var indexes: [String: Int] = [:]
        for event in input {
            guard event.kind == .shared, let expenseId = event.expenseId else {
                result.append(event)
                continue
            }
            let key = "\(expenseId.uuidString)-\(event.actorId.uuidString)-\(event.occurredAt.timeIntervalSince1970)"
            if let index = indexes[key] {
                let existing = result[index]
                var names = existing.recipientNames
                var ids = existing.recipientIds
                if ids.count == names.count, event.recipientIds.count == event.recipientNames.count {
                    for (id, name) in zip(event.recipientIds, event.recipientNames) where !ids.contains(id) {
                        ids.append(id)
                        names.append(name)
                    }
                } else {
                    ids = []
                    for name in event.recipientNames where !names.contains(name) { names.append(name) }
                }
                result[index] = ActivityEvent(
                    id: existing.id, occurredAt: existing.occurredAt, kind: existing.kind,
                    actorId: existing.actorId, actorName: existing.actorName,
                    recipientId: names.count == 1 ? existing.recipientId : nil,
                    recipientName: names.count == 1 ? names[0] : nil,
                    recipientNames: names, recipientIds: ids, expenseId: existing.expenseId,
                    expenseTitle: existing.expenseTitle, category: existing.category,
                    affectedShareMinor: existing.affectedShareMinor + event.affectedShareMinor,
                    expenseTotalMinor: existing.expenseTotalMinor, currency: existing.currency
                )
            } else {
                indexes[key] = result.count
                result.append(event)
            }
        }
        return result
    }
}
