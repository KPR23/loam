import Foundation

@MainActor
final class ExpenseStore: ObservableObject {
    @Published private(set) var expenses: [ExpenseRecord] = []
    @Published private(set) var summary: MonthSpendSummary = .zero()
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let repository: ExpenseRepository
    @Published private(set) var period: DatePeriod = .currentMonth

    init(repository: ExpenseRepository = ExpenseRepositoryFactory.make()) {
        self.repository = repository
    }

    func setPeriod(_ newPeriod: DatePeriod, userId: UUID?) async {
        guard period != newPeriod else { return }
        period = newPeriod
        await refresh(userId: userId)
    }

    func refresh(userId: UUID?) async {
        guard let userId else {
            expenses = []
            summary = .zero()
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let fetched = try await repository.fetchExpenses(for: userId, in: period)
            expenses = fetched
            summary = Self.makeSummary(expenses: fetched, userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addPersonal(
        amountMinor: Int,
        category: ExpenseCategory,
        note: String?,
        spentAt: Date,
        userId: UUID,
        recurring: RecurringRuleRecord? = nil
    ) async throws {
        let trimmedNote = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let recurringRule: RecurringRuleRecord?
        if var rule = recurring {
            rule.note = trimmedNote
            recurringRule = try await repository.createRecurringRule(rule)
        } else {
            recurringRule = nil
        }

        let shares = SplitCalculator.personal(totalMinor: amountMinor, userId: userId)
        let expense = ExpenseRecord(
            amountMinor: amountMinor,
            category: category,
            note: trimmedNote,
            spentAt: spentAt,
            paidBy: userId,
            createdBy: userId,
            householdId: nil,
            recurringId: recurringRule?.id,
            shares: shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) }
        )
        _ = try await repository.create(expense)
        await refresh(userId: userId)
    }

    func delete(id: UUID, userId: UUID) async {
        do {
            try await repository.delete(id: id)
            await refresh(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated static func makeSummary(
        expenses: [ExpenseRecord],
        userId: UUID,
        currency: String = "PLN"
    ) -> MonthSpendSummary {
        var total = 0
        var shared = 0
        for expense in expenses {
            let mine = expense.shares.first(where: { $0.userId == userId })?.amountMinor ?? 0
            total += mine
            if expense.householdId != nil {
                shared += mine
            }
        }
        return MonthSpendSummary(
            totalMine: Money(amountMinor: total, currencyCode: currency),
            sharedShare: Money(amountMinor: shared, currencyCode: currency)
        )
    }
}
