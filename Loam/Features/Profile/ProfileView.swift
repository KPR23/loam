import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var authSession: AuthSession

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(HomeTheme.tertiary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(authSession.displayName ?? "You")
                                .font(.headline)
                            Text(accountSubtitle)
                                .font(.footnote)
                                .foregroundStyle(HomeTheme.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                #if DEBUG
                if !authSession.isTestAccountActive {
                    Section("Test accounts") {
                        ForEach(TestAccount.allCases) { account in
                            Button {
                                Task { await authSession.switchToTestAccount(account) }
                            } label: {
                                HStack {
                                    Text(account.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.left.arrow.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Text("Switch to Julia or Philip to simulate their device. You can split with your Apple account while viewing as a test persona, and return anytime with Back to my account.")
                            .font(.footnote)
                            .foregroundStyle(HomeTheme.secondary)
                    }
                } else {
                    Section("Test account active") {
                        if authSession.canReturnToMainAccount {
                            Button {
                                Task { await authSession.switchBackToMainAccount() }
                            } label: {
                                HStack {
                                    Text(returnToMainAccountTitle)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.uturn.backward")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }

                        Text("You are viewing the app as a test persona.")
                            .font(.footnote)
                            .foregroundStyle(HomeTheme.secondary)
                    }
                }
                #endif

                Section("Budget") {
                    LabeledContent("Monthly budget", value: "Coming soon")
                        .foregroundStyle(HomeTheme.secondary)
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await authSession.signOut() }
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var accountSubtitle: String {
        #if DEBUG
        if authSession.isTestAccountActive {
            return "Test account"
        }
        #endif
        if authSession.usesDemoMode {
            return "Demo mode"
        }
        return SupabaseConfig.isConfigured ? "Apple account · Synced with Supabase" : "Demo mode"
    }

    private var returnToMainAccountTitle: String {
        if let name = authSession.savedMainAccountDisplayName, !name.isEmpty {
            return "Back to \(name)"
        }
        return "Back to my account"
    }
}

#Preview {
    ProfileView()
        .environmentObject(AuthSession())
}
