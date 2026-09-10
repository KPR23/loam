import Foundation
import AuthenticationServices
import Supabase

@MainActor
final class AuthSession: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn
    }

    private static let demoUserIdKey = "loam.demo.userId"
    private static let demoDisplayNameKey = "loam.demo.displayName"
    private static let demoModeKey = "loam.demo.active"

    @Published private(set) var state: State = .loading
    @Published private(set) var userId: UUID?
    @Published private(set) var displayName: String?
    @Published var lastError: String?

    /// Local-only session when Supabase is not configured or a dev persona is active.
    private(set) var usesDemoMode = false

    #if DEBUG
    private struct SavedMainAccount: Equatable {
        let userId: UUID
        let displayName: String
        let usesLocalStorage: Bool
    }

    private static let savedMainUserIdKey = "loam.debug.savedMain.userId"
    private static let savedMainDisplayNameKey = "loam.debug.savedMain.displayName"
    private static let savedMainUsesLocalStorageKey = "loam.debug.savedMain.usesLocalStorage"

    private var savedMainAccount: SavedMainAccount?

    var canReturnToMainAccount: Bool {
        savedMainAccount != nil || Self.loadPersistedMainAccount() != nil
    }

    var savedMainAccountDisplayName: String? {
        savedMainAccount?.displayName ?? Self.loadPersistedMainAccount()?.displayName
    }

    var savedMainAccountPartnerOption: SplitPartnerOption? {
        guard let saved = savedMainAccount ?? Self.loadPersistedMainAccount() else { return nil }
        return SplitPartnerOption(userId: saved.userId, displayName: saved.displayName)
    }
    #endif

    func bootstrap() async {
        guard let client = SupabaseClientProvider.shared else {
            usesDemoMode = true
            ExpenseRepositoryFactory.setUsesLocalStorage(true)
            state = .signedOut
            return
        }

        #if DEBUG
        if restoreTestAccountOverlayIfNeeded() {
            listenForAuthChanges(client: client)
            return
        }
        #endif

        do {
            let session = try await client.auth.session
            if session.isExpired {
                // Local session emitted immediately; wait for refresh via authStateChanges.
                state = .signedOut
            } else {
                apply(user: session.user)
            }
        } catch {
            state = .signedOut
        }

        listenForAuthChanges(client: client)
    }

    private func listenForAuthChanges(client: SupabaseClient) {
        Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    if let session, !session.isExpired {
                        self.apply(user: session.user)
                    } else if !self.usesDemoMode {
                        self.clearSession()
                    }
                case .signedOut:
                    if !self.usesDemoMode {
                        self.clearSession()
                    }
                default:
                    break
                }
            }
        }
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        lastError = nil

        if usesDemoMode || SupabaseClientProvider.shared == nil {
            activateDemoSession(
                displayName: formattedAppleName(from: credential.fullName) ?? "You"
            )
            return
        }

        guard let client = SupabaseClientProvider.shared,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            lastError = "Could not read Apple identity token."
            return
        }

        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken)
            )

            var appleName: String?
            if let fullName = credential.fullName {
                let formatted = PersonNameComponentsFormatter().string(from: fullName)
                if !formatted.isEmpty {
                    appleName = formatted
                    _ = try? await client.auth.update(
                        user: UserAttributes(data: ["full_name": .string(formatted)])
                    )
                }
            }

            apply(user: session.user)
            if let appleName {
                displayName = appleName
            }
        } catch {
            lastError = error.localizedDescription
            state = .signedOut
        }
    }

    func signInDemo() {
        let name = UserDefaults.standard.string(forKey: Self.demoDisplayNameKey) ?? "You"
        activateDemoSession(displayName: name)
    }

    #if DEBUG
    var isTestAccountActive: Bool {
        guard let userId else { return false }
        return TestAccount.contains(userId: userId)
    }

    func switchToTestAccount(_ account: TestAccount) async {
        lastError = nil

        if !isTestAccountActive {
            stashMainAccountForReturn()
        }

        activateDemoSession(displayName: account.displayName, userId: account.userId)
    }

    func switchBackToMainAccount() async {
        lastError = nil

        guard let saved = savedMainAccount ?? Self.loadPersistedMainAccount() else {
            return
        }

        clearSavedMainAccount()

        if let client = SupabaseClientProvider.shared {
            do {
                let session = try await client.auth.session
                if !session.isExpired {
                    apply(user: session.user)
                    if !saved.displayName.isEmpty {
                        displayName = saved.displayName
                    }
                    return
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        usesDemoMode = saved.usesLocalStorage
        ExpenseRepositoryFactory.setUsesLocalStorage(saved.usesLocalStorage)
        userId = saved.userId
        displayName = saved.displayName
        state = .signedIn
    }
    #endif

    func signOut() async {
        if let client = SupabaseClientProvider.shared, !usesDemoMode {
            try? await client.auth.signOut()
        }
        #if DEBUG
        clearSavedMainAccount()
        #endif
        clearSession()
    }

    private func clearSession() {
        userId = nil
        displayName = nil
        usesDemoMode = false
        ExpenseRepositoryFactory.setUsesLocalStorage(false)
        state = .signedOut
    }

    private func activateDemoSession(displayName: String, userId explicitUserId: UUID? = nil) {
        usesDemoMode = true
        ExpenseRepositoryFactory.setUsesLocalStorage(true)
        let id = explicitUserId ?? Self.loadDemoUserId()
        userId = id
        self.displayName = displayName
        Self.persistDemoSession(userId: id, displayName: displayName)
        state = .signedIn
    }

    private static func loadDemoUserId() -> UUID {
        if let stored = UserDefaults.standard.string(forKey: demoUserIdKey),
           let id = UUID(uuidString: stored) {
            return id
        }
        return UUID()
    }

    private static func persistDemoSession(userId: UUID, displayName: String) {
        UserDefaults.standard.set(userId.uuidString, forKey: demoUserIdKey)
        UserDefaults.standard.set(displayName, forKey: demoDisplayNameKey)
    }

    private func formattedAppleName(from components: PersonNameComponents?) -> String? {
        let formatted = PersonNameComponentsFormatter().string(from: components ?? PersonNameComponents())
        return formatted.isEmpty ? nil : formatted
    }

    private func apply(user: User) {
        #if DEBUG
        if savedMainAccount != nil {
            return
        }
        #endif

        usesDemoMode = false
        ExpenseRepositoryFactory.setUsesLocalStorage(SupabaseClientProvider.shared == nil)
        userId = user.id
        if let meta = user.userMetadata["full_name"] {
            let value = "\(meta)"
            displayName = value.isEmpty ? (user.email ?? "You") : value
        } else if let email = user.email {
            displayName = email
        } else {
            displayName = "You"
        }
        state = .signedIn
    }

    #if DEBUG
    private func stashMainAccountForReturn() {
        guard let userId, let displayName else { return }

        let saved = SavedMainAccount(
            userId: userId,
            displayName: displayName,
            usesLocalStorage: ExpenseRepositoryFactory.usesLocalStorage
        )
        savedMainAccount = saved
        Self.persistMainAccount(saved)
    }

    private func restoreTestAccountOverlayIfNeeded() -> Bool {
        guard
            let saved = Self.loadPersistedMainAccount(),
            let storedId = UserDefaults.standard.string(forKey: Self.demoUserIdKey),
            let demoUserId = UUID(uuidString: storedId),
            TestAccount.contains(userId: demoUserId)
        else {
            return false
        }

        savedMainAccount = saved
        let displayName = UserDefaults.standard.string(forKey: Self.demoDisplayNameKey) ?? "You"
        activateDemoSession(displayName: displayName, userId: demoUserId)
        return true
    }

    private func clearSavedMainAccount() {
        savedMainAccount = nil
        UserDefaults.standard.removeObject(forKey: Self.savedMainUserIdKey)
        UserDefaults.standard.removeObject(forKey: Self.savedMainDisplayNameKey)
        UserDefaults.standard.removeObject(forKey: Self.savedMainUsesLocalStorageKey)
    }

    private static func persistMainAccount(_ account: SavedMainAccount) {
        UserDefaults.standard.set(account.userId.uuidString, forKey: savedMainUserIdKey)
        UserDefaults.standard.set(account.displayName, forKey: savedMainDisplayNameKey)
        UserDefaults.standard.set(account.usesLocalStorage, forKey: savedMainUsesLocalStorageKey)
    }

    private static func loadPersistedMainAccount() -> SavedMainAccount? {
        guard
            let idString = UserDefaults.standard.string(forKey: savedMainUserIdKey),
            let userId = UUID(uuidString: idString)
        else {
            return nil
        }

        let displayName = UserDefaults.standard.string(forKey: savedMainDisplayNameKey) ?? "You"
        let usesLocalStorage = UserDefaults.standard.bool(forKey: savedMainUsesLocalStorageKey)
        return SavedMainAccount(
            userId: userId,
            displayName: displayName,
            usesLocalStorage: usesLocalStorage
        )
    }
    #endif
}
