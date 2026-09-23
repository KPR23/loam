import SwiftUI
import UIKit

/// Shared Profile/picker flow. Connections enable shared expenses only.
struct FriendConnectionHub: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var authSession: AuthSession
    @State private var showsConnectionCodePrompt = false
    var body: some View {
        List {
            Section { Text("Connecting lets you share expenses. It does not reveal personal expenses or automatically approve a split.").foregroundStyle(.secondary) }
            Section("Connect with friends") {
                NavigationLink("Share my code") { ShareConnectionCodeView() }
                Button("Enter a code") { showsConnectionCodePrompt = true }
            }
        }
        .navigationTitle("Connect with friends")
        .navigationBarTitleDisplayMode(.inline)
        .connectionCodePrompt(isPresented: $showsConnectionCodePrompt)
        .task { await connectionStore.refresh(userId: authSession.userId) }
    }
}

struct ShareConnectionCodeView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var invitation: ConnectionInvitation?
    @State private var error: String?
    @State private var isWorking = false
    @State private var justCopied = false
    var body: some View {
        List {
            if let invitation {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(invitation.code)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Expires \(invitation.expiresAt, format: .dateTime.day().month().hour().minute())")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        UIPasteboard.general.string = invitation.code
                        justCopied = true
                    } label: {
                        Label(justCopied ? "Copied" : "Copy code", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                    }
                    Button("Revoke code", role: .destructive) { Task { await revoke() } }
                } header: {
                    Text("Your active code")
                } footer: {
                    Text("Send this code to someone you trust. They’ll enter it in Loam to connect with you.")
                }
            }
            Section { Button { Task { await create() } } label: { Label(invitation == nil ? "Create code" : "Replace code", systemImage: "arrow.clockwise") }.disabled(isWorking) }
        }
        .navigationTitle("Share my code")
        .navigationBarTitleDisplayMode(.inline)
        .task { if invitation == nil { await loadOrCreate() } }
        .alert("Couldn’t create a code", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func create() async { guard !isWorking else { return }; isWorking = true; defer { isWorking = false }; do { invitation = try await connectionStore.createInvitation() } catch { self.error = error.localizedDescription } }
    private func loadOrCreate() async { guard !isWorking else { return }; isWorking = true; defer { isWorking = false }; do { if let active = try await connectionStore.activeInvitation() { invitation = active } else { invitation = try await connectionStore.createInvitation() } } catch { self.error = error.localizedDescription } }
    private func revoke() async { guard !isWorking else { return }; isWorking = true; defer { isWorking = false }; do { try await connectionStore.revokeInvitation(); invitation = nil } catch { self.error = error.localizedDescription } }
}

private struct ConnectionCodePrompt: ViewModifier {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Binding var isPresented: Bool
    let onConnected: ((SplitPartnerOption) -> Void)?
    @State private var code = ""
    @State private var inviterName: String?
    @State private var error: String?
    @State private var isWorking = false
    func body(content: Content) -> some View {
        content
            .alert("Enter a code", isPresented: $isPresented) {
                TextField("Code", text: codeBinding)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Continue") { Task { await preview() } }
                    .disabled(normalizedCode.count != 8 || isWorking)
            } message: {
                Text("Enter the eight-character code your friend shared with you.")
            }
            .confirmationDialog("Connect with \(inviterName ?? "this person")?", isPresented: Binding(get: { inviterName != nil }, set: { if !$0 { inviterName = nil } })) {
                Button("Connect") { Task { await redeem() } }
                Button("Cancel", role: .cancel) { inviterName = nil }
            } message: {
                Text("Connecting allows shared expenses. It does not expose personal expenses or approve splits automatically.")
            }
            .alert("Connection unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
            .onChange(of: isPresented) { _, shown in
                if shown { code = ""; inviterName = nil; error = nil }
            }
    }
    private var codeBinding: Binding<String> {
        Binding(
            get: { code },
            set: { input in
                code = String(input.filter { !$0.isWhitespace && $0 != "-" }.prefix(8))
            }
        )
    }
    private var normalizedCode: String { code.uppercased().filter { $0.isLetter || $0.isNumber } }
    private func preview() async { isWorking = true; defer { isWorking = false }; do { inviterName = try await connectionStore.preview(code: normalizedCode) } catch { self.error = error.localizedDescription } }
    private func redeem() async { isWorking = true; defer { isWorking = false }; do { let friend = try await connectionStore.redeem(code: normalizedCode); inviterName = nil; onConnected?(friend) } catch { self.error = error.localizedDescription } }
}

extension View {
    func connectionCodePrompt(isPresented: Binding<Bool>, onConnected: ((SplitPartnerOption) -> Void)? = nil) -> some View {
        modifier(ConnectionCodePrompt(isPresented: isPresented, onConnected: onConnected))
    }
}

struct AddFriendView: View {
    @Environment(\.dismiss) private var dismiss
    let onConnected: (SplitPartnerOption) -> Void
    @State private var showsConnectionCodePrompt = false
    var body: some View {
        List {
            Section { Text("Connect to share expenses. Personal expenses stay private, and every split still needs approval.").foregroundStyle(.secondary) }
            Section {
                NavigationLink("Share my code") { ShareConnectionCodeView() }
                Button("Enter a code") { showsConnectionCodePrompt = true }
            }
        }
        .navigationTitle("Add friend").navigationBarTitleDisplayMode(.inline)
        .connectionCodePrompt(isPresented: $showsConnectionCodePrompt, onConnected: { friend in
            onConnected(friend)
            dismiss()
        })
    }
}
