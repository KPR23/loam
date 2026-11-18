import SwiftUI
import Supabase

/// Preferences switch that accepts every expense someone shares with this account. The
/// database applies it to new shares and, when it is turned on, to the requests already waiting.
struct AutoAcceptExpensesToggle: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @State private var isOn = false
    @State private var hasLoaded = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        Toggle(isOn: binding) {
            ProfileRow("Auto-accept expenses", symbol: "checkmark.circle", color: .blue)
        }
        .tint(HomeTheme.accentFill)
        .disabled(!hasLoaded || isSaving)
        .task(id: authSession.userId) { await load() }
        .errorToast($error)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { newValue in Task { await save(newValue) } }
        )
    }

    private func load() async {
        hasLoaded = false
        guard let userId = authSession.userId, let client = SupabaseClientProvider.shared else { return }
        struct Row: Decodable {
            let autoAccept: Bool
            enum CodingKeys: String, CodingKey { case autoAccept = "auto_accept_expenses" }
        }
        do {
            let row: Row = try await client.from("profile")
                .select("auto_accept_expenses")
                .eq("id", value: userId)
                .single()
                .execute().value
            isOn = row.autoAccept
            hasLoaded = true
        } catch {
            // Stays disabled; reopening Profile retries.
        }
    }

    private func save(_ enabled: Bool) async {
        guard let userId = authSession.userId, let client = SupabaseClientProvider.shared else { return }
        isSaving = true
        defer { isSaving = false }
        struct Params: Encodable {
            let pEnabled: Bool
            enum CodingKeys: String, CodingKey { case pEnabled = "p_enabled" }
        }
        do {
            try await client.rpc("set_auto_accept_expenses", params: Params(pEnabled: enabled)).execute()
            isOn = enabled
            // The server also accepted the requests already waiting.
            if enabled { await expenseStore.refresh(userId: userId) }
        } catch {
            LoamErrorCapture.capture("profile.auto_accept_failed")
            self.error = UserFacingError.message(for: error)
        }
    }
}
