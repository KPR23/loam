import XCTest
@testable import Loam

/// Changes made offline stay on the device, show at once, and reach storage once back online.
@MainActor
final class OfflineSyncTests: LocalStorageTestCase {
    let me = TestUser.alice
    let partner = TestUser.bob

    private var online = true
    private var sync: OfflineSync!
    private var cacheDirectory: URL!
    private var savedCacheDirectory: URL!
    private let repository = LocalExpenseRepository()

    // The base class's setUp and tearDown aren't main-actor isolated, but XCTest calls them on the main thread.
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            savedCacheDirectory = OfflineCache.directory
            cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "OfflineSyncTests-\(UUID().uuidString)")
            OfflineCache.directory = cacheDirectory
            online = true
            sync = OfflineSync()
            sync.isEnabled = { true }
            sync.isOnline = { [unowned self] in self.online }
            sync.makeExpenseRepository = { LocalExpenseRepository() }
            sync.makeBalanceRepository = { LocalBalanceRepository() }
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            try? FileManager.default.removeItem(at: cacheDirectory)
            OfflineCache.directory = savedCacheDirectory
            sync = nil
        }
        super.tearDown()
    }

    private func makeStore() -> ExpenseStore {
        let store = ExpenseStore()
        store.sync = sync
        return store
    }

    // MARK: Store

    func testANewExpenseThatHangsIsSavedOnTheDeviceAndSentLater() async throws {
        let store = makeStore()
        store.newExpenseTimeout = .milliseconds(50)
        await store.refresh(userId: me)
        let expense = ExpenseRecord(amountMinor: 900, currency: "PLN", category: .groceries, title: "Slow", paidBy: me, createdBy: me, shares: [ExpenseShareRecord(userId: me, amountMinor: 900)])

        let outcome = try await store.sendOrQueue(.saveExpense(expense, isNew: true, rule: nil), userId: me) {
            try await Task.sleep(for: .seconds(30))
        }

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(sync.changes.count, 1)
        XCTAssertEqual(sync.notice?.kind, .savedOffline)
        await sync.flush(userId: me)
        let stored = try await repository.fetchExpenses(for: me, in: .currentMonth)
        XCTAssertEqual(stored.map(\.title), ["Slow"])
    }

    func testAnExpenseAddedOfflineShowsAtOnceAndSyncsWhenBackOnline() async throws {
        let store = makeStore()
        await store.refresh(userId: me)
        online = false

        try await store.addPersonal(amountMinor: 1250, category: .groceries, title: "Bread", note: nil, spentAt: Date(), userId: me)

        XCTAssertEqual(store.expenses.map(\.title), ["Bread"])
        XCTAssertEqual(store.summary.totalMine.amountMinor, 1250)
        XCTAssertEqual(sync.changes.count, 1)
        XCTAssertEqual(sync.notice?.kind, .savedOffline)
        let stored = try await repository.fetchExpenses(for: me, in: .currentMonth)
        XCTAssertTrue(stored.isEmpty, "Nothing reaches storage while offline")

        online = true
        await store.refresh(userId: me)

        XCTAssertTrue(sync.changes.isEmpty)
        XCTAssertEqual(sync.notice?.kind, .synced)
        let synced = try await repository.fetchExpenses(for: me, in: .currentMonth)
        XCTAssertEqual(synced.map(\.title), ["Bread"])
        XCTAssertEqual(store.expenses.map(\.title), ["Bread"])
    }

    func testOfflineChangesSurviveAnAppRestart() async throws {
        let store = makeStore()
        await store.refresh(userId: me)
        online = false
        try await store.addPersonal(amountMinor: 500, category: .dining, title: "Coffee", note: nil, spentAt: Date(), userId: me)

        // A new launch: fresh store and queue, same device.
        let relaunchedSync = OfflineSync()
        relaunchedSync.isEnabled = { true }
        relaunchedSync.isOnline = { [unowned self] in self.online }
        relaunchedSync.makeExpenseRepository = { LocalExpenseRepository() }
        let relaunched = ExpenseStore()
        relaunched.sync = relaunchedSync
        await relaunched.refresh(userId: me)

        XCTAssertEqual(relaunched.expenses.map(\.title), ["Coffee"])
        XCTAssertEqual(relaunchedSync.pendingChanges(for: me).count, 1)
    }

    func testDeletingAnExpenseAddedOfflineLeavesNothingToSync() async throws {
        let store = makeStore()
        await store.refresh(userId: me)
        online = false
        try await store.addPersonal(amountMinor: 900, category: .transport, title: "Taxi", note: nil, spentAt: Date(), userId: me)
        let id = try XCTUnwrap(store.expenses.first?.id)

        await store.delete(id: id, userId: me)

        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertTrue(sync.changes.isEmpty)
    }

    func testAnEditMadeOfflineSyncs() async throws {
        let store = makeStore()
        try await store.addPersonal(amountMinor: 1000, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me)
        let id = try XCTUnwrap(store.expenses.first?.id)
        online = false

        try await store.update(expenseId: id, amountMinor: 1500, category: .groceries, title: "Big shop", note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [])
        XCTAssertEqual(store.expenses.first?.amountMinor, 1500)
        XCTAssertEqual(sync.pendingExpenseIds, [id])

        online = true
        await store.refresh(userId: me)

        let stored = try await repository.fetchExpenses(ids: [id])
        XCTAssertEqual(stored.first?.amountMinor, 1500)
        XCTAssertEqual(stored.first?.title, "Big shop")
        XCTAssertTrue(sync.changes.isEmpty)
    }

    func testASecondOfflineEditAfterAnOnlineEditStartsFromTheCurrentVersion() async throws {
        let store = makeStore()
        try await store.addPersonal(amountMinor: 1000, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me)
        let id = try XCTUnwrap(store.expenses.first?.id)

        online = false
        try await store.update(expenseId: id, amountMinor: 1500, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [])
        online = true
        await store.refresh(userId: me)

        try await store.update(expenseId: id, amountMinor: 1600, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [])
        online = false
        try await store.update(expenseId: id, amountMinor: 1700, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [])
        online = true
        await store.refresh(userId: me)

        let stored = try await repository.fetchExpenses(ids: [id])
        XCTAssertEqual(stored.first?.amountMinor, 1700)
        XCTAssertTrue(sync.changes.isEmpty)
        XCTAssertNotEqual(sync.notice?.kind, .failed)
    }

    func testAnOfflineEditOfAnExpenseChangedElsewhereIsDroppedWithAMessage() async throws {
        let store = makeStore()
        try await store.addPersonal(amountMinor: 1000, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me)
        var original = try XCTUnwrap(store.expenses.first)
        online = false
        try await store.update(expenseId: original.id, amountMinor: 1500, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [])

        // Another device saves a different change first.
        original.amountMinor = 3000
        original.shares = [ExpenseShareRecord(userId: me, amountMinor: 3000)]
        _ = try await repository.update(original)

        online = true
        await store.refresh(userId: me)

        XCTAssertEqual(sync.notice?.kind, .failed)
        XCTAssertTrue(sync.notice?.message.contains("changed on another device") ?? false)
        XCTAssertTrue(sync.changes.isEmpty)
        XCTAssertEqual(store.expenses.first?.amountMinor, 3000)
    }

    func testAnEditWhoseFirstAttemptAlreadySavedCountsAsSynced() async throws {
        let store = makeStore()
        try await store.addPersonal(amountMinor: 1000, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me)
        let id = try XCTUnwrap(store.expenses.first?.id)
        online = false
        try await store.update(expenseId: id, amountMinor: 1500, category: .groceries, title: "Shop", note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [])

        // The earlier attempt reached storage, but its answer never came back.
        guard case let .saveExpense(edited, _, _) = try XCTUnwrap(sync.changes.first).change else { return XCTFail("Expected a save") }
        _ = try await repository.update(edited)

        online = true
        await store.refresh(userId: me)

        XCTAssertEqual(sync.notice?.kind, .synced)
        XCTAssertEqual(store.expenses.first?.amountMinor, 1500)
    }

    func testAnAnswerGivenOfflineIsNotSentWhenTheShareChangedMeanwhile() async throws {
        var expense = sharedExpense(1000, createdBy: partner, shares: [
            ExpenseShareRecord(userId: partner, amountMinor: 500),
            ExpenseShareRecord(userId: me, amountMinor: 500, status: .pending)
        ])
        expense = try await repository.create(expense)
        let store = makeStore()
        await store.refresh(userId: me)
        online = false

        await store.respondToShare(expenseId: expense.id, userId: me, action: .accept)
        XCTAssertEqual(store.expenses.first?.shareStatus(for: me), .accepted)

        // The creator changes the amounts before the answer syncs.
        expense.amountMinor = 2000
        expense.shares = [
            ExpenseShareRecord(userId: partner, amountMinor: 1000),
            ExpenseShareRecord(userId: me, amountMinor: 1000, status: .pending)
        ]
        _ = try await repository.update(expense)

        online = true
        await store.refresh(userId: me)

        XCTAssertEqual(sync.notice?.kind, .failed)
        let stored = try await repository.fetchExpenses(ids: [expense.id])
        XCTAssertEqual(stored.first?.shareStatus(for: me), .pending)
    }

    func testSuggestingAnEditNeedsAConnection() async throws {
        let store = makeStore()
        let expense = sharedExpense(1000, createdBy: partner, shares: [
            ExpenseShareRecord(userId: partner, amountMinor: 500),
            ExpenseShareRecord(userId: me, amountMinor: 500)
        ])
        online = false

        do {
            try await store.proposeEdit(for: expense, userId: me, amountMinor: 1200, category: .dining, note: nil, spentAt: Date(), paidBy: partner, shares: expense.shares, message: nil)
            XCTFail("Expected an offline error")
        } catch {
            XCTAssertEqual(error.localizedDescription, OfflineError.requiresConnection.localizedDescription)
        }
    }

    func testARepaymentRecordedOfflineWaitsOnTheDevice() async throws {
        let store = BalanceStore()
        store.sync = sync
        online = false

        try await store.repay(to: partner, amountMinor: 500, currencyCode: "PLN", note: "Pizza", paidAt: Date(), userId: me)

        guard case let .repayment(repayment) = try XCTUnwrap(sync.changes.first).change else { return XCTFail("Expected a repayment") }
        XCTAssertEqual(repayment.personId, partner)
        XCTAssertEqual(repayment.amountMinor, 500)
        XCTAssertFalse(repayment.isReceived)
        XCTAssertEqual(sync.notice?.kind, .savedOffline)
    }

    // MARK: Queue

    func testEditsToAQueuedExpenseFoldIntoOneChange() {
        var expense = personalExpense(1000)
        var queue = PendingChange.enqueue(.saveExpense(expense, isNew: true, rule: nil), into: [])
        expense.amountMinor = 2000
        queue = PendingChange.enqueue(.saveExpense(expense, isNew: false, rule: nil), into: queue)

        XCTAssertEqual(queue.count, 1)
        guard case let .saveExpense(saved, isNew, _) = queue[0].change else { return XCTFail("Expected a save") }
        XCTAssertTrue(isNew, "Still a new expense to the server")
        XCTAssertEqual(saved.amountMinor, 2000)
    }

    func testDeletingAnEditedExpenseSendsOnlyTheDeletion() {
        let expense = personalExpense(1000)
        var queue = PendingChange.enqueue(.saveExpense(expense, isNew: false, rule: nil), into: [])
        queue = PendingChange.enqueue(.deleteExpense(expense, recurringMode: nil), into: queue)

        XCTAssertEqual(queue.map(\.change), [.deleteExpense(expense, recurringMode: nil)])
    }

    func testAnEditAfterTheCreateBeingSentIsQueuedAsAnEdit() {
        var expense = personalExpense(1000)
        let queue = PendingChange.enqueue(.saveExpense(expense, isNew: true, rule: nil), into: [])
        expense.amountMinor = 2000

        let updated = PendingChange.enqueue(.saveExpense(expense, isNew: true, rule: nil), into: queue, sending: queue[0].id)

        XCTAssertEqual(updated.count, 2)
        guard case let .saveExpense(_, isNew, _) = updated[1].change else { return XCTFail("Expected a save") }
        XCTAssertFalse(isNew)
    }

    func testQueuedChangesShowOnTopOfTheLoadedMonth() {
        let kept = personalExpense(100, spentAt: Date())
        let deleted = personalExpense(200, spentAt: Date())
        var moved = personalExpense(300, spentAt: Date())
        let added = personalExpense(400, spentAt: Date())
        let declined = sharedExpense(1000, createdBy: partner, shares: [
            ExpenseShareRecord(userId: partner, amountMinor: 500),
            ExpenseShareRecord(userId: me, amountMinor: 500, status: .pending)
        ])
        let loaded = [kept, deleted, moved, declined]
        moved.spentAt = AppPreferences.calendar.date(byAdding: .month, value: -2, to: Date())!

        let changes: [PendingChange] = [
            .deleteExpense(deleted, recurringMode: nil),
            .saveExpense(moved, isNew: false, rule: nil),
            .saveExpense(added, isNew: true, rule: nil),
            .respondToShare(declined, action: .reject)
        ]
        let shown = PendingChange.apply(changes, to: loaded, userId: me, period: .currentMonth)

        XCTAssertEqual(Set(shown.map(\.id)), [kept.id, added.id])
        XCTAssertEqual(PendingChange.apply(changes, to: shown, userId: me, period: .currentMonth).map(\.id), shown.map(\.id), "Applying twice changes nothing")
    }

    // MARK: Saved copies

    func testSavedCopiesRoundTripAndSignOutKeepsUnsyncedChanges() throws {
        let expense = personalExpense(1234)
        OfflineCache.save([expense], key: "expenses-test", userId: me)
        XCTAssertEqual(OfflineCache.load([ExpenseRecord].self, key: "expenses-test", userId: me), [expense])

        sync.enqueue(.saveExpense(expense, isNew: true, rule: nil), userId: me)
        OfflineCache.removeSnapshots(for: me)

        XCTAssertNil(OfflineCache.load([ExpenseRecord].self, key: "expenses-test", userId: me))
        XCTAssertEqual(OfflineCache.load([PendingChangeEntry].self, key: OfflineCache.pendingChangesKey, userId: me)?.count, 1)

        OfflineCache.removeAll(for: me)
        XCTAssertNil(OfflineCache.load([PendingChangeEntry].self, key: OfflineCache.pendingChangesKey, userId: me))
    }

    func testOnlyConnectionFailuresCountAsOffline() {
        XCTAssertTrue(Connectivity.isOfflineError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(Connectivity.isOfflineError(URLError(.timedOut)))
        XCTAssertTrue(Connectivity.isOfflineError(NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])))
        XCTAssertFalse(Connectivity.isOfflineError(URLError(.cancelled)))
        XCTAssertFalse(Connectivity.isOfflineError(ExpenseRepositoryError.conflict))
    }
}
