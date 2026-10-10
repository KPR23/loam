import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @EnvironmentObject private var authSession: AuthSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Centered on tall phones; scrolls instead of clipping at large text sizes.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 0)

                    VStack(spacing: 12) {
                        LoamArcMark()
                        Text("Track your spending.\nSplit bills with friends.")
                            .font(.system(.title3, design: .rounded).weight(.medium))
                            .foregroundStyle(HomeTheme.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    VStack(spacing: 16) {
                        if authSession.deletionPending {
                            deletionStatusCard
                        }

                        if let error = authSession.lastError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        SignInWithAppleButton(.continue) { request in
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = authSession.prepareAppleSignInNonce()
                        } onCompletion: { result in
                            Task { await handleAppleSignIn(result) }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 58)
                        .clipShape(Capsule())
                        // The button doesn't restyle itself when the appearance changes.
                        .id(colorScheme)

                        developmentOptions

                        Text(legalNotice)
                            .font(.footnote)
                            .foregroundStyle(HomeTheme.secondary)
                            .tint(HomeTheme.text)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .background(HomeTheme.background)
    }

    private var legalNotice: LocalizedStringKey {
        "By continuing, you agree to Loam's [Terms](\(LegalPages.termsOfUse.absoluteString)) and [Privacy Policy](\(LegalPages.privacyPolicy.absoluteString))."
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
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

    /// Demo mode, backend status and test accounts; none of these appear in a configured release build.
    @ViewBuilder
    private var developmentOptions: some View {
        if !SupabaseConfig.isConfigured {
            Button("Continue without account (demo)") {
                authSession.signInDemo()
            }
            .font(.subheadline.weight(.medium))
            .tint(HomeTheme.secondary)
            .frame(minHeight: 44)

            if let issue = SupabaseConfig.configurationIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }

        #if DEBUG
        if SupabaseConfig.isConfigured {
            Text("Connected to Supabase")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

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
        }
        #endif
    }

    private var deletionStatusCard: some View {
        VStack(spacing: 10) {
            Label(deletionTitle, systemImage: deletionSymbol)
                .font(.system(.headline, design: .rounded))
            Text(deletionDetail)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if authSession.deletionStatus == .complete {
                Button("Done") { authSession.dismissDeletionConfirmation() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            } else {
                Button("Check status") { Task { await authSession.refreshDeletionStatus() } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(HomeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
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

#Preview {
    AuthView()
        .environmentObject(AuthSession())
}
