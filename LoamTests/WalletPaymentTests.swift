import XCTest
@testable import Loam

/// The Apple Pay "Transaction" automation action and how it reads what Wallet sends.
@MainActor
final class WalletPaymentTests: LocalStorageTestCase {
    private var services: AppServices { AppServices.shared }

    private func signIn() -> UUID {
        services.navigator.pendingScreen = nil
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
        XCTAssertEqual(MerchantCategory.guess(for: "Restauracja Pod Lipą"), .dining)
        XCTAssertEqual(MerchantCategory.guess(for: "McDonald's 0412"), .dining)
    }

    func testSimilarNamesDontMatchByAccident() {
        XCTAssertEqual(MerchantCategory.guess(for: "UBER *EATS"), .dining)
        XCTAssertEqual(MerchantCategory.guess(for: "Uber *Trip"), .transport)
        XCTAssertEqual(MerchantCategory.guess(for: "Benetton"), .other)
        XCTAssertEqual(MerchantCategory.guess(for: "Sparkasse"), .other)
        XCTAssertEqual(MerchantCategory.guess(for: "Facebook Marketplace"), .other)
        XCTAssertEqual(MerchantCategory.guess(for: "Republic Records"), .other)
        XCTAssertEqual(MerchantCategory.guess(for: "Kinokuniya"), .other)
        XCTAssertEqual(MerchantCategory.guess(for: "Google Play"), .other)
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

    func testAnUnsupportedCurrencySavesNothing() async throws {
        let me = signIn()
        let intent = LogWalletPaymentIntent()
        intent.amount = 15
        intent.currencyCode = "GBP"
        intent.merchant = "Pret"
        intent.mode = .addNow
        _ = try await intent.perform()

        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertTrue(saved.isEmpty)
    }

    func testARefundSavesNothing() async throws {
        let me = signIn()
        let intent = LogWalletPaymentIntent()
        intent.amount = -20
        intent.currencyCode = "PLN"
        intent.merchant = "Zara"
        intent.mode = .addNow
        _ = try await intent.perform()

        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertTrue(saved.isEmpty)
    }

    func testAskFirstWithoutNotificationsAddsRightAway() async throws {
        let me = signIn()
        let intent = LogWalletPaymentIntent()
        intent.amount = 7
        intent.currencyCode = "PLN"
        intent.merchant = "Żabka"
        intent.mode = .askFirst
        _ = try await intent.perform()

        let saved = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertEqual(saved.first?.amountMinor, 700)
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

    // MARK: Picking a category without one

    private let someone = UUID()

    private final class Counter: @unchecked Sendable { var count = 0 }
    private let coffee = CustomCategory(id: UUID(), ownerId: UUID(), name: "Coffee", symbol: "cup.and.saucer", colorHex: "8B5A2B")

    private func chain(
        options: [SpendCategory]? = nil,
        remembered: String? = nil,
        model: SpendCategory? = nil,
        modelCalls: Counter? = nil
    ) -> WalletCategoryChain {
        let offered = options ?? ExpenseCategory.allCases.map(SpendCategory.builtIn)
        return WalletCategoryChain(
            options: { _ in offered },
            remembered: { _, _ in remembered },
            model: { _, _, _ in
                modelCalls?.count += 1
                return model
            }
        )
    }

    private let fivePLN = Money(amountMinor: 500, currencyCode: "PLN")

    func testARememberedCategoryWinsOverKeywordsAndTheModel() async {
        let picked = await chain(remembered: ExpenseCategory.shopping.rawValue, model: .builtIn(.dining))
            .pick(merchant: "Żabka", money: fivePLN, userId: someone)
        XCTAssertEqual(picked, .builtIn(.shopping))
    }

    func testARememberedCustomCategoryIsUsed() async {
        let options = ExpenseCategory.allCases.map(SpendCategory.builtIn) + [.custom(coffee)]
        let picked = await chain(options: options, remembered: coffee.id.uuidString)
            .pick(merchant: "Żabka", money: fivePLN, userId: someone)
        XCTAssertEqual(picked, .custom(coffee))
    }

    func testARememberedCategoryThatIsGoneFallsThrough() async {
        // A deleted custom category, or one the picker no longer offers.
        let picked = await chain(remembered: UUID().uuidString).pick(merchant: "Żabka", money: fivePLN, userId: someone)
        XCTAssertEqual(picked, .builtIn(.groceries))
    }

    func testKeywordsWinOverTheModelWhichIsNotAsked() async {
        let calls = Counter()
        let picked = await chain(model: .builtIn(.shopping), modelCalls: calls).pick(merchant: "Biedronka", money: fivePLN, userId: someone)
        XCTAssertEqual(picked, .builtIn(.groceries))
        XCTAssertEqual(calls.count, 0)
    }

    func testAHiddenKeywordCategoryAsksTheModel() async {
        let options = ExpenseCategory.allCases.filter { $0 != .groceries }.map(SpendCategory.builtIn) + [.custom(coffee)]
        let picked = await chain(options: options, model: .custom(coffee)).pick(merchant: "Biedronka", money: fivePLN, userId: someone)
        XCTAssertEqual(picked, .custom(coffee))
    }

    func testTheModelFilesAnUnknownMerchant() async {
        let picked = await chain(model: .builtIn(.entertainment)).pick(merchant: "Teatr Roma", money: fivePLN, userId: someone)
        XCTAssertEqual(picked, .builtIn(.entertainment))
    }

    func testWithoutTheModelAnUnknownMerchantIsOther() async {
        let picked = await chain(model: nil).pick(merchant: "Teatr Roma", money: fivePLN, userId: someone)
        XCTAssertEqual(picked, .builtIn(.other))
    }

    func testAModelAnswerThePickerDoesntOfferIsOther() async {
        let picked = await chain(model: .custom(coffee)).pick(merchant: "Teatr Roma", money: fivePLN, userId: someone)
        XCTAssertEqual(picked, .builtIn(.other))
    }

    func testASlowAnswerIsDropped() async {
        let answer = await OnDeviceCategoryModel.firstAnswer(within: .milliseconds(50)) { () async -> String? in
            try? await Task.sleep(for: .seconds(5))
            return "late"
        }
        XCTAssertNil(answer)
        let quick = await OnDeviceCategoryModel.firstAnswer(within: .seconds(5)) { () async -> String? in "now" }
        XCTAssertEqual(quick, "now")
    }

    // MARK: Remembering categories

    private func memory() -> MerchantCategoryMemory {
        let name = "WalletPaymentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return MerchantCategoryMemory(defaults: defaults)
    }

    func testTheLastChoiceForAMerchantIsRemembered() {
        let memory = memory()
        memory.remember(.builtIn(.groceries), for: "Żabka", userId: someone)
        memory.remember(.custom(coffee), for: "ZABKA", userId: someone)
        XCTAssertEqual(memory.categoryId(for: "żabka", userId: someone), coffee.id.uuidString)
        XCTAssertNil(memory.categoryId(for: "Żabka", userId: UUID()))
        XCTAssertNil(memory.categoryId(for: "Lidl", userId: someone))
    }

    func testStoreNumbersDontSplitAMerchant() {
        let memory = memory()
        memory.remember(.builtIn(.transport), for: "ORLEN STACJA 123", userId: someone)
        XCTAssertEqual(memory.categoryId(for: "Orlen Stacja 456", userId: someone), ExpenseCategory.transport.rawValue)
        XCTAssertEqual(MerchantCategoryMemory.key(for: "7-11"), "7 11")
        XCTAssertNil(MerchantCategoryMemory.key(for: " - "))
    }

    func testNoTitleRemembersNothing() {
        let memory = memory()
        memory.remember(.builtIn(.dining), for: nil, userId: someone)
        memory.remember(.builtIn(.dining), for: "  ", userId: someone)
        XCTAssertNil(memory.categoryId(for: "", userId: someone))
    }

    func testTheOldestChoicesGoPastTheLimit() {
        let memory = memory()
        let start = Date(timeIntervalSince1970: 0)
        // Letters only, since numbers are left out of the name.
        func name(_ index: Int) -> String {
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            return "Place \(letters[index / 26 % 26])\(letters[index % 26])"
        }
        for index in 0...MerchantCategoryMemory.limit {
            memory.remember(.builtIn(.dining), for: name(index), userId: someone, at: start.addingTimeInterval(Double(index)))
        }
        XCTAssertNil(memory.categoryId(for: name(0), userId: someone))
        XCTAssertNotNil(memory.categoryId(for: name(1), userId: someone))
        XCTAssertNotNil(memory.categoryId(for: name(MerchantCategoryMemory.limit), userId: someone))
    }

    // MARK: The action with the chain

    func testTheActionUsesTheChainWhenNoCategoryIsSet() async throws {
        let me = signIn()
        let saved = WalletCategoryChain.current
        defer { WalletCategoryChain.current = saved }
        WalletCategoryChain.current = chain(model: .builtIn(.entertainment))

        let intent = LogWalletPaymentIntent()
        intent.amount = 30
        intent.currencyCode = "PLN"
        intent.merchant = "Teatr Roma"
        intent.mode = .addNow
        _ = try await intent.perform()

        let expenses = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertEqual(expenses.first?.category, .entertainment)
    }

    func testTheActionsCategoryWinsOverTheChain() async throws {
        let me = signIn()
        let saved = WalletCategoryChain.current
        defer { WalletCategoryChain.current = saved }
        WalletCategoryChain.current = chain(remembered: ExpenseCategory.shopping.rawValue)

        let intent = LogWalletPaymentIntent()
        intent.amount = 30
        intent.currencyCode = "PLN"
        intent.merchant = "Żabka"
        intent.category = .health
        intent.mode = .addNow
        _ = try await intent.perform()

        let expenses = try await LocalExpenseRepository().fetchExpenses(for: me, in: .currentMonth)
        XCTAssertEqual(expenses.first?.category, .health)
    }

    func testFilingUnderACustomCategoryKeepsOtherAsTheBuiltIn() throws {
        let payment = try WalletPayment.make(amount: 5, currencyCode: "PLN", merchant: "Żabka", category: nil, paidAt: Date())
            .filed(under: .custom(coffee))
        XCTAssertEqual(payment.category, .other)
        XCTAssertEqual(payment.spendCategory, .custom(coffee))
    }

    func testAnAskNotificationFromBeforeCustomCategoriesStillDecodes() throws {
        let json = #"{"money":{"amountMinor":400,"currencyCode":"EUR"},"merchant":"Starbucks","category":"dining","paidAt":0}"#
        let payment = try JSONDecoder().decode(WalletPayment.self, from: Data(json.utf8))
        XCTAssertNil(payment.customCategory)
        XCTAssertEqual(payment.spendCategory, .builtIn(.dining))
    }
}
