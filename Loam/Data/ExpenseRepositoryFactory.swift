import Foundation

enum ExpenseRepositoryFactory {
    private static let lock = NSLock()
    private static var demoModeEnabled = false

    static var usesLocalStorage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return demoModeEnabled || SupabaseClientProvider.shared == nil
    }

    static func make() -> any ExpenseRepository {
        if usesLocalStorage {
            return LocalExpenseRepository()
        }
        return SupabaseExpenseRepository(client: SupabaseClientProvider.shared!)
    }

    static func setUsesLocalStorage(_ value: Bool) {
        lock.lock()
        demoModeEnabled = value
        lock.unlock()
    }
}
