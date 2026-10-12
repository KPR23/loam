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
        XCTAssertEqual(summary.categoryBreakdown.first?.category, .builtIn(.groceries))
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

        let summary = ExpenseStore.makeSummary(expenses: [pln, eur], userId: user, currency: "PLN")
        XCTAssertEqual(summary.totalMine.amountMinor, 1_000, "Without a rate, other currencies are left out")
        XCTAssertEqual(summary.unconvertedCount, 1)
        XCTAssertEqual(ExpenseStore.makeSummary(expenses: [pln, eur], userId: user, currency: "EUR").totalMine.amountMinor, 1_000)
    }

    func testSummaryConvertsOtherCurrenciesAtTheRateOfTheDayTheyWereSpent() {
        // Expenses store the start of their day in the app's calendar, so days are read in it too.
        let calendar = AppPreferences.calendar
        let rates = ExchangeRates(days: [
            "2026-10-01": ["PLN": 4.0, "USD": 1.25],
            "2026-10-05": ["PLN": 5.0, "USD": 1.0],
        ], fetchedAt: ["2026-10": Date()])
        func expense(_ amountMinor: Int, _ currency: String, on day: Int) -> ExpenseRecord {
            ExpenseRecord(
                amountMinor: amountMinor,
                currency: currency,
                category: .groceries,
                spentAt: calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!,
                paidBy: user,
                createdBy: user,
                shares: [ExpenseShareRecord(userId: user, amountMinor: amountMinor)]
            )
        }
        // Saturday the 3rd has no rate of its own, so the 1st applies; the 6th uses the 5th.
        let expenses = [expense(1_000, "PLN", on: 2), expense(1_000, "EUR", on: 3), expense(1_000, "USD", on: 6)]

        let summary = ExpenseStore.makeSummary(expenses: expenses, userId: user, currency: "PLN", rates: rates, calendar: calendar)

        XCTAssertEqual(summary.totalMine.amountMinor, 1_000 + 4_000 + 5_000)
        XCTAssertEqual(summary.totalMine.currencyCode, "PLN")
        XCTAssertEqual(summary.convertedCount, 2)
        XCTAssertEqual(summary.unconvertedCount, 0)
        XCTAssertEqual(rates.convert(4_000, from: "PLN", to: "EUR", on: expenses[1].spentAt, calendar: calendar), 1_000)
        XCTAssertNil(rates.convert(100, from: "EUR", to: "PLN", on: calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!, calendar: calendar), "No rate before the first loaded day")

        // With only September loaded, October waits for its own rates instead of reusing September's last one.
        let september = ExchangeRates(days: ["2026-09-30": ["PLN": 4.0]], fetchedAt: ["2026-09": Date()])
        XCTAssertNotNil(september.convert(100, from: "EUR", to: "PLN", on: calendar.date(from: DateComponents(year: 2026, month: 9, day: 30))!, calendar: calendar))
        XCTAssertNil(september.convert(100, from: "EUR", to: "PLN", on: expenses[1].spentAt, calendar: calendar))
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

    func testCustomCategoriesGetTheirOwnSlice() {
        let pets = CustomCategory(id: UUID(), ownerId: user, name: "Pets", symbol: "pawprint.fill", colorHex: "9C7A55")
        var vet = personalExpense(400, category: .other)
        vet.spendCategory = .custom(pets)
        let summary = ExpenseStore.makeSummary(expenses: [vet, personalExpense(100, category: .other)], userId: user)

        XCTAssertEqual(vet.category, .other, "Custom categories are filed under Other")
        XCTAssertEqual(summary.categoryBreakdown, [
            CategorySpendSlice(category: .custom(pets), amountMinor: 400),
            CategorySpendSlice(category: .other, amountMinor: 100),
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
