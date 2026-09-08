import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @EnvironmentObject private var authSession: AuthSession

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Text("Loam")
                    .font(.system(size: 48, weight: .bold, design: .serif))
                Text("Personal spending, shared bills — without the mess.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                Task {
                    switch result {
                    case .success(let authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                            authSession.lastError = "Unexpected Apple credential."
                            return
                        }
                        await authSession.signInWithApple(credential: credential)
                    case .failure(let error):
                        // Simulator / no capability: fall back to demo for Phase 0.
                        if !SupabaseConfig.isConfigured {
                            authSession.signInDemo()
                        } else {
                            authSession.lastError = error.localizedDescription
                        }
                    }
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .padding(.horizontal, 24)

            if !SupabaseConfig.isConfigured {
                Button("Continue without account (demo)") {
                    authSession.signInDemo()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let issue = SupabaseConfig.configurationIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            } else {
                Text("Connected to Supabase")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = authSession.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer().frame(height: 40)
        }
        .background(Color(.systemBackground))
    }
}
