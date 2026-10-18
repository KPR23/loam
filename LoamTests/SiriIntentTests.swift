import AppIntents
import XCTest
@testable import Loam

/// Runs the Siri actions the way Siri does, against demo (local) storage.
@MainActor
final class SiriIntentTests: LocalStorageTestCase {
    let bob = TestUser.bob
    private var services: AppServices { AppServices.shared }

    private static let lockDomain = "SiriIntentTests.appLock"
    private var lockAuthenticator: SiriLockAuthenticator!

    /// Gives the services an App Lock with its own storage, on or off.
    private func useAppLock(enabled: Bool) {
        let defaults = UserDefaults(suiteName: Self.lockDomain)!
        defaults.removePersistentDomain(forName: Self.lockDomain)
        defaults.set(enabled, forKey: AppLock.enabledKey)
        lockAuthenticator = SiriLockAuthenticator()
        services.appLock = AppLock(defaults: defaults, authenticator: lockAuthenticator)
    }

    /// The demo account, with Bob as its only friend, and App Lock off.
    @discardableResult
    private func signIn() -> UUID {
        useAppLock(enabled: false)
        services.friendsOverride = [SplitPartnerOption(userId: bob, displayName: "Bob")]
        services.navigator.pendingScreen = nil
        services.authSession.signInDemo()
        return services.authSession.userId!
    }

    private func amount(_ value: Decimal, _ currency: String = "PLN") -> IntentCurrencyAmount {
        IntentCurrencyAmount(amount: value, currencyCode: currency)
    }

    // MARK: Adding expenses

    func testAddingAnExpenseByVoiceSavesIt() async throws {
        let me = signIn()
        let intent = AddExpenseIntent()
        intent.amount = amount(Decimal(string: "12.5")!)
        intent.category = .groceries
        intent.title = "Weekly shop"
        _ = try await intent.perform()

        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        let expense = try XCTUnwrap(saved.first)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(expense.amountMinor, 1250)
        XCTAssertEqual(expense.currency, "PLN")
        XCTAssertEqual(expense.category, .groceries)
        XCTAssertEqual(expense.title, "Weekly shop")
        XCTAssertEqual(expense.shareRecord(for: me)?.amountMinor, 1250)
        XCTAssertEqual(services.expenseStore.summary.totalMine.amountMinor, 1250, "Home shows it without a reload")
    }

    func testAnExpenseWithoutACategoryIsOther() async throws {
        let me = signIn()
        let intent = AddExpenseIntent()
        intent.amount = amount(20, "EUR")
        _ = try await intent.perform()

        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        let expense = try XCTUnwrap(saved.first)
        XCTAssertEqual(expense.category, .other)
        XCTAssertEqual(expense.currency, "EUR")
    }

    func testSplittingWithAFriendAsksThemToAccept() async throws {
        let me = signIn()
        let intent = AddExpenseIntent()
        intent.amount = amount(30)
        intent.category = .dining
        intent.friend = LoamFriendEntity(id: bob, name: "Bob")
        _ = try await intent.perform()

        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        let expense = try XCTUnwrap(saved.first)
        XCTAssertEqual(expense.paidBy, me)
        XCTAssertEqual(expense.shareRecord(for: me)?.amountMinor, 1500)
        XCTAssertEqual(expense.shareRecord(for: bob)?.amountMinor, 1500)
        XCTAssertEqual(expense.shareStatus(for: bob), .pending)
    }

    func testSplittingWithSomeoneWhoIsNotAFriendIsRefused() async throws {
        let me = signIn()
        let intent = AddExpenseIntent()
        intent.amount = amount(30)
        intent.friend = LoamFriendEntity(id: TestUser.carol, name: "Carol")
        do {
            _ = try await intent.perform()
            XCTFail("Expected the split to be refused")
        } catch {
            XCTAssertEqual(error as? LoamIntentError, .noFriend)
        }
        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertTrue(saved.isEmpty)
    }

    func testAnUnusableAmountIsAskedForAgain() async throws {
        let me = signIn()
        // Shortcuts pre-fills an empty amount in the region's currency, e.g. 0 ADP.
        for unusable in [amount(10, "GBP"), amount(0, "ADP"), amount(0, "PLN")] {
            let intent = AddExpenseIntent()
            intent.amount = unusable
            do {
                _ = try await intent.perform()
                XCTFail("Expected \(unusable.amount) \(unusable.currencyCode) to be asked for again")
            } catch {
                XCTAssertNil(error as? LoamIntentError, "Siri asks for the amount instead of failing")
            }
        }
        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertTrue(saved.isEmpty)
    }

    func testSignedOutActionsAskToSignIn() async throws {
        signIn()
        await services.authSession.signOut()
        let intent = GetBalancesIntent()
        do {
            _ = try await intent.perform()
            XCTFail("Expected a sign-in error")
        } catch {
            XCTAssertEqual(error as? LoamIntentError, .signedOut)
        }
    }

    // MARK: App Lock

    func testLockedAppAnswersNothing() async throws {
        let me = signIn()
        useAppLock(enabled: true)
        XCTAssertTrue(services.appLock.isLocked)

        let add = AddExpenseIntent()
        add.amount = amount(20)
        await assertLocked { _ = try await add.perform() }
        await assertLocked { _ = try await GetMonthlySpendingIntent().perform() }
        await assertLocked { _ = try await GetBalancesIntent().perform() }
        await assertLocked { _ = try await GetPendingExpensesIntent().perform() }
        let settle = SettleUpIntent()
        settle.friend = LoamFriendEntity(id: bob, name: "Bob")
        await assertLocked { _ = try await settle.perform() }

        let suggested = try await LoamFriendQuery().suggestedEntities()
        XCTAssertTrue(suggested.isEmpty)
        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertTrue(saved.isEmpty)
    }

    func testUnlockedAppAnswersAgain() async throws {
        signIn()
        useAppLock(enabled: true)
        lockAuthenticator.result = .success
        await services.appLock.unlock()
        XCTAssertFalse(services.appLock.isLocked)

        _ = try await GetBalancesIntent().perform()
        let suggested = try await LoamFriendQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), [bob])
    }

    func testLockTurnedOffChangesNothing() async throws {
        let me = signIn()
        XCTAssertFalse(services.appLock.isEnabled)
        services.appLock.appDidEnterBackground()
        XCTAssertFalse(services.appLock.isLocked)

        let intent = AddExpenseIntent()
        intent.amount = amount(15)
        _ = try await intent.perform()
        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertEqual(saved.count, 1)
    }

    private func assertLocked(_ action: () async throws -> Void, line: UInt = #line) async {
        do {
            try await action()
            XCTFail("Expected the locked error", line: line)
        } catch {
            XCTAssertEqual(error as? LoamIntentError, .locked, line: line)
        }
    }

    // MARK: Spending, balances and pending expenses

    func testMonthlySpendingCountsWhatWasAdded() async throws {
        let me = signIn()
        try await services.expenseStore.addPersonal(amountMinor: 4000, currency: "PLN", category: .groceries, note: nil, spentAt: Date(), userId: me)
        try await services.expenseStore.addPersonal(amountMinor: 1000, currency: "PLN", category: .transport, note: nil, spentAt: Date(), userId: me)
        _ = try await GetMonthlySpendingIntent().perform()

        let summary = try await services.currentMonthSummary(userId: me)
        XCTAssertEqual(summary.totalMine.amountMinor, 5000)
        XCTAssertEqual(SiriText.monthlySpending(summary, category: .groceries), "You've spent 40 zł on Groceries this month.")
    }

    func testSettlingUpWithoutAnAmountClearsTheBalance() async throws {
        let me = signIn()
        let add = AddExpenseIntent()
        add.amount = amount(30)
        add.friend = LoamFriendEntity(id: bob, name: "Bob")
        _ = try await add.perform()

        let bobsStore = ExpenseStore()
        await bobsStore.refresh(userId: bob)
        await bobsStore.respondToShares(expenseIds: bobsStore.pendingAcceptanceExpenses.map(\.id), userId: bob, action: .accept)

        let before = try await services.balances(userId: me)
        let plan = RepaymentPlan.make(balances: before.balances.filter { $0.personId == bob }, amount: nil, direction: nil)
        XCTAssertEqual(plan, .record(.theyPaidMe, Money(amountMinor: 1500, currencyCode: "PLN")))

        guard case let .record(direction, money) = plan else { return }
        try await SettleUpIntent.record(direction, money: money, with: bob, userId: me)

        let after = try await services.balances(userId: me)
        XCTAssertTrue(after.balances.filter { $0.amountMinor != 0 }.isEmpty)
        XCTAssertEqual(SiriText.balances(after, friend: LoamFriendEntity(id: bob, name: "Bob")), "You and Bob are settled up.")
    }

    func testPendingExpensesAreTheOnesWaitingForMe() async throws {
        let me = signIn()
        try await ExpenseStore().addSplit(amountMinor: 2000, currency: "PLN", category: .dining, note: nil, spentAt: Date(), userId: bob, splitMode: .equal, paidBy: bob, partnerUserIds: [me])
        _ = try await GetPendingExpensesIntent().perform()

        let pending = try await services.pendingExpenses(userId: me)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(SiriText.pendingExpenses(pending).hasPrefix("1 expense is waiting for your answer"))
    }

    func testOpeningAScreenAsksTheTabsToShowIt() async throws {
        signIn()
        let intent = OpenLoamScreenIntent()
        intent.screen = .balances
        _ = try await intent.perform()
        XCTAssertEqual(services.navigator.pendingScreen, .balances)
    }

    func testFriendQueryFindsFriendsByFirstName() async throws {
        signIn()
        services.friendsOverride = [
            SplitPartnerOption(userId: bob, displayName: "Bob Kowalski"),
            SplitPartnerOption(userId: TestUser.carol, displayName: "Carol"),
        ]
        let matches = try await LoamFriendQuery().entities(matching: "bob")
        XCTAssertEqual(matches.map(\.id), [bob])
        let suggested = try await LoamFriendQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.name), ["Bob Kowalski", "Carol"])
    }
}

/// Answers every App Lock prompt with `result`.
@MainActor
private final class SiriLockAuthenticator: DeviceAuthenticating {
    var result: DeviceAuthenticationResult = .failed

    func unlockMethod() -> DeviceUnlockMethod { .faceID }

    func authenticate(reason: String) async -> DeviceAuthenticationResult { result }
}

/// The parts of the Siri actions that need no storage.
final class SiriLogicTests: XCTestCase {
    let bob = TestUser.bob

    func testAmountsBecomeMinorUnitsWithoutRoundingErrors() throws {
        XCTAssertEqual(try SiriAmount.money(amount: Decimal(string: "19.99")!, currencyCode: "pln"), Money(amountMinor: 1999, currencyCode: "PLN"))
        XCTAssertEqual(try SiriAmount.money(amount: Decimal(string: "0.105")!, currencyCode: "EUR").amountMinor, 11)
        XCTAssertEqual(try SiriAmount.money(amount: 7, currencyCode: "USD").amountMinor, 700)
        XCTAssertThrowsError(try SiriAmount.money(amount: 0, currencyCode: "PLN")) {
            XCTAssertEqual($0 as? LoamIntentError, .invalidAmount)
        }
        XCTAssertThrowsError(try SiriAmount.money(amount: Decimal(string: "0.004")!, currencyCode: "PLN"))
        XCTAssertThrowsError(try SiriAmount.money(amount: 5, currencyCode: "GBP")) {
            XCTAssertEqual($0 as? LoamIntentError, .unsupportedCurrency("GBP"))
        }
    }

    private func balance(_ amountMinor: Int, _ currency: String = "PLN") -> PersonBalance {
        PersonBalance(personId: bob, displayName: "Bob", amountMinor: amountMinor, currencyCode: currency)
    }

    func testSettlingUpFollowsTheBalance() {
        let pln = { Money(amountMinor: $0, currencyCode: "PLN") }
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(1500)], amount: nil, direction: nil), .record(.theyPaidMe, pln(1500)))
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(-800)], amount: nil, direction: nil), .record(.iPaidThem, pln(800)))
        XCTAssertEqual(RepaymentPlan.make(balances: [], amount: nil, direction: nil), .settledUp)
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(0)], amount: nil, direction: nil), .settledUp)
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(1500), balance(200, "EUR")], amount: nil, direction: nil), .needsAmount)
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(1500)], amount: nil, direction: .iPaidThem), .nothingToSettle, "Bob owes me, so I have nothing to pay back")
    }

    func testSettlingUpPartOfABalance() {
        let part = Money(amountMinor: 500, currencyCode: "PLN")
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(1500)], amount: part, direction: nil), .record(.theyPaidMe, part))
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(-1500)], amount: part, direction: nil), .record(.iPaidThem, part))
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(1500)], amount: part, direction: .theyPaidMe), .record(.theyPaidMe, part))
    }

    func testSettlingUpNeverRecordsWhatTheBalanceWouldRefuse() {
        let part = Money(amountMinor: 500, currencyCode: "PLN")
        let pln = { Money(amountMinor: $0, currencyCode: "PLN") }
        XCTAssertEqual(RepaymentPlan.make(balances: [], amount: part, direction: nil), .nothingToSettle)
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(200, "EUR")], amount: part, direction: nil), .nothingToSettle)
        XCTAssertEqual(RepaymentPlan.make(balances: [], amount: part, direction: .iPaidThem), .nothingToSettle)
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(1500)], amount: part, direction: .iPaidThem), .nothingToSettle, "Bob owes me, not the other way")
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(1500)], amount: pln(2000), direction: nil), .exceedsBalance(.theyPaidMe, pln(1500)))
        XCTAssertEqual(RepaymentPlan.make(balances: [balance(-1500)], amount: pln(1500), direction: nil), .record(.iPaidThem, pln(1500)))
    }

    func testFriendNamesMatchByWordIgnoringCaseAndAccents() {
        let zoe = LoamFriendEntity(id: TestUser.alice, name: "Zoë Nowak")
        let bob = LoamFriendEntity(id: TestUser.bob, name: "Bob")
        let bobby = LoamFriendEntity(id: TestUser.carol, name: "Bobby")
        let friends = [zoe, bob, bobby]
        XCTAssertEqual(LoamFriendMatcher.matches(for: "zoe", in: friends), [zoe])
        XCTAssertEqual(LoamFriendMatcher.matches(for: "Bob", in: friends), [bob], "An exact name wins over a longer one")
        XCTAssertEqual(LoamFriendMatcher.matches(for: "bobb", in: friends), [bobby])
    }

    func testBalanceAnswers() {
        let carol = TestUser.carol
        let snapshot = BalanceSnapshot(balances: [
            PersonBalance(personId: bob, displayName: "Bob", amountMinor: 1500, currencyCode: "PLN"),
            PersonBalance(personId: carol, displayName: "Carol", amountMinor: -300, currencyCode: "PLN"),
        ])
        XCTAssertEqual(SiriText.balances(.empty, friend: nil), "You're all settled up.")
        let awaitingOnly = BalanceSnapshot(balances: [], awaiting: [AwaitingBalance(personId: bob, amountMinor: 1500, currencyCode: "PLN", expenseCount: 1)])
        XCTAssertEqual(SiriText.balances(awaitingOnly, friend: nil), "You're settled up, but another 15 zł is waiting for friends to accept.")
        XCTAssertEqual(
            SiriText.balances(snapshot, friend: nil),
            "You're owed 15 zł and you owe 3 zł. Bob owes you 15 zł. You owe Carol 3 zł."
        )
        XCTAssertEqual(SiriText.balances(snapshot, friend: LoamFriendEntity(id: carol, name: "Carol")), "You owe Carol 3 zł.")
    }
}
