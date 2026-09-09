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
                            Text(SupabaseConfig.isConfigured ? "Synced with Supabase" : "Demo mode")
                                .font(.footnote)
                                .foregroundStyle(HomeTheme.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Split testing") {
                    LabeledContent("Test partner", value: TestPartner.displayName)
                    Text("Use “Split with \(TestPartner.displayName)” when adding an expense. Only your share counts in the monthly total.")
                        .font(.footnote)
                        .foregroundStyle(HomeTheme.secondary)
                }

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
}

#Preview {
    ProfileView()
        .environmentObject(AuthSession())
}
