import XCTest
@testable import Loam

@MainActor
final class AppLockTests: XCTestCase {
    private final class FakeAuthenticator: DeviceAuthenticating {
        var method: DeviceUnlockMethod = .faceID
        var results: [DeviceAuthenticationResult] = []
        private(set) var prompts = 0
        /// Set to hold the next prompt open until the test resumes it.
        var holdsPrompt = false
        private var heldPrompt: CheckedContinuation<DeviceAuthenticationResult, Never>?

        func unlockMethod() -> DeviceUnlockMethod { method }

        func authenticate(reason: String) async -> DeviceAuthenticationResult {
            prompts += 1
            if holdsPrompt {
                holdsPrompt = false
                return await withCheckedContinuation { heldPrompt = $0 }
            }
            return results.isEmpty ? .failed : results.removeFirst()
        }

        var isHoldingPrompt: Bool { heldPrompt != nil }

        func resumePrompt(with result: DeviceAuthenticationResult) {
            heldPrompt?.resume(returning: result)
            heldPrompt = nil
        }
    }

    private let domain = "AppLockTests"
    private var defaults: UserDefaults!
    private var authenticator: FakeAuthenticator!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
        authenticator = FakeAuthenticator()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    private func makeLock() -> AppLock {
        AppLock(defaults: defaults, authenticator: authenticator)
    }

    func testStartsUnlockedWhenOff() {
        let lock = makeLock()
        lock.appDidEnterBackground()
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(lock.isLocked)
    }

    func testTurningOnNeedsTheOwner() async {
        let lock = makeLock()
        authenticator.results = [.failed]
        await lock.setEnabled(true)
        XCTAssertFalse(lock.isEnabled)

        authenticator.results = [.success]
        await lock.setEnabled(true)
        XCTAssertTrue(lock.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: AppLock.enabledKey))
        // Turning it on doesn't lock the screen the person is looking at.
        XCTAssertFalse(lock.isLocked)
    }

    func testTurningOffNeedsTheOwner() async {
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = makeLock()
        authenticator.results = [.success]
        await lock.unlock()

        authenticator.results = [.failed]
        await lock.setEnabled(false)
        XCTAssertTrue(lock.isEnabled)

        authenticator.results = [.success]
        await lock.setEnabled(false)
        XCTAssertFalse(lock.isEnabled)
    }

    func testLaunchesLockedWhenOn() async {
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = makeLock()
        XCTAssertTrue(lock.isLocked)

        authenticator.results = [.success]
        await lock.unlockAutomaticallyIfNeeded()
        XCTAssertFalse(lock.isLocked)
    }

    func testBackgroundLocksAgain() async {
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = makeLock()
        authenticator.results = [.success]
        await lock.unlock()

        lock.appDidEnterBackground()
        XCTAssertTrue(lock.isLocked)
    }

    func testBackgroundDuringAPromptStillLocks() async {
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = makeLock()
        authenticator.results = [.success]
        await lock.unlock()

        // Someone starts turning the lock off, then leaves the app; iOS cancels the prompt.
        authenticator.holdsPrompt = true
        let turningOff = Task { await lock.setEnabled(false) }
        while !authenticator.isHoldingPrompt { await Task.yield() }
        lock.appDidEnterBackground()
        authenticator.resumePrompt(with: .failed)
        await turningOff.value

        XCTAssertTrue(lock.isEnabled)
        XCTAssertTrue(lock.isLocked)
    }

    func testSuccessAfterBackgroundDoesNotUnlock() async {
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = makeLock()
        authenticator.holdsPrompt = true
        let unlocking = Task { await lock.unlock() }
        while !authenticator.isHoldingPrompt { await Task.yield() }
        // Face ID matched just as the person swiped home.
        lock.appDidEnterBackground()
        authenticator.resumePrompt(with: .success)
        await unlocking.value

        XCTAssertTrue(lock.isLocked)
    }

    func testPromptsByItselfOncePerLock() async {
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = makeLock()
        authenticator.results = [.failed]
        await lock.unlockAutomaticallyIfNeeded()
        // Cancelling makes the app active again; that must not prompt in a loop.
        await lock.unlockAutomaticallyIfNeeded()
        XCTAssertEqual(authenticator.prompts, 1)
        XCTAssertTrue(lock.isLocked)

        authenticator.results = [.success]
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
    }

    func testRemovedPasscodeDoesNotTrapTheOwner() async {
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = makeLock()
        authenticator.method = .unavailable
        authenticator.results = [.unavailable]
        await lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertEqual(lock.method, .unavailable)
    }

    func testSignOutClearsTheLock() {
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = makeLock()
        lock.reset()
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: AppLock.enabledKey))
    }
}
