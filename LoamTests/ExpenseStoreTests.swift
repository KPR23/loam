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
    }

    func testSharedShareSeparated() {
        let expense = ExpenseRecord(
            amountMinor: 1000,
            category: .dining,
            paidBy: user,
            createdBy: user,
            householdId: UUID(),
            shares: [
                ExpenseShareRecord(userId: user, amountMinor: 500),
                ExpenseShareRecord(userId: other, amountMinor: 500),
            ]
        )
        let summary = ExpenseStore.makeSummary(expenses: [expense], userId: user)
        XCTAssertEqual(summary.totalMine.amountMinor, 500)
        XCTAssertEqual(summary.sharedShare.amountMinor, 500)
    }
}
