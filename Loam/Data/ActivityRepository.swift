import Foundation

protocol ActivityRepository: Sendable {
    func fetchEvents(for userId: UUID, before: ActivityEvent?) async throws -> ActivityPage
    func record(_ event: ActivityEvent, audience: [UUID]) async throws
}

enum ActivityRepositoryFactory {
    static func make() -> any ActivityRepository {
        ExpenseRepositoryFactory.usesLocalStorage ? LocalActivityRepository() : SupabaseActivityRepository(client: SupabaseClientProvider.shared!)
    }
}
