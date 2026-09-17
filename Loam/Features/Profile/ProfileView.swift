import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    #if DEBUG
    @State private var showClearAllExpensesConfirm = false
    #endif

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
                if authSession.isTestAccountActive {
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

                        ForEach(TestAccount.configured.filter { $0 != authSession.activeTestAccount }) { account in
                            Button {
                                Task { await authSession.switchToTestAccount(account) }
                            } label: {
                                HStack {
                                    Text("Switch to \(account.displayName)")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.left.arrow.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Text("You are viewing the app as a test persona.")
                            .font(.footnote)
                            .foregroundStyle(HomeTheme.secondary)
                    }
                } else if SupabaseConfig.allowsTestAccounts,
                          !TestAccount.configured.isEmpty {
                    Section("Test accounts") {
                        ForEach(TestAccount.configured) { account in
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

                        Text("Each persona uses its own real Supabase Auth session and backend data, like a separate device.")
                            .font(.footnote)
                            .foregroundStyle(HomeTheme.secondary)
                    }
                } else {
                    Section("Test accounts") {
                        Text(testAccountsUnavailableMessage)
                            .font(.footnote)
                            .foregroundStyle(HomeTheme.secondary)
                    }
                }

                if let error = authSession.lastError {
                    Section("Account switching") {
                        Text(error)
                            .foregroundStyle(.red)
                        Button("Dismiss") { authSession.lastError = nil }
                    }
                }

                Section("Developer") {
                    Button("Clear expenses I created", role: .destructive) {
                        showClearAllExpensesConfirm = true
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
            #if DEBUG
            .alert(
                "Clear expenses you created?",
                isPresented: $showClearAllExpensesConfirm
            ) {
                Button("Clear mine", role: .destructive) {
                    guard let userId = authSession.userId else { return }
                    Task { await expenseStore.clearAllExpenses(userId: userId) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(clearExpensesConfirmationMessage)
            }
            #endif
        }
    }

    private var accountSubtitle: String {
        #if DEBUG
        if authSession.isTestAccountActive {
            return "Test account · Synced with Supabase"
        }
        #endif
        if authSession.usesDemoMode {
            return "Demo mode"
        }
        return SupabaseConfig.isConfigured ? "Apple account · Synced with Supabase" : "Demo mode"
    }

    #if DEBUG
    private var returnToMainAccountTitle: String {
        if let name = authSession.savedMainAccountDisplayName, !name.isEmpty {
            return "Back to \(name)"
        }
        return "Back to my account"
    }

    private var testAccountsUnavailableMessage: String {
        if SupabaseConfig.environment != .testing {
            return "Disabled outside the Debug testing configuration."
        }
        if !SupabaseConfig.allowsTestAccounts {
            return "The active Supabase URL does not match the allowlisted test project."
        }
        return "Add the Julia and Philip ID, email, and password variables to Secrets.xcconfig."
    }

    private var clearExpensesConfirmationMessage: String {
        if SupabaseConfig.isConfigured {
            return "Deletes synced expenses and recurring rules you created. Shared expenses created by others stay. This can’t be undone."
        }
        return "Deletes local demo expenses and recurring rules you created. This can’t be undone."
    }
    #endif
}

#Preview {
    ProfileView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
