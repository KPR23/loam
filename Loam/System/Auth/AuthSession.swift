import Foundation
import AuthenticationServices
import CryptoKit
import Security
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
    @Published private(set) var email: String?
    @Published var lastError: String? {
        // Every failure reaches the person as a toast, wherever they are in the app.
        didSet { if let lastError, lastError != oldValue { ToastCenter.shared.showError(lastError) } }
    }
    @Published private(set) var deletionPending = false
    @Published private(set) var deletionStatus: DeletionStatus = .none
    @Published private(set) var deletionUpdatedAt: Date?
    @Published private(set) var isCheckingDeletionStatus = false
    @Published private(set) var deletionCheckedAt: Date?

    enum DeletionStatus: String, Codable, Equatable {
        case none, submissionUncertain, processing, needsAttention, complete, unavailable
    }

    /// Local-only session used only when Supabase is not configured.
    private(set) var usesDemoMode = false

    private var authChangesTask: Task<Void, Never>?

    /// The raw nonce of the Sign in with Apple request in flight. Apple signs its hash into
    /// the ID token and Supabase checks the pair, so an intercepted token can't be replayed.
    private var appleNonce: String?

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

    private var bootstrapTask: Task<Void, Never>?
    /// When the launch sign-in check finished; an expired token may still be refreshing just after.
    private(set) var bootstrapFinishedAt: Date?

    /// Runs the launch sign-in check once. Siri can start an action before the first screen does.
    func bootstrapIfNeeded() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard state == .loading else { return }
        let task = Task {
            await bootstrap()
            bootstrapFinishedAt = Date()
        }
        bootstrapTask = task
        await task.value
    }

    func bootstrap() async {
        #if DEBUG
        activeTestAccount = nil
        #endif
        SupabaseClientProvider.activate(.main)
        await refreshDeletionStatus()
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

    private func listenForAuthChanges(client: SupabaseClient, expectedUserId: UUID? = nil) {
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
                        guard expectedUserId == nil || session.user.id == expectedUserId else {
                            #if DEBUG
                            self.lastError = TestAccountSwitchError.unexpectedUser.localizedDescription
                            await self.restoreMainAccountAfterFailedSwitch()
                            #endif
                            return
                        }
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

    /// Starts a Sign in with Apple request; set the result as the request's `nonce`.
    func prepareAppleSignInNonce() -> String {
        let nonce = UUID().uuidString + UUID().uuidString
        appleNonce = nonce
        return SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        lastError = nil
        let nonce = appleNonce
        appleNonce = nil

        if usesDemoMode || SupabaseClientProvider.shared == nil {
            activateDemoSession(
                displayName: formattedAppleName(from: credential.fullName) ?? "You"
            )
            return
        }

        guard let client = SupabaseClientProvider.shared,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            LoamErrorCapture.capture("auth.apple_identity_token_unavailable")
            lastError = "Sign in with Apple didn't finish. Try again."
            return
        }

        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )

            var appleName: String?
            if let fullName = credential.fullName {
                let formatted = PersonNameComponentsFormatter().string(from: fullName)
                if !formatted.isEmpty {
                    appleName = formatted
                    _ = try? await client.auth.update(
                        user: UserAttributes(data: ["full_name": .string(formatted)])
                    )
                    // The profile row was created from the email before Apple's
                    // name arrived; keep what other people see in sync.
                    _ = try? await client.rpc(
                        "update_display_name",
                        params: DisplayNameParams(displayName: formatted)
                    ).execute()
                }
            }

            apply(user: session.user)
            await refreshDeletionStatus()
            if let appleName {
                displayName = appleName
            }
        } catch {
            LoamErrorCapture.capture("auth.apple_sign_in_failed")
            lastError = UserFacingError.message(for: error)
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
        authChangesTask?.cancel()
        SupabaseClientProvider.activate(account.device)

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
            listenForAuthChanges(client: client, expectedUserId: expectedUserId)
        } catch {
            lastError = UserFacingError.message(for: error)
            await restoreMainAccountAfterFailedSwitch()
        }
    }

    func switchBackToMainAccount() async {
        lastError = nil
        await restoreMainAccountAfterFailedSwitch()
    }
    #endif

    func updateDisplayName(_ name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if usesDemoMode, let userId {
            displayName = name
            Self.persistDemoSession(userId: userId, displayName: name)
        } else if let client = SupabaseClientProvider.shared {
            let previousName = displayName
            try await LoamErrorCapture.withCapture("profile.display_name_database_update_failed") {
                try await client.rpc(
                    "update_display_name",
                    params: DisplayNameParams(displayName: name)
                ).execute()
            }
            do {
                let user = try await LoamErrorCapture.withCapture("profile.display_name_auth_update_failed") {
                    try await client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
                }
                apply(user: user)
            } catch {
                // Keep Auth and the shared profile mirrors aligned if Auth rejects
                // the metadata update after the database transaction succeeded.
                if let previousName, !previousName.isEmpty {
                    _ = try? await client.rpc(
                        "update_display_name",
                        params: DisplayNameParams(displayName: previousName)
                    ).execute()
                }
                throw error
            }
        }
    }

    func deleteAccount(credential: ASAuthorizationAppleIDCredential? = nil) async throws {
        guard userId != nil else {
            throw NSError(domain: "LoamAccount", code: 1, userInfo: [NSLocalizedDescriptionKey: "No account is signed in."])
        }

        #if DEBUG
        guard !isTestAccountActive else {
            throw NSError(domain: "LoamAccount", code: 2, userInfo: [NSLocalizedDescriptionKey: "Switch back to your main account before deleting it."])
        }
        #endif

        if usesDemoMode {
            let defaults = UserDefaults.standard
            for key in [
                Self.demoUserIdKey, Self.demoDisplayNameKey,
                "loam.local.expenses", "loam.local.recurring", "loam.local.proposals",
                "loam.local.trust", "loam.local.trust.v2", "loam.local.households", "loam.local.household",
                "loam.local.repayments", "loam.local.activity.v1",
            ] {
                defaults.removeObject(forKey: key)
            }
            clearSession()
            return
        }

        guard let client = SupabaseClientProvider.shared else {
            throw NSError(domain: "LoamAccount", code: 3, userInfo: [NSLocalizedDescriptionKey: "Account deletion is unavailable right now."])
        }

        guard let credential,
              let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
              let authorizationCode = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw NSError(domain: "LoamAccount", code: 4, userInfo: [NSLocalizedDescriptionKey: "Confirm with Apple before deleting your account."])
        }
        guard let deletingAccountId = userId else { return }
        let receipt = try DeletionReceipt.create(for: deletingAccountId)
        DeletionReceipt.setStatus(.submissionUncertain, for: deletingAccountId)
        deletionStatus = .submissionUncertain
        deletionPending = true
        do {
            try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(body: AccountDeletionRequest(
            operationId: receipt.operationId.uuidString,
            receiptSecret: receipt.secret,
            authorizationCode: authorizationCode,
            identityToken: identityToken
            )))
            DeletionReceipt.setStatus(.processing, for: deletingAccountId)
            deletionStatus = .processing
        } catch {
            if let functionError = error as? FunctionsError,
               case let .httpError(code, _) = functionError,
               Self.isDefinitiveDeletionRejection(code) {
                DeletionReceipt.remove(for: deletingAccountId)
                deletionPending = false
                deletionStatus = .none
                deletionUpdatedAt = nil
                let message = Self.deletionRejectionMessage(for: code)
                lastError = message
                throw NSError(domain: "LoamAccountDeletion", code: code, userInfo: [NSLocalizedDescriptionKey: message])
            }

            // The server may have committed acceptance before the response was
            // lost. Preserve the receipt and reconcile against its status endpoint.
            LoamErrorCapture.capture("account_deletion.response_uncertain")
            lastError = "Couldn't confirm your deletion request. Check its status before trying again."
            await refreshDeletionStatus()
            try? await client.auth.signOut(scope: .local)
            clearSession()
            return
        }
        // Acceptance closes app access immediately; the service worker revokes
        // Apple, removes owned avatars, and then soft-deletes the Auth identity.
        // Whoever signs up next on this device starts fresh, so they see onboarding.
        UserDefaults.standard.set(false, forKey: OnboardingView.completedKey)
        try? await client.auth.signOut(scope: .local)
        #if DEBUG
        savedMainAccount = nil
        #endif
        clearSession()
    }

    private static func isDefinitiveDeletionRejection(_ statusCode: Int) -> Bool {
        // These responses are returned before accept_account_deletion creates
        // an operation. Transport, relay, timeout, and server errors stay
        // uncertain because the request may have reached the database.
        [400, 401, 403, 404, 405, 422, 429, 503].contains(statusCode)
    }

    private static func deletionRejectionMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 400:
            "Apple couldn’t verify this confirmation. Your account is still active; try the deletion flow again."
        case 401:
            "Your sign-in expired before the deletion request was accepted. Your account is still active; sign in and try again."
        case 503:
            "The deletion service is temporarily unavailable. Your account is still active; try again shortly."
        default:
            "The deletion request wasn’t accepted. Your account is still active; try again."
        }
    }

    /// Keeps the status fresh while a deletion is still running, so nobody has to keep tapping
    /// "Check status". Cancelled with the view that started it.
    func watchDeletionStatus() async {
        while !Task.isCancelled {
            await refreshDeletionStatus()
            guard deletionPending, deletionStatus != .complete, deletionStatus != .needsAttention else { return }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    func refreshDeletionStatus() async {
        guard !isCheckingDeletionStatus else { return }
        isCheckingDeletionStatus = true
        defer {
            isCheckingDeletionStatus = false
            deletionCheckedAt = Date()
        }
        let receipt = userId.flatMap { DeletionReceipt.pendingReceipt(for: $0) }
            ?? (userId == nil ? DeletionReceipt.pendingReceipt() : nil)
        guard let receipt else {
            deletionPending = false
            deletionStatus = .none
            return
        }
        deletionPending = true
        guard let base = URL(string: SupabaseConfig.url), SupabaseConfig.isConfigured else {
            deletionStatus = .unavailable
            return
        }
        let statusURL = base.appendingPathComponent("functions").appendingPathComponent("v1").appendingPathComponent("delete-account")
        var components = URLComponents(url: statusURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "operationId", value: receipt.operationId.uuidString)]
        guard let url = components?.url else { deletionStatus = .unavailable; return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(receipt.secret, forHTTPHeaderField: "X-Deletion-Receipt")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard response.statusCode == 200 else {
                if response.statusCode == 404 {
                    deletionStatus = DeletionReceipt.savedStatus(for: receipt.accountId) ?? .submissionUncertain
                } else {
                    deletionStatus = .unavailable
                }
                return
            }
            let status = try JSONDecoder().decode(DeletionStatusResponse.self, from: data)
            let previousStatus = deletionStatus
            // The first confirmation of a request whose response was lost; deleteAccount resets on a clean accept.
            if (DeletionReceipt.savedStatus(for: receipt.accountId) ?? .submissionUncertain) == .submissionUncertain {
                UserDefaults.standard.set(false, forKey: OnboardingView.completedKey)
            }
            switch status.status {
            case "complete":
                deletionStatus = .complete
                deletionUpdatedAt = status.completedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            case "failed", "needs_attention": deletionStatus = .needsAttention
            default: deletionStatus = .processing
            }
            if deletionStatus == .needsAttention, previousStatus != .needsAttention {
                LoamErrorCapture.capture("account_deletion.background_processing_needs_attention")
            }
            DeletionReceipt.setStatus(deletionStatus, for: receipt.accountId)
        } catch {
            deletionStatus = .unavailable
        }
    }

    func dismissDeletionConfirmation() {
        guard deletionStatus == .complete else { return }
        if let userId { DeletionReceipt.remove(for: userId) }
        else { DeletionReceipt.remove() }
        deletionPending = false
        deletionStatus = .none
        Task { await refreshDeletionStatus() }
    }

    func signOut() async {
        lastError = nil
        #if DEBUG
        let signedOutTestDevice = isTestAccountActive
        #endif
        if let client = SupabaseClientProvider.shared, !usesDemoMode {
            // Needs the session, so it runs before the sign-out ends it.
            await PushNotificationStore.shared.deviceWillSignOut()
            do {
                try await client.auth.signOut()
            } catch {
                await PushNotificationStore.shared.signOutFailed()
                LoamErrorCapture.capture("auth.sign_out_failed")
                lastError = UserFacingError.message(for: error)
                return
            }
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
        email = nil
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
        email = nil
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
        email = user.email
        deletionPending = DeletionReceipt.exists(for: user.id)
        deletionStatus = DeletionReceipt.savedStatus(for: user.id) ?? (deletionPending ? .submissionUncertain : .none)
        if let meta = user.userMetadata["full_name"], !"\(meta)".isEmpty {
            displayName = "\(meta)"
        } else {
            // Accounts without a chosen name use the profile's name, which the
            // database derives from the email; never show the raw address.
            displayName = Self.emailLocalPart(user.email) ?? "You"
            let userId = user.id
            Task { await self.loadProfileDisplayName(for: userId) }
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

    private static func emailLocalPart(_ email: String?) -> String? {
        guard let local = email?.split(separator: "@").first, !local.isEmpty else { return nil }
        return String(local)
    }

    private func loadProfileDisplayName(for userId: UUID) async {
        guard let client = SupabaseClientProvider.shared else { return }
        struct Row: Decodable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
        do {
            let row: Row = try await client.from("profile")
                .select("display_name")
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            let name = row.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, self.userId == userId else { return }
            displayName = name
            #if DEBUG
            if savedMainAccount?.userId == userId {
                savedMainAccount = SavedMainAccount(userId: userId, displayName: name)
            }
            #endif
        } catch {
            // Keep the email-derived fallback; the next sign-in retries.
        }
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

private struct AccountDeletionRequest: Encodable {
    let operationId: String
    let receiptSecret: String
    let authorizationCode: String
    let identityToken: String
}

private struct DeletionStatusResponse: Decodable {
    let status: String
    let completedAt: String?
    enum CodingKeys: String, CodingKey {
        case status
        case completedAt = "completed_at"
    }
}

private enum DeletionReceipt {
    struct Value: Codable {
        let accountId: UUID
        let operationId: UUID
        let secret: String
        var status: AuthSession.DeletionStatus
        let createdAt: Date

        init(accountId: UUID, operationId: UUID, secret: String, status: AuthSession.DeletionStatus, createdAt: Date = Date()) {
            self.accountId = accountId
            self.operationId = operationId
            self.secret = secret
            self.status = status
            self.createdAt = createdAt
        }
    }
    private static var service: String {
        let host = URL(string: SupabaseConfig.url)?.host ?? "unconfigured"
        return "app.loam.account-deletion.\(SupabaseConfig.environment.rawValue).\(host)"
    }
    static func create(for accountId: UUID) throws -> (operationId: UUID, secret: String) {
        if let value = load(for: accountId) { return (value.operationId, value.secret) }
        let value = Value(accountId: accountId, operationId: UUID(), secret: UUID().uuidString + UUID().uuidString, status: .submissionUncertain)
        guard save(value) else {
            LoamErrorCapture.capture("account_deletion.receipt_secure_storage_failed")
            throw NSError(domain: "LoamAccountDeletion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not securely save the deletion receipt. No deletion request was sent."])
        }
        return (value.operationId, value.secret)
    }
    static func setStatus(_ status: AuthSession.DeletionStatus, for accountId: UUID) {
        guard var value = load(for: accountId) else { return }
        value.status = status
        save(value)
    }
    static func savedStatus(for accountId: UUID) -> AuthSession.DeletionStatus? {
        load(for: accountId)?.status
    }
    static func exists(for accountId: UUID) -> Bool { load(for: accountId) != nil }
    static func pendingReceipt() -> Value? {
        loadAny() ?? migrateLegacyReceipt()
    }
    static func pendingReceipt(for accountId: UUID) -> Value? {
        if let value = load(for: accountId) { return value }
        guard let value = migrateLegacyReceipt(), value.accountId == accountId else { return nil }
        return value
    }
    private static func migrateLegacyReceipt() -> Value? {
        // Migrate the prior UserDefaults receipt once, then remove its plaintext copy.
        let legacyKey = "loam.accountDeletionReceipt"
        guard let saved = UserDefaults.standard.dictionary(forKey: legacyKey),
              let account = saved["accountId"] as? String, let accountId = UUID(uuidString: account),
              let operation = saved["operationId"] as? String, let operationId = UUID(uuidString: operation),
              let secret = saved["secret"] as? String, secret.count >= 32 else { return nil }
        let value = Value(accountId: accountId, operationId: operationId, secret: secret, status: .submissionUncertain)
        guard save(value) else { return nil }
        UserDefaults.standard.removeObject(forKey: legacyKey)
        return value
    }
    static func remove() {
        if let value = pendingReceipt() { delete(for: value.accountId) }
    }
    static func remove(for accountId: UUID) { delete(for: accountId) }

    private static func load(for accountId: UUID) -> Value? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountId.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
    private static func loadAny() -> Value? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [Data] else { return nil }
        return rows.compactMap { try? JSONDecoder().decode(Value.self, from: $0) }.max(by: { $0.createdAt < $1.createdAt })
    }
    @discardableResult
    private static func save(_ value: Value) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: value.accountId.uuidString]
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var query = identity
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    private static func delete(for accountId: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountId.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}

private struct DisplayNameParams: Encodable {
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "p_display_name"
    }
}

#if DEBUG
private enum TestAccountSwitchError: LocalizedError {
    case unexpectedUser

    var errorDescription: String? {
        "The signed-in Supabase user does not match the configured test account ID."
    }
}
#endif
