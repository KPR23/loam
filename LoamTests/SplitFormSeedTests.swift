import XCTest
@testable import Loam

final class SplitFormSeedTests: XCTestCase {
    let alice = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let bob = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let carol = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testMultiPersonPercentageSplitReopensWithoutChangingAllocation() {
        let stored = SplitCalculator.percentage(
            totalMinor: 1001,
            userPercentages: [(alice, 20), (bob, 30), (carol, 50)],
            paidByUserId: bob
        )
        let expense = sharedExpense(totalMinor: 1001, paidBy: bob, shares: stored)

        let seed = SplitFormSeed.from(expense: expense, myUserId: alice)

        XCTAssertEqual(seed.splitMode, .percentage)
        XCTAssertEqual(seed.participantPercentages, [alice: 20, bob: 30, carol: 50])
        let reopened = SplitCalculator.split(
            totalMinor: expense.amountMinor,
            mode: seed.splitMode,
            myUserId: alice,
            partnerUserIds: [bob, carol],
            paidByUserId: expense.paidBy,
            participantPercentages: seed.participantPercentages
        )
        XCTAssertTrue(SplitCalculator.sharesMatch(reopened, stored))
    }

    func testMultiPersonExactSplitReopensWithoutChangingAllocation() {
        let stored = [
            SplitCalculator.Share(userId: alice, amountMinor: 101),
            SplitCalculator.Share(userId: bob, amountMinor: 400),
            SplitCalculator.Share(userId: carol, amountMinor: 500),
        ]
        let expense = sharedExpense(totalMinor: 1001, paidBy: bob, shares: stored)

        let seed = SplitFormSeed.from(expense: expense, myUserId: alice)
        let exactAmounts = seed.participantAmountTexts.compactMapValues {
            Money(majorString: $0)?.amountMinor
        }

        XCTAssertEqual(seed.splitMode, .exactAmount)
        XCTAssertEqual(exactAmounts, [alice: 101, bob: 400, carol: 500])
        let reopened = SplitCalculator.split(
            totalMinor: expense.amountMinor,
            mode: seed.splitMode,
            myUserId: alice,
            partnerUserIds: [bob, carol],
            paidByUserId: expense.paidBy,
            participantExactAmountMinors: exactAmounts
        )
        XCTAssertTrue(SplitCalculator.sharesMatch(reopened, stored))
    }

    func testMultiPersonEqualSplitStillReopensAsEqual() {
        let stored = SplitCalculator.equal(
            totalMinor: 1001,
            participants: [alice, bob, carol],
            paidByUserId: bob
        )
        let expense = sharedExpense(totalMinor: 1001, paidBy: bob, shares: stored)

        let seed = SplitFormSeed.from(expense: expense, myUserId: alice)

        XCTAssertEqual(seed.splitMode, .equal)
    }

    /// Rent-sized exact splits must reopen with amounts the form can parse and save.
    func testLargeExactSplitReopensWithParseableAmounts() {
        let stored = [
            SplitCalculator.Share(userId: alice, amountMinor: 1_800_00),
            SplitCalculator.Share(userId: bob, amountMinor: 1_234_50),
        ]
        let expense = sharedExpense(totalMinor: 3_034_50, paidBy: alice, shares: stored)

        let seed = SplitFormSeed.from(expense: expense, myUserId: alice)

        XCTAssertEqual(seed.splitMode, .exactAmount)
        XCTAssertEqual(Money(majorString: seed.myExactAmountText)?.amountMinor, 1_800_00)
        XCTAssertEqual(seed.participantAmountTexts.compactMapValues { Money(majorString: $0)?.amountMinor }, [alice: 1_800_00, bob: 1_234_50])
        XCTAssertNil(SplitExpenseSection.validationError(
            totalMinor: expense.amountMinor,
            selectedPartnerCount: 1,
            splitMode: seed.splitMode,
            participantUserIds: [alice, bob],
            participantPercentages: seed.participantPercentages,
            participantAmountTexts: seed.participantAmountTexts
        ))
    }

    func testPersonalExpenseSeedsAnEmptyEqualSplit() {
        let expense = sharedExpense(totalMinor: 1000, paidBy: alice, shares: [SplitCalculator.Share(userId: alice, amountMinor: 1000)])

        let seed = SplitFormSeed.from(expense: expense, myUserId: alice)

        XCTAssertEqual(seed.splitMode, .equal)
        XCTAssertTrue(seed.participantAmountTexts.isEmpty)
    }

    private func sharedExpense(
        totalMinor: Int,
        paidBy: UUID,
        shares: [SplitCalculator.Share]
    ) -> ExpenseRecord {
        ExpenseRecord(
            amountMinor: totalMinor,
            category: .groceries,
            paidBy: paidBy,
            createdBy: alice,
            shares: shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) }
        )
    }
}
