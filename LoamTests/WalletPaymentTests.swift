import XCTest
@testable import Loam

/// The Apple Pay "Transaction" automation action and how it reads what Wallet sends.
@MainActor
final class WalletPaymentTests: LocalStorageTestCase {
    private var services: AppServices { AppServices.shared }

    private func signIn() -> UUID {
        services.authSession.signInDemo()
        return services.authSession.userId!
    }

    // MARK: Reading Wallet's values

    func testAmountKeepsItsCents() throws {
        let payment = try WalletPayment.make(amount: 12.3, currencyCode: "PLN", merchant: "Żabka", category: nil, paidAt: Date())
        XCTAssertEqual(payment.money, Money(amountMinor: 1230, currencyCode: "PLN"))
        XCTAssertEqual(payment.merchant, "Żabka")
    }

    func testZeroOrMissingAmountIsRejected() {
        XCTAssertThrowsError(try WalletPayment.make(amount: 0, currencyCode: "PLN", merchant: "Lidl", category: nil, paidAt: Date()))
        XCTAssertThrowsError(try WalletPayment.make(amount: nil, currencyCode: "PLN", merchant: "Lidl", category: nil, paidAt: Date()))
    }

    func testCurrencySymbolsAndEmptyCodes() {
        XCTAssertEqual(WalletPayment.currency(from: "pln"), "PLN")
        XCTAssertEqual(WalletPayment.currency(from: "zł"), "PLN")
        XCTAssertEqual(WalletPayment.currency(from: "€"), "EUR")
        XCTAssertEqual(WalletPayment.currency(from: " "), AppPreferences.defaultCurrencyCode)
        XCTAssertEqual(WalletPayment.currency(from: nil), AppPreferences.defaultCurrencyCode)
    }

    func testUnsupportedCurrencyIsRejected() {
        XCTAssertThrowsError(try WalletPayment.make(amount: 5, currencyCode: "GBP", merchant: nil, category: nil, paidAt: Date()))
    }

    func testBlankMerchantIsDropped() throws {
        let payment = try WalletPayment.make(amount: 5, currencyCode: "EUR", merchant: "  ", category: nil, paidAt: Date())
        XCTAssertNil(payment.merchant)
        XCTAssertEqual(payment.category, .other)
    }

    // MARK: Guessing the category

    func testCategoryIsGuessedFromTheMerchant() {
        XCTAssertEqual(MerchantCategory.guess(for: "ŻABKA Z1234 WARSZAWA"), .groceries)
        XCTAssertEqual(MerchantCategory.guess(for: "Bolt.eu"), .transport)
        XCTAssertEqual(MerchantCategory.guess(for: "Apteka Gemini"), .health)
        XCTAssertEqual(MerchantCategory.guess(for: "Orlen Stacja 123"), .transport)
        XCTAssertEqual(MerchantCategory.guess(for: "Some Unknown Shop Ltd"), .other)
        XCTAssertEqual(MerchantCategory.guess(for: nil), .other)
    }

    func testAChosenCategoryWinsOverTheGuess() throws {
        let payment = try WalletPayment.make(amount: 5, currencyCode: "PLN", merchant: "Żabka", category: .dining, paidAt: Date())
        XCTAssertEqual(payment.category, .dining)
    }

    // MARK: The action

    func testAddRightAwaySavesAPersonalExpense() async throws {
        let me = signIn()
        let intent = LogWalletPaymentIntent()
        intent.amount = 23.99
        intent.currencyCode = "PLN"
        intent.merchant = "Biedronka"
        intent.mode = .addNow
        _ = try await intent.perform()

        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        let expense = try XCTUnwrap(saved.first)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(expense.amountMinor, 2399)
        XCTAssertEqual(expense.currency, "PLN")
        XCTAssertEqual(expense.title, "Biedronka")
        XCTAssertEqual(expense.category, .groceries)
        XCTAssertEqual(expense.shareRecord(for: me)?.amountMinor, 2399)
    }

    func testAMissingAmountSavesNothing() async throws {
        let me = signIn()
        let intent = LogWalletPaymentIntent()
        intent.amount = 0
        intent.merchant = "Lidl"
        intent.mode = .addNow
        _ = try await intent.perform()

        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertTrue(saved.isEmpty)
    }

    func testUndoFromTheNotificationDeletesTheExpense() async throws {
        let me = signIn()
        let payment = try WalletPayment.make(amount: 9.5, currencyCode: "PLN", merchant: "Lidl", category: nil, paidAt: Date())
        let id = try await LogWalletPaymentIntent.save(payment, userId: me)

        let handled = await WalletPaymentNotifier.shared.handle(
            category: WalletPaymentNotifier.Category.added,
            action: WalletPaymentNotifier.Action.undo,
            userInfo: ["wallet_expense_id": id.uuidString, "user_id": me.uuidString]
        )
        XCTAssertTrue(handled)
        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertTrue(saved.isEmpty)
    }

    func testAddFromTheAskNotificationSavesIt() async throws {
        let me = signIn()
        let payment = try WalletPayment.make(amount: 4, currencyCode: "EUR", merchant: "Starbucks", category: nil, paidAt: Date())
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(payment), encoding: .utf8))

        _ = await WalletPaymentNotifier.shared.handle(
            category: WalletPaymentNotifier.Category.ask,
            action: WalletPaymentNotifier.Action.add,
            userInfo: ["wallet_payment": json, "user_id": me.uuidString]
        )
        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertEqual(saved.first?.amountMinor, 400)
        XCTAssertEqual(saved.first?.category, .dining)
    }

    func testOtherNotificationsAreLeftAlone() async {
        let handled = await WalletPaymentNotifier.shared.handle(category: "", action: "", userInfo: [:])
        XCTAssertFalse(handled)
    }
}
