import Foundation
import LocalAuthentication

/// How this iPhone proves it's the owner: the biometric it has set up, or just the passcode.
enum DeviceUnlockMethod: Equatable {
    case faceID
    case touchID
    case opticID
    case passcode
    /// No passcode is set, so iOS can't lock anything.
    case unavailable

    var title: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode, .unavailable: "Passcode"
        }
    }

    var symbolName: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode, .unavailable: "lock"
        }
    }
}

enum DeviceAuthenticationResult: Equatable {
    case success
    /// Cancelled or not recognized; the lock stays as it was.
    case failed
    /// The passcode was removed, so iOS can no longer check who's holding the phone.
    case unavailable
}

@MainActor
protocol DeviceAuthenticating {
    func unlockMethod() -> DeviceUnlockMethod
    func authenticate(reason: String) async -> DeviceAuthenticationResult
}

struct LocalDeviceAuthenticator: DeviceAuthenticating {
    func unlockMethod() -> DeviceUnlockMethod {
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            switch context.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            case .opticID: return .opticID
            case .none: break
            @unknown default: break
            }
        }
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) ? .passcode : .unavailable
    }

    func authenticate(reason: String) async -> DeviceAuthenticationResult {
        // Falls back to the passcode when Face ID fails or isn't set up.
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch let error as LAError where error.code == .passcodeNotSet {
            return .unavailable
        } catch {
            return .failed
        }
    }
}

/// Keeps Loam behind Face ID (or the passcode) whenever it comes back from the background.
@MainActor
final class AppLock: ObservableObject {
    static let enabledKey = "loam.appLock.enabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var method: DeviceUnlockMethod

    /// Each lock offers Face ID once by itself; after a cancel the person taps Unlock.
    private var promptsAutomatically: Bool
    /// Bumped on every trip to the background, so a prompt that finishes afterwards can't unlock.
    private var lockGeneration = 0
    private let defaults: UserDefaults
    private let authenticator: DeviceAuthenticating

    /// The authenticator defaults inside the body: default arguments are evaluated off the main actor.
    init(defaults: UserDefaults = .standard, authenticator: DeviceAuthenticating? = nil) {
        let authenticator = authenticator ?? LocalDeviceAuthenticator()
        self.defaults = defaults
        self.authenticator = authenticator
        let enabled = defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        isLocked = enabled
        promptsAutomatically = enabled
        method = authenticator.unlockMethod()
    }

    /// Face ID only makes the scene inactive, so only a real trip to the background locks,
    /// even mid-prompt: iOS cancels the prompt, and the app must not come back unlocked.
    func appDidEnterBackground() {
        guard isEnabled else { return }
        isLocked = true
        promptsAutomatically = true
        lockGeneration += 1
    }

    func refreshMethod() {
        method = authenticator.unlockMethod()
    }

    /// Called whenever the app becomes active while locked.
    func unlockAutomaticallyIfNeeded() async {
        guard isLocked, promptsAutomatically, !isAuthenticating else { return }
        promptsAutomatically = false
        await unlock()
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let generation = lockGeneration
        let result = await authenticator.authenticate(reason: "Unlock Loam")
        guard generation == lockGeneration else { return }
        switch result {
        case .success:
            isLocked = false
        case .unavailable:
            // Without a passcode nothing can unlock it, so the lock must not trap the owner.
            setStored(false)
            isLocked = false
            refreshMethod()
        case .failed:
            break
        }
    }

    /// Both turning it on and off need the owner, so someone handed an unlocked phone can't remove it.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let reason = enabled ? "Turn on the app lock" : "Turn off the app lock"
        let generation = lockGeneration
        let result = await authenticator.authenticate(reason: reason)
        // The app left mid-prompt and is locked again; the change waits for the owner to come back.
        guard generation == lockGeneration else { return }
        switch result {
        case .success:
            setStored(enabled)
        case .unavailable:
            setStored(false)
            refreshMethod()
        case .failed:
            break
        }
    }

    /// The lock belongs to the signed-in session; the next person to sign in starts without it.
    func reset() {
        setStored(false)
        isLocked = false
        promptsAutomatically = false
    }

    private func setStored(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}
