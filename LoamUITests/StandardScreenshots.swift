import XCTest

/// The screens every UI PR shows: each main tab and the add-expense sheet, with the seeded sample data.
/// A PR that names screens in its `Screenshots:` line gets only those, unless the line also says `standard`.
final class StandardScreenshots: ScreenshotTestCase {
    func testMainScreens() throws {
        let names = Self.requestedNames
        try XCTSkipIf(!names.isEmpty && !names.contains("standard"), "Only the requested screens were asked for")
        signIn()
        settle(3)
        try capture("01-home")

        let addExpense = app.buttons["Add expense"].firstMatch
        if addExpense.waitForExistence(timeout: 5) {
            addExpense.tap()
            XCTAssertTrue(app.textFields["Amount"].waitForExistence(timeout: 5))
            app.textFields["Amount"].tap()
            app.textFields["Amount"].typeText("42")
            try capture("02-add-expense")
            app.navigationBars.buttons["Cancel"].tap()
        }

        tab("Balances").tap()
        settle(2.5)
        try capture("03-balances")

        tab("Activity").tap()
        settle(2)
        try capture("04-activity")

        tab("Profile").tap()
        settle(1.5)
        try capture("05-profile")
    }
}
