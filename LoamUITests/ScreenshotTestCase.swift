import XCTest

/// Base class for the PR screenshot flows. They run only in the screenshots workflow, which points the
/// app at a throwaway local backend filled by scripts/screenshots/seed.sql; every other run skips them.
/// A PR that changes a screen adds its own subclass here and calls `capture` for the screens it touches.
class ScreenshotTestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Self.outputDirectory != nil, "Screenshot flows only run in the screenshots workflow")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-resetLocalData", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    /// The workflow sets this through TEST_RUNNER_SCREENSHOT_DIR.
    private static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Steps

    /// Launches the app and signs in as the seeded sample user.
    func signIn(as name: String = "Julia") {
        app.launch()
        let button = app.buttons["Continue as \(name)"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "No test account button; is the app pointed at the local backend?")
        button.tap()
        XCTAssertTrue(tab("Expenses").waitForExistence(timeout: 20))
    }

    func tab(_ name: String) -> XCUIElement {
        app.tabBars.buttons[name].firstMatch
    }

    /// Lets lists and loading states settle before a capture.
    func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Saves the current screen as `<name>-<appearance>.png`; the workflow sets the simulator's appearance
    /// before each run and passes its name through TEST_RUNNER_SCREENSHOT_APPEARANCE.
    func capture(_ name: String) throws {
        let directory = try XCTUnwrap(Self.outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearance = ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] ?? "light"
        settle(0.8)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try data.write(to: directory.appending(path: "\(name)-\(appearance).png"))
    }
}
