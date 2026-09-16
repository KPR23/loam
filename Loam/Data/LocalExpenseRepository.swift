import Foundation

/// On-device store for demo mode and offline Phase 1. Swapped for Supabase when configured.
actor LocalExpenseRepository: ExpenseRepository {
    private let defaultsKey = "loam.local.expenses"
    private let recurringDefaultsKey = "loam.local.recurring"
    private let proposalsDefaultsKey = "loam.local.proposals"
    private let trustDefaultsKey = "loam.local.trust"
    private var cache: [ExpenseRecord]?
    private var recurringCache: [RecurringRuleRecord]?
    private var proposalsCache: [ExpenseEditProposal]?
    private var trustCache: [LocalTrustRecord]?

    func fetchExpenses(for userId: UUID, in period: DatePeriod) async throws -> [ExpenseRecord] {
        let all = try load()
        let (start, endExclusive) = period.dateRange
        return all
            .filter { expense in
                guard let share = expense.shareRecord(for: userId) else { return false }
                return share.status != .rejected
                    && expense.spentAt >= start
                    && expense.spentAt < endExclusive
            }
            .sorted { $0.spentAt > $1.spentAt || ($0.spentAt == $1.spentAt && $0.createdAt > $1.createdAt) }
    }

    func fetchExpenses(ids: [UUID]) async throws -> [ExpenseRecord] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        return try load().filter { wanted.contains($0.id) }
    }

    func create(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        try validate(expense)
        var all = try load()
        all.append(expense)
        try save(all)
        return expense
    }

    func createRecurringRule(_ rule: RecurringRuleRecord) async throws -> RecurringRuleRecord {
        var all = try loadRecurring()
        all.append(rule)
        try saveRecurring(all)
        return rule
    }

    func updateRecurringRule(_ rule: RecurringRuleRecord) async throws -> RecurringRuleRecord {
        var all = try loadRecurring()
        guard let index = all.firstIndex(where: { $0.id == rule.id }) else {
            throw ExpenseRepositoryError.notFound
        }
        all[index] = rule
        try saveRecurring(all)
        return rule
    }

    func fetchActiveRecurringRules(for userId: UUID) async throws -> [RecurringRuleRecord] {
        try loadRecurring().filter { $0.ownerUserId == userId && $0.isActive }
    }

    func fetchRecurringRule(id: UUID) async throws -> RecurringRuleRecord? {
        try loadRecurring().first { $0.id == id }
    }

    func fetchLatestExpense(forRecurringId recurringId: UUID) async throws -> ExpenseRecord? {
        try load()
            .filter { $0.recurringId == recurringId }
            .sorted {
                $0.spentAt > $1.spentAt || ($0.spentAt == $1.spentAt && $0.createdAt > $1.createdAt)
            }
            .first
    }

    func hasExpense(recurringId: UUID, spentAt: Date) async throws -> Bool {
        let day = Calendar.current.startOfDay(for: spentAt)
        return try load().contains {
            $0.recurringId == recurringId && Calendar.current.isDate($0.spentAt, inSameDayAs: day)
        }
    }

    func update(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        try validate(expense)
        var all = try load()
        guard let index = all.firstIndex(where: { $0.id == expense.id }) else {
            throw ExpenseRepositoryError.notFound
        }
        var updated = expense
        updated.updatedAt = Date()
        all[index] = updated
        try save(all)
        return updated
    }

    func delete(id: UUID) async throws {
        var all = try load()
        let before = all.count
        all.removeAll { $0.id == id }
        guard all.count < before else { throw ExpenseRepositoryError.notFound }
        try save(all)

        var proposals = try loadProposals()
        proposals.removeAll { $0.expenseId == id }
        try saveProposals(proposals)
    }

    #if DEBUG
    func deleteAllCreatedBy(_ userId: UUID) async throws {
        var all = try load()
        let removedIds = Set(all.filter { $0.createdBy == userId }.map(\.id))
        all.removeAll { $0.createdBy == userId }
        try save(all)

        var recurring = try loadRecurring()
        recurring.removeAll { $0.ownerUserId == userId }
        try saveRecurring(recurring)

        var proposals = try loadProposals()
        proposals.removeAll { removedIds.contains($0.expenseId) }
        try saveProposals(proposals)
    }
    #endif

    func deleteFutureRecurringExpenses(recurringId: UUID, after date: Date) async throws {
        let calendar = Calendar.current
        let cutoff = calendar.startOfDay(for: date)
        var all = try load()
        let removedIds = Set(all.filter {
            $0.recurringId == recurringId
                && calendar.startOfDay(for: $0.spentAt) > cutoff
        }.map(\.id))
        guard !removedIds.isEmpty else { return }

        all.removeAll { removedIds.contains($0.id) }
        try save(all)

        var proposals = try loadProposals()
        proposals.removeAll { removedIds.contains($0.expenseId) }
        try saveProposals(proposals)
    }

    func respondToShare(expenseId: UUID, userId: UUID, action: ExpenseShareResponseAction) async throws {
        var all = try load()
        guard let index = all.firstIndex(where: { $0.id == expenseId }) else {
            throw ExpenseRepositoryError.notFound
        }

        // Only this participant's share — never mutate other users' statuses.
        guard let shareIndex = all[index].shares.firstIndex(where: { $0.userId == userId }) else {
            throw ExpenseRepositoryError.notFound
        }
        guard all[index].shares[shareIndex].status == .pending else {
            throw ExpenseRepositoryError.notFound
        }

        var updatedShares = all[index].shares
        switch action {
        case .reject:
            updatedShares[shareIndex].status = .rejected
            updatedShares[shareIndex].respondedAt = Date()
            updatedShares[shareIndex].acceptedViaTrust = false
        case .accept, .acceptWithTrust:
            updatedShares[shareIndex].status = .accepted
            updatedShares[shareIndex].respondedAt = Date()
            // Manual accept — even with trust opt-in — is not "accepted via trust".
            updatedShares[shareIndex].acceptedViaTrust = false
            if action == .acceptWithTrust, let householdId = all[index].householdId {
                try await addTrust(
                    for: userId,
                    trustedUserId: all[index].createdBy,
                    householdId: householdId
                )
            }
        }
        all[index].shares = updatedShares
        all[index].updatedAt = Date()

        try save(all)
    }

    func fetchPendingProposals(for userId: UUID) async throws -> [ExpenseEditProposal] {
        try loadProposals().filter { $0.status == .pending }
    }

    func createEditProposal(_ proposal: ExpenseEditProposal, expenseId: UUID) async throws -> ExpenseEditProposal {
        var proposals = try loadProposals()
        proposals.removeAll {
            $0.expenseId == expenseId && $0.proposedBy == proposal.proposedBy && $0.status == .pending
        }
        proposals.append(proposal)
        try saveProposals(proposals)
        return proposal
    }

    func respondToProposal(proposalId: UUID, accept: Bool) async throws {
        var proposals = try loadProposals()
        guard let proposalIndex = proposals.firstIndex(where: { $0.id == proposalId && $0.status == .pending }) else {
            throw ExpenseRepositoryError.notFound
        }

        var proposal = proposals[proposalIndex]
        var all = try load()
        guard let expenseIndex = all.firstIndex(where: { $0.id == proposal.expenseId }) else {
            throw ExpenseRepositoryError.notFound
        }

        let householdId = all[expenseIndex].householdId
        let createdBy = all[expenseIndex].createdBy

        proposal.status = accept ? .accepted : .rejected
        proposal.respondedAt = Date()
        proposals[proposalIndex] = proposal

        if accept {
            let proposerIsParticipant = all[expenseIndex].shares.contains { $0.userId == proposal.proposedBy }
            guard householdId != nil, proposal.proposedBy != createdBy, proposerIsParticipant else {
                throw ExpenseRepositoryError.notFound
            }

            var usersTrustingCreator: Set<UUID> = []
            if let householdId {
                for share in proposal.shares where share.userId != createdBy {
                    let trustedCreators = (try? await fetchTrustedUserIds(for: share.userId, householdId: householdId)) ?? []
                    if trustedCreators.contains(createdBy) {
                        usersTrustingCreator.insert(share.userId)
                    }
                }
            }

            all[expenseIndex].amountMinor = proposal.amountMinor
            all[expenseIndex].category = proposal.category
            all[expenseIndex].title = proposal.title
            all[expenseIndex].note = proposal.note
            all[expenseIndex].location = proposal.location
            all[expenseIndex].spentAt = proposal.spentAt
            all[expenseIndex].paidBy = proposal.paidBy
            all[expenseIndex].shares = proposal.shares.map { share in
                let status = ExpenseShareAcceptance.statusForShare(
                    userId: share.userId,
                    createdBy: createdBy,
                    householdId: householdId,
                    usersTrustingCreator: usersTrustingCreator
                )
                return ExpenseShareRecord(
                    id: share.id,
                    userId: share.userId,
                    amountMinor: share.amountMinor,
                    status: status,
                    respondedAt: status == .accepted ? Date() : nil,
                    acceptedViaTrust: status == .accepted && usersTrustingCreator.contains(share.userId)
                )
            }
            all[expenseIndex].updatedAt = Date()
            try save(all)

            for index in proposals.indices where proposals[index].expenseId == proposal.expenseId && proposals[index].status == .pending && proposals[index].id != proposalId {
                proposals[index].status = .rejected
                proposals[index].respondedAt = Date()
            }
        }

        try saveProposals(proposals)
    }

    func fetchTrustedUserIds(for userId: UUID, householdId: UUID) async throws -> Set<UUID> {
        Set(
            try loadTrust()
                .filter { $0.userId == userId && $0.householdId == householdId }
                .map(\.trustedUserId)
        )
    }

    func addTrust(for userId: UUID, trustedUserId: UUID, householdId: UUID) async throws {
        var trust = try loadTrust()
        let record = LocalTrustRecord(userId: userId, trustedUserId: trustedUserId, householdId: householdId)
        guard !trust.contains(record) else { return }
        trust.append(record)
        try saveTrust(trust)
    }

    private func validate(_ expense: ExpenseRecord) throws {
        let sum = expense.shares.reduce(0) { $0 + $1.amountMinor }
        guard sum == expense.amountMinor else {
            throw ExpenseRepositoryError.invalidShares
        }
    }

    private func load() throws -> [ExpenseRecord] {
        // Always reload from UserDefaults so separate repository instances
        // (e.g. after switching test accounts) see each other's share updates.
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            cache = []
            return []
        }
        do {
            let decoded = try JSONDecoder().decode([ExpenseRecord].self, from: data)
            cache = decoded
            return decoded
        } catch {
            // Drop incompatible cached payloads instead of blocking the whole app.
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            cache = []
            return []
        }
    }

    private func save(_ expenses: [ExpenseRecord]) throws {
        let data = try JSONEncoder().encode(expenses)
        UserDefaults.standard.set(data, forKey: defaultsKey)
        cache = expenses
    }

    private func loadRecurring() throws -> [RecurringRuleRecord] {
        if let recurringCache { return recurringCache }
        guard let data = UserDefaults.standard.data(forKey: recurringDefaultsKey) else {
            recurringCache = []
            return []
        }
        let decoded = try JSONDecoder().decode([RecurringRuleRecord].self, from: data)
        recurringCache = decoded
        return decoded
    }

    private func saveRecurring(_ rules: [RecurringRuleRecord]) throws {
        let data = try JSONEncoder().encode(rules)
        UserDefaults.standard.set(data, forKey: recurringDefaultsKey)
        recurringCache = rules
    }

    private func loadProposals() throws -> [ExpenseEditProposal] {
        if let proposalsCache { return proposalsCache }
        guard let data = UserDefaults.standard.data(forKey: proposalsDefaultsKey) else {
            proposalsCache = []
            return []
        }
        let decoded = try JSONDecoder().decode([ExpenseEditProposal].self, from: data)
        proposalsCache = decoded
        return decoded
    }

    private func saveProposals(_ proposals: [ExpenseEditProposal]) throws {
        let data = try JSONEncoder().encode(proposals)
        UserDefaults.standard.set(data, forKey: proposalsDefaultsKey)
        proposalsCache = proposals
    }

    private func loadTrust() throws -> [LocalTrustRecord] {
        if let trustCache { return trustCache }
        guard let data = UserDefaults.standard.data(forKey: trustDefaultsKey) else {
            trustCache = []
            return []
        }
        let decoded = try JSONDecoder().decode([LocalTrustRecord].self, from: data)
        trustCache = decoded
        return decoded
    }

    private func saveTrust(_ trust: [LocalTrustRecord]) throws {
        let data = try JSONEncoder().encode(trust)
        UserDefaults.standard.set(data, forKey: trustDefaultsKey)
        trustCache = trust
    }
}

private struct LocalTrustRecord: Codable, Hashable {
    var userId: UUID
    var trustedUserId: UUID
    var householdId: UUID
}
