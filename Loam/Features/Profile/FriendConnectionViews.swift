import SwiftUI
import UIKit

/// Everything about friends in one place: connect with new people, see who you're connected
/// to, and remove someone. Connections enable shared expenses only.
struct FriendsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var authSession: AuthSession
    @State private var showsConnectionCodePrompt = false
    @State private var showsPlaceholderPrompt = false
    @State private var searchText = ""
    @State private var friendPendingRemoval: SplitPartnerOption?
    @State private var removalError: String?

    private var visibleFriends: [SplitPartnerOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return connectionStore.connections }
        return connectionStore.connections.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                NavigationLink { ShareConnectionCodeView() } label: {
                    Label("Share my code", systemImage: "square.and.arrow.up")
                }
                Button { showsConnectionCodePrompt = true } label: {
                    Label("Enter a code", systemImage: "key")
                }
                Button { showsPlaceholderPrompt = true } label: {
                    Label("Add someone without an account", systemImage: "person.badge.plus")
                }
            } header: {
                Text("Add a friend")
            } footer: {
                Text("Connecting lets you share expenses. It does not reveal personal expenses or automatically approve a split. People without an account are only tracked by you.")
            }

            Section {
                if connectionStore.connections.isEmpty {
                    if connectionStore.hasLoadedConnections {
                        Text("No friends yet.")
                            .foregroundStyle(.secondary)
                    } else if connectionStore.lastError != nil, !connectionStore.isLoading {
                        // A failed load would otherwise read as loading forever.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Couldn’t load your friends.")
                                .foregroundStyle(.secondary)
                            Button("Try again") {
                                Task { await connectionStore.refresh(userId: authSession.userId) }
                            }
                        }
                    } else {
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                } else if visibleFriends.isEmpty {
                    Text("No friends match “\(searchText)”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleFriends) { friend in
                        HStack(spacing: 12) {
                            AvatarView(userId: friend.userId, size: 36, name: friend.displayName)
                            Text(friend.displayName)
                            Spacer(minLength: 0)
                            if friend.isPlaceholder {
                                Text("No account")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            // Avoid `role: .destructive` — it removes the row before the confirmation;
                            // the explicit tint keeps the destructive color the app tint would replace.
                            Button("Remove", systemImage: "person.badge.minus") { friendPendingRemoval = friend }
                                .tint(.red)
                        }
                        .contextMenu {
                            Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) {
                                friendPendingRemoval = friend
                            }
                        }
                    }
                }
            } header: {
                Text(connectionStore.connections.isEmpty ? "Friends" : "Friends (\(connectionStore.connections.count))")
            } footer: {
                if !connectionStore.connections.isEmpty {
                    Text("Swipe a friend to remove them. Past shared expenses stay in your history.")
                }
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search friends")
        .connectionCodePrompt(isPresented: $showsConnectionCodePrompt)
        .placeholderFriendPrompt(isPresented: $showsPlaceholderPrompt) { _ in }
        .task { await connectionStore.refresh(userId: authSession.userId) }
        .refreshable { await connectionStore.refresh(userId: authSession.userId) }
        .confirmationDialog(
            "Remove \(friendPendingRemoval?.displayName ?? "this friend")?",
            isPresented: Binding(get: { friendPendingRemoval != nil }, set: { if !$0 { friendPendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove friend", role: .destructive) {
                guard let friend = friendPendingRemoval else { return }
                friendPendingRemoval = nil
                Task {
                    do { try await connectionStore.remove(friend) }
                    catch { removalError = error.localizedDescription }
                }
            }
        } message: {
            Text(friendPendingRemoval?.isPlaceholder == true
                 ? "Anything they owe or are owed is settled, and expenses you already shared stay in your history."
                 : "You won’t be able to share new expenses until you connect again. Expenses you already shared stay in your history.")
        }
        .alert("Couldn’t remove friend", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK") { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }
}

struct ShareConnectionCodeView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var invitation: ConnectionInvitation?
    @State private var error: String?
    @State private var isWorking = false
    @State private var justCopied = false
    @State private var requiresPro = false
    @State private var showsPaywall = false
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
            if requiresPro {
                Section {
                    Button { showsPaywall = true } label: { Label("Upgrade to Loam Pro", systemImage: "sparkles") }
                } header: {
                    Text("Invite more people")
                } footer: {
                    Text("Loam Free includes one connection. Upgrade to invite more. Joining with a code someone sends you is always free.")
                }
            } else {
                Section { Button { Task { await create() } } label: { Label(invitation == nil ? "Create code" : "Replace code", systemImage: "arrow.clockwise") }.disabled(isWorking) }
            }
        }
        .navigationTitle("Share my code")
        .navigationBarTitleDisplayMode(.inline)
        .task { if invitation == nil { await loadOrCreate() } }
        .proPaywall(isPresented: $showsPaywall)
        .onChange(of: subscriptions.isPro) { _, isPro in
            if isPro, requiresPro { requiresPro = false; Task { await create() } }
        }
        .alert("Couldn’t create a code", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    /// The server enforces the same limit; checking first just opens the paywall sooner.
    private var needsPro: Bool {
        !subscriptions.isPro && connectionStore.connections.filter { !$0.isPlaceholder }.count >= SubscriptionStore.freeConnectionLimit
    }
    private func create() async { guard !isWorking else { return }; isWorking = true; defer { isWorking = false }; await createInvitation() }
    private func loadOrCreate() async {
        guard !isWorking else { return }; isWorking = true; defer { isWorking = false }
        do {
            if let active = try await connectionStore.activeInvitation() { invitation = active }
            else if needsPro { showPaywall() }
            else { await createInvitation() }
        } catch { self.error = error.localizedDescription }
    }
    private func createInvitation() async {
        do { invitation = try await connectionStore.createInvitation() }
        catch ConnectionError.proRequired where subscriptions.isPro {
            // A fresh purchase can beat RevenueCat's webhook to the backend.
            await subscriptions.syncBackendEntitlement()
            do { invitation = try await connectionStore.createInvitation() }
            catch ConnectionError.proRequired { showPaywall() }
            catch { self.error = error.localizedDescription }
        }
        catch ConnectionError.proRequired { showPaywall() }
        catch { self.error = error.localizedDescription }
    }
    private func showPaywall() { requiresPro = true; showsPaywall = true }
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
                // Not disabled by the code's length: alert buttons don't reliably re-enable
                // as the text field changes, so preview() checks the length instead.
                Button("Continue") { Task { await preview() } }
                    .disabled(isWorking)
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
    private func preview() async {
        guard normalizedCode.count == 8 else { error = "Codes are eight characters long. Check it and try again."; return }
        isWorking = true; defer { isWorking = false }
        do { inviterName = try await connectionStore.preview(code: normalizedCode) } catch { self.error = error.localizedDescription }
    }
    private func redeem() async { isWorking = true; defer { isWorking = false }; do { let friend = try await connectionStore.redeem(code: normalizedCode); inviterName = nil; onConnected?(friend) } catch { self.error = error.localizedDescription } }
}

/// Asks for a name and adds someone without an account as a friend.
private struct PlaceholderFriendPrompt: ViewModifier {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Binding var isPresented: Bool
    let onCreated: (SplitPartnerOption) -> Void
    @State private var name = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("Add someone without an account", isPresented: $isPresented) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Add") { Task { await create() } }
                    .disabled(trimmedName.isEmpty)
            } message: {
                Text("They appear in your friends like anyone else, and every expense you split with them is accepted right away.")
            }
            .alert("Couldn’t add them", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onChange(of: isPresented) { _, shown in
                if shown { name = ""; error = nil }
            }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() async {
        let chosen = trimmedName
        guard !chosen.isEmpty else { return }
        do { onCreated(try await connectionStore.createPlaceholder(name: chosen)) }
        catch { self.error = error.localizedDescription }
    }
}

extension View {
    func placeholderFriendPrompt(isPresented: Binding<Bool>, onCreated: @escaping (SplitPartnerOption) -> Void) -> some View {
        modifier(PlaceholderFriendPrompt(isPresented: isPresented, onCreated: onCreated))
    }

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
