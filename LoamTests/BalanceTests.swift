import XCTest
@testable import Loam

final class LocalBalanceRepositoryTests: LocalStorageTestCase {
    let me = TestUser.alice
    let friend = TestUser.bob

    private func store(_ expenses: ExpenseRecord...) async throws {
        let repository = LocalExpenseRepository()
        for expense in expenses { _ = try await repository.create(expense) }
    }

    private func dinner(paidBy payer: UUID, owed: Int, status: ExpenseShareStatus = .accepted, currency: String = "PLN") -> ExpenseRecord {
        let debtor = payer == me ? friend : me
        return ExpenseRecord(
            amountMinor: owed * 2,
            currency: currency,
            category: .dining,
            paidBy: payer,
            createdBy: payer,
            shares: [
                ExpenseShareRecord(userId: payer, amountMinor: owed),
                ExpenseShareRecord(userId: debtor, amountMinor: owed, status: status),
            ]
        )
    }

    private func balance(for userId: UUID, with person: UUID, currency: String = "PLN") async throws -> Int? {
        try await LocalBalanceRepository().fetchBalances(for: userId).balances
            .first { $0.personId == person && $0.currencyCode == currency }?.amountMinor
    }

    func testAcceptedSharesOweThePayerFromBothSides() async throws {
        try await store(dinner(paidBy: me, owed: 1500))
        let mine = try await balance(for: me, with: friend)
        let theirs = try await balance(for: friend, with: me)
        XCTAssertEqual(mine, 1500)
        XCTAssertEqual(theirs, -1500)
    }

    func testUnacceptedSharesCreateNoDebt() async throws {
        try await store(dinner(paidBy: me, owed: 1500, status: .pending), dinner(paidBy: me, owed: 700, status: .rejected))
        let snapshot = try await LocalBalanceRepository().fetchBalances(for: me)
        XCTAssertTrue(snapshot.balances.isEmpty)
    }

    func testOpposingDebtsNetOutPerCurrency() async throws {
        try await store(
            dinner(paidBy: me, owed: 1500),
            dinner(paidBy: friend, owed: 500),
            dinner(paidBy: friend, owed: 900, currency: "EUR")
        )
        let pln = try await balance(for: me, with: friend)
        let eur = try await balance(for: me, with: friend, currency: "EUR")
        XCTAssertEqual(pln, 1000)
        XCTAssertEqual(eur, -900)
    }

    func testRepaymentReducesTheDebtAndReversalRestoresIt() async throws {
        try await store(dinner(paidBy: friend, owed: 2000))
        let repository = LocalBalanceRepository()
        let operation = UUID()

        try await repository.createRepayment(from: me, to: friend, amountMinor: 1200, currencyCode: "pln", note: nil, paidAt: Date(), operationId: operation)
        let afterPayment = try await balance(for: me, with: friend)
        let creditorView = try await balance(for: friend, with: me)
        XCTAssertEqual(afterPayment, -800)
        XCTAssertEqual(creditorView, 800)

        try await repository.reverseRepayment(id: operation, operationId: UUID())
        let afterReversal = try await balance(for: me, with: friend)
        XCTAssertEqual(afterReversal, -2000)
    }

    func testHistoryListsSharesAndRepaymentsSignedForTheViewer() async throws {
        try await store(dinner(paidBy: friend, owed: 2000, currency: "EUR"))
        let repository = LocalBalanceRepository()
        try await repository.createRepayment(from: me, to: friend, amountMinor: 500, currencyCode: "EUR", note: "Cash", paidAt: Date().addingTimeInterval(60), operationId: UUID())

        let mine = try await repository.fetchHistory(for: me, personId: friend)
        XCTAssertEqual(mine.map(\.kind), [.repayment, .purchase])
        XCTAssertEqual(mine.map(\.amountMinor), [500, -2000])
        XCTAssertEqual(mine.map(\.currencyCode), ["EUR", "EUR"])
        XCTAssertEqual(mine.last?.displayTitle, "Dining")

        let theirs = try await repository.fetchHistory(for: friend, personId: me)
        XCTAssertEqual(theirs.map(\.amountMinor), [-500, 2000])
    }

    func testRepaymentsCannotExceedTheDebtOrBeEmpty() async throws {
        try await store(dinner(paidBy: friend, owed: 1000))
        let repository = LocalBalanceRepository()

        do {
            try await repository.createRepayment(from: me, to: friend, amountMinor: 1001, currencyCode: "PLN", note: nil, paidAt: Date(), operationId: UUID())
            XCTFail("Recorded a repayment larger than the debt")
        } catch BalanceRepositoryError.exceedsDebt {}
        do {
            try await repository.createRepayment(from: me, to: friend, amountMinor: 0, currencyCode: "PLN", note: nil, paidAt: Date(), operationId: UUID())
            XCTFail("Recorded an empty repayment")
        } catch BalanceRepositoryError.invalidAmount {}
        do {
            try await repository.createRepayment(from: me, to: friend, amountMinor: 100, currencyCode: "EUR", note: nil, paidAt: Date(), operationId: UUID())
            XCTFail("Repaid a debt in the wrong currency")
        } catch BalanceRepositoryError.exceedsDebt {}
    }

    func testCreditorCannotRecordARepaymentToTheDebtor() async throws {
        try await store(dinner(paidBy: me, owed: 1000))
        do {
            try await LocalBalanceRepository().createRepayment(from: me, to: friend, amountMinor: 100, currencyCode: "PLN", note: nil, paidAt: Date(), operationId: UUID())
            XCTFail("Paid someone who owes me")
        } catch BalanceRepositoryError.exceedsDebt {}
    }
}

final class BalanceSnapshotTests: XCTestCase {
    func testTotalsAreSeparatedByDirectionAndCurrency() {
        let snapshot = BalanceSnapshot(balances: [
            PersonBalance(personId: TestUser.alice, displayName: "A", amountMinor: 1000, currencyCode: "PLN"),
            PersonBalance(personId: TestUser.bob, displayName: "B", amountMinor: 500, currencyCode: "pln"),
            PersonBalance(personId: TestUser.carol, displayName: "C", amountMinor: -300, currencyCode: "EUR"),
        ])
        XCTAssertEqual(snapshot.owedToYou, [Money(amountMinor: 1500, currencyCode: "PLN")])
        XCTAssertEqual(snapshot.youOwe, [Money(amountMinor: 300, currencyCode: "EUR")])
    }

    func testPersonBalanceShowsAPositiveAmountWithADirection() {
        let owing = PersonBalance(personId: TestUser.bob, displayName: "B", amountMinor: -300, currencyCode: "PLN")
        XCTAssertEqual(owing.money.amountMinor, 300)
        XCTAssertEqual(owing.direction, "You owe")
        XCTAssertNotEqual(owing.id, PersonBalance(personId: TestUser.bob, displayName: "B", amountMinor: 1, currencyCode: "EUR").id)
    }
}

final class ActivityTests: LocalStorageTestCase {
    /// Carol acts, so Alice and Bob see her events as unread.
    private func event(_ kind: ActivityEventKind, at seconds: TimeInterval, by actor: UUID = TestUser.carol, expenseId: UUID? = nil, recipient: String? = nil, share: Int = 0) -> ActivityEvent {
        ActivityEvent(
            occurredAt: Date(timeIntervalSince1970: seconds),
            kind: kind,
            actorId: actor,
            actorName: "Carol",
            recipientName: recipient,
            recipientNames: recipient.map { [$0] } ?? [],
            expenseId: expenseId,
            expenseTitle: "Dinner",
            category: .dining,
            affectedShareMinor: share,
            expenseTotalMinor: 900,
            currency: "PLN"
        )
    }

    func testEventsAreVisibleOnlyToTheirAudienceNewestFirst() async throws {
        let repository = LocalActivityRepository()
        let first = event(.edited, at: 100)
        let second = event(.deleted, at: 200)
        try await repository.record(first, audience: [TestUser.alice, TestUser.bob])
        try await repository.record(second, audience: [TestUser.alice])

        let alicePage = try await repository.fetchUnreadEvents(for: TestUser.alice, before: nil)
        let bobPage = try await repository.fetchUnreadEvents(for: TestUser.bob, before: nil)
        XCTAssertEqual(alicePage.events.map(\.id), [second.id, first.id])
        XCTAssertEqual(bobPage.events.map(\.id), [first.id])
    }

    func testPagesContinueAfterTheLastEvent() async throws {
        let repository = LocalActivityRepository()
        for second in 0..<55 {
            try await repository.record(event(.edited, at: TimeInterval(second)), audience: [TestUser.alice])
        }

        let firstPage = try await repository.fetchUnreadEvents(for: TestUser.alice, before: nil)
        let secondPage = try await repository.fetchUnreadEvents(for: TestUser.alice, before: firstPage.nextCursor)

        XCTAssertEqual(firstPage.events.count, 50)
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(secondPage.events.count, 5)
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertTrue(Set(firstPage.events.map(\.id)).isDisjoint(with: secondPage.events.map(\.id)))
    }

    @MainActor
    func testSharingWithSeveralPeopleShowsAsOneHistoryEvent() async throws {
        let expenseId = UUID()
        let repository = LocalActivityRepository()
        try await repository.record(event(.shared, at: 100, expenseId: expenseId, recipient: "Bob", share: 300), audience: [TestUser.alice])
        try await repository.record(event(.shared, at: 100, expenseId: expenseId, recipient: "Carol", share: 300), audience: [TestUser.alice])

        let history = try await ActivityStore().history(forExpense: expenseId, userId: TestUser.alice)

        XCTAssertEqual(history.count, 1)
        // Both rows share a timestamp, so the name order is not defined.
        XCTAssertEqual(Set(history.first?.recipientNames ?? []), ["Bob", "Carol"])
        XCTAssertEqual(history.first?.affectedShareMinor, 600)
        XCTAssertNil(history.first?.recipientName)
    }

    func testOwnActionsAreNeverUnread() async throws {
        let repository = LocalActivityRepository()
        try await repository.record(event(.shared, at: 100, by: TestUser.alice, expenseId: UUID()), audience: [TestUser.alice, TestUser.bob])

        let alicePage = try await repository.fetchUnreadEvents(for: TestUser.alice, before: nil)
        let bobPage = try await repository.fetchUnreadEvents(for: TestUser.bob, before: nil)
        let aliceCount = try await repository.unseenCount(for: TestUser.alice)
        XCTAssertTrue(alicePage.events.isEmpty)
        XCTAssertEqual(aliceCount, 0)
        XCTAssertEqual(bobPage.events.count, 1)
    }

    func testANewerEventAboutTheSameExpenseReadsOlderOnes() async throws {
        let expenseId = UUID()
        let repository = LocalActivityRepository()
        let shared = event(.shared, at: 100, expenseId: expenseId)
        try await repository.record(shared, audience: [TestUser.alice, TestUser.carol])
        try await repository.record(event(.accepted, at: 200, by: TestUser.alice, expenseId: expenseId), audience: [TestUser.alice, TestUser.carol])

        let alicePage = try await repository.fetchUnreadEvents(for: TestUser.alice, before: nil)
        let history = try await repository.fetchExpenseEvents(expenseId: expenseId, userId: TestUser.alice)
        XCTAssertTrue(alicePage.events.isEmpty, "Answering reads the request")
        XCTAssertEqual(history.count, 2, "Read events stay in the expense's history")
        let carolPage = try await repository.fetchUnreadEvents(for: TestUser.carol, before: nil)
        XCTAssertEqual(carolPage.events.map(\.kind), [.accepted])
    }

    @MainActor
    func testMarkingReadRemovesTheEventOnlyForThatPerson() async throws {
        let repository = LocalActivityRepository()
        let edited = event(.edited, at: 100, expenseId: UUID())
        try await repository.record(edited, audience: [TestUser.alice, TestUser.bob])

        let store = ActivityStore()
        await store.refresh(userId: TestUser.alice)
        XCTAssertEqual(store.badgeCount, 1)
        await store.markRead(store.events, userId: TestUser.alice)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.badgeCount, 0)

        await store.refresh(userId: TestUser.alice)
        XCTAssertTrue(store.events.isEmpty)
        let bobCount = try await repository.unseenCount(for: TestUser.bob)
        XCTAssertEqual(bobCount, 1)
    }

    @MainActor
    func testOpeningActivityClearsTheBadgeButKeepsEventsUnread() async throws {
        let repository = LocalActivityRepository()
        try await repository.record(event(.edited, at: 100, expenseId: UUID()), audience: [TestUser.alice, TestUser.bob])

        let store = ActivityStore()
        await store.refresh(userId: TestUser.alice)
        XCTAssertEqual(store.badgeCount, 1)
        store.isInboxVisible = true
        await store.refresh(userId: TestUser.alice)
        XCTAssertEqual(store.badgeCount, 0)
        XCTAssertEqual(store.events.count, 1, "Seen events stay in the inbox until read")

        // Something newer than what was on screen still counts.
        store.isInboxVisible = false
        try await repository.record(event(.edited, at: 200, expenseId: UUID()), audience: [TestUser.alice, TestUser.bob])
        await store.refreshBadgeCount(userId: TestUser.alice)
        XCTAssertEqual(store.badgeCount, 1)
        let bobCount = try await repository.unseenCount(for: TestUser.bob)
        XCTAssertEqual(bobCount, 2, "Seeing is per person")
    }
}
