import Foundation

@MainActor
final class ActivityStore: ObservableObject {
    /// Unread events only; read ones live on in each expense's history.
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = false
    @Published var lastError: String? {
        // Every failure reaches the person as a toast, wherever they are in the app.
        didSet {
            guard let lastError, lastError != oldValue else { return }
            let userId = accountId
            ToastCenter.shared.showError(lastError, action: Toast.Action(title: "Retry") { [weak self] in
                Task { await self?.refresh(userId: userId) }
            })
        }
    }
    /// Unread events not seen yet; drives the tab and app icon badges.
    @Published private(set) var badgeCount = 0
    /// While Activity is on screen, every refresh marks what it loaded as seen.
    var isInboxVisible = false
    private var accountId: UUID?
    private var nextCursor: UUID?
    /// Rows folded into a shown event, so marking it read reads all of them.
    private var foldedIds: [UUID: [UUID]] = [:]
    /// Bumped by each refresh so a page fetched before it can't land on the new list.
    private var generation = 0

    func refreshBadgeCount(userId: UUID?) async {
        guard let userId else { badgeCount = 0; return }
        guard let count = try? await ActivityRepositoryFactory.make().unseenCount(for: userId), accountId == nil || accountId == userId else { return }
        badgeCount = count
    }

    /// Opening Activity clears the badge; the events stay until they are marked read.
    /// Only events already loaded count as seen, so ones on later pages keep the badge up.
    func markSeen(userId: UUID) async {
        guard accountId == userId else { return }
        let ids = events.flatMap { foldedIds[$0.id] ?? [$0.id] }
        guard !ids.isEmpty else { return await refreshBadgeCount(userId: userId) }
        if !canLoadMore { badgeCount = 0 }
        try? await ActivityRepositoryFactory.make().markSeen(ids, userId: userId)
        await refreshBadgeCount(userId: userId)
    }

    func refresh(userId: UUID?) async {
        guard let userId else {
            accountId = nil; events = []; foldedIds = [:]; canLoadMore = false; nextCursor = nil; lastError = nil; badgeCount = 0
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
        } catch { guard accountId == userId else { return }; lastError = UserFacingError.message(for: error) }
        if isInboxVisible { await markSeen(userId: userId) } else { await refreshBadgeCount(userId: userId) }
    }

    func loadMore(userId: UUID) async {
        guard !isLoading, canLoadMore, let cursor = nextCursor else { return }; isLoading = true
        let current = generation
        defer { if generation == current { isLoading = false } }
        do { let page = try await ActivityRepositoryFactory.make().fetchUnreadEvents(for: userId, before: cursor); guard accountId == userId, generation == current else { return }; setEvents(events + page.events, keepingFolds: true); nextCursor = page.nextCursor; canLoadMore = page.hasMore && page.nextCursor != nil } catch { guard generation == current else { return }; lastError = UserFacingError.message(for: error) }
        if isInboxVisible, generation == current { await markSeen(userId: userId) }
    }

    /// Takes the events out of the inbox right away; a failed save puts them back.
    func markRead(_ read: [ActivityEvent], userId: UUID) async {
        guard accountId == userId, !read.isEmpty else { return }
        let ids = Set(read.map(\.id))
        let rowIds = ids.flatMap { foldedIds[$0] ?? [$0] }
        events.removeAll { ids.contains($0.id) }
        do {
            try await ActivityRepositoryFactory.make().markRead(rowIds, userId: userId)
            await PushNotificationStore.shared.clearDelivered(eventIds: rowIds)
            await refreshBadgeCount(userId: userId)
        } catch {
            guard accountId == userId else { return }
            lastError = UserFacingError.message(for: error)
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
