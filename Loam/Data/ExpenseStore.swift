import Foundation

@MainActor
final class ExpenseStore: ObservableObject {
    @Published private(set) var expenses: [ExpenseRecord] = []
    @Published private(set) var pendingProposals: [ExpenseEditProposal] = []
    @Published private(set) var summary: MonthSpendSummary = .zero()
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    @Published private(set) var period: DatePeriod = .currentMonth

    var pendingAcceptanceExpenses: [ExpenseRecord] {
        expenses.filter { expense in
            guard let userId = currentUserId else { return false }
            return expense.isPendingAcceptance(for: userId)
        }
    }

    private var currentUserId: UUID?

    func setPeriod(_ newPeriod: DatePeriod, userId: UUID?) async {
        guard period != newPeriod else { return }
        period = newPeriod
        await refresh(userId: userId)
    }

    func refresh(userId: UUID?) async {
        currentUserId = userId
        guard let userId else {
            expenses = []
            pendingProposals = []
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
                if let localExpenses = try? await LocalExpenseRepository().fetchExpenses(for: userId, in: period) {
                    let existingIds = Set(fetched.map(\.id))
                    fetched.append(contentsOf: localExpenses.filter { !existingIds.contains($0.id) })
                    fetched.sort {
                        $0.spentAt > $1.spentAt || ($0.spentAt == $1.spentAt && $0.createdAt > $1.createdAt)
                    }
                }
            }
            #endif
            expenses = fetched
            summary = Self.makeSummary(expenses: fetched, userId: userId)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        pendingProposals = (try? await primaryRepository.fetchPendingProposals(for: userId)) ?? []
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

        let calculatedShares = SplitCalculator.split(
            totalMinor: amountMinor,
            mode: splitMode,
            myUserId: userId,
            partnerUserIds: partnerUserIds,
            paidByUserId: paidBy,
            myPercentage: myPercentage,
            myExactAmountMinor: myExactAmountMinor
        )

        let draft = ExpenseRecord(
            amountMinor: amountMinor,
            category: category,
            note: trimmedNote,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: userId,
            householdId: householdId,
            shares: []
        )

        let activeRepository = repository(forSplitWith: partnerUserIds)
        let usersTrustingCreator = await usersTrusting(
            creatorId: userId,
            partnerUserIds: partnerUserIds,
            householdId: householdId,
            repository: activeRepository
        )
        let shareRecords = ExpenseShareAcceptance.sharesWithAcceptance(
            calculatedShares: calculatedShares,
            expense: draft,
            usersTrustingCreator: usersTrustingCreator
        )

        let expense = ExpenseRecord(
            amountMinor: amountMinor,
            category: category,
            note: trimmedNote,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: userId,
            householdId: householdId,
            shares: shareRecords
        )
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
        let activeRepository = repository(forSplitWith: partnerUserIds)
        let usersTrustingCreator = await usersTrusting(
            creatorId: userId,
            partnerUserIds: partnerUserIds,
            householdId: householdId,
            repository: activeRepository
        )
        expense.shares = ExpenseShareAcceptance.sharesWithAcceptance(
            calculatedShares: shares,
            expense: expense,
            usersTrustingCreator: usersTrustingCreator
        )
        expense.updatedAt = Date()

        _ = try await activeRepository.update(expense)
        await refresh(userId: userId)
    }

    func respondToShare(
        expenseId: UUID,
        userId: UUID,
        action: ExpenseShareResponseAction
    ) async {
        do {
            guard let expense = expenses.first(where: { $0.id == expenseId }) else {
                throw ExpenseRepositoryError.notFound
            }
            let activeRepository = repository(for: expense)
            try await activeRepository.respondToShare(expenseId: expenseId, userId: userId, action: action)
            await refresh(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func proposeEdit(
        for expense: ExpenseRecord,
        userId: UUID,
        amountMinor: Int,
        category: ExpenseCategory,
        note: String?,
        spentAt: Date,
        paidBy: UUID,
        shares: [ExpenseShareRecord],
        message: String?
    ) async throws {
        let proposal = ExpenseEditProposal(
            expenseId: expense.id,
            proposedBy: userId,
            amountMinor: amountMinor,
            category: category,
            note: note,
            spentAt: spentAt,
            paidBy: paidBy,
            shares: shares,
            message: message
        )
        let activeRepository = repository(for: expense)
        _ = try await activeRepository.createEditProposal(proposal, expenseId: expense.id)
        await refresh(userId: userId)
    }

    func respondToProposal(proposalId: UUID, userId: UUID, accept: Bool) async {
        do {
            let expenseId = pendingProposals.first(where: { $0.id == proposalId })?.expenseId
            let activeRepository = expenseId.flatMap { id in expenses.first(where: { $0.id == id }).map { repository(for: $0) } }
                ?? primaryRepository
            try await activeRepository.respondToProposal(proposalId: proposalId, accept: accept)
            await refresh(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pendingProposals(for expenseId: UUID, userId: UUID) -> [ExpenseEditProposal] {
        pendingProposals.filter { proposal in
            proposal.expenseId == expenseId
                && proposal.status == .pending
                && (proposal.proposedBy != userId || expenses.contains(where: { $0.id == expenseId && $0.createdBy == userId }))
        }
    }

    func incomingProposals(for userId: UUID) -> [ExpenseEditProposal] {
        pendingProposals.filter { proposal in
            guard proposal.status == .pending else { return false }
            guard let expense = expenses.first(where: { $0.id == proposal.expenseId }) else { return false }
            return expense.createdBy == userId
        }
    }

    private func usersTrusting(
        creatorId: UUID,
        partnerUserIds: [UUID],
        householdId: UUID,
        repository: ExpenseRepository
    ) async -> Set<UUID> {
        var trusting: Set<UUID> = []
        for partnerId in partnerUserIds where partnerId != creatorId {
            let trustedCreators = (try? await repository.fetchTrustedUserIds(for: partnerId, householdId: householdId)) ?? []
            if trustedCreators.contains(creatorId) {
                trusting.insert(partnerId)
            }
        }
        return trusting
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
        if usesLocalRepository(for: expense) {
            return LocalExpenseRepository()
        }
        return primaryRepository
    }

    private func usesLocalRepository(for expense: ExpenseRecord) -> Bool {
        #if DEBUG
        if ExpenseRepositoryFactory.usesLocalStorage {
            return true
        }
        let partnerIds = expense.shares.map(\.userId).filter { $0 != expense.createdBy }
        return SplitPartnerOption.shouldUseLocalSimulation(for: partnerIds)
        #else
        return false
        #endif
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
            let mine = expense.acceptedShareMinor(for: userId)
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
