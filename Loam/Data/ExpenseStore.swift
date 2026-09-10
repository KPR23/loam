import Foundation

@MainActor
final class ExpenseStore: ObservableObject {
    @Published private(set) var expenses: [ExpenseRecord] = []
    @Published private(set) var summary: MonthSpendSummary = .zero()
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    @Published private(set) var period: DatePeriod = .currentMonth

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
            var fetched = try await primaryRepository.fetchExpenses(for: userId, in: period)
            #if DEBUG
            if !ExpenseRepositoryFactory.usesLocalStorage {
                let localExpenses = try await LocalExpenseRepository().fetchExpenses(for: userId, in: period)
                let existingIds = Set(fetched.map(\.id))
                fetched.append(contentsOf: localExpenses.filter { !existingIds.contains($0.id) })
                fetched.sort {
                    $0.spentAt > $1.spentAt || ($0.spentAt == $1.spentAt && $0.createdAt > $1.createdAt)
                }
            }
            #endif
            expenses = fetched
            summary = Self.makeSummary(expenses: fetched, userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addSplit(
        amountMinor: Int,
        category: ExpenseCategory,
        note: String?,
        spentAt: Date,
        userId: UUID,
        householdId: UUID,
        splitMode: SplitExpenseMode,
        paidBy: UUID,
        partnerUserIds: [UUID],
        myPercentage: Int = 50,
        myExactAmountMinor: Int? = nil
    ) async throws {
        let trimmedNote = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        let shares = SplitCalculator.split(
            totalMinor: amountMinor,
            mode: splitMode,
            myUserId: userId,
            partnerUserIds: partnerUserIds,
            paidByUserId: paidBy,
            myPercentage: myPercentage,
            myExactAmountMinor: myExactAmountMinor
        )

        let expense = ExpenseRecord(
            amountMinor: amountMinor,
            category: category,
            note: trimmedNote,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: userId,
            householdId: householdId,
            shares: shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) }
        )
        let activeRepository = repository(forSplitWith: partnerUserIds)
        _ = try await activeRepository.create(expense)
        await refresh(userId: userId)
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
        let activeRepository = primaryRepository

        let recurringRule: RecurringRuleRecord?
        if var rule = recurring {
            rule.note = trimmedNote
            recurringRule = try await activeRepository.createRecurringRule(rule)
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
        _ = try await activeRepository.create(expense)
        await refresh(userId: userId)
    }

    func delete(id: UUID, userId: UUID) async {
        do {
            if let expense = expenses.first(where: { $0.id == id }) {
                let activeRepository = repository(for: expense)
                try await activeRepository.delete(id: id)
            } else {
                try await primaryRepository.delete(id: id)
            }
            await refresh(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applySplit(
        to expenseId: UUID,
        userId: UUID,
        householdId: UUID,
        splitMode: SplitExpenseMode,
        paidBy: UUID,
        partnerUserIds: [UUID],
        myPercentage: Int = 50,
        myExactAmountMinor: Int? = nil
    ) async throws {
        guard var expense = expenses.first(where: { $0.id == expenseId }) else {
            throw ExpenseRepositoryError.notFound
        }

        let shares = SplitCalculator.split(
            totalMinor: expense.amountMinor,
            mode: splitMode,
            myUserId: userId,
            partnerUserIds: partnerUserIds,
            paidByUserId: paidBy,
            myPercentage: myPercentage,
            myExactAmountMinor: myExactAmountMinor
        )

        expense.householdId = householdId
        expense.paidBy = paidBy
        expense.shares = shares.map { share in
            let existingId = expense.shares.first(where: { $0.userId == share.userId })?.id ?? UUID()
            return ExpenseShareRecord(id: existingId, userId: share.userId, amountMinor: share.amountMinor)
        }
        expense.updatedAt = Date()

        let activeRepository = repository(forSplitWith: partnerUserIds)
        _ = try await activeRepository.update(expense)
        await refresh(userId: userId)
    }

    private var primaryRepository: ExpenseRepository {
        ExpenseRepositoryFactory.make()
    }

    private func repository(forSplitWith partnerUserIds: [UUID]) -> ExpenseRepository {
        #if DEBUG
        if ExpenseRepositoryFactory.usesLocalStorage || SplitPartnerOption.shouldUseLocalSimulation(for: partnerUserIds) {
            return LocalExpenseRepository()
        }
        #endif
        return primaryRepository
    }

    private func repository(for expense: ExpenseRecord) -> ExpenseRepository {
        #if DEBUG
        let partnerIds = expense.shares.map(\.userId).filter { $0 != expense.createdBy }
        if ExpenseRepositoryFactory.usesLocalStorage
            || expense.householdId != nil
            || SplitPartnerOption.shouldUseLocalSimulation(for: partnerIds)
            || TestAccount.contains(userId: expense.createdBy) {
            return LocalExpenseRepository()
        }
        #endif
        return primaryRepository
    }

    nonisolated static func makeSummary(
        expenses: [ExpenseRecord],
        userId: UUID,
        currency: String = "PLN"
    ) -> MonthSpendSummary {
        var total = 0
        var shared = 0
        var byCategory: [ExpenseCategory: Int] = [:]
        for expense in expenses {
            let mine = expense.shares.first(where: { $0.userId == userId })?.amountMinor ?? 0
            total += mine
            if mine > 0 {
                byCategory[expense.category, default: 0] += mine
            }
            if expense.householdId != nil {
                shared += mine
            }
        }
        let categoryBreakdown = byCategory
            .map { CategorySpendSlice(category: $0.key, amountMinor: $0.value) }
            .sorted { lhs, rhs in
                if lhs.amountMinor != rhs.amountMinor {
                    return lhs.amountMinor > rhs.amountMinor
                }
                return lhs.category.displayName < rhs.category.displayName
            }
        return MonthSpendSummary(
            totalMine: Money(amountMinor: total, currencyCode: currency),
            sharedShare: Money(amountMinor: shared, currencyCode: currency),
            categoryBreakdown: categoryBreakdown
        )
    }
}
