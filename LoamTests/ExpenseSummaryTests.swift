import XCTest
@testable import Loam

final class ExpenseSummaryTests: XCTestCase {
    let user = TestUser.alice
    let other = TestUser.bob
    let third = TestUser.carol

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

    func testDeclinedByEveryoneElseIsNotCountedAsShared() {
        let expense = ExpenseRecord(
            amountMinor: 1000,
            category: .dining,
            paidBy: user,
            createdBy: user,
            shares: [
                ExpenseShareRecord(userId: user, amountMinor: 500, status: .accepted),
                ExpenseShareRecord(userId: other, amountMinor: 500, status: .rejected),
            ]
        )
        let summary = ExpenseStore.makeSummary(expenses: [expense], userId: user)
        XCTAssertEqual(summary.totalMine.amountMinor, 500)
        XCTAssertEqual(summary.sharedShare.amountMinor, 0)
    }

    func testPaidInFullBySomeoneElseCountsAsShared() {
        let expense = ExpenseRecord(
            amountMinor: 1000,
            category: .dining,
            paidBy: other,
            createdBy: other,
            shares: [
                ExpenseShareRecord(userId: other, amountMinor: 0, status: .accepted),
                ExpenseShareRecord(userId: user, amountMinor: 1000, status: .accepted),
            ]
        )
        let summary = ExpenseStore.makeSummary(expenses: [expense], userId: user)
        XCTAssertEqual(summary.totalMine.amountMinor, 1000)
        XCTAssertEqual(summary.sharedShare.amountMinor, 1000)
        XCTAssertEqual(ExpenseStore.makeSummary(expenses: [expense], userId: other).totalMine.amountMinor, 0)
    }

    func testSharedShareSeparated() {
        let expense = ExpenseRecord(
            amountMinor: 1000,
            category: .dining,
            paidBy: user,
            createdBy: user,
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
            shares: [
                ExpenseShareRecord(userId: other, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: user, amountMinor: 1000, status: .pending),
            ]
        )
        let summary = ExpenseStore.makeSummary(expenses: [expense], userId: user)
        XCTAssertEqual(summary.totalMine.amountMinor, 0)
        XCTAssertEqual(summary.sharedShare.amountMinor, 0)
    }

    func testSummaryDoesNotCombineCurrencies() {
        let pln = ExpenseRecord(
            amountMinor: 1_000,
            currency: "PLN",
            category: .groceries,
            paidBy: user,
            createdBy: user,
            shares: [ExpenseShareRecord(userId: user, amountMinor: 1_000)]
        )
        let eur = ExpenseRecord(
            amountMinor: 1_000,
            currency: "EUR",
            category: .groceries,
            paidBy: user,
            createdBy: user,
            shares: [ExpenseShareRecord(userId: user, amountMinor: 1_000)]
        )

        XCTAssertEqual(ExpenseStore.makeSummary(expenses: [pln, eur], userId: user, currency: "PLN").totalMine.amountMinor, 1_000)
        XCTAssertEqual(ExpenseStore.makeSummary(expenses: [pln, eur], userId: user, currency: "EUR").totalMine.amountMinor, 1_000)
    }

    func testPendingAcceptanceIsPerUser() {
        let expense = ExpenseRecord(
            amountMinor: 3000,
            category: .shopping,
            paidBy: user,
            createdBy: user,
            shares: [
                ExpenseShareRecord(userId: user, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: other, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: third, amountMinor: 1000, status: .pending),
            ]
        )

        XCTAssertFalse(expense.isPendingAcceptance(for: user))
        XCTAssertFalse(expense.isPendingAcceptance(for: other))
        XCTAssertTrue(expense.isPendingAcceptance(for: third))
    }

    func testRejectedShareDoesNotCount() {
        let expense = sharedExpense(1000, createdBy: other, shares: [
            ExpenseShareRecord(userId: other, amountMinor: 500),
            ExpenseShareRecord(userId: user, amountMinor: 500, status: .rejected),
        ])
        XCTAssertEqual(ExpenseStore.makeSummary(expenses: [expense], userId: user).totalMine.amountMinor, 0)
    }

    func testCategoriesAreOrderedBySpendThenName() {
        let summary = ExpenseStore.makeSummary(expenses: [
            personalExpense(300, category: .transport),
            personalExpense(500, category: .groceries),
            personalExpense(300, category: .dining),
            personalExpense(200, category: .groceries),
        ], userId: user)

        XCTAssertEqual(summary.totalMine.amountMinor, 1300)
        XCTAssertEqual(summary.categoryBreakdown, [
            CategorySpendSlice(category: .groceries, amountMinor: 700),
            CategorySpendSlice(category: .dining, amountMinor: 300),
            CategorySpendSlice(category: .transport, amountMinor: 300),
        ])
    }

    func testCreatorIsNeverPendingOnTheirOwnExpense() {
        let expense = sharedExpense(1000, createdBy: user, shares: [
            ExpenseShareRecord(userId: user, amountMinor: 500, status: .pending),
            ExpenseShareRecord(userId: other, amountMinor: 500, status: .pending),
        ])
        XCTAssertFalse(expense.isPendingAcceptance(for: user))
        XCTAssertTrue(expense.isPendingAcceptance(for: other))
        XCTAssertFalse(expense.isPendingAcceptance(for: third))
    }

    func testRecordHelpers() {
        var expense = personalExpense(1250)
        XCTAssertFalse(expense.isShared)
        XCTAssertEqual(expense.displayTitle, "Groceries")
        expense.title = "   "
        XCTAssertEqual(expense.displayTitle, "Groceries")
        XCTAssertFalse(expense.hasCustomTitle)
        expense.title = "Weekly shop"
        XCTAssertEqual(expense.displayTitle, "Weekly shop")
        XCTAssertEqual(expense.share(for: other).amountMinor, 0)
        XCTAssertEqual(expense.share(for: user).amountMinor, 1250)
    }
}

final class ExpenseShareAcceptanceTests: XCTestCase {
    let creator = TestUser.alice
    let partner = TestUser.bob
    let trustingPartner = TestUser.carol

    func testNewSharesAreAcceptedOnlyForTheCreatorAndTrustingPartners() {
        let draft = sharedExpense(900, createdBy: creator, shares: [])
        let shares = ExpenseShareAcceptance.sharesWithAcceptance(
            calculatedShares: [
                .init(userId: creator, amountMinor: 300),
                .init(userId: partner, amountMinor: 300),
                .init(userId: trustingPartner, amountMinor: 300),
            ],
            expense: draft,
            usersTrustingCreator: [trustingPartner]
        )

        XCTAssertEqual(shares.map(\.status), [.accepted, .pending, .accepted])
        XCTAssertEqual(shares.map(\.acceptedViaTrust), [false, false, true])
        XCTAssertNil(shares[1].respondedAt)
    }

    func testRecalculatedSharesKeepTheirIds() {
        let existing = ExpenseShareRecord(userId: partner, amountMinor: 500)
        let expense = sharedExpense(1000, createdBy: creator, shares: [ExpenseShareRecord(userId: creator, amountMinor: 500), existing])
        let shares = ExpenseShareAcceptance.sharesWithAcceptance(
            calculatedShares: [.init(userId: creator, amountMinor: 400), .init(userId: partner, amountMinor: 600)],
            expense: expense
        )
        XCTAssertEqual(shares[1].id, existing.id)
    }

    func testUnchangedAmountsKeepTheirAnswerIncludingRejections() {
        let previous = sharedExpense(1000, createdBy: creator, shares: [
            ExpenseShareRecord(userId: creator, amountMinor: 500),
            ExpenseShareRecord(userId: partner, amountMinor: 500, status: .rejected),
        ])
        let rebuilt = [
            ExpenseShareRecord(userId: creator, amountMinor: 500),
            ExpenseShareRecord(userId: partner, amountMinor: 500, status: .pending),
        ]
        let kept = ExpenseShareAcceptance.preservingResponses(rebuilt, from: previous, paidBy: creator, currency: "PLN", forced: [creator])
        XCTAssertEqual(kept[1].status, .rejected)
    }

    func testChangedAmountPayerOrCurrencyAsksAgain() {
        let previous = sharedExpense(1000, createdBy: creator, shares: [
            ExpenseShareRecord(userId: creator, amountMinor: 500),
            ExpenseShareRecord(userId: partner, amountMinor: 500, status: .accepted),
        ])
        let pending = [
            ExpenseShareRecord(userId: creator, amountMinor: 500),
            ExpenseShareRecord(userId: partner, amountMinor: 500, status: .pending),
        ]
        XCTAssertEqual(ExpenseShareAcceptance.preservingResponses(pending, from: previous, paidBy: partner, currency: "PLN", forced: [creator])[1].status, .pending)
        XCTAssertEqual(ExpenseShareAcceptance.preservingResponses(pending, from: previous, paidBy: creator, currency: "EUR", forced: [creator])[1].status, .pending)

        let changed = [
            ExpenseShareRecord(userId: creator, amountMinor: 400),
            ExpenseShareRecord(userId: partner, amountMinor: 600, status: .pending),
        ]
        XCTAssertEqual(ExpenseShareAcceptance.preservingResponses(changed, from: previous, paidBy: creator, currency: "PLN", forced: [creator])[1].status, .pending)
    }

    func testForcedUsersKeepTheStatusAlreadyAssigned() {
        let previous = sharedExpense(1000, createdBy: creator, shares: [
            ExpenseShareRecord(userId: creator, amountMinor: 500),
            ExpenseShareRecord(userId: partner, amountMinor: 500, status: .rejected),
        ])
        let proposed = [
            ExpenseShareRecord(userId: creator, amountMinor: 500),
            ExpenseShareRecord(userId: partner, amountMinor: 500, status: .accepted),
        ]
        let kept = ExpenseShareAcceptance.preservingResponses(proposed, from: previous, paidBy: creator, currency: "PLN", forced: [creator, partner])
        XCTAssertEqual(kept[1].status, .accepted)
    }
}
