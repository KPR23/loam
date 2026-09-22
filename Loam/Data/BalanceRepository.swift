import Foundation

protocol BalanceRepository: Sendable {
    func fetchBalances(for userId: UUID) async throws -> BalanceSnapshot
    func fetchHistory(for userId: UUID, personId: UUID) async throws -> [BalanceHistoryEntry]
    func createRepayment(from userId: UUID, to personId: UUID, amountMinor: Int, currencyCode: String, note: String?, paidAt: Date, operationId: UUID) async throws
    func reverseRepayment(id: UUID, operationId: UUID) async throws
}

enum BalanceRepositoryError: LocalizedError {
    case invalidAmount
    case exceedsDebt

    var errorDescription: String? {
        switch self {
        case .invalidAmount: return "Enter a positive amount."
        case .exceedsDebt: return "That payment is larger than the confirmed debt."
        }
    }
}

enum BalanceRepositoryFactory {
    static func make() -> any BalanceRepository {
        if ExpenseRepositoryFactory.usesLocalStorage { return LocalBalanceRepository() }
        return SupabaseBalanceRepository(client: SupabaseClientProvider.shared!)
    }
}
