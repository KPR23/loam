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

    /// Local-only session when Supabase is not configured (Phase 0 simulator / UI work).
    private var demoMode = false

    func bootstrap() async {
        guard let client = SupabaseClientProvider.shared else {
            demoMode = true
            state = .signedOut
            return
        }

        do {
            let session = try await client.auth.session
            apply(user: session.user)
        } catch {
            state = .signedOut
        }

        Task { [weak self] in
            for await (_, session) in await client.auth.authStateChanges {
                guard let self else { return }
                if let session {
                    self.apply(user: session.user)
                } else {
                    self.userId = nil
                    self.displayName = nil
                    self.state = .signedOut
                }
            }
        }
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async {
        lastError = nil

        if demoMode || SupabaseClientProvider.shared == nil {
            userId = UUID()
            displayName = PersonNameComponentsFormatter().string(from: credential.fullName ?? PersonNameComponents())
            if displayName?.isEmpty != false {
                displayName = "You"
            }
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
            apply(user: session.user)
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
        userId = nil
        displayName = nil
        state = .signedOut
    }

    private func apply(user: User) {
        userId = user.id
        if let meta = user.userMetadata["full_name"] {
            displayName = "\(meta)"
        } else if let email = user.email {
            displayName = email
        } else {
            displayName = "You"
        }
        state = .signedIn
    }
}
