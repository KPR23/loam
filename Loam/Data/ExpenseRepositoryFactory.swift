import Foundation

enum ExpenseRepositoryFactory {
    static func make() -> any ExpenseRepository {
        if let client = SupabaseClientProvider.shared {
            return SupabaseExpenseRepository(client: client)
        }
        return LocalExpenseRepository()
    }
}
