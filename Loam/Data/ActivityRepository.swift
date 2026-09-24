import Foundation

protocol ActivityRepository: Sendable {
    /// Events older than the row `cursor` names (an `ActivityPage.nextCursor`), newest first.
    func fetchEvents(for userId: UUID, before cursor: UUID?) async throws -> ActivityPage
    /// One expense's history visible to `userId`, oldest first.
    func fetchExpenseEvents(expenseId: UUID, userId: UUID) async throws -> [ActivityEvent]
    func record(_ event: ActivityEvent, audience: [UUID]) async throws
}

enum ActivityRepositoryFactory {
    static func make() -> any ActivityRepository {
        ExpenseRepositoryFactory.usesLocalStorage ? LocalActivityRepository() : SupabaseActivityRepository(client: SupabaseClientProvider.shared!)
    }
}
