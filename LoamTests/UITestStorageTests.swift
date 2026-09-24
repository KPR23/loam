import XCTest
@testable import Loam

final class UITestStorageTests: XCTestCase {
    private let domain = "app.loam.tests.ui-storage"
    private var defaults: UserDefaults!
    private var backupURL: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
        backupURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).plist")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: backupURL)
        super.tearDown()
    }

    func testUITestsStartEmptyAndTheRealDataComesBackOnTheNextNormalLaunch() {
        defaults.set("real", forKey: "loam.demo.displayName")

        UITestStorage.setAsideAndClear(defaults: defaults, domain: domain, backupURL: backupURL)
        XCTAssertNil(defaults.string(forKey: "loam.demo.displayName"))

        defaults.set("test", forKey: "loam.demo.displayName")
        UITestStorage.restore(defaults: defaults, domain: domain, backupURL: backupURL)

        XCTAssertEqual(defaults.string(forKey: "loam.demo.displayName"), "real")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testSeveralTestLaunchesKeepTheOriginalBackup() {
        defaults.set("real", forKey: "loam.demo.displayName")
        UITestStorage.setAsideAndClear(defaults: defaults, domain: domain, backupURL: backupURL)
        defaults.set("test", forKey: "loam.demo.displayName")
        UITestStorage.setAsideAndClear(defaults: defaults, domain: domain, backupURL: backupURL)

        UITestStorage.restore(defaults: defaults, domain: domain, backupURL: backupURL)

        XCTAssertEqual(defaults.string(forKey: "loam.demo.displayName"), "real")
    }

    func testNormalLaunchWithoutABackupChangesNothing() {
        defaults.set("real", forKey: "loam.demo.displayName")
        UITestStorage.restore(defaults: defaults, domain: domain, backupURL: backupURL)
        XCTAssertEqual(defaults.string(forKey: "loam.demo.displayName"), "real")
    }
}
