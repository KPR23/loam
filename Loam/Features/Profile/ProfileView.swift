import SwiftUI
import PhotosUI
import SafariServices
import Supabase
import UIKit

@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    private static let signedURLLifetime = 5 * 60

    @Published private(set) var urls: [UUID: URL] = [:]
    private var loadedAt: [UUID: Date] = [:]

    func load(_ userId: UUID) async {
        if let loadedAt = loadedAt[userId], Date().timeIntervalSince(loadedAt) < 60 { return }
        guard let client = SupabaseClientProvider.shared else { return }
        struct Row: Decodable {
            let avatarPath: String?
            enum CodingKeys: String, CodingKey { case avatarPath = "avatar_path" }
        }
        do {
            let row: Row = try await client.from("profile")
                .select("avatar_path")
                .eq("id", value: userId)
                .single()
                .execute().value
            loadedAt[userId] = Date()
            if let path = row.avatarPath {
                urls[userId] = try await client.storage.from("avatars").createSignedURL(
                    path: path,
                    expiresIn: Self.signedURLLifetime
                )
            } else {
                urls.removeValue(forKey: userId)
            }
        } catch {
            // A failed request can be retried when the view appears again.
        }
    }

    func upload(_ imageData: Data, for userId: UUID) async throws {
        guard let client = SupabaseClientProvider.shared else {
            throw NSError(domain: "LoamAvatar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign in to add a profile photo."])
        }
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        let storage = client.storage.from("avatars")
        try await LoamErrorCapture.withCapture("profile.avatar_upload_failed") {
            try await storage.upload(path, data: imageData, options: FileOptions(contentType: "image/jpeg"))
        }
        do {
            let url = try await storage.createSignedURL(path: path, expiresIn: Self.signedURLLifetime)
            struct Change: Codable { let avatar_path: String }
            let _: Change = try await client.from("profile")
                .update(Change(avatar_path: path))
                .eq("id", value: userId)
                .select("avatar_path")
                .single()
                .execute().value
            let previousPath = urls[userId]?.lastPathComponent
            urls[userId] = url
            loadedAt[userId] = Date()
            if let previousPath {
                _ = try? await storage.remove(paths: ["\(userId.uuidString.lowercased())/\(previousPath)"])
            }
        } catch {
            LoamErrorCapture.capture("profile.avatar_metadata_save_failed")
            _ = try? await storage.remove(paths: [path])
            throw error
        }
    }
}

struct AvatarView: View {
    let userId: UUID?
    let size: CGFloat

    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        Group {
            if let userId, let url = avatars.urls[userId] {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: userId) {
            if let userId { await avatars.load(userId) }
        }
    }

    private var fallback: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(HomeTheme.secondary)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .system, .light: "sun.max"
        case .dark: "moon.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct ProfileView: View {
    private enum FeaturebaseDestination: String, Identifiable {
        case changelog
        case feedback

        var id: String { rawValue }

        var url: URL {
            switch self {
            case .changelog:
                URL(string: "https://kprslab.featurebase.app/changelog")!
            case .feedback:
                URL(string: "https://kprslab.featurebase.app")!
            }
        }
    }

    @EnvironmentObject private var authSession: AuthSession
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isUploadingPhoto = false
    @State private var photoError: String?
    @AppStorage("loam.appearance") private var appearance: AppAppearance = .system
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue
    @AppStorage(AppPreferences.defaultCurrencyKey) private var defaultCurrency = "PLN"
    @AppStorage(AppPreferences.timeZoneKey) private var timeZoneIdentifier = ""
    @State private var analyticsConsent = false
    @State private var showsSignOut = false
    @State private var isSigningOut = false
    @State private var featurebaseDestination: FeaturebaseDestination?
    @State private var showsConnectionCodePrompt = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(userId: authSession.userId, size: 72)

                            if !authSession.usesDemoMode {
                                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                    ZStack {
                                        Circle()
                                            .fill(HomeTheme.background)
                                            .frame(width: 28, height: 28)
                                        Circle()
                                            .fill(HomeTheme.text)
                                            .frame(width: 24, height: 24)
                                        if isUploadingPhoto {
                                            ProgressView()
                                                .tint(HomeTheme.background)
                                                .scaleEffect(0.7)
                                        } else {
                                            Image(systemName: "camera.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(HomeTheme.background)
                                        }
                                    }
                                }
                                .accessibilityLabel("Change profile photo")
                                .disabled(isUploadingPhoto)
                            }
                        }
                        VStack(spacing: 4) {
                            Text(authSession.displayName ?? "You")
                                .font(.system(.title, design: .rounded).weight(.semibold))
                            Text(authSession.email ?? "Your own little corner of Loam.")
                                .font(.subheadline)
                                .foregroundStyle(HomeTheme.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section("Account") {
                    NavigationLink {
                        PersonalDetailsView()
                    } label: {
                        ProfileRow("Personal details", symbol: "person.text.rectangle", color: .blue)
                    }
                    NavigationLink { ShareConnectionCodeView() } label: {
                        ProfileRow("Share my code", symbol: "square.and.arrow.up", color: .teal)
                    }
                    Button { showsConnectionCodePrompt = true } label: {
                        ProfileRow("Enter a code", symbol: "key", color: .orange)
                    }
                }

                if authSession.deletionPending {
                    Section("Account deletion") {
                        Label(deletionStatusTitle, systemImage: deletionStatusSymbol)
                        Text(deletionStatusDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if authSession.deletionStatus == .complete {
                            Button("Dismiss confirmation") { authSession.dismissDeletionConfirmation() }
                        } else {
                            Button("Check deletion status") { Task { await authSession.refreshDeletionStatus() } }
                        }
                    }
                }

                themeSection
                preferencesSection
                if let userId = authSession.userId, !authSession.usesDemoMode {
                    privacySection(userId: userId)
                }

                Section {
                    Button {
                        featurebaseDestination = .changelog
                    } label: {
                        ProfileRow("Changelog", symbol: "newspaper", color: .purple)
                    }
                    .accessibilityHint("Opens Loam's changelog")
                    Button {
                        featurebaseDestination = .feedback
                    } label: {
                        ProfileRow("Give feedback", symbol: "star", color: .orange)
                    }
                    .accessibilityHint("Opens Loam's feedback board")
                    Link(destination: URL(string: "mailto:kprcode@icloud.com")!) {
                        ProfileRow("Contact support", symbol: "envelope", color: .blue)
                    }
                    .accessibilityHint("Opens an email addressed to Loam support")
                    NavigationLink {
                        ProfileInfoView(title: "About the app", symbol: "app.badge", message: "A little clarity. Every day.", detail: "A calmer place for your expenses, shared moments, and everything in between.\n\n\(Self.version)")
                    } label: {
                        ProfileRow("About the app", symbol: "app.badge", color: .purple)
                    }
                }

                Section {
                    Button { showsSignOut = true } label: {
                        HStack {
                            ProfileRow("Sign out", symbol: "rectangle.portrait.and.arrow.right", color: .red, destructive: true)
                            if isSigningOut { ProgressView() }
                        }
                    }
                    .disabled(isSigningOut)
                } footer: {
                    Text("Loam · \(Self.version)")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }

                #if DEBUG
                Section {
                    NavigationLink {
                        ProfileDeveloperView()
                    } label: {
                        ProfileRow("Developer", symbol: "hammer", color: .gray)
                    }
                }
                #endif
            }
            .listStyle(.insetGrouped)
            .connectionCodePrompt(isPresented: $showsConnectionCodePrompt)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedPhoto) { _, photo in
                guard let photo, let userId = authSession.userId else { return }
                isUploadingPhoto = true
                photoError = nil
                Task {
                    defer { isUploadingPhoto = false; selectedPhoto = nil }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self),
                              let image = UIImage(data: data),
                              let jpeg = Self.avatarJPEG(from: image) else {
                            throw NSError(domain: "LoamAvatar", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read that photo."])
                        }
                        try await AvatarStore.shared.upload(jpeg, for: userId)
                    } catch { photoError = error.localizedDescription }
                }
            }
            .alert("Profile photo", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
                Button("OK") { photoError = nil }
            } message: {
                Text(photoError ?? "")
            }
            .confirmationDialog("Sign out of Loam?", isPresented: $showsSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    isSigningOut = true
                    Task {
                        await authSession.signOut()
                        isSigningOut = false
                    }
                }
            } message: {
                Text("You can sign back in whenever you’re ready.")
            }
            .sheet(item: $featurebaseDestination) { destination in
                SafariView(url: destination.url)
                    .ignoresSafeArea()
            }
            .alert("Account", isPresented: Binding(get: { authSession.lastError != nil }, set: { if !$0 { authSession.lastError = nil } })) {
                Button("OK") { authSession.lastError = nil }
            } message: {
                Text(authSession.lastError ?? "")
            }
        }
    }

    static var version: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private var themeSection: some View {
        Section("Theme") {
            Picker(selection: $appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                preferenceLabel("Appearance", symbol: appearance.symbol, color: .indigo)
            }
            .pickerStyle(.menu)
            .tint(HomeTheme.secondary)

            Picker(selection: $accentColor) {
                ForEach(AppAccentColor.allCases) { option in
                    HStack(spacing: 8) {
                        Image(uiImage: option.menuDot).renderingMode(.original)
                        Text(option.title).foregroundStyle(HomeTheme.text)
                    }
                    .tag(option)
                }
            } label: {
                preferenceLabel("Accent color", symbol: "paintbrush.pointed", color: .blue)
            }
            .pickerStyle(.menu)
            .tint(HomeTheme.secondary)
        }
    }

    private var preferencesSection: some View {
        Section {
            NavigationLink {
                DefaultCurrencySettingsView()
            } label: {
                ProfileRow("Default currency", symbol: "dollarsign.arrow.circlepath", color: .green, detail: defaultCurrency.uppercased())
            }
            NavigationLink {
                TimeZoneSettingsView()
            } label: {
                ProfileRow("Time zone", symbol: "globe", color: .teal, detail: AppPreferences.timeZoneName(timeZoneIdentifier))
            }
        } header: {
            Text("Preferences")
        }
    }

    private func privacySection(userId: UUID) -> some View {
        Section {
            Toggle(isOn: $analyticsConsent) {
                ProfileRow("Share usage analytics", symbol: "chart.bar", color: .indigo)
            }
            .task(id: userId) {
                analyticsConsent = Telemetry.hasAnalyticsConsent(for: userId)
            }
            .onChange(of: analyticsConsent) { _, granted in
                Telemetry.setAnalyticsConsent(granted, for: userId)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Helps improve Loam by recording which screens you use and masked screen recordings. Amounts, descriptions and names are never included. Crash reports are always sent.")
        }
    }

    private func preferenceLabel(_ title: String, symbol: String, color: Color) -> some View {
        Label {
            Text(title)
                .font(.callout)
                .foregroundStyle(HomeTheme.text)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
        }
        .labelStyle(CompactProfileLabelStyle())
    }

    private static func avatarJPEG(from image: UIImage) -> Data? {
        let targetSize: CGFloat = 256
        let scale = targetSize / min(image.size.width, image.size.height)
        let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetSize, height: targetSize))
        let cropped = renderer.image { _ in
            image.draw(in: CGRect(x: (targetSize - scaled.width) / 2,
                                  y: (targetSize - scaled.height) / 2,
                                  width: scaled.width, height: scaled.height))
        }
        return cropped.jpegData(compressionQuality: 0.8)
    }

    private var deletionStatusTitle: String {
        switch authSession.deletionStatus {
        case .submissionUncertain: "Request status needs checking"
        case .processing: "Deletion in progress"
        case .needsAttention: "Deletion needs attention"
        case .complete: "Deletion complete"
        case .unavailable: "Status temporarily unavailable"
        case .none: "Deletion status"
        }
    }

    private var deletionStatusSymbol: String {
        switch authSession.deletionStatus {
        case .complete: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .unavailable, .submissionUncertain: "arrow.clockwise.circle"
        default: "hourglass"
        }
    }

    private var deletionStatusDetail: String {
        switch authSession.deletionStatus {
        case .submissionUncertain: "We couldn’t confirm the request response. Check its status before trying again."
        case .processing: "Your account is closed. Deletion usually finishes within a few minutes."
        case .needsAttention: "Your account is closed, but processing is taking longer than expected. Contact support if this continues."
        case .complete: "Your account and private data have been deleted."
        case .unavailable: "The status service is unavailable. Your secure receipt is saved; try again shortly."
        case .none: ""
        }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct CompactProfileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}

private struct ProfileRow: View {
    let title: String
    let symbol: String
    let color: Color
    var detail: String? = nil
    var destructive = false

    init(_ title: String, symbol: String, color: Color, detail: String? = nil, destructive: Bool = false) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.detail = detail
        self.destructive = destructive
    }

    var body: some View {
        HStack {
            Label {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(destructive ? Color.red : HomeTheme.text)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
            }
            .labelStyle(CompactProfileLabelStyle())
            if let detail {
                Spacer(minLength: 8)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PersonalDetailsView: View {
    @EnvironmentObject private var authSession: AuthSession
    @State private var name = ""
    @State private var isSaving = false
    @State private var isDeletingAccount = false
    @State private var showsDeleteConfirmation = false
    @State private var error: String?
    @State private var deletionAuthorization = AppleDeletionAuthorization()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("E-mail") {
                    Text(authSession.email ?? "Not provided")
                        .textSelection(.enabled)
                }
            } footer: {
                Text(authSession.usesDemoMode ? "You’re using a local demo account." : "This is the email associated with your sign-in account. Apple may provide a private relay address.")
            }
            Section {
                Button {
                    showsDeleteConfirmation = true
                } label: {
                    HStack {
                        ProfileRow("Delete account", symbol: "person.crop.circle.badge.minus", color: .red, destructive: true)
                        if isDeletingAccount { Spacer(); ProgressView() }
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Personal details")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving || isDeletingAccount)
        .onAppear { name = authSession.displayName ?? "" }
        .confirmationDialog("Delete your account?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                isDeletingAccount = true
                error = nil
                Task {
                    do {
                        // Cancelling this system prompt exits without touching the account.
                        let credential = try await deletionAuthorization.request()
                        try await authSession.deleteAccount(credential: credential)
                    } catch {
                        self.error = error.localizedDescription
                    }
                    isDeletingAccount = false
                }
            }
        } message: {
            Text(authSession.usesDemoMode
                 ? "This permanently removes your on-device demo data. This can’t be undone."
                 : "Your sign-in, profile photo and private expenses will be removed. Shared expenses and balances remain for other participants under the name Deleted user. This can’t be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    isSaving = true
                    error = nil
                    Task {
                        do {
                            try await authSession.updateDisplayName(name)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        isSaving = false
                    }
                } label: {
                    if isSaving { ProgressView() } else { Text("Save") }
                }
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == authSession.displayName)
            }
        }
    }
}

private struct ConnectedAccountsView: View {
    @EnvironmentObject private var authSession: AuthSession
    var body: some View {
        List {
            Section {
                provider("Apple", id: "apple")
                provider("Google", id: "google")
                ForEach(authSession.connectedProviders.subtracting(["apple", "google"]).sorted(), id: \.self) { provider in
                    self.provider(provider.capitalized, id: provider)
                }
            } footer: {
                Text("Your connected sign-in methods appear here. Connecting additional accounts is coming soon.")
            }
        }
        .navigationTitle("Connected accounts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func provider(_ title: String, id: String) -> some View {
        LabeledContent {
            Text(authSession.connectedProviders.contains(id) ? "Connected" : "Not connected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } label: {
            Label {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
            } icon: {
                if id == "google" {
                    Image("GoogleG")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: id == "apple" ? "apple.logo" : "envelope")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(id == "apple" ? Color.primary : Color.blue)
                        .frame(width: 20, height: 20)
                }
            }
            .labelStyle(CompactProfileLabelStyle())
        }
        .alignmentGuide(.listRowSeparatorLeading) { dimensions in dimensions[.leading] }
    }
}

private struct DefaultCurrencySettingsView: View {
    @AppStorage(AppPreferences.defaultCurrencyKey) private var currency = "PLN"

    var body: some View {
        List {
            Section {
                ForEach(AppPreferences.supportedCurrencies, id: \.self) { code in
                    Button {
                        currency = code
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(code)
                                    .foregroundStyle(HomeTheme.text)
                                Text(AppPreferences.currencyName(code))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if currency.uppercased() == code {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("New expenses use this currency. Existing expenses are never converted or changed.")
            }
        }
        .navigationTitle("Default currency")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TimeZoneSettingsView: View {
    @AppStorage(AppPreferences.timeZoneKey) private var timeZoneIdentifier = ""
    @State private var searchText = ""

    private var identifiers: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.localizedCaseInsensitiveContains(query)
                || AppPreferences.timeZoneName($0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                timeZoneRow(identifier: "", title: "Device time zone", subtitle: TimeZone.current.localizedName(for: .standard, locale: .current) ?? TimeZone.current.identifier)
            } footer: {
                Text("Used for calendar dates and recurring expenses.")
            }

            Section("Time zones") {
                ForEach(identifiers, id: \.self) { identifier in
                    timeZoneRow(
                        identifier: identifier,
                        title: AppPreferences.timeZoneName(identifier),
                        subtitle: identifier
                    )
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search city or time zone")
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func timeZoneRow(identifier: String, title: String, subtitle: String) -> some View {
        Button {
            timeZoneIdentifier = identifier
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(HomeTheme.text)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Text(utcOffset(for: identifier))
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if timeZoneIdentifier == identifier {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Selected")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func utcOffset(for identifier: String) -> String {
        let timeZone = identifier.isEmpty ? TimeZone.current : TimeZone(identifier: identifier) ?? .current
        let seconds = timeZone.secondsFromGMT(for: Date())
        let sign = seconds >= 0 ? "+" : "−"
        let absoluteSeconds = abs(seconds)
        return String(format: "UTC%@%02d:%02d", sign, absoluteSeconds / 3_600, (absoluteSeconds % 3_600) / 60)
    }
}

private struct ProfileInfoView: View {
    let title: String
    let symbol: String
    let message: String
    let detail: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(HomeTheme.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text(detail)
                    .font(.body)
                    .foregroundStyle(HomeTheme.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(32)
            .padding(.top, 48)
        }
        .background(HomeTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
private struct ProfileDeveloperView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @State private var showClearAllExpensesConfirm = false
    var body: some View {
        List {
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
        }
        .navigationTitle("Developer")
        .alert("Clear expenses you created?", isPresented: $showClearAllExpensesConfirm) {
            Button("Clear mine", role: .destructive) {
                guard let userId = authSession.userId else { return }
                Task { await expenseStore.clearAllExpenses(userId: userId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearExpensesConfirmationMessage)
        }
    }
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
}
#endif

#Preview {
    ProfileView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
