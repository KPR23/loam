import Foundation
import UIKit

@MainActor
final class ExpenseStore: ObservableObject {
    @Published private(set) var expenses: [ExpenseRecord] = []
    @Published private(set) var pendingProposals: [ExpenseEditProposal] = []
    /// Expenses referenced by pending proposals that fall outside the active period.
    @Published private(set) var proposalExpenses: [ExpenseRecord] = []
    /// Expenses opened outside Home (e.g. from Activity) that fall outside the
    /// active period, kept fresh so their detail screen can act on them.
    @Published private(set) var detachedExpenses: [ExpenseRecord] = []
    /// The user's rules the server could not generate a due occurrence for.
    @Published private(set) var failingRecurringRules: [RecurringRuleRecord] = []
    @Published private(set) var summary: MonthSpendSummary = .zero(currency: AppPreferences.defaultCurrencyCode)
    @Published private(set) var isLoading = false
    @Published var lastError: String? {
        // Every failure reaches the person as a toast, wherever they are in the app.
        didSet { if let lastError { ToastCenter.shared.showError(lastError) } }
    }
    /// Replaces the backend lookup of every expense still waiting on a user, so tests can make it fail.
    var pendingAcceptanceLookup: ((UUID) async throws -> [ExpenseRecord])?
    /// Keeps changes made offline until they sync; tests use their own.
    var sync: OfflineSync = .shared

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

    /// Changes shown with Undo, keyed by expense. Nothing reaches the backend until
    /// their toast goes away, so an undone change never notifies anyone.
    private var stagedChanges: [UUID: StagedChange] = [:]
    /// Saves in flight, so the next change to the same expense waits for its version.
    private var commitTasks: [UUID: Task<Void, Never>] = [:]

    private struct StagedChange {
        enum Kind {
            case delete
            case save(ExpenseRecord)
        }

        let kind: Kind
        let original: ExpenseRecord
        /// Where the deleted expense sat in `expenses`, to put it back on Undo.
        let index: Int?
        /// The month on screen when it was staged; Undo only puts a row back into that month.
        var period: DatePeriod = .currentMonth
        let failureMessage: String
        /// Writes the change; the refresh after it is the store's.
        let persist: @MainActor () async throws -> Void
        var isCommitting = false
    }

    func setPeriod(_ newPeriod: DatePeriod, userId: UUID?) async {
        guard period != newPeriod else { return }
        period = newPeriod
        await refresh(userId: userId)
    }

    /// Months and days follow the selected time zone. Keeps "this month" selected
    /// when that zone moves across a month boundary, and refetches with the new day edges.
    func timeZoneDidChange(from oldTimeZone: TimeZone, userId: UUID?, now: Date = Date()) async {
        var oldCalendar = Calendar(identifier: .gregorian)
        oldCalendar.timeZone = oldTimeZone
        let old = oldCalendar.dateComponents([.year, .month], from: now)
        if let year = old.year, let month = old.month, period == .month(year: year, month: month) {
            period = DatePeriod(from: now)
        }
        await refresh(userId: userId)
    }

    func refresh(userId: UUID?) async {
        let sameAccount = currentUserId == userId
        // Changes waiting on Undo belong to the account that made them.
        if userId != currentUserId { stagedChanges = [:] }
        currentUserId = userId
        guard let userId else {
            expenses = []
            pendingProposals = []
            proposalExpenses = []
            detachedExpenses = []
            failingRecurringRules = []
            recurringStartDatesById = [:]
            summary = .zero(currency: AppPreferences.defaultCurrencyCode)
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        // Changes made offline go first, so the fetch below already includes them.
        await sync.flush(userId: userId)
        guard isUsableOnline else {
            showSavedCopy(userId: userId, sameAccount: sameAccount)
            return
        }

        do {
            try await materializeDueRecurring(userId: userId, repository: primaryRepository)
            let fetched = try await primaryRepository.fetchExpenses(for: userId, in: period)
            expenses = withStagedChanges(withPendingChanges(fetched, userId: userId))
            summary = makeSummary(expenses, userId: userId)
            recurringStartDatesById = await loadRecurringStartDates(for: fetched)
            lastError = nil
        } catch where sync.isEnabled() && Connectivity.isOfflineError(error) {
            showSavedCopy(userId: userId, sameAccount: sameAccount)
            return
        } catch {
            lastError = UserFacingError.message(for: error)
        }

        // Other currencies convert at their day's rate, which may need downloading first.
        await ExchangeRateStore.shared.ensureRates(for: period)
        recomputeSummary()

        let rules = (try? await primaryRepository.fetchActiveRecurringRules(for: userId)) ?? []
        failingRecurringRules = rules.filter { $0.generationFailure != nil }

        let proposals = (try? await primaryRepository.fetchPendingProposals(for: userId)) ?? []
        pendingProposals = proposals
        let resolvedProposalExpenses = await resolveProposalExpenses(proposals: proposals, periodExpenses: expenses)
        proposalExpenses = withStagedChanges(withPendingChanges(resolvedProposalExpenses, userId: userId, addsMissing: false))
        let resolvedDetachedExpenses = await refreshDetachedExpenses(userId: userId)
        detachedExpenses = withStagedChanges(withPendingChanges(resolvedDetachedExpenses, userId: userId, addsMissing: false))
        saveCopy(userId: userId)
    }

    // MARK: Offline

    /// Whether to reach the server now. Demo storage is always reachable.
    private var isUsableOnline: Bool {
        !sync.isEnabled() || sync.isOnline()
    }

    /// The month as last loaded, with what was changed offline on top.
    private func showSavedCopy(userId: UUID, sameAccount: Bool) {
        let saved = OfflineCache.load(OfflineSnapshot.self, key: period.offlineCacheKey, userId: userId)
        // A month never loaded before keeps whatever of it is already on screen.
        let fallback = sameAccount ? expenses.filter { period.contains($0.spentAt) } : []
        expenses = withStagedChanges(withPendingChanges(saved?.expenses ?? fallback, userId: userId))
        if let saved {
            pendingProposals = saved.proposals
            proposalExpenses = withStagedChanges(withPendingChanges(saved.proposalExpenses, userId: userId, addsMissing: false))
        } else if !sameAccount {
            pendingProposals = []
            proposalExpenses = []
            detachedExpenses = []
        }
        detachedExpenses = withStagedChanges(withPendingChanges(detachedExpenses, userId: userId, addsMissing: false))
        summary = makeSummary(expenses, userId: userId)
        lastError = nil
    }

    private func saveCopy(userId: UUID) {
        guard sync.isEnabled(), currentUserId == userId else { return }
        let snapshot = OfflineSnapshot(expenses: expenses, proposals: pendingProposals, proposalExpenses: proposalExpenses)
        OfflineCache.save(snapshot, key: period.offlineCacheKey, userId: userId)
    }

    private func withPendingChanges(_ list: [ExpenseRecord], userId: UUID, addsMissing: Bool = true) -> [ExpenseRecord] {
        guard sync.isEnabled() else { return list }
        let changes = sync.pendingChanges(for: userId)
        guard !changes.isEmpty else { return list }
        return PendingChange.apply(changes, to: list, userId: userId, period: addsMissing ? period : nil, addsMissing: addsMissing)
    }

    /// Sends a change, or keeps it on the device when there's no connection. A change also waits
    /// when an earlier one to the same expense hasn't synced, so the two arrive in order.
    private func sendOrQueue(_ change: PendingChange, userId: UUID, send: () async throws -> Void) async throws -> WriteOutcome {
        if sync.shouldQueue(change, userId: userId) {
            let offline = !sync.isOnline()
            queue(change, userId: userId, announce: offline)
            // Online, it only waited its turn; send it with the earlier change now.
            if !offline {
                await sync.flush(userId: userId)
                await refresh(userId: userId)
            }
            return .queued
        }
        do {
            try await send()
            return .sent
        } catch where sync.isEnabled() && Connectivity.isOfflineError(error) {
            queue(change, userId: userId, announce: true)
            return .queued
        }
    }

    private func queue(_ change: PendingChange, userId: UUID, announce: Bool) {
        sync.enqueue(change, userId: userId, announce: announce)
        guard currentUserId == userId else { return }
        expenses = PendingChange.apply([change], to: expenses, userId: userId, period: period)
        proposalExpenses = PendingChange.apply([change], to: proposalExpenses, userId: userId, period: nil, addsMissing: false)
        detachedExpenses = PendingChange.apply([change], to: detachedExpenses, userId: userId, period: nil, addsMissing: false)
        summary = makeSummary(expenses, userId: userId)
        saveCopy(userId: userId)
    }

    private enum WriteOutcome {
        case sent
        case queued
    }

    func expense(forProposal proposal: ExpenseEditProposal) -> ExpenseRecord? {
        knownExpense(id: proposal.expenseId)
    }

    /// The freshest loaded copy of an expense, wherever it was loaded from.
    func knownExpense(id: UUID) -> ExpenseRecord? {
        expenses.first(where: { $0.id == id })
            ?? proposalExpenses.first(where: { $0.id == id })
            ?? detachedExpenses.first(where: { $0.id == id })
    }

    /// Used by Activity after an event is selected; a missing row is expected for deleted/inaccessible history.
    func fetchExpense(id: UUID, userId: UUID) async -> ExpenseRecord? {
        if case .delete? = stagedChanges[id]?.kind { return nil }
        if let cached = expenses.first(where: { $0.id == id }) { return cached }
        guard let fetched = try? await primaryRepository.fetchExpenses(ids: [id]).first(where: { $0.shareRecord(for: userId) != nil }) else {
            detachedExpenses.removeAll { $0.id == id }
            return nil
        }
        detachedExpenses.removeAll { $0.id == id }
        guard let shown = withStagedChanges([fetched]).first else { return nil }
        detachedExpenses.append(shown)
        return shown
    }

    /// Loads expenses Activity refers to that aren't loaded yet (e.g. outside the
    /// active period), so their pending requests can be answered from there.
    func loadDetachedExpenses(ids: [UUID], userId: UUID) async {
        guard currentUserId == userId else { return }
        let missing = Array(Set(ids.filter { knownExpense(id: $0) == nil }))
        guard !missing.isEmpty,
              let fetched = try? await primaryRepository.fetchExpenses(ids: missing),
              currentUserId == userId else { return }
        detachedExpenses.append(contentsOf: withStagedChanges(fetched).filter { $0.shareRecord(for: userId) != nil && knownExpense(id: $0.id) == nil })
    }

    /// Reloads one expense and the pending proposals so its detail screen shows
    /// answers and suggestions that arrived since the last full refresh.
    func reloadForDetail(expenseId: UUID, userId: UUID) async {
        guard currentUserId == userId else { return }
        if let proposals = try? await primaryRepository.fetchPendingProposals(for: userId) {
            pendingProposals = proposals
            proposalExpenses = withStagedChanges(await resolveProposalExpenses(proposals: proposals, periodExpenses: expenses))
        }
        // A change waiting on Undo stays as shown until it is saved.
        guard stagedChanges[expenseId] == nil,
              let fetched = try? await primaryRepository.fetchExpenses(ids: [expenseId]).first,
              fetched.shareRecord(for: userId) != nil,
              currentUserId == userId else { return }
        if let index = expenses.firstIndex(where: { $0.id == expenseId }) {
            expenses[index] = fetched
            summary = makeSummary(expenses, userId: userId)
        } else if let index = proposalExpenses.firstIndex(where: { $0.id == expenseId }) {
            proposalExpenses[index] = fetched
        } else {
            detachedExpenses.removeAll { $0.id == expenseId }
            detachedExpenses.append(fetched)
        }
    }

    /// Pending proposals for one expense that this user can see: their own, or
    /// every proposal when they own the expense.
    func visibleProposals(forExpense expenseId: UUID, userId: UUID) -> [ExpenseEditProposal] {
        pendingProposals
            .filter { proposal in
                proposal.expenseId == expenseId
                    && proposal.status == .pending
                    && (proposal.proposedBy == userId || knownExpense(id: expenseId)?.createdBy == userId)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func addSplit(
        amountMinor: Int,
        currency: String = AppPreferences.defaultCurrencyCode,
        category: ExpenseCategory,
        customCategory: CustomCategory? = nil,
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
            customCategory: customCategory,
            title: trimmedTitle,
            note: trimmedNote,
            location: location,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: userId,
            shares: []
        )

        let activeRepository = repository(forSplitWith: partnerUserIds)
        let usersTrustingCreator = await usersTrustingIfOnline(
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
            customCategory: customCategory,
            title: trimmedTitle,
            note: trimmedNote,
            location: location,
            spentAt: spentAt,
            paidBy: paidBy,
            createdBy: userId,
            recurringId: recurringRule?.id,
            shares: shareRecords
        )
        let outcome = try await sendOrQueue(.saveExpense(expense, isNew: true, rule: recurringRule), userId: userId) {
            _ = try await LoamErrorCapture.withCapture("expense.shared_create_failed") {
                if let recurringRule {
                    return try await activeRepository.createRecurringExpense(expense, rule: recurringRule)
                }
                return try await activeRepository.create(expense)
            }
        }
        Telemetry.capture(.expenseCreated(shared: true, recurring: recurringRule != nil, participantCount: shareRecords.count))
        RecentSplitPartners.record(partnerUserIds, for: userId)
        guard outcome == .sent else { return }
        await recordActivity(kind: .shared, actorId: userId, expense: expense, recipients: partnerUserIds)
        if recurringRule != nil {
            try await materializeDueRecurring(userId: userId, repository: activeRepository)
        }
        await refresh(userId: userId)
    }

    func addPersonal(
        amountMinor: Int,
        currency: String = AppPreferences.defaultCurrencyCode,
        category: ExpenseCategory,
        customCategory: CustomCategory? = nil,
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
            customCategory: customCategory,
            title: trimmedTitle,
            note: trimmedNote,
            location: location,
            spentAt: spentAt,
            paidBy: userId,
            createdBy: userId,
            recurringId: recurringRule?.id,
            shares: shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) }
        )
        let outcome = try await sendOrQueue(.saveExpense(expense, isNew: true, rule: recurringRule), userId: userId) {
            _ = try await LoamErrorCapture.withCapture("expense.personal_create_failed") {
                if let recurringRule {
                    return try await activeRepository.createRecurringExpense(expense, rule: recurringRule)
                }
                return try await activeRepository.create(expense)
            }
        }
        Telemetry.capture(.expenseCreated(shared: false, recurring: recurringRule != nil, participantCount: 1))
        guard outcome == .sent else { return }
        if recurringRule != nil {
            try await materializeDueRecurring(userId: userId, repository: activeRepository)
        }
        await refresh(userId: userId)
    }

    func update(
        expenseId: UUID,
        amountMinor: Int,
        category: ExpenseCategory,
        customCategory: CustomCategory? = nil,
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
        undoable: Bool = false
    ) async throws {
        await settleStagedChange(for: expenseId)
        guard var expense = knownExpense(id: expenseId) else {
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
        expense.spendCategory = customCategory.map(SpendCategory.custom) ?? .builtIn(category)
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
            let usersTrustingCreator = await usersTrustingIfOnline(
                creatorId: userId,
                partnerUserIds: partnerUserIds,
                repository: activeRepository
            )
            expense.shares = ExpenseShareAcceptance.sharesWithAcceptance(
                calculatedShares: calculatedShares,
                expense: expense,
                usersTrustingCreator: usersTrustingCreator
            )
        }

        let updated = expense
        let persist: @MainActor () async throws -> Void = { [self] in
            let outcome = try await sendOrQueue(.saveExpense(updated, isNew: false, rule: nil), userId: userId) {
                _ = try await LoamErrorCapture.withCapture("expense.update_failed") {
                    try await activeRepository.update(updated)
                }
            }
            guard outcome == .sent else { return }
            if updated.isShared || originalExpense.isShared {
                let removed = Set(originalExpense.shares.map(\.userId)).subtracting(updated.shares.map(\.userId))
                await recordActivity(kind: .edited, actorId: userId, expense: updated, recipients: updated.shares.map(\.userId).filter { $0 != userId })
                for participant in removed {
                    await recordActivity(kind: .participantRemoved, actorId: userId, expense: originalExpense, recipients: [participant])
                }
            }
        }

        if undoable {
            stage(
                StagedChange(
                    kind: .save(updated),
                    original: originalExpense,
                    index: nil,
                    failureMessage: "Couldn't save your changes to \u{201C}\(updated.displayTitle)\u{201D}.",
                    persist: persist
                ),
                message: "Expense updated",
                userId: userId
            )
        } else {
            try await persist()
            await refresh(userId: userId)
        }
    }

    func delete(id: UUID, userId: UUID, recurringMode: RecurringDeletionMode? = nil) async {
        await settleStagedChange(for: id)
        do {
            try await performDelete(expense: knownExpense(id: id), id: id, userId: userId, recurringMode: recurringMode)
            await refresh(userId: userId)
        } catch {
            LoamErrorCapture.capture("expense.delete_failed")
            lastError = UserFacingError.message(for: error)
        }
    }

    /// Hides the expense at once and deletes it when its Undo toast goes away.
    func deleteWithUndo(id: UUID, userId: UUID, recurringMode: RecurringDeletionMode? = nil) async {
        await settleStagedChange(for: id)
        guard let expense = knownExpense(id: id) else {
            await delete(id: id, userId: userId, recurringMode: recurringMode)
            return
        }
        let message = recurringMode == .stopRecurring ? "Expense deleted and stopped repeating" : "Expense deleted"
        stage(
            StagedChange(
                kind: .delete,
                original: expense,
                index: expenses.firstIndex(where: { $0.id == id }),
                failureMessage: "Couldn't delete \u{201C}\(expense.displayTitle)\u{201D}.",
                persist: { [self] in
                    do {
                        try await performDelete(expense: expense, id: id, userId: userId, recurringMode: recurringMode)
                    } catch {
                        LoamErrorCapture.capture("expense.delete_failed")
                        throw error
                    }
                }
            ),
            message: message,
            userId: userId
        )
    }

    private func performDelete(
        expense: ExpenseRecord?,
        id: UUID,
        userId: UUID,
        recurringMode: RecurringDeletionMode?
    ) async throws {
        if let expense {
            let activeRepository = repository(for: expense)
            let outcome = try await sendOrQueue(.deleteExpense(expense, recurringMode: recurringMode), userId: userId) {
                try await activeRepository.delete(id: id)
            }
            guard outcome == .sent else { return }
            if expense.isShared { await recordActivity(kind: .deleted, actorId: userId, expense: expense, recipients: expense.shares.map(\.userId).filter { $0 != userId }) }
            if let recurringId = expense.recurringId, let mode = recurringMode {
                try await Self.applyRecurringDeletion(
                    recurringId: recurringId,
                    occurrenceDate: expense.spentAt,
                    mode: mode,
                    repository: activeRepository
                )
            }
        } else {
            try await primaryRepository.delete(id: id)
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
            lastError = UserFacingError.message(for: error)
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
        return AppPreferences.calendar.isDate(expense.spentAt, inSameDayAs: startDate)
    }

    /// Also replays a deletion made offline, once it syncs.
    static func applyRecurringDeletion(
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
        participantExactAmountMinors: [UUID: Int] = [:],
        undoable: Bool = false
    ) async throws {
        await settleStagedChange(for: expenseId)
        guard var expense = knownExpense(id: expenseId), expense.createdBy == userId else {
            throw ExpenseRepositoryError.notFound
        }
        let originalExpense = expense

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
        let usersTrustingCreator = await usersTrustingIfOnline(
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

        let updated = expense
        let persist: @MainActor () async throws -> Void = { [self] in
            let outcome = try await sendOrQueue(.saveExpense(updated, isNew: false, rule: nil), userId: userId) {
                _ = try await LoamErrorCapture.withCapture("expense.split_setup_failed") {
                    try await activeRepository.update(updated)
                }
            }
            guard outcome == .sent else { return }
            await recordActivity(kind: .edited, actorId: userId, expense: updated, recipients: updated.shares.map(\.userId).filter { $0 != userId })
        }
        RecentSplitPartners.record(partnerUserIds, for: userId)

        if undoable {
            stage(
                StagedChange(
                    kind: .save(updated),
                    original: originalExpense,
                    index: nil,
                    failureMessage: "Couldn't save the split for \u{201C}\(updated.displayTitle)\u{201D}.",
                    persist: persist
                ),
                message: originalExpense.isShared ? "Split updated" : "Expense split",
                userId: userId
            )
        } else {
            try await persist()
            await refresh(userId: userId)
        }
    }

    // MARK: - Undo

    /// The loaded copies as people see them, with changes waiting on Undo applied.
    private func withStagedChanges(_ list: [ExpenseRecord]) -> [ExpenseRecord] {
        guard !stagedChanges.isEmpty else { return list }
        return list.compactMap { expense in
            switch stagedChanges[expense.id]?.kind {
            case .delete?: return nil
            case let .save(updated)?: return updated
            case nil: return expense
            }
        }
    }

    private func stage(_ change: StagedChange, message: String, userId: UUID) {
        let id = change.original.id
        var change = change
        change.period = period
        change.isCommitting = false
        stagedChanges[id] = change
        expenses = withStagedChanges(expenses)
        proposalExpenses = withStagedChanges(proposalExpenses)
        detachedExpenses = withStagedChanges(detachedExpenses)
        summary = makeSummary(expenses, userId: userId)
        ToastCenter.shared.show(.undoable(
            message,
            undo: { [weak self] in self?.undoStagedChange(id: id, userId: userId) },
            commit: { [weak self] in self?.commitStagedChange(id: id, userId: userId) }
        ))
    }

    private func undoStagedChange(id: UUID, userId: UUID) {
        guard let change = stagedChanges[id], !change.isCommitting else { return }
        stagedChanges[id] = nil
        let original = change.original
        switch change.kind {
        case .delete:
            if let index = change.index {
                // Another month may be on screen by now; the next refresh finds it there.
                if change.period == period { expenses.insert(original, at: min(index, expenses.count)) }
            } else {
                detachedExpenses.append(original)
            }
        case .save:
            if let index = expenses.firstIndex(where: { $0.id == id }) { expenses[index] = original }
            if let index = proposalExpenses.firstIndex(where: { $0.id == id }) { proposalExpenses[index] = original }
            if let index = detachedExpenses.firstIndex(where: { $0.id == id }) { detachedExpenses[index] = original }
        }
        if currentUserId == userId { summary = makeSummary(expenses, userId: userId) }
        LoamFeedback.tap()
        switch change.kind {
        case .delete: ToastCenter.shared.show(.undone("Expense restored"))
        case .save: ToastCenter.shared.show(.undone("Change undone"))
        }
    }

    /// Saves the change. It stays on screen while saving, then the refresh shows the saved copy.
    private func commitStagedChange(id: UUID, userId: UUID) {
        guard let change = stagedChanges[id], !change.isCommitting else { return }
        stagedChanges[id]?.isCommitting = true
        let previous = commitTasks[id]
        let task = Task { [weak self] in
            await previous?.value
            // Finishes the save if the app moves to the background meanwhile.
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save expense change")
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            var failure: Error?
            do {
                try await change.persist()
            } catch {
                failure = error
            }
            guard let self else { return }
            self.stagedChanges[id] = nil
            // Shows the expense as saved, or as it was when the save failed. A store
            // that has moved on to another account keeps that account's expenses.
            if self.currentUserId == userId { await self.refresh(userId: userId) }
            if let failure {
                let reason = UserFacingError.message(for: failure) ?? UserFacingError.fallback
                // The sheet is closed by now, so Retry keeps the change instead of losing it.
                ToastCenter.shared.showError("\(change.failureMessage) \(reason)", action: Toast.Action(title: "Retry") { [weak self] in
                    guard let self, self.currentUserId == userId, self.stagedChanges[id] == nil else { return }
                    self.retry(change, userId: userId)
                })
            }
        }
        commitTasks[id] = task
        Task { [weak self] in
            await task.value
            if self?.commitTasks[id] == task { self?.commitTasks[id] = nil }
        }
    }

    /// Saves a change whose first save failed, showing it again until the save finishes.
    private func retry(_ change: StagedChange, userId: UUID) {
        let id = change.original.id
        var change = change
        change.isCommitting = false
        stagedChanges[id] = change
        expenses = withStagedChanges(expenses)
        proposalExpenses = withStagedChanges(proposalExpenses)
        detachedExpenses = withStagedChanges(detachedExpenses)
        summary = makeSummary(expenses, userId: userId)
        commitStagedChange(id: id, userId: userId)
    }

    /// Saves every change still waiting on Undo and waits for every save in flight.
    func settleStagedChanges() async {
        for id in Array(stagedChanges.keys) { await settleStagedChange(for: id) }
        for task in Array(commitTasks.values) { await task.value }
    }

    /// Saves a change still waiting on Undo, and any save in flight, before the
    /// expense changes again, so the next save starts from the saved version.
    private func settleStagedChange(for id: UUID) async {
        if let change = stagedChanges[id], !change.isCommitting {
            // Only the toast on screen can hold a change, so ending it commits this one.
            ToastCenter.shared.expireCurrent()
            if let userId = currentUserId { commitStagedChange(id: id, userId: userId) }
        }
        await commitTasks[id]?.value
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
        for id in expenseIds { await settleStagedChange(for: id) }
        var targets: [(id: UUID, expense: ExpenseRecord)] = expenseIds.compactMap { id in
            guard let expense = knownExpense(id: id),
                  expense.isPendingAcceptance(for: userId) else { return nil }
            return (id, expense)
        }
        guard !targets.isEmpty else { return }

        // Refreshing clears `lastError`, so the lookup warning is restored after it.
        var lookupWarning: String?

        // Trusting a creator also accepts everything else they are still waiting on you for,
        // including months other than the one on screen.
        if action == .acceptWithTrust {
            let trustedCreators = Set(targets.map(\.expense.createdBy))
            var candidates = expenses + detachedExpenses
            do {
                if let lookup = pendingAcceptanceLookup {
                    candidates += try await lookup(userId)
                } else {
                    candidates += try await primaryRepository.fetchPendingAcceptance(for: userId)
                }
            } catch {
                // The chosen expenses are still answered; only the older ones can't be found.
                LoamErrorCapture.capture("expense.pending_lookup_failed")
                lookupWarning = "Couldn't check for older requests from this person. They are still waiting for your answer."
            }
            var handled = Set(targets.map(\.id))
            for expense in candidates where trustedCreators.contains(expense.createdBy)
                && expense.isPendingAcceptance(for: userId)
                && handled.insert(expense.id).inserted {
                targets.append((expense.id, expense))
            }
        }

        for (id, _) in targets {
            applyOptimisticShareResponse(expenseId: id, userId: userId, action: action)
        }
        summary = makeSummary(expenses, userId: userId)

        do {
            let savedOfflineBefore = sync.savedOfflineCount
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
                let outcome = try await sendOrQueue(.respondToShare(target.expense, action: itemAction), userId: userId) {
                    try await activeRepository.respondToShare(
                        expenseId: target.id,
                        userId: userId,
                        action: itemAction
                    )
                }
                guard outcome == .sent else { continue }
                await recordActivity(kind: itemAction == .reject ? .rejected : .accepted, actorId: userId, expense: target.expense, recipients: [target.expense.createdBy])
            }
            sync.showSuccess(Self.shareResponseMessage(action: action, count: targets.count), unlessSavedOfflineSince: savedOfflineBefore)
            await refresh(userId: userId)
        } catch {
            LoamErrorCapture.capture("expense.share_response_failed")
            lastError = UserFacingError.message(for: error)
            await refresh(userId: userId)
        }
        if let lookupWarning, lastError == nil { lastError = lookupWarning }
    }

    nonisolated static func shareResponseMessage(action: ExpenseShareResponseAction, count: Int) -> String {
        let noun = count == 1 ? "Expense" : "\(count) expenses"
        switch action {
        case .reject: return "\(noun) declined"
        case .accept, .acceptWithTrust: return "\(noun) accepted"
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
        message: String?,
        clearsCustomCategory: Bool = false
    ) async throws {
        // A suggestion is checked against the version it was made on, so it needs a connection.
        guard isUsableOnline else { throw OfflineError.requiresConnection }
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
            message: message,
            clearsCustomCategory: clearsCustomCategory
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
        guard isUsableOnline else {
            lastError = OfflineError.requiresConnection.localizedDescription
            return
        }
        if let expenseId = pendingProposals.first(where: { $0.id == proposalId })?.expenseId {
            await settleStagedChange(for: expenseId)
        }
        do {
            let expenseId = pendingProposals.first(where: { $0.id == proposalId })?.expenseId
            let expense = expenseId.flatMap { knownExpense(id: $0) }
            let activeRepository = expense.map { repository(for: $0) } ?? primaryRepository
            try await LoamErrorCapture.withCapture("expense.edit_proposal_response_failed") {
                try await activeRepository.respondToProposal(proposalId: proposalId, accept: accept)
            }
            if let expense {
                let proposer = pendingProposals.first(where: { $0.id == proposalId })?.proposedBy
                await recordActivity(kind: accept ? .proposalAccepted : .proposalRejected, actorId: userId, expense: expense, recipients: proposer.map { [$0] } ?? [])
            }
            ToastCenter.shared.showSuccess(accept ? "Suggestion accepted" : "Suggestion declined")
            await refresh(userId: userId)
        } catch {
            lastError = UserFacingError.message(for: error)
        }
    }

    func incomingProposals(for userId: UUID) -> [ExpenseEditProposal] {
        pendingProposals.filter { proposal in
            guard proposal.status == .pending else { return false }
            guard let expense = expense(forProposal: proposal) else { return false }
            return expense.createdBy == userId
        }
    }

    private func refreshDetachedExpenses(userId: UUID) async -> [ExpenseRecord] {
        let periodIds = Set(expenses.map(\.id)).union(proposalExpenses.map(\.id))
        let ids = detachedExpenses.map(\.id).filter { !periodIds.contains($0) }
        guard !ids.isEmpty else { return [] }
        guard let fetched = try? await primaryRepository.fetchExpenses(ids: ids) else { return detachedExpenses }
        return fetched.filter { $0.shareRecord(for: userId) != nil }
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
            recipientIds: recipients,
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
    /// Adds recurring expenses that came due, without reloading the month on screen.
    func materializeDueRecurring(userId: UUID) async throws {
        try await materializeDueRecurring(userId: userId, repository: primaryRepository)
    }

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

    /// Offline, partners show as waiting; the server applies their trust when the change syncs.
    private func usersTrustingIfOnline(
        creatorId: UUID,
        partnerUserIds: [UUID],
        repository: ExpenseRepository
    ) async -> Set<UUID> {
        guard isUsableOnline else { return [] }
        return await usersTrusting(creatorId: creatorId, partnerUserIds: partnerUserIds, repository: repository)
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

    /// Recomputes totals for the loaded month, e.g. after the default currency or the rates change.
    func recomputeSummary() {
        guard let userId = currentUserId else { return }
        summary = makeSummary(expenses, userId: userId)
    }

    private func makeSummary(_ expenses: [ExpenseRecord], userId: UUID) -> MonthSpendSummary {
        Self.makeSummary(expenses: expenses, userId: userId, rates: ExchangeRateStore.shared.rates)
    }

    /// Totals are in `currency`. Expenses in another currency convert at the rate of the day
    /// they were spent; those without a loaded rate are left out and counted instead.
    nonisolated static func makeSummary(
        expenses: [ExpenseRecord],
        userId: UUID,
        currency: String = AppPreferences.defaultCurrencyCode,
        rates: ExchangeRates = .empty,
        calendar: Calendar = AppPreferences.calendar
    ) -> MonthSpendSummary {
        var total = 0
        var shared = 0
        var converted = 0
        var unconverted = 0
        var byCategory: [SpendCategory: Int] = [:]
        for expense in expenses {
            let original = expense.acceptedShareMinor(for: userId)
            guard original != 0 else { continue }
            guard let mine = rates.convert(original, from: expense.currency, to: currency, on: expense.spentAt, calendar: calendar) else {
                unconverted += 1
                continue
            }
            if expense.currency.uppercased() != currency.uppercased() { converted += 1 }
            total += mine
            if mine > 0 {
                byCategory[expense.spendCategory, default: 0] += mine
            }
            if expense.isSharedWithOthers(for: userId) {
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
            categoryBreakdown: categoryBreakdown,
            convertedCount: converted,
            unconvertedCount: unconverted
        )
    }
}

/// One month as last loaded, kept for opening Loam offline.
private struct OfflineSnapshot: Codable {
    var expenses: [ExpenseRecord]
    var proposals: [ExpenseEditProposal]
    var proposalExpenses: [ExpenseRecord]
}
