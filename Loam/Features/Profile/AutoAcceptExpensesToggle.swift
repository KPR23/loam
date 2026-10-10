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
            Label {
                Text("Auto-accept expenses")
                    .font(.body)
                    .foregroundStyle(HomeTheme.text)
            } icon: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 24, height: 24)
            }
        }
        .disabled(!hasLoaded || isSaving)
        .task(id: authSession.userId) { await load() }
        .alert("Couldn’t update the setting", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
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
            self.error = error.localizedDescription
        }
    }
}
