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

    @Published private(set) var state: State = .loading
    @Published private(set) var userId: UUID?
    @Published private(set) var displayName: String?
    @Published var lastError: String?

    /// Local-only session used only when Supabase is not configured.
    private(set) var usesDemoMode = false

    private var authChangesTask: Task<Void, Never>?

    #if DEBUG
    private struct SavedMainAccount: Equatable {
        let userId: UUID
        let displayName: String
    }

    private var savedMainAccount: SavedMainAccount?
    @Published private(set) var activeTestAccount: TestAccount?

    var canReturnToMainAccount: Bool {
        savedMainAccount != nil
    }

    var savedMainAccountDisplayName: String? {
        savedMainAccount?.displayName
    }

    var savedMainAccountPartnerOption: SplitPartnerOption? {
        guard let saved = savedMainAccount else { return nil }
        return SplitPartnerOption(userId: saved.userId, displayName: saved.displayName)
    }
    #endif

    func bootstrap() async {
        #if DEBUG
        activeTestAccount = nil
        #endif
        SupabaseClientProvider.activate(.main)
        guard let client = SupabaseClientProvider.shared else {
            usesDemoMode = true
            ExpenseRepositoryFactory.setUsesLocalStorage(true)
            state = .signedOut
            return
        }

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
        authChangesTask?.cancel()
        let observedDevice = SupabaseClientProvider.activeDevice
        authChangesTask = Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard !Task.isCancelled,
                      let self,
                      SupabaseClientProvider.activeDevice == observedDevice else { return }
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
        activeTestAccount != nil
    }

    func switchToTestAccount(_ account: TestAccount) async {
        lastError = nil
        guard SupabaseConfig.allowsTestAccounts, account.isConfigured,
              let expectedUserId = account.userId,
              let client = SupabaseClientProvider.client(for: account.device) else {
            lastError = "Test accounts require a configured non-production Supabase project."
            return
        }

        if SupabaseClientProvider.activeDevice == .main {
            stashMainAccountForReturn()
        }

        state = .loading
        SupabaseClientProvider.activate(account.device)
        listenForAuthChanges(client: client)

        do {
            let session: Session
            if let cached = try? await client.auth.session,
               !cached.isExpired,
               cached.user.id == expectedUserId {
                session = cached
            } else {
                session = try await client.auth.signIn(email: account.email, password: account.password)
            }

            guard session.user.id == expectedUserId else {
                throw TestAccountSwitchError.unexpectedUser
            }
            activeTestAccount = account
            apply(user: session.user)
            displayName = account.displayName
        } catch {
            lastError = error.localizedDescription
            await restoreMainAccountAfterFailedSwitch()
        }
    }

    func switchBackToMainAccount() async {
        lastError = nil
        await restoreMainAccountAfterFailedSwitch()
    }
    #endif

    func signOut() async {
        #if DEBUG
        let signedOutTestDevice = isTestAccountActive
        #endif
        if let client = SupabaseClientProvider.shared, !usesDemoMode {
            try? await client.auth.signOut()
        }
        #if DEBUG
        if signedOutTestDevice {
            await restoreMainAccountAfterFailedSwitch()
            return
        }
        if SupabaseClientProvider.activeDevice == .main {
            savedMainAccount = nil
        }
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
        #if DEBUG
        if SupabaseClientProvider.activeDevice == .main {
            savedMainAccount = SavedMainAccount(
                userId: user.id,
                displayName: displayName ?? "You"
            )
        }
        #endif
        state = .signedIn
    }

    #if DEBUG
    private func stashMainAccountForReturn() {
        guard let userId, let displayName else { return }
        savedMainAccount = SavedMainAccount(userId: userId, displayName: displayName)
    }

    private func restoreMainAccountAfterFailedSwitch() async {
        activeTestAccount = nil
        SupabaseClientProvider.activate(.main)
        guard let client = SupabaseClientProvider.client(for: .main) else {
            clearSession()
            return
        }

        listenForAuthChanges(client: client)
        do {
            let session = try await client.auth.session
            guard !session.isExpired else {
                clearSession()
                return
            }
            apply(user: session.user)
        } catch {
            clearSession()
        }
    }
    #endif
}

#if DEBUG
private enum TestAccountSwitchError: LocalizedError {
    case unexpectedUser

    var errorDescription: String? {
        "The signed-in Supabase user does not match the configured test account ID."
    }
}
#endif
