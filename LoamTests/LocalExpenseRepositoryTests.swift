import XCTest
@testable import Loam

final class LocalExpenseRepositoryTests: LocalStorageTestCase {
    let user = TestUser.alice
    let other = TestUser.bob
    let third = TestUser.carol

    private func split(_ amounts: [(UUID, Int, ExpenseShareStatus)], paidBy: UUID? = nil, spentAt: Date = Date()) -> ExpenseRecord {
        sharedExpense(
            amounts.reduce(0) { $0 + $1.1 },
            createdBy: user,
            paidBy: paidBy,
            shares: amounts.map { ExpenseShareRecord(userId: $0.0, amountMinor: $0.1, status: $0.2) },
            spentAt: spentAt
        )
    }

    func testSearchMatchesOnlyMyExpensesAcrossMonthsIgnoringCaseAndShortQueries() async throws {
        let repository = LocalExpenseRepository()
        let today = AppPreferences.calendar.startOfDay(for: Date())
        let lastYear = AppPreferences.calendar.date(byAdding: .year, value: -1, to: today)!
        var mine = personalExpense(100, spentAt: today)
        mine.title = "Morning Coffee"
        var old = personalExpense(200, spentAt: lastYear)
        old.note = "coffee beans"
        var theirs = personalExpense(300, by: other, spentAt: today)
        theirs.title = "Coffee for Bob"
        for expense in [mine, old, theirs] { _ = try await repository.create(expense) }

        let found = try await repository.searchExpenses(matching: " COFFEE ", for: user, limit: 50)
        let tooShort = try await repository.searchExpenses(matching: "c", for: user, limit: 50)

        XCTAssertEqual(found.map(\.id), [mine.id, old.id])
        XCTAssertTrue(tooShort.isEmpty)
    }

    func testFetchReturnsMyNonRejectedExpensesInThePeriodNewestFirst() async throws {
        let repository = LocalExpenseRepository()
        let today = AppPreferences.calendar.startOfDay(for: Date())
        let yesterday = AppPreferences.calendar.date(byAdding: .day, value: -1, to: today)!
        let older = personalExpense(100, spentAt: yesterday)
        let newer = personalExpense(200, spentAt: today)
        let notMine = personalExpense(300, by: other, spentAt: today)
        let rejected = sharedExpense(400, createdBy: other, shares: [
            ExpenseShareRecord(userId: other, amountMinor: 200),
            ExpenseShareRecord(userId: user, amountMinor: 200, status: .rejected),
        ], spentAt: today)
        let lastYear = personalExpense(500, spentAt: AppPreferences.calendar.date(byAdding: .year, value: -1, to: today)!)
        for expense in [older, newer, notMine, rejected, lastYear] {
            _ = try await repository.create(expense)
        }

        let fetched = try await repository.fetchExpenses(for: user, in: DatePeriod(from: today))

        let expected = DatePeriod(from: yesterday) == DatePeriod(from: today) ? [newer.id, older.id] : [newer.id]
        XCTAssertEqual(fetched.map(\.id), expected)
    }

    func testSharesMustAddUpToTheTotal() async throws {
        var expense = personalExpense(1000)
        expense.shares[0].amountMinor = 999
        do {
            _ = try await LocalExpenseRepository().create(expense)
            XCTFail("Saved an expense whose shares do not add up")
        } catch ExpenseRepositoryError.invalidShares {}
    }

    func testUpdateBumpsTheVersionAndRejectsStaleEdits() async throws {
        let repository = LocalExpenseRepository()
        let expense = try await repository.create(personalExpense(1000))

        var edit = expense
        edit.note = "First"
        let saved = try await repository.update(edit)
        XCTAssertEqual(saved.version, 2)

        var stale = expense
        stale.note = "Second"
        do {
            _ = try await repository.update(stale)
            XCTFail("Stale edit overwrote a newer version")
        } catch ExpenseRepositoryError.conflict {}
    }

    func testMissingExpensesAreNotFound() async throws {
        let repository = LocalExpenseRepository()
        do {
            _ = try await repository.update(personalExpense(100))
            XCTFail("Updated a missing expense")
        } catch ExpenseRepositoryError.notFound {}
        do {
            try await repository.delete(id: UUID())
            XCTFail("Deleted a missing expense")
        } catch ExpenseRepositoryError.notFound {}
    }

    func testDeletingAnExpenseDropsItsProposals() async throws {
        let repository = LocalExpenseRepository()
        let expense = try await repository.create(split([(user, 500, .accepted), (other, 500, .accepted)]))
        _ = try await repository.createEditProposal(proposal(for: expense, by: other, amounts: [600, 400]), expenseId: expense.id)

        try await repository.delete(id: expense.id)

        let proposals = try await repository.fetchPendingProposals(for: user)
        XCTAssertTrue(proposals.isEmpty)
    }

    func testParticipantsAnswerOnlyOnce() async throws {
        let repository = LocalExpenseRepository()
        let expense = try await repository.create(split([(user, 500, .accepted), (other, 500, .pending)]))
        try await repository.respondToShare(expenseId: expense.id, userId: other, action: .reject)

        do {
            try await repository.respondToShare(expenseId: expense.id, userId: other, action: .accept)
            XCTFail("Changed an answered share")
        } catch ExpenseRepositoryError.notFound {}
        let visible = try await repository.fetchExpenses(for: other, in: .currentMonth)
        XCTAssertTrue(visible.isEmpty, "Rejected expenses leave the participant's list")
    }

    func testAcceptWithTrustTrustsTheCreatorButIsNotItselfATrustAcceptance() async throws {
        let repository = LocalExpenseRepository()
        let expense = try await repository.create(split([(user, 500, .accepted), (other, 500, .pending)]))

        try await repository.respondToShare(expenseId: expense.id, userId: other, action: .acceptWithTrust)

        let trusted = try await repository.fetchTrustedUserIds(for: other)
        XCTAssertEqual(trusted, [user])
        let saved = try await repository.fetchExpenses(ids: [expense.id]).first
        XCTAssertEqual(saved?.shareRecord(for: other)?.status, .accepted)
        XCTAssertEqual(saved?.shareRecord(for: other)?.acceptedViaTrust, false)
    }

    func testRecurringSeedWithInvalidSharesLeavesNoRule() async throws {
        let repository = LocalExpenseRepository()
        let rule = RecurringRuleRecord(ownerUserId: user, amountMinor: 1000, category: .housing, intervalUnit: .month, startDate: Date())
        var seed = personalExpense(1000)
        seed.recurringId = rule.id
        seed.shares[0].amountMinor = 1

        do {
            _ = try await repository.createRecurringExpense(seed, rule: rule)
            XCTFail("Saved an invalid seed")
        } catch ExpenseRepositoryError.invalidShares {}
        let saved = try await repository.fetchRecurringRule(id: rule.id)
        XCTAssertNil(saved)
    }

    func testRecurringRuleIdsAreUnique() async throws {
        let repository = LocalExpenseRepository()
        let rule = RecurringRuleRecord(ownerUserId: user, amountMinor: 1000, category: .housing, intervalUnit: .month, startDate: Date())
        _ = try await repository.createRecurringExpense(personalExpense(1000), rule: rule)
        do {
            _ = try await repository.createRecurringExpense(personalExpense(1000), rule: rule)
            XCTFail("Created the same rule twice")
        } catch ExpenseRepositoryError.conflict {}
    }

    func testRecurringRuleUpdatesAreVersioned() async throws {
        let repository = LocalExpenseRepository()
        let rule = RecurringRuleRecord(ownerUserId: user, amountMinor: 1000, category: .housing, intervalUnit: .month, startDate: Date())
        _ = try await repository.createRecurringExpense(personalExpense(1000), rule: rule)

        var edit = rule
        edit.amountMinor = 1200
        let saved = try await repository.updateRecurringRule(edit)
        XCTAssertEqual(saved.version, 2)
        do {
            _ = try await repository.updateRecurringRule(edit)
            XCTFail("Stale rule edit was saved")
        } catch ExpenseRepositoryError.conflict {}
    }

    func testEachRecurringOccurrenceIsCreatedOnce() async throws {
        let repository = LocalExpenseRepository()
        let ruleId = UUID()
        var first = personalExpense(1000, spentAt: day(2026, 9, 1))
        first.recurringId = ruleId
        var duplicate = personalExpense(1000, spentAt: day(2026, 9, 1))
        duplicate.recurringId = ruleId

        let created = try await repository.createRecurringOccurrence(first)
        let deduplicated = try await repository.createRecurringOccurrence(duplicate)

        XCTAssertEqual(deduplicated.id, created.id)
        let exists = try await repository.hasExpense(recurringId: ruleId, spentAt: day(2026, 9, 1))
        XCTAssertTrue(exists)
    }

    func testStoppingARuleRemovesOnlyLaterOccurrences() async throws {
        let repository = LocalExpenseRepository()
        let ruleId = UUID()
        for date in [day(2026, 9, 1), day(2026, 9, 2), day(2026, 9, 3)] {
            var occurrence = personalExpense(1000, spentAt: date)
            occurrence.recurringId = ruleId
            _ = try await repository.create(occurrence)
        }

        try await repository.deleteFutureRecurringExpenses(recurringId: ruleId, after: day(2026, 9, 2))

        let kept = try await repository.fetchExpenses(for: user, in: .month(year: 2026, month: 9))
        XCTAssertEqual(kept.map(\.spentAt), [day(2026, 9, 2), day(2026, 9, 1)])
    }

    func testStaleProposalCannotBeApplied() async throws {
        let repository = LocalExpenseRepository()
        let expense = try await repository.create(split([(user, 500, .accepted), (other, 500, .accepted)]))
        let stale = proposal(for: expense, by: other, amounts: [600, 400])
        var edit = expense
        edit.note = "Changed meanwhile"
        _ = try await repository.update(edit)
        _ = try await repository.createEditProposal(stale, expenseId: expense.id)

        do {
            try await repository.respondToProposal(proposalId: stale.id, accept: true)
            XCTFail("Applied a proposal made against an old version")
        } catch ExpenseRepositoryError.conflict {}
        let pending = try await repository.fetchPendingProposals(for: user)
        XCTAssertEqual(pending.map(\.id), [stale.id])
    }

    func testAcceptingAProposalClosesCompetingOnes() async throws {
        let repository = LocalExpenseRepository()
        let expense = try await repository.create(split([(user, 400, .accepted), (other, 300, .accepted), (third, 300, .accepted)]))
        let fromOther = proposal(for: expense, by: other, amounts: [400, 400, 200])
        let fromThird = proposal(for: expense, by: third, amounts: [400, 200, 400])
        _ = try await repository.createEditProposal(fromOther, expenseId: expense.id)
        _ = try await repository.createEditProposal(fromThird, expenseId: expense.id)

        try await repository.respondToProposal(proposalId: fromOther.id, accept: true)

        let pending = try await repository.fetchPendingProposals(for: user)
        XCTAssertTrue(pending.isEmpty)
        let applied = try await repository.fetchExpenses(ids: [expense.id]).first
        XCTAssertEqual(applied?.shareRecord(for: third)?.amountMinor, 200)
        XCTAssertEqual(applied?.version, 2)
    }

    func testRejectingAProposalLeavesTheExpenseUnchanged() async throws {
        let repository = LocalExpenseRepository()
        let expense = try await repository.create(split([(user, 500, .accepted), (other, 500, .accepted)]))
        let change = proposal(for: expense, by: other, amounts: [700, 300])
        _ = try await repository.createEditProposal(change, expenseId: expense.id)

        try await repository.respondToProposal(proposalId: change.id, accept: false)

        let unchanged = try await repository.fetchExpenses(ids: [expense.id]).first
        XCTAssertEqual(unchanged?.shareRecord(for: other)?.amountMinor, 500)
        let pending = try await repository.fetchPendingProposals(for: user)
        XCTAssertTrue(pending.isEmpty)
    }

    func testUnreadableStoredExpensesAreDiscardedInsteadOfBlockingTheApp() async throws {
        UserDefaults.standard.set(Data("not json".utf8), forKey: "loam.local.expenses")
        let fetched = try await LocalExpenseRepository().fetchExpenses(for: user, in: .currentMonth)
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: "loam.local.expenses"))
    }

    private func proposal(for expense: ExpenseRecord, by proposer: UUID, amounts: [Int]) -> ExpenseEditProposal {
        let shares = zip(expense.shares, amounts).map { ExpenseShareRecord(userId: $0.userId, amountMinor: $1) }
        return ExpenseEditProposal(
            expenseId: expense.id,
            proposedBy: proposer,
            baseVersion: expense.version ?? 1,
            amountMinor: amounts.reduce(0, +),
            category: expense.category,
            spentAt: expense.spentAt,
            paidBy: expense.paidBy,
            shares: shares
        )
    }

    func testEachParticipantAcceptsIndependently() async throws {
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
}

final class LocalCustomCategoryTests: LocalStorageTestCase {
    func testDeletingACategoryFilesItsExpensesUnderOtherAndRenamingShowsEverywhere() async throws {
        let repository = LocalCustomCategoryRepository()
        var pets = CustomCategory(id: UUID(), ownerId: TestUser.alice, name: "Pets", symbol: "pawprint.fill", colorHex: "9C7A55")
        try await repository.save(pets, userId: TestUser.alice)
        var vet = personalExpense(400, category: .other)
        vet.spendCategory = .custom(pets)
        _ = try await LocalExpenseRepository().create(vet)

        pets.name = "Animals"
        try await repository.save(pets, userId: TestUser.alice)
        var stored = try await LocalExpenseRepository().fetchExpenses(ids: [vet.id])
        XCTAssertEqual(stored.first?.spendCategory.displayName, "Animals")

        try await repository.delete(pets, userId: TestUser.alice)
        stored = try await LocalExpenseRepository().fetchExpenses(ids: [vet.id])
        XCTAssertEqual(stored.first?.spendCategory, .builtIn(.other))
        let loaded = try await repository.load(userId: TestUser.alice)
        XCTAssertTrue(loaded.categories.isEmpty)
    }

    func testCategoryOrderIsSavedAndListedCategoriesComeFirst() async throws {
        let repository = LocalCustomCategoryRepository()
        let pets = CustomCategory(id: UUID(), ownerId: TestUser.alice, name: "Pets", symbol: "pawprint.fill", colorHex: "9C7A55")
        let options: [SpendCategory] = [.builtIn(.groceries), .builtIn(.dining), .builtIn(.other), .custom(pets)]

        let keys = [pets.id.uuidString, "other", "groceries"]
        try await repository.setOrder(keys, userId: TestUser.alice)
        let loaded = try await repository.load(userId: TestUser.alice)
        XCTAssertEqual(loaded.order, keys)

        // Dining isn't listed, so it follows the listed categories.
        XCTAssertEqual(
            CustomCategoryStore.sorted(options, by: loaded.order),
            [.custom(pets), .builtIn(.other), .builtIn(.groceries), .builtIn(.dining)]
        )
        XCTAssertEqual(CustomCategoryStore.sorted(options, by: []), options)
    }
}
