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
                request.nonce = authSession.prepareAppleSignInNonce()
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

            #if DEBUG
            if SupabaseConfig.allowsTestAccounts, !TestAccount.configured.isEmpty {
                VStack(spacing: 8) {
                    Text("Test accounts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(TestAccount.configured) { account in
                        Button("Continue as \(account.displayName)") {
                            Task { await authSession.switchToTestAccount(account) }
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.top, 4)
            }
            #endif

            if authSession.deletionPending {
                VStack(spacing: 10) {
                    Label(deletionTitle, systemImage: deletionSymbol)
                        .font(.headline)
                    Text(deletionDetail)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if authSession.deletionStatus == .complete {
                        Button("Done") { authSession.dismissDeletionConfirmation() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Check status") { Task { await authSession.refreshDeletionStatus() } }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
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

    private var deletionTitle: String {
        switch authSession.deletionStatus {
        case .submissionUncertain: "Request status needs checking"
        case .processing: "Deletion in progress"
        case .needsAttention: "Deletion needs attention"
        case .complete: "Deletion complete"
        case .unavailable: "Status temporarily unavailable"
        case .none: "Deletion status"
        }
    }

    private var deletionSymbol: String {
        switch authSession.deletionStatus {
        case .complete: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .unavailable, .submissionUncertain: "arrow.clockwise.circle"
        default: "hourglass"
        }
    }

    private var deletionDetail: String {
        switch authSession.deletionStatus {
        case .submissionUncertain: "We saved your request securely. We’re checking whether it reached the server. Retry this check; don’t assume the request failed."
        case .processing: "Your account is closed. We’ll finish deleting its data, usually within a few minutes."
        case .needsAttention: "Your account is closed, but deletion is taking longer than expected. We’re working to complete it. Check again later or contact support."
        case .complete: "Your account and private data have been deleted."
        case .unavailable: "We couldn’t reach the deletion status service. Your saved receipt is safe; try again shortly."
        case .none: ""
        }
    }
}
