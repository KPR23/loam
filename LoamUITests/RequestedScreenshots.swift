import XCTest

/// Screens a PR can ask for by name. The workflow reads a `Screenshots:` line in the PR description
/// (for example `Screenshots: profile-bottom, activity`) and passes the names here through
/// SCREENSHOT_SCREENS. A PR that needs a screen no one has captured yet adds an entry below: the closure
/// starts on the Expenses tab, does whatever setup the screen needs (open a sheet, pull down for search,
/// long-press a row) and calls `capture`. It should leave the app on a tab screen again.
enum RequestedScreens {
    static let steps: [String: (ScreenshotTestCase) throws -> Void] = [
        "activity": { test in
            test.tab("Activity").tap()
            test.settle(2)
            try test.capture("activity")
        },
        "profile-bottom": { test in
            test.tab("Profile").tap()
            test.settle(1.5)
            for _ in 0..<3 { test.app.swipeUp() }
            test.settle(1)
            try test.capture("profile-bottom")
        },
        "notification-settings": { test in
            test.tab("Profile").tap()
            test.settle(1.5)
            let row = test.app.buttons["Notifications"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Notifications row is missing in Profile")
            row.tap()
            test.settle(1.5)
            try test.capture("notification-settings")
            test.app.navigationBars.buttons.firstMatch.tap()
        },
        "expense-menu": { test in
            let row = test.app.buttons.containing(NSPredicate(format: "label CONTAINS 'Weekly shop'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Seeded expense 'Weekly shop' is missing")
            row.press(forDuration: 1.2)
            test.settle(1)
            try test.capture("expense-menu")
            test.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        },
    ]
}

/// Runs the screens named in SCREENSHOT_SCREENS after the default set. Nothing is requested on most PRs.
final class RequestedScreenshots: ScreenshotTestCase {
    func testRequestedScreens() throws {
        let names = (ProcessInfo.processInfo.environment["SCREENSHOT_SCREENS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try XCTSkipIf(names.isEmpty, "No extra screens requested")
        let unknown = names.filter { RequestedScreens.steps[$0] == nil }
        XCTAssertTrue(unknown.isEmpty, "Unknown screens \(unknown). Known: \(RequestedScreens.steps.keys.sorted()). Add one in RequestedScreenshots.swift.")

        signIn()
        settle(3)
        for name in names {
            tab("Expenses").tap()
            settle(1)
            try RequestedScreens.steps[name]?(self)
        }
    }
}
