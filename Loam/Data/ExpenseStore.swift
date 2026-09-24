import Foundation

@MainActor
final class ExpenseStore: ObservableObject {
    @Published private(set) var expenses: [ExpenseRecord] = []
    @Published private(set) var pendingProposals: [ExpenseEditProposal] = []
    /// Expenses referenced by pending proposals that fall outside the active period.
    @Published private(set) var proposalExpenses: [ExpenseRecord] = []
    /// The user's rules the server could not generate a due occurrence for.
    @Published private(set) var failingRecurringRules: [RecurringRuleRecord] = []
    @Published private(set) var summary: MonthSpendSummary = .zero()
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    @Published private(set) var period: DatePeriod = .currentMonth

    /// `recurringId` → rule `startDate` for expenses in the active period (drives first-occurrence highlight).
    private var recurringStartDatesById: [UUID: Date] = [:]

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
            proposalExpenses = []
            failingRecurringRules = []
            recurringStartDatesById = [:]
            summary = .zero()
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            try await materializeDueRecurring(userId: userId, repository: primaryRepository)
            let fetched = try await primaryRepository.fetchExpenses(for: userId, in: period)
            expenses = fetched
            summary = Self.makeSummary(expenses: fetched, userId: userId)
            recurringStartDatesById = await loadRecurringStartDates(for: fetched)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        let rules = (try? await primaryRepository.fetchActiveRecurringRules(for: userId)) ?? []
        failingRecurringRules = rules.filter { $0.generationFailure != nil }

        let proposals = (try? await primaryRepository.fetchPendingProposals(for: userId)) ?? []
        pendingProposals = proposals
        proposalExpenses = await resolveProposalExpenses(proposals: proposals, periodExpenses: expenses)
    }

    func expense(forProposal proposal: ExpenseEditProposal) -> ExpenseRecord? {
        expenses.first(where: { $0.id == proposal.expenseId })
            ?? proposalExpenses.first(where: { $0.id == proposal.expenseId })
    }

    /// Used by Activity after an event is selected; a missing row is expected for deleted/inaccessible history.
    func fetchExpense(id: UUID, userId: UUID) async -> ExpenseRecord? {
        if let cached = expenses.first(where: { $0.id == id }) { return cached }
        return try? await primaryRepository.fetchExpenses(ids: [id]).first(where: { $0.shareRecord(for: userId) != nil })
    }

    func addSplit(
        amountMinor: Int,
        currency: String = AppPreferences.defaultCurrencyCode,
        category: ExpenseCategory,
        title: String? = nil,
        note: String?,
        location: ExpenseLocation? = nil,
        spentAt: Date,
        userId: UUID,
        splitMode: SplitExpenseMode,
        paidBy: UUID,
        partnerUserIds: [UUID],
        myPercentage: Int = 50,
        myExactAmountMinor: Int? = nil,
        participantPercentages: [UUID: Int] = [:],
        participantExactAmountMinors: [UUID: Int] = [:],
        recurring: RecurringRuleRecord? = nil
    ) async throws {
        let trimmedTitle = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let trimmedNote = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        let calculatedShares = SplitCalculator.split(
            totalMinor: amountMinor,
            mode: splitMode,
            myUserId: userId,
            partnerUserIds: partnerUserIds,
            paidByUserId: paidBy,
            myPercentage: myPercentage,
            myExactAmountMinor: myExactAmountMinor,
            participantPercentages: participantPercentages,
            participantExactAmountMinors: participantExactAmountMinors
        )

        let draft = ExpenseRecord(
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            title: trimmedTitle,
            note: trimmedNote,
            location: location,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: userId,
            shares: []
        )

        let activeRepository = repository(forSplitWith: partnerUserIds)
        let usersTrustingCreator = await usersTrusting(
            creatorId: userId,
            partnerUserIds: partnerUserIds,
            repository: activeRepository
        )
        let shareRecords = ExpenseShareAcceptance.sharesWithAcceptance(
            calculatedShares: calculatedShares,
            expense: draft,
            usersTrustingCreator: usersTrustingCreator
        )

        let recurringRule = makeRecurringRule(
            recurring,
            title: trimmedTitle,
            note: trimmedNote,
            location: location,
            paidBy: paidBy,
            shares: shareRecords,
            seedDate: spentAt
        )

        let expense = ExpenseRecord(
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            title: trimmedTitle,
            note: trimmedNote,
            location: location,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: userId,
            recurringId: recurringRule?.id,
            shares: shareRecords
        )
        _ = try await LoamErrorCapture.withCapture("expense.shared_create_failed") {
            if let recurringRule {
                return try await activeRepository.createRecurringExpense(expense, rule: recurringRule)
            }
            return try await activeRepository.create(expense)
        }
        Telemetry.capture(.expenseCreated(shared: true, recurring: recurringRule != nil, participantCount: shareRecords.count))
        await recordActivity(kind: .shared, actorId: userId, expense: expense, recipients: partnerUserIds)
        RecentSplitPartners.record(partnerUserIds, for: userId)
        if recurringRule != nil {
            try await materializeDueRecurring(userId: userId, repository: activeRepository)
        }
        await refresh(userId: userId)
    }

    func addPersonal(
        amountMinor: Int,
        currency: String = AppPreferences.defaultCurrencyCode,
        category: ExpenseCategory,
        title: String? = nil,
        note: String?,
        location: ExpenseLocation? = nil,
        spentAt: Date,
        userId: UUID,
        recurring: RecurringRuleRecord? = nil
    ) async throws {
        let trimmedTitle = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let trimmedNote = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let activeRepository = primaryRepository

        let recurringRule = makeRecurringRule(
            recurring,
            title: trimmedTitle,
            note: trimmedNote,
            location: location,
            paidBy: userId,
            shares: [ExpenseShareRecord(userId: userId, amountMinor: amountMinor)],
            seedDate: spentAt
        )

        let shares = SplitCalculator.personal(totalMinor: amountMinor, userId: userId)
        let expense = ExpenseRecord(
            amountMinor: amountMinor,
            currency: currency,
            category: category,
            title: trimmedTitle,
            note: trimmedNote,
            location: location,
            spentAt: spentAt,
            paidBy: userId,
            createdBy: userId,
            recurringId: recurringRule?.id,
            shares: shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) }
        )
        _ = try await LoamErrorCapture.withCapture("expense.personal_create_failed") {
            if let recurringRule {
                return try await activeRepository.createRecurringExpense(expense, rule: recurringRule)
            }
            return try await activeRepository.create(expense)
        }
        Telemetry.capture(.expenseCreated(shared: false, recurring: recurringRule != nil, participantCount: 1))
        if recurringRule != nil {
            try await materializeDueRecurring(userId: userId, repository: activeRepository)
        }
        await refresh(userId: userId)
    }

    func update(
        expenseId: UUID,
        amountMinor: Int,
        category: ExpenseCategory,
        title: String? = nil,
        note: String?,
        location: ExpenseLocation? = nil,
        spentAt: Date,
        userId: UUID,
        splitMode: SplitExpenseMode,
        paidBy: UUID,
        partnerUserIds: [UUID],
        myPercentage: Int = 50,
        myExactAmountMinor: Int? = nil,
        participantPercentages: [UUID: Int] = [:],
        participantExactAmountMinors: [UUID: Int] = [:]
    ) async throws {
        guard var expense = expenses.first(where: { $0.id == expenseId }) else {
            throw ExpenseRepositoryError.notFound
        }
        let originalExpense = expense
        guard expense.createdBy == userId else {
            throw ExpenseRepositoryError.notFound
        }

        // Resolve storage from the original expense before mutating shares/partners,
        // so DEBUG local-vs-Supabase routing cannot flip mid-update.
        let activeRepository = repository(for: expense)

        let trimmedTitle = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let trimmedNote = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        expense.amountMinor = amountMinor
        expense.category = category
        expense.title = trimmedTitle
        expense.note = trimmedNote
        expense.location = location
        expense.spentAt = AppPreferences.calendar.startOfDay(for: spentAt)
        expense.paidBy = paidBy
        expense.updatedAt = Date()

        if partnerUserIds.isEmpty {
            expense.paidBy = userId
            expense.shares = SplitCalculator.personal(totalMinor: amountMinor, userId: userId).map {
                ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor)
            }
            _ = try await LoamErrorCapture.withCapture("expense.update_failed") {
                try await activeRepository.update(expense)
            }
        } else {
            let calculatedShares = SplitCalculator.split(
                totalMinor: amountMinor,
                mode: splitMode,
                myUserId: userId,
                partnerUserIds: partnerUserIds,
                paidByUserId: paidBy,
                myPercentage: myPercentage,
                myExactAmountMinor: myExactAmountMinor,
                participantPercentages: participantPercentages,
                participantExactAmountMinors: participantExactAmountMinors
            )
            let usersTrustingCreator = await usersTrusting(
                creatorId: userId,
                partnerUserIds: partnerUserIds,
                repository: activeRepository
            )
            expense.shares = ExpenseShareAcceptance.sharesWithAcceptance(
                calculatedShares: calculatedShares,
                expense: expense,
                usersTrustingCreator: usersTrustingCreator
            )
            _ = try await LoamErrorCapture.withCapture("expense.update_failed") {
                try await activeRepository.update(expense)
            }
        }

        if expense.isShared || originalExpense.isShared {
            let removed = Set(originalExpense.shares.map(\.userId)).subtracting(expense.shares.map(\.userId))
            await recordActivity(kind: .edited, actorId: userId, expense: expense, recipients: expense.shares.map(\.userId).filter { $0 != userId })
            for participant in removed {
                await recordActivity(kind: .participantRemoved, actorId: userId, expense: originalExpense, recipients: [participant])
            }
        }

        await refresh(userId: userId)
    }

    func delete(id: UUID, userId: UUID, recurringMode: RecurringDeletionMode? = nil) async {
        do {
            if let expense = expenses.first(where: { $0.id == id }) {
                let activeRepository = repository(for: expense)
                try await activeRepository.delete(id: id)
                if expense.isShared { await recordActivity(kind: .deleted, actorId: userId, expense: expense, recipients: expense.shares.map(\.userId).filter { $0 != userId }) }
                if let recurringId = expense.recurringId, let mode = recurringMode {
                    try await applyRecurringDeletion(
                        recurringId: recurringId,
                        occurrenceDate: expense.spentAt,
                        mode: mode,
                        repository: activeRepository
                    )
                }
            } else {
                try await primaryRepository.delete(id: id)
            }
            await refresh(userId: userId)
        } catch {
            LoamErrorCapture.capture("expense.delete_failed")
            lastError = error.localizedDescription
        }
    }

    #if DEBUG
    /// Deletes expenses (and recurring rules) this user created. Shared rows created by others remain.
    func clearAllExpenses(userId: UUID) async {
        do {
            try await primaryRepository.deleteAllCreatedBy(userId)
            await refresh(userId: userId)
            if !expenses.isEmpty {
                lastError = "Cleared expenses you created. \(expenses.count) shared expense(s) from others remain."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
    #endif

    func fetchRecurringRule(for expense: ExpenseRecord) async -> RecurringRuleRecord? {
        guard let recurringId = expense.recurringId else { return nil }
        let activeRepository = repository(for: expense)
        return try? await activeRepository.fetchRecurringRule(id: recurringId)
    }

    /// True only for the seed occurrence of a recurring series (`spentAt` on the rule's `startDate`).
    func isInitialRecurringOccurrence(_ expense: ExpenseRecord) -> Bool {
        guard let recurringId = expense.recurringId,
              let startDate = recurringStartDatesById[recurringId] else {
            return false
        }
        return Calendar.current.isDate(expense.spentAt, inSameDayAs: startDate)
    }

    private func applyRecurringDeletion(
        recurringId: UUID,
        occurrenceDate: Date,
        mode: RecurringDeletionMode,
        repository: ExpenseRepository
    ) async throws {
        guard var rule = try await repository.fetchRecurringRule(id: recurringId) else { return }
        switch mode {
        case .occurrenceOnly:
            rule.skipOccurrence(on: occurrenceDate)
        case .stopRecurring:
            rule.isActive = false
            rule.endDate = occurrenceDate
            try await repository.deleteFutureRecurringExpenses(
                recurringId: recurringId,
                after: occurrenceDate
            )
        }
        rule = try await repository.updateRecurringRule(rule)
    }

    func applySplit(
        to expenseId: UUID,
        userId: UUID,
        splitMode: SplitExpenseMode,
        paidBy: UUID,
        partnerUserIds: [UUID],
        myPercentage: Int = 50,
        myExactAmountMinor: Int? = nil,
        participantPercentages: [UUID: Int] = [:],
        participantExactAmountMinors: [UUID: Int] = [:]
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
            myExactAmountMinor: myExactAmountMinor,
            participantPercentages: participantPercentages,
            participantExactAmountMinors: participantExactAmountMinors
        )

        expense.paidBy = paidBy
        let activeRepository = repository(forSplitWith: partnerUserIds)
        let usersTrustingCreator = await usersTrusting(
            creatorId: userId,
            partnerUserIds: partnerUserIds,
            repository: activeRepository
        )
        expense.shares = ExpenseShareAcceptance.sharesWithAcceptance(
            calculatedShares: shares,
            expense: expense,
            usersTrustingCreator: usersTrustingCreator
        )
        expense.updatedAt = Date()

        _ = try await LoamErrorCapture.withCapture("expense.split_setup_failed") {
            try await activeRepository.update(expense)
        }
        await recordActivity(kind: .edited, actorId: userId, expense: expense, recipients: expense.shares.map(\.userId).filter { $0 != userId })
        RecentSplitPartners.record(partnerUserIds, for: userId)
        await refresh(userId: userId)
    }

    func respondToShare(
        expenseId: UUID,
        userId: UUID,
        action: ExpenseShareResponseAction
    ) async {
        await respondToShares(expenseIds: [expenseId], userId: userId, action: action)
    }

    /// Accepts or rejects multiple pending shares, refreshing once at the end.
    func respondToShares(
        expenseIds: [UUID],
        userId: UUID,
        action: ExpenseShareResponseAction
    ) async {
        let targets: [(id: UUID, expense: ExpenseRecord)] = expenseIds.compactMap { id in
            guard let expense = expenses.first(where: { $0.id == id }),
                  expense.isPendingAcceptance(for: userId) else { return nil }
            return (id, expense)
        }
        guard !targets.isEmpty else { return }

        for (id, _) in targets {
            applyOptimisticShareResponse(expenseId: id, userId: userId, action: action)
        }
        summary = Self.makeSummary(expenses: expenses, userId: userId)

        do {
            var trustedScopes: Set<String> = []
            for target in targets {
                // Trust once per creator when bulk-accepting with trust.
                let itemAction: ExpenseShareResponseAction
                if action == .acceptWithTrust {
                    let scopeKey = target.expense.createdBy.uuidString
                    if trustedScopes.contains(scopeKey) {
                        itemAction = .accept
                    } else {
                        itemAction = .acceptWithTrust
                        trustedScopes.insert(scopeKey)
                    }
                } else {
                    itemAction = action
                }
                let activeRepository = repository(for: target.expense)
                try await activeRepository.respondToShare(
                    expenseId: target.id,
                    userId: userId,
                    action: itemAction
                )
                await recordActivity(kind: itemAction == .reject ? .rejected : .accepted, actorId: userId, expense: target.expense, recipients: [target.expense.createdBy])
            }
            await refresh(userId: userId)
        } catch {
            LoamErrorCapture.capture("expense.share_response_failed")
            lastError = error.localizedDescription
            await refresh(userId: userId)
        }
    }

    private func applyOptimisticShareResponse(
        expenseId: UUID,
        userId: UUID,
        action: ExpenseShareResponseAction
    ) {
        guard let expenseIndex = expenses.firstIndex(where: { $0.id == expenseId }),
              let shareIndex = expenses[expenseIndex].shares.firstIndex(where: { $0.userId == userId }),
              expenses[expenseIndex].shares[shareIndex].status == .pending
        else { return }

        var expense = expenses[expenseIndex]
        switch action {
        case .reject:
            expense.shares[shareIndex].status = .rejected
            expense.shares[shareIndex].respondedAt = Date()
        case .accept, .acceptWithTrust:
            expense.shares[shareIndex].status = .accepted
            expense.shares[shareIndex].respondedAt = Date()
        }
        expenses[expenseIndex] = expense
    }

    func proposeEdit(
        for expense: ExpenseRecord,
        userId: UUID,
        amountMinor: Int,
        category: ExpenseCategory,
        title: String? = nil,
        note: String?,
        location: ExpenseLocation? = nil,
        spentAt: Date,
        paidBy: UUID,
        shares: [ExpenseShareRecord],
        message: String?
    ) async throws {
        let proposal = ExpenseEditProposal(
            expenseId: expense.id,
            proposedBy: userId,
            baseVersion: expense.version ?? 1,
            amountMinor: amountMinor,
            category: category,
            title: title,
            note: note,
            location: location,
            spentAt: spentAt,
            paidBy: paidBy,
            shares: shares,
            message: message
        )
        let activeRepository = repository(for: expense)
        _ = try await LoamErrorCapture.withCapture("expense.edit_proposal_create_failed") {
            try await activeRepository.createEditProposal(proposal, expenseId: expense.id)
        }
        await recordActivity(kind: .proposalCreated, actorId: userId, expense: expense, recipients: [expense.createdBy])
        let partnerIds = shares.map(\.userId).filter { $0 != userId }
        RecentSplitPartners.record(partnerIds, for: userId)
        await refresh(userId: userId)
    }

    func respondToProposal(proposalId: UUID, userId: UUID, accept: Bool) async {
        do {
            let expenseId = pendingProposals.first(where: { $0.id == proposalId })?.expenseId
            let expense = expenseId.flatMap { id in
                expenses.first(where: { $0.id == id })
                    ?? proposalExpenses.first(where: { $0.id == id })
            }
            let activeRepository = expense.map { repository(for: $0) } ?? primaryRepository
            try await LoamErrorCapture.withCapture("expense.edit_proposal_response_failed") {
                try await activeRepository.respondToProposal(proposalId: proposalId, accept: accept)
            }
            if let expense {
                let proposer = pendingProposals.first(where: { $0.id == proposalId })?.proposedBy
                await recordActivity(kind: accept ? .proposalAccepted : .proposalRejected, actorId: userId, expense: expense, recipients: proposer.map { [$0] } ?? [])
            }
            await refresh(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pendingProposals(for expenseId: UUID, userId: UUID) -> [ExpenseEditProposal] {
        pendingProposals.filter { proposal in
            proposal.expenseId == expenseId
                && proposal.status == .pending
                && (proposal.proposedBy != userId || expenses.contains(where: { $0.id == expenseId && $0.createdBy == userId })
                    || proposalExpenses.contains(where: { $0.id == expenseId && $0.createdBy == userId }))
        }
    }

    func incomingProposals(for userId: UUID) -> [ExpenseEditProposal] {
        pendingProposals.filter { proposal in
            guard proposal.status == .pending else { return false }
            guard let expense = expense(forProposal: proposal) else { return false }
            return expense.createdBy == userId
        }
    }

    private func resolveProposalExpenses(
        proposals: [ExpenseEditProposal],
        periodExpenses: [ExpenseRecord]
    ) async -> [ExpenseRecord] {
        let knownIds = Set(periodExpenses.map(\.id))
        let missingIds = Array(Set(proposals.map(\.expenseId)).subtracting(knownIds))
        guard !missingIds.isEmpty else { return [] }

        return (try? await primaryRepository.fetchExpenses(ids: missingIds)) ?? []
    }

    private func recordActivity(kind: ActivityEventKind, actorId: UUID, expense: ExpenseRecord, recipients: [UUID]) async {
        guard ExpenseRepositoryFactory.usesLocalStorage else { return }
        let audience = Array(Set(recipients + [actorId]))
        guard !recipients.isEmpty else { return }
        let event = ActivityEvent(
            kind: kind,
            actorId: actorId,
            actorName: SplitPartnerOption.displayName(for: actorId, fallback: "You"),
            recipientId: recipients.count == 1 ? recipients[0] : nil,
            recipientName: recipients.count == 1 ? SplitPartnerOption.displayName(for: recipients[0]) : nil,
            recipientNames: recipients.map { SplitPartnerOption.displayName(for: $0) },
            expenseId: expense.id,
            expenseTitle: expense.displayTitle,
            category: expense.category,
            affectedShareMinor: recipients.reduce(0) { $0 + (expense.shareRecord(for: $1)?.amountMinor ?? 0) },
            expenseTotalMinor: expense.amountMinor,
            currency: expense.currency
        )
        try? await ActivityRepositoryFactory.make().record(event, audience: audience)
    }

    /// The rule is saved with its seed expense, already advanced past it.
    private func makeRecurringRule(
        _ recurring: RecurringRuleRecord?,
        title: String?,
        note: String?,
        location: ExpenseLocation?,
        paidBy: UUID,
        shares: [ExpenseShareRecord],
        seedDate: Date
    ) -> RecurringRuleRecord? {
        guard var rule = recurring else { return nil }
        rule.title = title
        rule.note = note
        rule.location = location
        rule.paidBy = paidBy
        rule.shares = shares
        rule.nextOccurrence = rule.nextOccurrence(after: seedDate, calendar: AppPreferences.calendar)
        return rule
    }

    /// Creates expense rows for every due occurrence of active rules through today.
    private func materializeDueRecurring(userId: UUID, repository: ExpenseRepository) async throws {
        let today = AppPreferences.calendar.startOfDay(for: Date())
        if try await repository.materializeRecurringRules(through: today) { return }

        let rules = try await repository.fetchActiveRecurringRules(for: userId)
        guard !rules.isEmpty else { return }

        for var rule in rules {
            let calendar = AppPreferences.calendar
            let dueDates = RecurringMaterializer.dueDates(for: rule, through: today, calendar: calendar)
            guard !dueDates.isEmpty else { continue }

            let partnerIds = rule.shares.map(\.userId)
                .filter { $0 != rule.ownerUserId }
            let trusting: Set<UUID>
            if !partnerIds.isEmpty {
                trusting = await usersTrusting(
                    creatorId: rule.ownerUserId,
                    partnerUserIds: partnerIds,
                    repository: repository
                )
            } else {
                trusting = []
            }

            var createdAny = false
            for date in dueDates {
                var occurrence = RecurringMaterializer.occurrenceExpense(
                    rule: rule,
                    spentAt: date
                )
                if occurrence.isShared {
                    let calculated = occurrence.shares.map {
                        SplitCalculator.Share(userId: $0.userId, amountMinor: $0.amountMinor)
                    }
                    occurrence.shares = ExpenseShareAcceptance.sharesWithAcceptance(
                        calculatedShares: calculated,
                        expense: occurrence,
                        usersTrustingCreator: trusting
                    )
                }
                let materialized = try await repository.createRecurringOccurrence(occurrence)
                createdAny = materialized.id == occurrence.id
            }

            if let last = dueDates.last {
                let advanced = rule.nextOccurrence(after: last, calendar: calendar)
                if advanced != rule.nextOccurrence || createdAny {
                    rule.nextOccurrence = advanced
                    rule = try await repository.updateRecurringRule(rule)
                }
            }
        }
    }

    private func usersTrusting(
        creatorId: UUID,
        partnerUserIds: [UUID],
        repository: ExpenseRepository
    ) async -> Set<UUID> {
        var trusting: Set<UUID> = []
        for partnerId in partnerUserIds where partnerId != creatorId {
            let trustedCreators = (try? await repository.fetchTrustedUserIds(for: partnerId)) ?? []
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
        _ = partnerUserIds
        return primaryRepository
    }

    private func repository(for expense: ExpenseRecord) -> ExpenseRepository {
        if usesLocalRepository(for: expense) {
            return LocalExpenseRepository()
        }
        return primaryRepository
    }

    private func usesLocalRepository(for expense: ExpenseRecord) -> Bool {
        _ = expense
        return ExpenseRepositoryFactory.usesLocalStorage
    }

    private func loadRecurringStartDates(for expenses: [ExpenseRecord]) async -> [UUID: Date] {
        let recurringIds = Set(expenses.compactMap(\.recurringId))
        guard !recurringIds.isEmpty else { return [:] }

        var startDates: [UUID: Date] = [:]
        for id in recurringIds {
            if let rule = try? await primaryRepository.fetchRecurringRule(id: id) {
                startDates[id] = rule.startDate
                continue
            }
        }
        return startDates
    }

    nonisolated static func makeSummary(
        expenses: [ExpenseRecord],
        userId: UUID,
        currency: String = AppPreferences.defaultCurrencyCode
    ) -> MonthSpendSummary {
        var total = 0
        var shared = 0
        var byCategory: [ExpenseCategory: Int] = [:]
        for expense in expenses {
            guard expense.currency.uppercased() == currency.uppercased() else { continue }
            let mine = expense.acceptedShareMinor(for: userId)
            total += mine
            if mine > 0 {
                byCategory[expense.category, default: 0] += mine
            }
            if expense.isShared {
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
