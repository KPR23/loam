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
            for await (event, session) in await client.auth.authStateChanges {
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
            userId = UUID()
            let name = PersonNameComponentsFormatter().string(from: credential.fullName ?? PersonNameComponents())
            displayName = name.isEmpty ? "You" : name
            state = .signedIn
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
        demoMode = true
        userId = UUID()
        displayName = "You"
        state = .signedIn
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
        state = .signedOut
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
