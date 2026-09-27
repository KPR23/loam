import Foundation

@MainActor
final class ActivityStore: ObservableObject {
    /// Unread events only; read ones live on in each expense's history.
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false
    @Published var lastError: String?
    /// Drives the tab badge.
    @Published private(set) var unreadCount = 0
    private var accountId: UUID?
    private var nextCursor: UUID?
    /// Rows folded into a shown event, so marking it read reads all of them.
    private var foldedIds: [UUID: [UUID]] = [:]
    /// Bumped by each refresh so a page fetched before it can't land on the new list.
    private var generation = 0

    func refreshUnreadCount(userId: UUID?) async {
        guard let userId else { unreadCount = 0; return }
        guard let count = try? await ActivityRepositoryFactory.make().unreadCount(for: userId), accountId == nil || accountId == userId else { return }
        unreadCount = count
    }

    func refresh(userId: UUID?) async {
        guard let userId else {
            accountId = nil; events = []; foldedIds = [:]; canLoadMore = false; nextCursor = nil; lastError = nil; unreadCount = 0
            return
        }
        generation += 1
        let current = generation
        accountId = userId; isLoading = true; lastError = nil
        defer { if generation == current { isLoading = false } }
        let repository = ActivityRepositoryFactory.make()
        do {
            let page = try await repository.fetchUnreadEvents(for: userId, before: nil)
            guard accountId == userId, generation == current else { return }
            setEvents(page.events); nextCursor = page.nextCursor; canLoadMore = page.hasMore && page.nextCursor != nil
        } catch { guard accountId == userId else { return }; lastError = error.localizedDescription }
        await refreshUnreadCount(userId: userId)
    }

    func loadMore(userId: UUID) async {
        guard !isLoading, canLoadMore, let cursor = nextCursor else { return }; isLoading = true
        let current = generation
        defer { if generation == current { isLoading = false } }
        do { let page = try await ActivityRepositoryFactory.make().fetchUnreadEvents(for: userId, before: cursor); guard accountId == userId, generation == current else { return }; setEvents(events + page.events, keepingFolds: true); nextCursor = page.nextCursor; canLoadMore = page.hasMore && page.nextCursor != nil } catch { guard generation == current else { return }; lastError = error.localizedDescription }
    }

    /// Takes the events out of the inbox right away; a failed save puts them back.
    func markRead(_ read: [ActivityEvent], userId: UUID) async {
        guard accountId == userId, !read.isEmpty else { return }
        let ids = Set(read.map(\.id))
        let rowIds = ids.flatMap { foldedIds[$0] ?? [$0] }
        events.removeAll { ids.contains($0.id) }
        unreadCount = max(0, unreadCount - rowIds.count)
        do {
            try await ActivityRepositoryFactory.make().markRead(rowIds, userId: userId)
        } catch {
            guard accountId == userId else { return }
            lastError = error.localizedDescription
            await refresh(userId: userId)
        }
    }

    func recordLocal(_ event: ActivityEvent, audience: [UUID]) async {
        guard ExpenseRepositoryFactory.usesLocalStorage else { return }
        try? await ActivityRepositoryFactory.make().record(event, audience: audience)
        if let accountId, audience.contains(accountId) { await refresh(userId: accountId) }
    }

    /// History for one expense's detail screen, oldest first.
    func history(forExpense expenseId: UUID, userId: UUID) async throws -> [ActivityEvent] {
        let events = try await ActivityRepositoryFactory.make().fetchExpenseEvents(expenseId: expenseId, userId: userId)
        return coalesceSharedEvents(events).events
    }

    /// Folding again after "Load more" only sees the shown rows, so earlier folds are kept.
    private func setEvents(_ input: [ActivityEvent], keepingFolds: Bool = false) {
        let (coalesced, folded) = coalesceSharedEvents(input)
        events = coalesced
        foldedIds = keepingFolds ? foldedIds.merging(folded) { Array(Set($0 + $1)) } : folded
    }

    /// Also returns, for each shown event that absorbed others, every row ID it stands for.
    private func coalesceSharedEvents(_ input: [ActivityEvent]) -> (events: [ActivityEvent], folded: [UUID: [UUID]]) {
        var result: [ActivityEvent] = []
        var folded: [UUID: [UUID]] = [:]
        var indexes: [String: Int] = [:]
        for event in input {
            guard event.kind == .shared, let expenseId = event.expenseId else {
                result.append(event)
                continue
            }
            let key = "\(expenseId.uuidString)-\(event.actorId.uuidString)-\(event.occurredAt.timeIntervalSince1970)"
            if let index = indexes[key] {
                let existing = result[index]
                folded[existing.id, default: [existing.id]].append(event.id)
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
        return (result, folded)
    }
}
