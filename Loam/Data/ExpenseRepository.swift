import Foundation

protocol ExpenseRepository: Sendable {
    func fetchExpenses(for userId: UUID, in period: DatePeriod) async throws -> [ExpenseRecord]
    func create(_ expense: ExpenseRecord) async throws -> ExpenseRecord
    func update(_ expense: ExpenseRecord) async throws -> ExpenseRecord
    func delete(id: UUID) async throws
}

enum ExpenseRepositoryError: LocalizedError {
    case notFound
    case invalidShares
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notFound: return "Expense not found."
        case .invalidShares: return "Shares must sum to the expense total."
        case .notSignedIn: return "Sign in to manage expenses."
        }
    }
}
