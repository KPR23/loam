import XCTest

/// End-to-end flows in demo mode: no backend, fresh local storage, English UI.
final class LoamUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-resetLocalData", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // An empty backend URL forces demo mode even in builds configured for staging.
        app.launchEnvironment = ["SUPABASE_URL": "", "SUPABASE_ANON_KEY": ""]
    }

    // MARK: - Flows

    func testDemoSignInLandsOnAnEmptyMonth() {
        signInToDemo()
        XCTAssertTrue(app.staticTexts["No expenses this month yet"].waitForExistence(timeout: 5))
    }

    func testAddButtonsStayDisabledUntilThereIsAnAmount() {
        signInToDemo()
        openAddExpense()

        let quickAdd = app.buttons["Quick add"]
        let details = app.buttons["Add details"]
        XCTAssertFalse(quickAdd.isEnabled)
        XCTAssertFalse(details.isEnabled)

        typeAmount("0")
        XCTAssertFalse(quickAdd.isEnabled, "A zero amount can be saved")

        typeAmount("5")
        XCTAssertTrue(quickAdd.isEnabled)
        XCTAssertTrue(details.isEnabled)
    }

    func testQuickAddShowsTheExpenseAndMonthlyTotal() {
        signInToDemo()
        addExpense(amount: "12,5")

        XCTAssertTrue(expenseRow(containing: "Groceries").waitForExistence(timeout: 5))
        XCTAssertTrue(monthlyTotal(containing: "12.50").exists)
    }

    func testAddingWithDetailsUsesTheTitle() {
        signInToDemo()
        openAddExpense()
        typeAmount("80")
        app.buttons["Add details"].tap()

        let title = app.textFields["Title (optional)"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Concert tickets")
        app.navigationBars.buttons["Save"].tap()

        XCTAssertTrue(expenseRow(containing: "Concert tickets").waitForExistence(timeout: 5))
        XCTAssertTrue(monthlyTotal(containing: "80").exists)
    }

    func testCancellingAddSavesNothing() {
        signInToDemo()
        openAddExpense()
        typeAmount("40")
        app.navigationBars.buttons["Cancel"].tap()

        XCTAssertTrue(app.staticTexts["No expenses this month yet"].waitForExistence(timeout: 5))
    }

    func testDeletingAnExpenseEmptiesTheMonth() {
        signInToDemo()
        addExpense(amount: "30")
        let row = expenseRow(containing: "Groceries")
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.alerts["Delete this expense?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["Delete"].tap()

        XCTAssertTrue(app.staticTexts["No expenses this month yet"].waitForExistence(timeout: 5))
    }

    func testDemoExpensesSurviveARelaunch() {
        signInToDemo()
        addExpense(amount: "45")
        XCTAssertTrue(expenseRow(containing: "Groceries").waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments.removeAll { $0 == "-resetLocalData" }
        signInToDemo()

        XCTAssertTrue(expenseRow(containing: "Groceries").waitForExistence(timeout: 5))
        XCTAssertTrue(monthlyTotal(containing: "45").exists)
    }

    func testEveryTabOpens() {
        signInToDemo()

        tab("Balances").tap()
        XCTAssertTrue(app.staticTexts["No balances yet"].waitForExistence(timeout: 5))

        tab("Activity").tap()
        XCTAssertTrue(app.staticTexts["You're all caught up"].waitForExistence(timeout: 5))

        tab("Profile").tap()
        XCTAssertTrue(scrollDown(to: signOutButton).exists)
    }

    func testSigningOutReturnsToSignIn() {
        signInToDemo()
        tab("Profile").tap()

        scrollDown(to: signOutButton).tap()
        let confirm = app.sheets.buttons["Sign out"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.buttons["Continue without account (demo)"].waitForExistence(timeout: 5))
    }

    // MARK: - Steps

    private func signInToDemo() {
        app.launch()
        let demo = app.buttons["Continue without account (demo)"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "Demo sign-in is missing; is the app in demo mode?")
        demo.tap()
        XCTAssertTrue(addExpenseButton.waitForExistence(timeout: 10))
    }

    private func openAddExpense() {
        addExpenseButton.tap()
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
    }

    /// The floating button, or the empty month's own button while no expenses exist.
    private var addExpenseButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Add expense", "Add an expense"])).firstMatch
    }

    private var amountField: XCUIElement {
        app.textFields["Amount"]
    }

    private func typeAmount(_ text: String) {
        amountField.tap()
        amountField.typeText(text)
    }

    private func addExpense(amount: String) {
        openAddExpense()
        typeAmount(amount)
        app.buttons["Quick add"].tap()
        XCTAssertTrue(addExpenseButton.waitForExistence(timeout: 5))
    }

    private func expenseRow(containing text: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func monthlyTotal(containing amount: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'You spent' AND label CONTAINS %@", amount))
            .firstMatch
    }

    /// Sign out is the last row of the Profile list, below the fold.
    private var signOutButton: XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Sign out'")).firstMatch
    }

    /// Lists only create rows near the screen, so scroll until the row exists.
    @discardableResult
    private func scrollDown(to element: XCUIElement, maxSwipes: Int = 8) -> XCUIElement {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "Scrolled \(maxSwipes) times without reaching the element")
        return element
    }

    private func tab(_ name: String) -> XCUIElement {
        app.tabBars.buttons[name].firstMatch
    }
}
