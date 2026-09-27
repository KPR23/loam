import XCTest
@testable import Loam

/// Drives the store the way the screens do, against demo (local) storage.
@MainActor
final class ExpenseStoreTests: LocalStorageTestCase {
    let me = TestUser.alice
    let partner = TestUser.bob
    let calendar = AppPreferences.calendar

    private var today: Date { calendar.startOfDay(for: Date()) }

    private func daysAgo(_ count: Int) -> Date {
        calendar.date(byAdding: .day, value: -count, to: today)!
    }

    private func dailyRule(startingDaysAgo count: Int) -> RecurringRuleRecord {
        RecurringRuleRecord(ownerUserId: me, amountMinor: 1000, category: .transport, intervalUnit: .day, startDate: daysAgo(count))
    }

    func testAddingAPersonalExpenseTrimsTextAndUpdatesTheSummary() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1250, currency: "PLN", category: .groceries, title: "  Weekly shop ", note: "   ", spentAt: Date(), userId: me)

        let expense = try XCTUnwrap(store.expenses.first)
        XCTAssertEqual(expense.title, "Weekly shop")
        XCTAssertNil(expense.note)
        XCTAssertEqual(store.summary.totalMine.amountMinor, 1250)
        XCTAssertEqual(store.summary.categoryBreakdown, [CategorySpendSlice(category: .groceries, amountMinor: 1250)])
        XCTAssertNil(store.lastError)
    }

    func testSplitCountsOnlyMyShareUntilThePartnerAccepts() async throws {
        let store = ExpenseStore()
        try await store.addSplit(amountMinor: 1001, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [partner])

        let expense = try XCTUnwrap(store.expenses.first)
        XCTAssertEqual(expense.shareRecord(for: me)?.amountMinor, 501)
        XCTAssertEqual(expense.shareStatus(for: partner), .pending)
        XCTAssertEqual(store.summary.totalMine.amountMinor, 501)
        XCTAssertEqual(store.summary.sharedShare.amountMinor, 501)
        XCTAssertEqual(RecentSplitPartners.loadIDs(for: me), [partner])

        await store.refresh(userId: partner)
        XCTAssertEqual(store.pendingAcceptanceExpenses.map(\.id), [expense.id])
        XCTAssertEqual(store.summary.totalMine.amountMinor, 0)
    }

    func testSplitWithSomeoneWhoTrustsMeIsAcceptedAutomatically() async throws {
        try await LocalExpenseRepository().addTrust(for: partner, trustedUserId: me)
        let store = ExpenseStore()
        try await store.addSplit(amountMinor: 1000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [partner])

        let share = try XCTUnwrap(store.expenses.first?.shareRecord(for: partner))
        XCTAssertEqual(share.status, .accepted)
        XCTAssertTrue(share.acceptedViaTrust)
    }

    func testAcceptingWithTrustTrustsEachCreatorOnce() async throws {
        let creatorStore = ExpenseStore()
        for amount in [1000, 2000] {
            try await creatorStore.addSplit(amountMinor: amount, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [partner])
        }

        let partnerStore = ExpenseStore()
        await partnerStore.refresh(userId: partner)
        await partnerStore.respondToShares(expenseIds: partnerStore.pendingAcceptanceExpenses.map(\.id), userId: partner, action: .acceptWithTrust)

        XCTAssertTrue(partnerStore.pendingAcceptanceExpenses.isEmpty)
        XCTAssertEqual(partnerStore.summary.totalMine.amountMinor, 1500)
        let trusted = try await LocalExpenseRepository().fetchTrustedUserIds(for: partner)
        XCTAssertEqual(trusted, [me])
        XCTAssertNil(partnerStore.lastError)
    }

    func testRejectedSplitDisappearsForThePartner() async throws {
        try await ExpenseStore().addSplit(amountMinor: 1000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [partner])

        let partnerStore = ExpenseStore()
        await partnerStore.refresh(userId: partner)
        await partnerStore.respondToShare(expenseId: try XCTUnwrap(partnerStore.expenses.first?.id), userId: partner, action: .reject)

        XCTAssertTrue(partnerStore.expenses.isEmpty)
    }

    func testEditingASplitBackToPersonalGivesMeTheWholeAmount() async throws {
        let store = ExpenseStore()
        try await store.addSplit(amountMinor: 1000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: partner, partnerUserIds: [partner])
        let expense = try XCTUnwrap(store.expenses.first)

        try await store.update(expenseId: expense.id, amountMinor: 1200, category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: partner, partnerUserIds: [])

        let updated = try XCTUnwrap(store.expenses.first)
        XCTAssertFalse(updated.isShared)
        XCTAssertEqual(updated.paidBy, me)
        XCTAssertEqual(store.summary.totalMine.amountMinor, 1200)
    }

    func testOnlyTheCreatorCanEditDirectly() async throws {
        let store = ExpenseStore()
        try await store.addSplit(amountMinor: 1000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [partner])
        let expense = try XCTUnwrap(store.expenses.first)

        do {
            try await store.update(expenseId: expense.id, amountMinor: 1, category: .dining, note: nil, spentAt: Date(), userId: partner, splitMode: .equal, paidBy: partner, partnerUserIds: [me])
            XCTFail("A participant rewrote someone else's expense")
        } catch ExpenseRepositoryError.notFound {}
    }

    func testRecurringExpenseBackfillsMissedDaysOnce() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1000, currency: "PLN", category: .transport, note: nil, spentAt: daysAgo(3), userId: me, recurring: dailyRule(startingDaysAgo: 3))
        await store.refresh(userId: me)

        let repository = LocalExpenseRepository()
        let rule = try await repository.fetchActiveRecurringRules(for: me).first
        let ruleId = try XCTUnwrap(rule?.id)
        for offset in 0...3 {
            let exists = try await repository.hasExpense(recurringId: ruleId, spentAt: daysAgo(offset))
            XCTAssertTrue(exists, "Missing the occurrence from \(offset) days ago")
        }
        XCTAssertEqual(rule?.nextOccurrence, calendar.date(byAdding: .day, value: 1, to: today))
        let thisMonth = try await repository.fetchExpenses(for: me, in: DatePeriod(from: today))
        XCTAssertEqual(thisMonth.filter { $0.spentAt == today }.count, 1, "A refresh generated today twice")
    }

    func testDeletingOneOccurrenceSkipsItForGood() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1000, currency: "PLN", category: .transport, note: nil, spentAt: daysAgo(2), userId: me, recurring: dailyRule(startingDaysAgo: 2))
        await store.setPeriod(DatePeriod(from: daysAgo(1)), userId: me)
        let occurrence = try XCTUnwrap(store.expenses.first { $0.spentAt == daysAgo(1) })

        await store.delete(id: occurrence.id, userId: me, recurringMode: .occurrenceOnly)
        await store.refresh(userId: me)

        let repository = LocalExpenseRepository()
        let rule = try await repository.fetchRecurringRule(id: try XCTUnwrap(occurrence.recurringId))
        XCTAssertEqual(rule?.isActive, true)
        XCTAssertEqual(rule?.skippedDates, [daysAgo(1)])
        let recreated = try await repository.hasExpense(recurringId: occurrence.recurringId!, spentAt: daysAgo(1))
        XCTAssertFalse(recreated)
        XCTAssertNil(store.lastError)
    }

    func testStoppingASeriesEndsItAndRemovesLaterOccurrences() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1000, currency: "PLN", category: .transport, note: nil, spentAt: daysAgo(2), userId: me, recurring: dailyRule(startingDaysAgo: 2))
        await store.setPeriod(DatePeriod(from: daysAgo(1)), userId: me)
        let occurrence = try XCTUnwrap(store.expenses.first { $0.spentAt == daysAgo(1) })
        let ruleId = try XCTUnwrap(occurrence.recurringId)

        await store.delete(id: occurrence.id, userId: me, recurringMode: .stopRecurring)
        await store.refresh(userId: me)

        let repository = LocalExpenseRepository()
        let rule = try await repository.fetchRecurringRule(id: ruleId)
        XCTAssertEqual(rule?.isActive, false)
        XCTAssertEqual(rule?.endDate, daysAgo(1))
        let seedKept = try await repository.hasExpense(recurringId: ruleId, spentAt: daysAgo(2))
        let laterKept = try await repository.hasExpense(recurringId: ruleId, spentAt: today)
        XCTAssertTrue(seedKept)
        XCTAssertFalse(laterKept)
    }

    func testProposalFlowBetweenParticipantAndCreator() async throws {
        let creatorStore = ExpenseStore()
        try await creatorStore.addSplit(amountMinor: 1000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [partner])

        let partnerStore = ExpenseStore()
        await partnerStore.refresh(userId: partner)
        let expense = try XCTUnwrap(partnerStore.expenses.first)
        try await partnerStore.proposeEdit(
            for: expense, userId: partner, amountMinor: 800, category: .dining, note: nil, spentAt: expense.spentAt, paidBy: me,
            shares: [ExpenseShareRecord(userId: me, amountMinor: 400), ExpenseShareRecord(userId: partner, amountMinor: 400)],
            message: "Wrong total"
        )

        await creatorStore.refresh(userId: me)
        let proposal = try XCTUnwrap(creatorStore.incomingProposals(for: me).first)
        XCTAssertEqual(creatorStore.visibleProposals(forExpense: expense.id, userId: me).map(\.id), [proposal.id])
        await creatorStore.respondToProposal(proposalId: proposal.id, userId: me, accept: true)

        XCTAssertTrue(creatorStore.incomingProposals(for: me).isEmpty)
        XCTAssertEqual(creatorStore.expenses.first?.amountMinor, 800)
        XCTAssertEqual(creatorStore.expenses.first?.shareStatus(for: partner), .accepted, "The proposer agreed to their own change")
    }

    func testSignedOutStoreIsEmpty() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1000, currency: "PLN", category: .other, note: nil, spentAt: Date(), userId: me)

        await store.refresh(userId: nil)

        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertEqual(store.summary.totalMine.amountMinor, 0)
    }

    func testSwitchingMonthsShowsThatMonthOnly() async throws {
        let store = ExpenseStore()
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: today)!
        try await store.addPersonal(amountMinor: 700, currency: "PLN", category: .other, note: nil, spentAt: lastMonth, userId: me)
        XCTAssertTrue(store.expenses.isEmpty)

        await store.setPeriod(DatePeriod(from: lastMonth), userId: me)

        XCTAssertEqual(store.expenses.map(\.amountMinor), [700])
        XCTAssertEqual(store.summary.totalMine.amountMinor, 700)
    }

    func testChangingTimeZoneKeepsThisMonthSelected() async throws {
        // 20:00 UTC on Sep 30 is still September in Honolulu but October in Kiritimati.
        let now = ISO8601DateFormatter().date(from: "2026-09-30T20:00:00Z")!
        setTimeZonePreference("Pacific/Honolulu")
        let store = ExpenseStore()
        await store.setPeriod(.month(year: 2026, month: 9), userId: me)

        setTimeZonePreference("Pacific/Kiritimati")
        await store.timeZoneDidChange(from: TimeZone(identifier: "Pacific/Honolulu")!, userId: me, now: now)

        XCTAssertEqual(store.period, .month(year: 2026, month: 10))
    }

    func testChangingTimeZoneKeepsAMonthTheUserBrowsedTo() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-30T20:00:00Z")!
        setTimeZonePreference("Pacific/Honolulu")
        let store = ExpenseStore()
        await store.setPeriod(.month(year: 2026, month: 5), userId: me)

        setTimeZonePreference("Pacific/Kiritimati")
        await store.timeZoneDidChange(from: TimeZone(identifier: "Pacific/Honolulu")!, userId: me, now: now)

        XCTAssertEqual(store.period, .month(year: 2026, month: 5))
    }

    func testChangingTimeZoneRefetchesWithTheNewDayEdges() async throws {
        setTimeZonePreference("Pacific/Honolulu")
        let store = ExpenseStore()
        await store.refresh(userId: me)
        _ = try await LocalExpenseRepository().create(personalExpense(900))

        await store.timeZoneDidChange(from: TimeZone(identifier: "Pacific/Honolulu")!, userId: me)

        XCTAssertEqual(store.summary.totalMine.amountMinor, 900)
    }
}

final class ActivitySentenceTests: XCTestCase {
    let me = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let julia = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let philip = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    private func event(
        _ kind: ActivityEventKind,
        actor: UUID,
        actorName: String,
        recipient: UUID? = nil,
        recipientName: String? = nil,
        recipientIds: [UUID] = [],
        recipientNames: [String] = []
    ) -> ActivityEvent {
        ActivityEvent(
            kind: kind,
            actorId: actor,
            actorName: actorName,
            recipientId: recipient,
            recipientName: recipientName,
            recipientNames: recipientNames,
            recipientIds: recipientIds,
            expenseTitle: "Dinner",
            category: .dining,
            affectedShareMinor: 500,
            expenseTotalMinor: 1500,
            currency: "PLN"
        )
    }

    func testSharedExpenseCallsTheViewerYou() {
        let shared = event(.shared, actor: julia, actorName: "Julia", recipientIds: [philip, me], recipientNames: ["Philip", "Kacper Z"])
        XCTAssertEqual(shared.sentence(viewerId: me), "Julia shared an expense with you and Philip")
        XCTAssertEqual(shared.sentence(viewerId: philip), "Julia shared an expense with you and Kacper Z")
    }

    /// The actor's own copy of a "shared" event should read "You", not their own name.
    func testSharedExpenseCallsTheActingViewerYouToo() {
        let shared = event(.shared, actor: julia, actorName: "Julia", recipientIds: [philip], recipientNames: ["Philip"])
        XCTAssertEqual(shared.sentence(viewerId: julia), "You shared an expense with Philip")
    }

    func testResponsesUsePossessiveYou() {
        let accepted = event(.accepted, actor: julia, actorName: "Julia", recipient: me, recipientName: "Kacper Z")
        XCTAssertEqual(accepted.sentence(viewerId: me), "Julia accepted your expense")
    }

    func testAcceptedProposalNamesTheProposer() {
        let accepted = event(.proposalAccepted, actor: me, actorName: "Kacper Z", recipient: julia, recipientName: "Julia")
        XCTAssertEqual(accepted.sentence(viewerId: me), "You accepted Julia's suggested changes")
        XCTAssertEqual(accepted.sentence(viewerId: julia), "Kacper Z accepted your suggested changes")
    }

    func testHeadlinesNameTheExpense() {
        let shared = event(.shared, actor: julia, actorName: "Julia", recipientIds: [me], recipientNames: ["Kacper Z"])
        XCTAssertEqual(String(shared.headline(viewerId: me).characters), "Julia shared Dinner with you")
        let accepted = event(.proposalAccepted, actor: me, actorName: "Kacper Z", recipient: julia, recipientName: "Julia")
        XCTAssertEqual(String(accepted.headline(viewerId: julia).characters), "Kacper Z accepted your changes to Dinner")
        let deleted = event(.deleted, actor: me, actorName: "Kacper Z")
        XCTAssertEqual(String(deleted.headline(viewerId: me).characters), "You deleted Dinner")
    }

    func testHeadlineEmphasizesOnlyTheTitle() {
        let edited = event(.edited, actor: julia, actorName: "Julia")
        let bold = edited.headline(viewerId: me).runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(edited.headline(viewerId: me)[$0.range].characters) }
        XCTAssertEqual(bold, ["Dinner"])
    }

    func testRepaymentsReadFromEachSide() {
        let repayment = event(.repaymentRecorded, actor: julia, actorName: "Julia", recipient: me, recipientName: "Kacper Z")
        XCTAssertEqual(repayment.sentence(viewerId: me), "Julia recorded a repayment to you")
        XCTAssertEqual(repayment.sentence(viewerId: julia), "You recorded a repayment to Kacper Z")
    }

    func testRemovedParticipantIsToldDirectly() {
        let removed = event(.participantRemoved, actor: julia, actorName: "Julia", recipientIds: [me], recipientNames: ["Kacper Z"])
        XCTAssertEqual(removed.sentence(viewerId: me), "Julia removed you from an expense")
    }
}
