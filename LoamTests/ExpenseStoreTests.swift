import XCTest
@testable import Loam

final class ExpenseStoreSummaryTests: XCTestCase {
    let user = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let other = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    func testPersonalExpenseCountsFully() {
        let expense = ExpenseRecord(
            amountMinor: 2500,
            category: .groceries,
            paidBy: user,
            createdBy: user,
            shares: [ExpenseShareRecord(userId: user, amountMinor: 2500)]
        )
        let summary = ExpenseStore.makeSummary(expenses: [expense], userId: user)
        XCTAssertEqual(summary.totalMine.amountMinor, 2500)
        XCTAssertEqual(summary.sharedShare.amountMinor, 0)
        XCTAssertEqual(summary.categoryBreakdown.count, 1)
        XCTAssertEqual(summary.categoryBreakdown.first?.category, .groceries)
        XCTAssertEqual(summary.categoryBreakdown.first?.amountMinor, 2500)
    }

    func testSharedShareSeparated() {
        let expense = ExpenseRecord(
            amountMinor: 1000,
            category: .dining,
            paidBy: user,
            createdBy: user,
            householdId: UUID(),
            shares: [
                ExpenseShareRecord(userId: user, amountMinor: 500, status: .accepted),
                ExpenseShareRecord(userId: other, amountMinor: 500, status: .accepted),
            ]
        )
        let summary = ExpenseStore.makeSummary(expenses: [expense], userId: user)
        XCTAssertEqual(summary.totalMine.amountMinor, 500)
        XCTAssertEqual(summary.sharedShare.amountMinor, 500)
    }

    func testPendingShareExcludedFromSummary() {
        let expense = ExpenseRecord(
            amountMinor: 2000,
            category: .groceries,
            paidBy: other,
            createdBy: other,
            householdId: UUID(),
            shares: [
                ExpenseShareRecord(userId: other, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: user, amountMinor: 1000, status: .pending),
            ]
        )
        let summary = ExpenseStore.makeSummary(expenses: [expense], userId: user)
        XCTAssertEqual(summary.totalMine.amountMinor, 0)
        XCTAssertEqual(summary.sharedShare.amountMinor, 0)
    }
}
