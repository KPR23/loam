import Foundation

enum ExpenseRepositoryFactory {
    private static let demoModeKey = "loam.demo.active"

    static var usesLocalStorage: Bool {
        UserDefaults.standard.bool(forKey: demoModeKey)
            || SupabaseClientProvider.shared == nil
    }

    static func make() -> any ExpenseRepository {
        if usesLocalStorage {
            return LocalExpenseRepository()
        }
        return SupabaseExpenseRepository(client: SupabaseClientProvider.shared!)
    }

    static func setUsesLocalStorage(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: demoModeKey)
    }
}
