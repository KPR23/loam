import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Everything about friends in one place: connect with new people, see who you're connected
/// to, and remove someone. Connections enable shared expenses only.
struct FriendsView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showsConnectionCodePrompt = false
    @State private var showsPlaceholderPrompt = false
    @State private var searchText = ""
    @State private var friendPendingRemoval: SplitPartnerOption?
    @State private var friendBeingRenamed: SplitPartnerOption?
    @State private var error: String?
    @State private var showsSplitwisePicker = false
    @State private var splitwiseExport: SplitwiseImport.Export?
    @State private var pendingShareCount: Int?

    private var visibleFriends: [SplitPartnerOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return connectionStore.connections }
        return connectionStore.connections.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                NavigationLink { ShareConnectionCodeView() } label: {
                    ProfileRow("Share my code", symbol: "square.and.arrow.up", color: .blue)
                }
                Button { showsConnectionCodePrompt = true } label: {
                    ProfileRow("Enter a code", symbol: "key", color: .orange)
                }
                Button { showsPlaceholderPrompt = true } label: {
                    AddWithoutAccountRow(showsProBadge: !subscriptions.isPro)
                }
                Button {
                    if let sample = SplitwiseImportView.sampleExport { splitwiseExport = sample } else { showsSplitwisePicker = true }
                } label: {
                    ProfileRow("Import from Splitwise", symbol: "square.and.arrow.down", color: .teal)
                }
            } header: {
                Text("Add a friend")
            } footer: {
                Text("Friends only see expenses you share with them. People without an account are tracked by you alone.")
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
                        Group {
                            // People without an account are yours to edit; tapping opens the rename sheet.
                            if friend.isPlaceholder {
                                Button { friendBeingRenamed = friend } label: { FriendRow(friend: friend) }
                                    .accessibilityHint("Rename")
                            } else {
                                FriendRow(friend: friend)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            // Avoid `role: .destructive` — it removes the row before the confirmation;
                            // the explicit tint keeps the destructive color the app tint would replace.
                            Button("Remove", systemImage: "person.badge.minus") { confirmRemoval(of: friend) }
                                .tint(.red)
                            if friend.isPlaceholder {
                                Button("Rename", systemImage: "pencil") { friendBeingRenamed = friend }
                            }
                        }
                        .contextMenu {
                            if friend.isPlaceholder {
                                Button("Rename", systemImage: "pencil") { friendBeingRenamed = friend }
                            }
                            Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) {
                                confirmRemoval(of: friend)
                            }
                        }
                        // On the row, so on iOS 26 the confirmation points at the friend being removed
                        // rather than floating over the top of the list.
                        .confirmationDialog(
                            "Remove \(friend.displayName)?",
                            isPresented: Binding(
                                get: { friendPendingRemoval?.id == friend.id },
                                set: { if !$0, friendPendingRemoval?.id == friend.id { friendPendingRemoval = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Remove friend", role: .destructive) { remove(friend) }
                        } message: {
                            Text(removalMessage)
                        }
                    }
                }
            } header: {
                Text(connectionStore.connections.isEmpty ? "Friends" : "Friends (\(connectionStore.connections.count))")
            } footer: {
                if !connectionStore.connections.isEmpty {
                    Text(connectionStore.connections.contains(where: \.isPlaceholder)
                         ? "Tap someone without an account to rename them. Swipe a friend to remove them. Past shared expenses stay in your history."
                         : "Swipe a friend to remove them. Past shared expenses stay in your history.")
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
        .renamePlaceholderPrompt(friend: $friendBeingRenamed)
        .task { await connectionStore.refresh(userId: authSession.userId) }
        .refreshable { await connectionStore.refresh(userId: authSession.userId) }
        .fileImporter(isPresented: $showsSplitwisePicker, allowedContentTypes: [.commaSeparatedText, .plainText]) { picked in
            do { splitwiseExport = try SplitwiseImportView.readExport(from: picked) }
            catch CocoaError.userCancelled {}
            catch { self.error = UserFacingError.message(for: error) }
        }
        .sheet(isPresented: Binding(get: { splitwiseExport != nil }, set: { if !$0 { splitwiseExport = nil } })) {
            if let splitwiseExport { SplitwiseImportSheet(export: splitwiseExport) }
        }
        .errorToast($error)
    }

    private func remove(_ friend: SplitPartnerOption) {
        friendPendingRemoval = nil
        Task {
            do {
                try await connectionStore.remove(friend)
            } catch { self.error = UserFacingError.message(for: error) }
        }
    }

    /// Asks first how many expenses removal would decline, so the dialog can say so before anything happens.
    private func confirmRemoval(of friend: SplitPartnerOption) {
        Task {
            pendingShareCount = await connectionStore.pendingShareCount(with: friend)
            friendPendingRemoval = friend
        }
    }

    private var removalMessage: String {
        if friendPendingRemoval?.isPlaceholder == true {
            return String(localized: "Anything they owe or are owed is settled, and expenses you already shared stay in your history.")
        }
        let waiting = switch pendingShareCount {
        case 0: String(localized: "Expenses you already shared stay in your history.")
        case let count?: String(localized: "\(count) expenses between you are still waiting for an answer and will be declined. The rest stay in your history.")
        case nil: String(localized: "Expenses between you that are still waiting for an answer are declined, and the rest stay in your history.")
        }
        return String(localized: "You won’t be able to share new expenses until you connect again.") + " " + waiting
    }
}

private struct FriendRow: View {
    let friend: SplitPartnerOption
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(userId: friend.userId, size: 36, name: friend.displayName)
            Text(friend.displayName)
                .foregroundStyle(HomeTheme.text)
            Spacer(minLength: 0)
            if friend.isPlaceholder {
                Text("No account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// "Add without an account", marked PRO for accounts on the free plan.
struct AddWithoutAccountRow: View {
    let showsProBadge: Bool
    var body: some View {
        HStack {
            ProfileRow("Add without an account", symbol: "person.crop.circle.badge.plus", color: .green)
            if showsProBadge {
                Spacer(minLength: 8)
                ProBadge()
            }
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
                        ProfileRow(justCopied ? "Copied" : "Copy code", symbol: justCopied ? "checkmark" : "doc.on.doc", color: justCopied ? .green : .blue)
                    }
                    Button { Task { await revoke() } } label: {
                        ProfileRow("Revoke code", symbol: "xmark", color: .red, destructive: true)
                    }
                } header: {
                    Text("Your active code")
                } footer: {
                    Text("Share this code with a friend you want to connect with. They’ll enter it in Loam.")
                }
                .listRowBackground(HomeTheme.surface)
            }
            if requiresPro {
                Section {
                    Button { showsPaywall = true } label: {
                        ProfileRow("Upgrade to Loam Pro", symbol: "arrow.up.circle", color: .blue)
                    }
                } header: {
                    Text("Invite more people")
                } footer: {
                    Text("Loam Free includes one connection. Upgrade to invite more. Joining with a code someone sends you is always free.")
                }
                .listRowBackground(HomeTheme.surface)
            } else {
                Section {
                    Button { Task { await create() } } label: {
                        ProfileRow(invitation == nil ? "Create code" : "Replace code", symbol: "arrow.clockwise", color: .orange)
                    }
                    .disabled(isWorking)
                    // ProfileRow sets its own text color, so dim it by hand while a request runs.
                    .opacity(isWorking ? 0.5 : 1)
                }
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
                    title: inviterName.map { String(localized: "Connect with \($0)?") } ?? String(localized: "Enter a code"),
                    message: inviterName == nil
                        ? String(localized: "Enter the eight-character code your friend shared with you.")
                        : String(localized: "Connecting allows shared expenses. It does not expose personal expenses or approve splits automatically."),
                    actionTitle: inviterName == nil ? String(localized: "Continue") : String(localized: "Connect"),
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
        guard normalizedCode.count == 8 else { error = String(localized: "Codes are eight characters long. Check it and try again."); return }
        isWorking = true; defer { isWorking = false }
        do { inviterName = try await connectionStore.preview(code: normalizedCode) } catch { self.error = UserFacingError.message(for: error) }
    }
    private func redeem() async {
        isWorking = true; defer { isWorking = false }
        do {
            let friend = try await connectionStore.redeem(code: normalizedCode)
            isPresented = false
            onConnected?(friend)
        } catch { self.error = UserFacingError.message(for: error) }
    }
}

/// Asks for a name and adds someone without an account as a friend. Adding people without an
/// account is a Loam Pro feature, so a free account sees the paywall first and, once it
/// upgrades, the name sheet.
private struct PlaceholderFriendPrompt: ViewModifier {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Binding var isPresented: Bool
    let onCreated: (SplitPartnerOption) -> Void
    @State private var name = ""
    @State private var error: String?
    @State private var isWorking = false
    @State private var showsPaywall = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            // Never shown without Pro, so a free account doesn't see the sheet flash before the paywall.
            .sheet(isPresented: Binding(get: { isPresented && subscriptions.isPro }, set: { if !$0 { isPresented = false } })) {
                CompactEntrySheet(
                    title: String(localized: "Add someone without an account"),
                    message: String(localized: "They appear in your friends like anyone else, and every expense you split with them is accepted right away."),
                    actionTitle: String(localized: "Add"),
                    actionDisabled: trimmedName.isEmpty || isWorking,
                    onCancel: { isPresented = false },
                    onAction: { Task { await create() } }
                ) {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($isFocused)
                        .onAppear { isFocused = true }
                }
            }
            .proPaywall(isPresented: $showsPaywall) {
                // Upgraded on the paywall: carry on to the name sheet now that it's gone.
                if subscriptions.isPro { isPresented = true }
            }
            .errorToast($error)
            .onChange(of: isPresented) { _, shown in
                guard shown else { return }
                name = ""; error = nil
                if !subscriptions.isPro {
                    isPresented = false
                    showsPaywall = true
                }
            }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() async {
        let chosen = trimmedName
        guard !chosen.isEmpty, !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        do {
            onCreated(try await connectionStore.createPlaceholder(name: chosen))
            isPresented = false
        }
        catch ConnectionError.placeholderProRequired where subscriptions.isPro {
            // A fresh purchase can beat RevenueCat's webhook to the backend.
            await subscriptions.syncBackendEntitlement()
            do {
                onCreated(try await connectionStore.createPlaceholder(name: chosen))
                isPresented = false
            } catch { self.error = UserFacingError.message(for: error) }
        }
        catch ConnectionError.placeholderProRequired { self.error = String(localized: "Adding people without an account needs Loam Pro.") }
        catch { self.error = UserFacingError.message(for: error) }
    }
}

/// Renames someone without an account. Like adding them, this is Loam Pro: a free account
/// sees the paywall first and, once it upgrades, the rename sheet.
private struct RenamePlaceholderPrompt: ViewModifier {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Binding var friend: SplitPartnerOption?
    @State private var name = ""
    @State private var error: String?
    @State private var isWorking = false
    @State private var showsPaywall = false
    /// Who to rename once the paywall closes with Pro.
    @State private var pendingFriend: SplitPartnerOption?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            // Never shown without Pro, so a free account doesn't see the sheet flash before the paywall.
            .sheet(item: Binding(get: { subscriptions.isPro ? friend : nil }, set: { friend = $0 })) { friend in
                CompactEntrySheet(
                    title: String(localized: "Rename \(friend.displayName)"),
                    message: String(localized: "Only you see this name. It updates everywhere you split with them."),
                    actionTitle: String(localized: "Save"),
                    actionDisabled: trimmedName.isEmpty || trimmedName == friend.displayName || isWorking,
                    onCancel: { self.friend = nil },
                    onAction: { Task { await save(friend) } }
                ) {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { Task { await save(friend) } }
                        .focused($isFocused)
                        .onAppear { isFocused = true }
                }
            }
            .proPaywall(isPresented: $showsPaywall) {
                // Upgraded on the paywall: carry on to the rename sheet now that it's gone.
                if subscriptions.isPro { friend = pendingFriend }
                pendingFriend = nil
            }
            .errorToast($error)
            .onChange(of: friend?.id) { _, id in
                guard id != nil else { return }
                name = friend?.displayName ?? ""; error = nil
                if !subscriptions.isPro {
                    pendingFriend = friend
                    friend = nil
                    showsPaywall = true
                }
            }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save(_ target: SplitPartnerOption) async {
        let chosen = trimmedName
        guard !chosen.isEmpty, chosen != target.displayName, !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        do {
            try await connectionStore.renamePlaceholder(target, to: chosen)
            friend = nil
        }
        catch ConnectionError.placeholderProRequired where subscriptions.isPro {
            // A fresh purchase can beat RevenueCat's webhook to the backend.
            await subscriptions.syncBackendEntitlement()
            do {
                try await connectionStore.renamePlaceholder(target, to: chosen)
                friend = nil
            } catch { self.error = UserFacingError.message(for: error) }
        }
        catch ConnectionError.placeholderProRequired { self.error = String(localized: "Renaming people without an account needs Loam Pro.") }
        catch { self.error = UserFacingError.message(for: error) }
    }
}

extension View {
    func placeholderFriendPrompt(isPresented: Binding<Bool>, onCreated: @escaping (SplitPartnerOption) -> Void) -> some View {
        modifier(PlaceholderFriendPrompt(isPresented: isPresented, onCreated: onCreated))
    }

    func renamePlaceholderPrompt(friend: Binding<SplitPartnerOption?>) -> some View {
        modifier(RenamePlaceholderPrompt(friend: friend))
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
            Section {
                NavigationLink { ShareConnectionCodeView() } label: {
                    ProfileRow("Share my code", symbol: "square.and.arrow.up", color: .blue)
                }
                Button { showsConnectionCodePrompt = true } label: {
                    ProfileRow("Enter a code", symbol: "key", color: .orange)
                }
            } footer: {
                Text("Friends only see expenses you share with them, and every split still needs their approval.")
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
