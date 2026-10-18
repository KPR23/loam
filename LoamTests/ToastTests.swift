import XCTest
@testable import Loam

/// Deletes and edits with Undo, against demo (local) storage.
@MainActor
final class UndoableChangeTests: LocalStorageTestCase {
    let me = TestUser.alice
    let partner = TestUser.bob

    override func setUp() async throws {
        try await super.setUp()
        ToastCenter.shared.expireCurrent()
    }

    private func savedExpense(id: UUID) async throws -> ExpenseRecord? {
        try await LocalExpenseRepository().fetchExpenses(ids: [id]).first
    }

    private func tapUndo() throws {
        let toast = try XCTUnwrap(ToastCenter.shared.current)
        XCTAssertEqual(toast.action?.title, "Undo")
        ToastCenter.shared.performAction(of: toast.id)
    }

    func testDeleteHidesTheExpenseAndDeletesItWhenTheToastEnds() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1250, currency: "PLN", category: .groceries, note: nil, spentAt: Date(), userId: me)
        let expense = try XCTUnwrap(store.expenses.first)

        await store.deleteWithUndo(id: expense.id, userId: me)

        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertEqual(store.summary.totalMine.amountMinor, 0)
        let kept = try await savedExpense(id: expense.id)
        XCTAssertNotNil(kept, "Deleted before Undo ran out")

        ToastCenter.shared.expireCurrent()
        await store.settleStagedChanges()

        let deleted = try await savedExpense(id: expense.id)
        XCTAssertNil(deleted)
        XCTAssertTrue(store.expenses.isEmpty)
    }

    func testUndoingADeleteKeepsTheExpense() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1250, currency: "PLN", category: .groceries, note: nil, spentAt: Date(), userId: me)
        let expense = try XCTUnwrap(store.expenses.first)

        await store.deleteWithUndo(id: expense.id, userId: me)
        try tapUndo()
        await store.settleStagedChanges()
        await store.refresh(userId: me)

        XCTAssertEqual(store.expenses.map(\.id), [expense.id])
        XCTAssertEqual(store.summary.totalMine.amountMinor, 1250)
        let kept = try await savedExpense(id: expense.id)
        XCTAssertNotNil(kept)
    }

    func testAnotherUndoableChangeSavesTheFirstOne() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1000, currency: "PLN", category: .groceries, title: "First", note: nil, spentAt: Date(), userId: me)
        try await store.addPersonal(amountMinor: 2000, currency: "PLN", category: .groceries, title: "Second", note: nil, spentAt: Date(), userId: me)
        let first = try XCTUnwrap(store.expenses.first { $0.title == "First" })
        let second = try XCTUnwrap(store.expenses.first { $0.title == "Second" })

        await store.deleteWithUndo(id: first.id, userId: me)
        await store.deleteWithUndo(id: second.id, userId: me)
        try tapUndo()
        await store.settleStagedChanges()

        let firstSaved = try await savedExpense(id: first.id)
        let secondSaved = try await savedExpense(id: second.id)
        XCTAssertNil(firstSaved, "The replaced toast's delete never saved")
        XCTAssertNotNil(secondSaved)
        XCTAssertEqual(store.expenses.map(\.id), [second.id])
    }

    func testUndoingAnEditPutsTheOriginalBack() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me)
        let expense = try XCTUnwrap(store.expenses.first)

        try await store.update(expenseId: expense.id, amountMinor: 1200, category: .dining, note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [], undoable: true)
        XCTAssertEqual(store.expenses.first?.amountMinor, 1200)
        let unsaved = try await savedExpense(id: expense.id)
        XCTAssertEqual(unsaved?.amountMinor, 1000, "Saved before Undo ran out")

        try tapUndo()
        XCTAssertEqual(store.expenses.first?.amountMinor, 1000)
        await store.settleStagedChanges()
        let saved = try await savedExpense(id: expense.id)
        XCTAssertEqual(saved?.amountMinor, 1000)
    }

    func testUndoingASplitKeepsTheExpensePersonal() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me)
        let expense = try XCTUnwrap(store.expenses.first)

        try await store.applySplit(to: expense.id, userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [partner], undoable: true)
        XCTAssertEqual(store.expenses.first?.isShared, true)

        try tapUndo()
        await store.settleStagedChanges()
        await store.refresh(userId: me)
        XCTAssertEqual(store.expenses.first?.isShared, false)
    }

    func testAnotherEditSavesTheOneWaitingOnUndoFirst() async throws {
        let store = ExpenseStore()
        try await store.addPersonal(amountMinor: 1000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: me)
        let expense = try XCTUnwrap(store.expenses.first)

        try await store.update(expenseId: expense.id, amountMinor: 1200, category: .dining, title: "Lunch", note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [], undoable: true)
        try await store.update(expenseId: expense.id, amountMinor: 1300, category: .dining, title: "Lunch", note: nil, spentAt: Date(), userId: me, splitMode: .equal, paidBy: me, partnerUserIds: [], undoable: true)
        ToastCenter.shared.expireCurrent()
        await store.settleStagedChanges()

        let saved = try await savedExpense(id: expense.id)
        XCTAssertEqual(saved?.amountMinor, 1300)
        XCTAssertEqual(saved?.title, "Lunch")
        XCTAssertNil(store.lastError)
    }
}

final class UserFacingErrorTests: XCTestCase {
    func testOfflineErrorsSayWhatToDo() {
        XCTAssertEqual(UserFacingError.message(for: URLError(.notConnectedToInternet)), UserFacingError.offline)
        XCTAssertEqual(UserFacingError.message(for: URLError(.networkConnectionLost)), UserFacingError.offline)
    }

    func testCancellationsShowNothing() {
        XCTAssertNil(UserFacingError.message(for: CancellationError()))
        XCTAssertNil(UserFacingError.message(for: URLError(.cancelled)))
    }

    func testKnownBackendReasonsAreReworded() {
        XCTAssertEqual(UserFacingError.message(postgrestCode: "P0001", text: "Expense changed. Refresh and try again."), "This expense changed. Refresh and try again.")
        XCTAssertEqual(UserFacingError.message(postgrestCode: "P0001", text: "Not authenticated"), UserFacingError.sessionExpired)
    }

    func testUnknownBackendTextNeverReachesTheScreen() {
        XCTAssertEqual(UserFacingError.message(postgrestCode: "XX000", text: "duplicate key value violates constraint \"expense_pkey\""), UserFacingError.fallback)
        XCTAssertEqual(UserFacingError.message(postgrestCode: "42501", text: "new row violates row-level security policy"), "You don't have permission to do that.")
    }

    func testStatusCodesMapToShortSentences() {
        XCTAssertEqual(UserFacingError.message(status: 503), "Loam is having trouble right now. Try again shortly.")
        XCTAssertEqual(UserFacingError.message(status: 401), UserFacingError.sessionExpired)
    }

    func testLoamsOwnErrorsKeepTheirWording() {
        XCTAssertEqual(UserFacingError.message(for: BalanceRepositoryError.exceedsDebt), "That payment is larger than the confirmed debt.")
        XCTAssertEqual(UserFacingError.message(for: ExpenseRepositoryError.notFound), "This expense is no longer available.")
    }
}
