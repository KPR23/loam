import Foundation

protocol ActivityRepository: Sendable {
    /// Unread events older than the row `cursor` names (an `ActivityPage.nextCursor`), newest first.
    /// Own actions are never unread, and a newer event about the same expense or repayment reads the older ones.
    func fetchUnreadEvents(for userId: UUID, before cursor: UUID?) async throws -> ActivityPage
    /// One expense's history visible to `userId`, oldest first.
    func fetchExpenseEvents(expenseId: UUID, userId: UUID) async throws -> [ActivityEvent]
    func record(_ event: ActivityEvent, audience: [UUID]) async throws
    /// Unread events `userId` hasn't seen yet; the tab and app icon badge show it.
    func unseenCount(for userId: UUID) async throws -> Int
    /// Unread events up to `through` stop counting toward the badge but stay unread.
    func markSeen(_ eventIds: [UUID], userId: UUID) async throws
    /// IDs that are not `userId`'s events are ignored.
    func markRead(_ eventIds: [UUID], userId: UUID) async throws
}

enum ActivityRepositoryFactory {
    static func make() -> any ActivityRepository {
        ExpenseRepositoryFactory.usesLocalStorage ? LocalActivityRepository() : SupabaseActivityRepository(client: SupabaseClientProvider.shared!)
    }
}
