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

    /// Local-only session when Supabase is not configured.
    private var demoMode = false

    func bootstrap() async {
        guard let client = SupabaseClientProvider.shared else {
            demoMode = true
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

        Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    if let session, !session.isExpired {
                        self.apply(user: session.user)
                    } else if !self.demoMode {
                        self.clearSession()
                    }
                case .signedOut:
                    if !self.demoMode {
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

        if demoMode || SupabaseClientProvider.shared == nil {
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

    func signOut() async {
        if let client = SupabaseClientProvider.shared, !demoMode {
            try? await client.auth.signOut()
        }
        clearSession()
    }

    private func clearSession() {
        userId = nil
        displayName = nil
        demoMode = false
        state = .signedOut
    }

    private func activateDemoSession(displayName: String) {
        demoMode = true
        let id = Self.loadDemoUserId()
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
}
