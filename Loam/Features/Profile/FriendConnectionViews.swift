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
            .listRowBackground(HomeTheme.surface)

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
            .listRowBackground(HomeTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
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
                    do {
                        try await connectionStore.remove(friend)
                        ToastCenter.shared.showSuccess("Removed \(friend.displayName)")
                    }
                    catch { removalError = UserFacingError.message(for: error) }
                }
            }
        } message: {
            Text(friendPendingRemoval?.isPlaceholder == true
                 ? "Anything they owe or are owed is settled, and expenses you already shared stay in your history."
                 : "You won’t be able to share new expenses until you connect again. Expenses you already shared stay in your history.")
        }
        .errorToast($removalError)
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
                .listRowBackground(HomeTheme.surface)
            }
            if requiresPro {
                Section {
                    Button { showsPaywall = true } label: { Label("Upgrade to Loam Pro", systemImage: "sparkles") }
                } header: {
                    Text("Invite more people")
                } footer: {
                    Text("Loam Free includes one connection. Upgrade to invite more. Joining with a code someone sends you is always free.")
                }
                .listRowBackground(HomeTheme.surface)
            } else {
                Section { Button { Task { await create() } } label: { Label(invitation == nil ? "Create code" : "Replace code", systemImage: "arrow.clockwise") }.disabled(isWorking) }
                .listRowBackground(HomeTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
        .navigationTitle("Share my code")
        .navigationBarTitleDisplayMode(.inline)
        .task { if invitation == nil { await loadOrCreate() } }
        .proPaywall(isPresented: $showsPaywall)
        .onChange(of: subscriptions.isPro) { _, isPro in
            if isPro, requiresPro { requiresPro = false; Task { await create() } }
        }
        .errorToast($error)
    }
    /// The server enforces the same limit; checking first skips a request that would be refused.
    private var needsPro: Bool {
        !subscriptions.isPro && connectionStore.connections.filter { !$0.isPlaceholder }.count >= SubscriptionStore.freeConnectionLimit
    }
    private func create() async { guard !isWorking else { return }; isWorking = true; defer { isWorking = false }; await createInvitation() }
    private func loadOrCreate() async {
        guard !isWorking else { return }; isWorking = true; defer { isWorking = false }
        do {
            if let active = try await connectionStore.activeInvitation() { invitation = active }
            else if needsPro { requiresPro = true }
            else { await createInvitation() }
        } catch { self.error = UserFacingError.message(for: error) }
    }
    private func createInvitation() async {
        do { invitation = try await connectionStore.createInvitation() }
        catch ConnectionError.proRequired where subscriptions.isPro {
            // A fresh purchase can beat RevenueCat's webhook to the backend.
            await subscriptions.syncBackendEntitlement()
            do { invitation = try await connectionStore.createInvitation() }
            catch ConnectionError.proRequired { requiresPro = true }
            catch { self.error = UserFacingError.message(for: error) }
        }
        catch ConnectionError.proRequired { requiresPro = true }
        catch { self.error = UserFacingError.message(for: error) }
    }
    private func revoke() async { guard !isWorking else { return }; isWorking = true; defer { isWorking = false }; do { try await connectionStore.revokeInvitation(); invitation = nil } catch { self.error = UserFacingError.message(for: error) } }
}

/// A small bottom sheet with one text field and one action, used instead of a system alert
/// so the keyboard's hide button stays above it.
private struct CompactEntrySheet<Field: View>: View {
    let title: String
    let message: String
    let actionTitle: String
    let actionDisabled: Bool
    let onCancel: () -> Void
    let onAction: () -> Void
    @ViewBuilder let field: Field

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            field
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(actionDisabled)
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }
}

private struct ConnectionCodePrompt: ViewModifier {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Binding var isPresented: Bool
    let onConnected: ((SplitPartnerOption) -> Void)?
    @State private var code = ""
    @State private var inviterName: String?
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var isFocused: Bool
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                CompactEntrySheet(
                    title: inviterName.map { "Connect with \($0)?" } ?? "Enter a code",
                    message: inviterName == nil
                        ? "Enter the eight-character code your friend shared with you."
                        : "Connecting allows shared expenses. It does not expose personal expenses or approve splits automatically.",
                    actionTitle: inviterName == nil ? "Continue" : "Connect",
                    actionDisabled: isWorking || (inviterName == nil && normalizedCode.count < 8),
                    onCancel: { isPresented = false },
                    onAction: { Task { if inviterName == nil { await preview() } else { await redeem() } } }
                ) {
                    if inviterName == nil {
                        TextField("Code", text: codeBinding)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($isFocused)
                            .onAppear { isFocused = true }
                    } else {
                        Text(code.uppercased())
                    }
                }
            }
            .errorToast($error)
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
        do { inviterName = try await connectionStore.preview(code: normalizedCode) } catch { self.error = UserFacingError.message(for: error) }
    }
    private func redeem() async {
        isWorking = true; defer { isWorking = false }
        do {
            let friend = try await connectionStore.redeem(code: normalizedCode)
            isPresented = false
            onConnected?(friend)
            ToastCenter.shared.showSuccess("Connected with \(friend.displayName)")
        } catch { self.error = UserFacingError.message(for: error) }
    }
}

/// Asks for a name and adds someone without an account as a friend.
private struct PlaceholderFriendPrompt: ViewModifier {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Binding var isPresented: Bool
    let onCreated: (SplitPartnerOption) -> Void
    @State private var name = ""
    @State private var error: String?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                CompactEntrySheet(
                    title: "Add someone without an account",
                    message: "They appear in your friends like anyone else, and every expense you split with them is accepted right away.",
                    actionTitle: "Add",
                    actionDisabled: trimmedName.isEmpty,
                    onCancel: { isPresented = false },
                    onAction: { Task { await create() } }
                ) {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($isFocused)
                        .onAppear { isFocused = true }
                }
            }
            .errorToast($error)
            .onChange(of: isPresented) { _, shown in
                if shown { name = ""; error = nil }
            }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() async {
        let chosen = trimmedName
        guard !chosen.isEmpty else { return }
        do {
            onCreated(try await connectionStore.createPlaceholder(name: chosen))
            isPresented = false
            ToastCenter.shared.showSuccess("Added \(chosen)")
        }
        catch { self.error = UserFacingError.message(for: error) }
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
            .listRowBackground(HomeTheme.surface)
            Section {
                NavigationLink("Share my code") { ShareConnectionCodeView() }
                Button("Enter a code") { showsConnectionCodePrompt = true }
            }
            .listRowBackground(HomeTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
        .navigationTitle("Add friend").navigationBarTitleDisplayMode(.inline)
        .connectionCodePrompt(isPresented: $showsConnectionCodePrompt, onConnected: { friend in
            onConnected(friend)
            dismiss()
        })
    }
}
