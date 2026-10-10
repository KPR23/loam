import XCTest
@testable import Loam

final class OnboardingHistoryTests: XCTestCase {
    private let domain = "app.loam.tests.onboarding-history"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    private func hasUsedLoam(storedSession: Bool = false) -> Bool {
        OnboardingHistory.hasUsedLoam(defaults: defaults, domain: domain) { storedSession }
    }

    func testAFreshInstallHasNoHistory() {
        XCTAssertFalse(hasUsedLoam())
    }

    func testKeysEveryLaunchWritesDoNotCountAsHistory() {
        defaults.set(true, forKey: "loam.demo.fixtures.removed")
        defaults.set(false, forKey: OnboardingView.completedKey)
        defaults.set("other", forKey: "com.revenuecat.userdefaults.appUserID.new")

        XCTAssertFalse(hasUsedLoam())
    }

    func testSettingsOrDemoDataCountAsHistory() {
        defaults.set("dark", forKey: "loam.appearance")
        XCTAssertTrue(hasUsedLoam())

        defaults.removePersistentDomain(forName: domain)
        defaults.set(Data(), forKey: "loam.local.expenses")
        XCTAssertTrue(hasUsedLoam())
    }

    func testAStoredSessionCountsAsHistory() {
        XCTAssertTrue(hasUsedLoam(storedSession: true))
    }
}
