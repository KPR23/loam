import Foundation

protocol ExpenseRepository: Sendable {
    func fetchExpenses(for userId: UUID, in period: DatePeriod) async throws -> [ExpenseRecord]
    func fetchExpenses(ids: [UUID]) async throws -> [ExpenseRecord]
    func create(_ expense: ExpenseRecord) async throws -> ExpenseRecord
    func createRecurringRule(_ rule: RecurringRuleRecord) async throws -> RecurringRuleRecord
    func updateRecurringRule(_ rule: RecurringRuleRecord) async throws -> RecurringRuleRecord
    func fetchActiveRecurringRules(for userId: UUID) async throws -> [RecurringRuleRecord]
    func fetchRecurringRule(id: UUID) async throws -> RecurringRuleRecord?
    func fetchLatestExpense(forRecurringId recurringId: UUID) async throws -> ExpenseRecord?
    func hasExpense(recurringId: UUID, spentAt: Date) async throws -> Bool
    func update(_ expense: ExpenseRecord) async throws -> ExpenseRecord
    func delete(id: UUID) async throws
    #if DEBUG
    /// Removes expenses (and owned recurring rules) created by `userId` only.
    func deleteAllCreatedBy(_ userId: UUID) async throws
    #endif
    func deleteFutureRecurringExpenses(recurringId: UUID, after date: Date) async throws
    func respondToShare(expenseId: UUID, userId: UUID, action: ExpenseShareResponseAction) async throws
    func fetchPendingProposals(for userId: UUID) async throws -> [ExpenseEditProposal]
    func createEditProposal(_ proposal: ExpenseEditProposal, expenseId: UUID) async throws -> ExpenseEditProposal
    func respondToProposal(proposalId: UUID, accept: Bool) async throws
    func fetchTrustedUserIds(for userId: UUID, householdId: UUID) async throws -> Set<UUID>
    func addTrust(for userId: UUID, trustedUserId: UUID, householdId: UUID) async throws
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
