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
            test.openProfileRow("Settings")
            test.openProfileRow("Notifications")
            try test.capture("notification-settings")
            test.swipeBack()
            test.swipeBack()
        },
        "profile-settings": { test in
            test.tab("Profile").tap()
            test.settle(1.5)
            test.openProfileRow("Settings")
            try test.capture("profile-settings")
            test.swipeBack()
        },
        "friends": { test in
            test.tab("Profile").tap()
            test.settle(1.5)
            test.openProfileRow("Friends")
            try test.capture("friends")
            test.swipeBack()
        },
        "share-code": { test in
            test.tab("Profile").tap()
            test.settle(1.5)
            test.openProfileRow("Friends")
            test.openProfileRow("Share my code")
            test.settle(1.5)
            try test.capture("share-code")
            test.swipeBack()
            test.swipeBack()
        },
        "profile-about": { test in
            test.tab("Profile").tap()
            test.settle(1.5)
            for _ in 0..<2 { test.app.swipeUp() }
            test.openProfileRow("About & legal")
            try test.capture("profile-about")
            test.swipeBack()
        },
        "home-scrolled": { test in
            // A slow drag with no fling, far enough past the point where the amount moves into the top bar.
            let start = test.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.1, thenDragTo: test.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            test.settle(1.5)
            try test.capture("home-scrolled")
            test.app.swipeDown()
            test.settle(1)
        },
        "about-app": { test in
            test.tab("Profile").tap()
            test.settle(1.5)
            for _ in 0..<2 { test.app.swipeUp() }
            test.openProfileRow("About & legal")
            test.openProfileRow("About the app")
            try test.capture("about-app")
            test.swipeBack()
            test.swipeBack()
        },
        "remove-friend": { test in
            test.tab("Profile").tap()
            test.settle(1.5)
            test.openProfileRow("Friends")
            let row = test.app.staticTexts["Philip"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Seeded friend 'Philip' is missing")
            row.press(forDuration: 1.2)
            test.settle(1)
            test.app.buttons["Remove friend"].firstMatch.tap()
            test.settle(1)
            try test.capture("remove-friend")
            // iOS 26 shows the dialog without a Cancel button; tapping outside dismisses it.
            test.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            test.settle(1)
            test.swipeBack()
        },
        "splitwise-import": { test in
            // The system file picker can't be driven, so the app opens the sheet with a built-in export.
            test.tab("Profile").tap()
            test.settle(1.5)
            test.openProfileRow("Friends")
            let importButton = test.app.buttons["Import from Splitwise"].firstMatch
            XCTAssertTrue(importButton.waitForExistence(timeout: 5), "Import from Splitwise row is missing")
            importButton.tap()
            test.settle(2)
            try test.capture("splitwise-import")
            test.app.buttons["Cancel"].firstMatch.tap()
            test.settle(1)
            test.swipeBack()
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

/// Runs the screens named in SCREENSHOT_SCREENS after the standard set (or instead of it). Nothing is requested on most PRs.
final class RequestedScreenshots: ScreenshotTestCase {
    func testRequestedScreens() throws {
        let names = Self.requestedNames.filter { $0 != "standard" }
        try XCTSkipIf(names.isEmpty, "No extra screens requested")
        let unknown = names.filter { RequestedScreens.steps[$0] == nil }
        XCTAssertTrue(unknown.isEmpty, "Unknown screens \(unknown). Known: \(RequestedScreens.steps.keys.sorted()). Add one in RequestedScreenshots.swift.")

        app.launchArguments.append("-splitwiseSample")
        signIn()
        settle(3)
        for name in names {
            tab("Expenses").tap()
            settle(1)
            try RequestedScreens.steps[name]?(self)
        }
    }
}

private extension ScreenshotTestCase {
    /// Taps a Profile row by its title and waits for the screen it opens.
    func openProfileRow(_ title: String) {
        let row = app.buttons[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(title) row is missing")
        row.tap()
        settle(1.5)
    }

    /// Edge swipe back: the navigation bar's back button isn't reliably exposed to queries.
    func swipeBack() {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        settle(1)
    }
}
