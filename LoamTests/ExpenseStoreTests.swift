import XCTest
@testable import Loam

final class CreateRepaymentParamsTests: XCTestCase {
    func testNilNoteIsEncodedAsExplicitNullForPostgRESTFunctionResolution() throws {
        let params = CreateRepaymentParams(
            toUserId: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            amountMinor: 100,
            currency: "EUR",
            note: nil,
            paidAt: "2026-09-17",
            operationId: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )

        let data = try JSONEncoder().encode(params)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(payload.keys.contains("p_note"))
        XCTAssertTrue(payload["p_note"] is NSNull)
        XCTAssertEqual(payload["p_amount_minor"] as? Int, 100)
        XCTAssertEqual(payload["p_currency"] as? String, "EUR")
    }
}

final class ExpenseStoreSummaryTests: XCTestCase {
    let user = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let other = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let third = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

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

    func testEachParticipantAcceptsIndependently() async throws {
        let defaultsKey = "loam.local.expenses"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let expense = ExpenseRecord(
            amountMinor: 3000,
            category: .groceries,
            paidBy: user,
            createdBy: user,
            shares: [
                ExpenseShareRecord(userId: user, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: other, amountMinor: 1000, status: .pending),
                ExpenseShareRecord(userId: third, amountMinor: 1000, status: .pending),
            ]
        )

        let creatorRepo = LocalExpenseRepository()
        _ = try await creatorRepo.create(expense)

        // First participant accepts — only their share changes.
        let otherRepo = LocalExpenseRepository()
        try await otherRepo.respondToShare(expenseId: expense.id, userId: other, action: .accept)

        let afterFirst = try await otherRepo.fetchExpenses(for: other, in: .currentMonth)
        let afterFirstExpense = try XCTUnwrap(afterFirst.first(where: { $0.id == expense.id }))
        XCTAssertEqual(afterFirstExpense.shareStatus(for: other), .accepted)
        XCTAssertEqual(afterFirstExpense.shareStatus(for: third), .pending)
        XCTAssertEqual(afterFirstExpense.shareStatus(for: user), .accepted)

        XCTAssertEqual(
            ExpenseStore.makeSummary(expenses: afterFirst, userId: other).totalMine.amountMinor,
            1000
        )
        XCTAssertEqual(
            ExpenseStore.makeSummary(expenses: afterFirst, userId: third).totalMine.amountMinor,
            0
        )

        // Second participant can still accept independently.
        let thirdRepo = LocalExpenseRepository()
        try await thirdRepo.respondToShare(expenseId: expense.id, userId: third, action: .accept)

        let afterSecond = try await thirdRepo.fetchExpenses(for: third, in: .currentMonth)
        let afterSecondExpense = try XCTUnwrap(afterSecond.first(where: { $0.id == expense.id }))
        XCTAssertEqual(afterSecondExpense.shareStatus(for: other), .accepted)
        XCTAssertEqual(afterSecondExpense.shareStatus(for: third), .accepted)
        XCTAssertEqual(
            ExpenseStore.makeSummary(expenses: afterSecond, userId: third).totalMine.amountMinor,
            1000
        )
    }

    func testLocalEditKeepsResponsesForUnchangedObligations() async throws {
        let keys = ["loam.local.expenses", "loam.local.proposals"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

        let expense = ExpenseRecord(
            amountMinor: 3000,
            category: .groceries,
            paidBy: user,
            createdBy: user,
            shares: [
                ExpenseShareRecord(userId: user, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: other, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: third, amountMinor: 1000, status: .accepted),
            ]
        )
        let repository = LocalExpenseRepository()
        _ = try await repository.create(expense)

        // The store rebuilds every share as pending for non-trusting partners.
        var edited = expense
        edited.title = "Groceries and snacks"
        edited.amountMinor = 3200
        edited.shares = [
            ExpenseShareRecord(userId: user, amountMinor: 1000, status: .accepted),
            ExpenseShareRecord(userId: other, amountMinor: 1000, status: .pending),
            ExpenseShareRecord(userId: third, amountMinor: 1200, status: .pending),
        ]
        let saved = try await repository.update(edited)

        XCTAssertEqual(saved.shareStatus(for: other), .accepted)
        XCTAssertEqual(saved.shareStatus(for: third), .pending)

        // A new payer changes everyone's obligation.
        var repaid = saved
        repaid.paidBy = other
        repaid.shares = saved.shares.map {
            ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor, status: $0.userId == user ? .accepted : .pending)
        }
        let afterPayerChange = try await repository.update(repaid)
        XCTAssertEqual(afterPayerChange.shareStatus(for: other), .pending)
    }

    func testAcceptedLocalProposalAcceptsProposerAndKeepsUnchangedResponses() async throws {
        let keys = ["loam.local.expenses", "loam.local.proposals"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

        let expense = ExpenseRecord(
            amountMinor: 3000,
            category: .groceries,
            paidBy: user,
            createdBy: user,
            shares: [
                ExpenseShareRecord(userId: user, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: other, amountMinor: 1000, status: .accepted),
                ExpenseShareRecord(userId: third, amountMinor: 1000, status: .accepted),
            ]
        )
        let repository = LocalExpenseRepository()
        _ = try await repository.create(expense)
        let proposal = ExpenseEditProposal(
            expenseId: expense.id,
            proposedBy: other,
            amountMinor: 3500,
            category: .groceries,
            spentAt: expense.spentAt,
            paidBy: user,
            shares: [
                ExpenseShareRecord(userId: user, amountMinor: 1000),
                ExpenseShareRecord(userId: other, amountMinor: 1500),
                ExpenseShareRecord(userId: third, amountMinor: 1000),
            ]
        )
        _ = try await repository.createEditProposal(proposal, expenseId: expense.id)
        try await repository.respondToProposal(proposalId: proposal.id, accept: true)

        let appliedRows = try await repository.fetchExpenses(ids: [expense.id])
        let applied = try XCTUnwrap(appliedRows.first)
        XCTAssertEqual(applied.amountMinor, 3500)
        XCTAssertEqual(applied.shareStatus(for: other), .accepted)
        XCTAssertEqual(applied.shareStatus(for: third), .accepted)
    }

    func testLegacyDemoRuleAdoptsSplitFromLatestOccurrence() async throws {
        let keys = ["loam.local.expenses", "loam.local.recurring"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

        let rule = RecurringRuleRecord(ownerUserId: user, amountMinor: 1000, category: .housing, intervalUnit: .month, startDate: Date())
        // Rules saved before payer and split lived on the rule have neither key.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        legacy.removeValue(forKey: "paidBy")
        legacy.removeValue(forKey: "shares")
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: [legacy]), forKey: "loam.local.recurring")

        let older = ExpenseRecord(
            amountMinor: 1000, category: .housing, spentAt: Date(timeIntervalSinceNow: -86_400 * 40),
            paidBy: user, createdBy: user, recurringId: rule.id,
            shares: [ExpenseShareRecord(userId: user, amountMinor: 1000)]
        )
        let latest = ExpenseRecord(
            amountMinor: 1200, category: .housing, title: "Rent", spentAt: Date(timeIntervalSinceNow: -86_400 * 10),
            paidBy: other, createdBy: user, recurringId: rule.id,
            shares: [ExpenseShareRecord(userId: user, amountMinor: 600), ExpenseShareRecord(userId: other, amountMinor: 600)]
        )
        let repository = LocalExpenseRepository()
        _ = try await repository.create(latest)
        _ = try await repository.create(older)

        let migratedRule = try await repository.fetchRecurringRule(id: rule.id)
        let migrated = try XCTUnwrap(migratedRule)
        XCTAssertEqual(migrated.paidBy, other)
        XCTAssertEqual(migrated.amountMinor, 1200)
        XCTAssertEqual(migrated.title, "Rent")
        XCTAssertEqual(migrated.shares.map(\.userId), [user, other])
        XCTAssertEqual(migrated.shares.map(\.amountMinor), [600, 600])

        // The migration is saved, so a fresh load keeps the split.
        let reloadedRule = try await LocalExpenseRepository().fetchRecurringRule(id: rule.id)
        let reloaded = try XCTUnwrap(reloadedRule)
        XCTAssertEqual(reloaded.shares.count, 2)
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
}
