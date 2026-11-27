import SwiftUI
import PhotosUI
import RevenueCatUI
import SafariServices
import Supabase
import UIKit

/// Avatars are cached in memory and on disk, keyed by the storage path. Every upload gets a new
/// path, so a cached file is never stale: opening Profile shows the photo at once, and only a
/// changed path downloads again.
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()
    private static let pathsKey = "loam.avatarPaths"
    private static let recheckInterval: TimeInterval = 60

    /// Bumped when a photo changes, so views showing it redraw. Reading from disk does not bump it,
    /// because views do that while drawing.
    @Published private(set) var revision = 0
    private var images: [UUID: UIImage] = [:]
    private var paths: [UUID: String]
    private var checkedAt: [UUID: Date] = [:]
    /// Bumped whenever a photo is stored or dropped, so a slower download can tell it is outdated.
    private var generations: [UUID: Int] = [:]

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.pathsKey) as? [String: String] ?? [:]
        paths = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    /// The cached photo, read from disk the first time it is needed.
    func image(for userId: UUID) -> UIImage? {
        if let image = images[userId] { return image }
        guard let path = paths[userId], let data = try? Data(contentsOf: Self.fileURL(for: path)),
              let image = UIImage(data: data)
        else { return nil }
        images[userId] = image
        return image
    }

    func load(_ userId: UUID) async {
        if let checkedAt = checkedAt[userId], Date().timeIntervalSince(checkedAt) < Self.recheckInterval { return }
        guard let client = SupabaseClientProvider.shared else { return }
        struct Row: Decodable {
            let avatarPath: String?
            enum CodingKeys: String, CodingKey { case avatarPath = "avatar_path" }
        }
        let generation = generations[userId, default: 0]
        do {
            let row: Row = try await client.from("profile")
                .select("avatar_path")
                .eq("id", value: userId)
                .single()
                .execute().value
            guard generations[userId, default: 0] == generation else { return }
            guard let path = row.avatarPath else {
                checkedAt[userId] = Date()
                forget(userId)
                return
            }
            if path == paths[userId], image(for: userId) != nil {
                checkedAt[userId] = Date()
                return
            }
            let data = try await client.storage.from("avatars").download(path: path)
            guard let image = UIImage(data: data), generations[userId, default: 0] == generation else { return }
            checkedAt[userId] = Date()
            store(image, data: data, path: path, for: userId)
        } catch {
            // A failed request can be retried when the view appears again; the cached photo stays.
        }
    }

    func upload(_ imageData: Data, for userId: UUID) async throws {
        guard let client = SupabaseClientProvider.shared else {
            throw NSError(domain: "LoamAvatar", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Sign in to add a profile photo.")])
        }
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        let storage = client.storage.from("avatars")
        try await LoamErrorCapture.withCapture("profile.avatar_upload_failed") {
            try await storage.upload(path, data: imageData, options: FileOptions(contentType: "image/jpeg"))
        }
        do {
            struct Change: Codable { let avatar_path: String }
            let _: Change = try await client.from("profile")
                .update(Change(avatar_path: path))
                .eq("id", value: userId)
                .select("avatar_path")
                .single()
                .execute().value
            let previousPath = paths[userId]
            if let image = UIImage(data: imageData) {
                store(image, data: imageData, path: path, for: userId)
            }
            checkedAt[userId] = Date()
            if let previousPath, previousPath != path {
                _ = try? await storage.remove(paths: [previousPath])
            }
        } catch {
            LoamErrorCapture.capture("profile.avatar_metadata_save_failed")
            _ = try? await storage.remove(paths: [path])
            throw error
        }
    }

    private func store(_ image: UIImage, data: Data, path: String, for userId: UUID) {
        let previousPath = paths[userId]
        images[userId] = image
        paths[userId] = path
        generations[userId, default: 0] += 1
        revision += 1
        persistPaths()
        let url = Self.fileURL(for: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        if let previousPath, previousPath != path {
            try? FileManager.default.removeItem(at: Self.fileURL(for: previousPath))
        }
    }

    private func forget(_ userId: UUID) {
        images.removeValue(forKey: userId)
        generations[userId, default: 0] += 1
        revision += 1
        guard let path = paths.removeValue(forKey: userId) else { return }
        persistPaths()
        try? FileManager.default.removeItem(at: Self.fileURL(for: path))
    }

    private func persistPaths() {
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: paths.map { ($0.key.uuidString, $0.value) }),
            forKey: Self.pathsKey
        )
    }

    /// Caches may be purged by the system, which just means a photo downloads again.
    private static func fileURL(for path: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("avatars", isDirectory: true)
            .appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }
}

struct AvatarView: View {
    let userId: UUID?
    let size: CGFloat
    /// Without a photo, shows this name's initials on a tint picked from the user ID.
    var name: String? = nil

    @ObservedObject private var avatars = AvatarStore.shared

    var body: some View {
        Group {
            if let userId, let image = avatars.image(for: userId) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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

    @ViewBuilder
    private var fallback: some View {
        if let initials {
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(HomeTheme.secondary)
        }
    }

    private var initials: String? {
        let letters = (name ?? "").split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }

    /// Stable across launches, unlike `hashValue`.
    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        let seed = userId?.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) } ?? 0
        return palette[seed % palette.count]
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
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

/// Pages Profile opens in an in-app browser.
private enum WebDestination: String, Identifiable {
    case feedback
    case privacyPolicy
    case termsOfUse

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .feedback:
            URL(string: "https://kprslab.featurebase.app")!
        case .privacyPolicy:
            LegalPages.privacyPolicy
        case .termsOfUse:
            LegalPages.termsOfUse
        }
    }
}

/// The photo, name and e-mail at the top of Profile.
private struct ProfileHeader: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var subscriptions: SubscriptionStore

    var body: some View {
        VStack(spacing: 12) {
            if showsProHeader {
                ProProfileAvatar(userId: authSession.userId, name: authSession.displayName)
            } else {
                AvatarView(userId: authSession.userId, size: ProfileView.avatarSize, name: authSession.displayName)
            }
            VStack(spacing: 4) {
                Text(authSession.displayName ?? String(localized: "You"))
                    .font(.system(.title, design: .rounded).weight(.semibold))
                Text(authSession.email ?? String(localized: "Your own little corner of Loam."))
                    .font(.subheadline)
                    .foregroundStyle(HomeTheme.secondary)
                    .textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Debug builds can show the Pro header on a free account (launch with
    /// `-loam.debug.proHeader YES`), so it can be checked without a subscription.
    private var showsProHeader: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "loam.debug.proHeader") { return true }
        #endif
        return subscriptions.isPro
    }
}

/// Shown while an account deletion request is being processed.
private struct AccountDeletionSection: View {
    @EnvironmentObject private var authSession: AuthSession

    var body: some View {
        Section("Account deletion") {
            Label(deletionStatusTitle, systemImage: deletionStatusSymbol)
            Text(deletionStatusDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if authSession.deletionStatus == .complete {
                Button("Dismiss confirmation") { authSession.dismissDeletionConfirmation() }
            } else {
                Button {
                    Task { await authSession.refreshDeletionStatus() }
                } label: {
                    HStack(spacing: 8) {
                        Text(authSession.isCheckingDeletionStatus ? "Checking…" : "Check deletion status")
                        if authSession.isCheckingDeletionStatus { ProgressView() }
                    }
                }
                .disabled(authSession.isCheckingDeletionStatus)
                if let checkedAt = authSession.deletionCheckedAt {
                    Text("Last checked \(checkedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listRowBackground(HomeTheme.surface)
        .task { await authSession.watchDeletionStatus() }
    }

    private var deletionStatusTitle: LocalizedStringKey {
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

    private var deletionStatusDetail: LocalizedStringKey {
        switch authSession.deletionStatus {
        case .submissionUncertain: "We couldn’t confirm the request response. Check its status before trying again."
        case .processing: "Your account is closed. Deletion usually finishes within a few minutes."
        case .needsAttention: "Your account is closed, but processing is taking longer than expected. Contact support if this continues."
        case .complete: "Your account and private data have been deleted. Usage analytics are erased by our analytics provider, which can take a few days."
        case .unavailable: "The status service is unavailable. Your secure receipt is saved; try again shortly."
        case .none: ""
        }
    }
}

/// The light, dark or system appearance picker.
private struct AppearancePicker: View {
    @AppStorage("loam.appearance") private var appearance: AppAppearance = .system

    var body: some View {
        Picker(selection: $appearance) {
            ForEach(AppAppearance.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        } label: {
            PreferenceLabel(title: "Appearance", symbol: appearance.symbol, color: .indigo)
        }
        .pickerStyle(.menu)
        .tint(HomeTheme.secondary)
    }
}

private struct AccentColorPicker: View {
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue

    var body: some View {
        Picker(selection: $accentColor) {
            ForEach(AppAccentColor.allCases) { option in
                HStack(spacing: 8) {
                    Image(uiImage: option.menuDot).renderingMode(.original)
                    Text(option.title).foregroundStyle(HomeTheme.text)
                }
                .tag(option)
            }
        } label: {
            PreferenceLabel(title: "Accent color", symbol: "paintbrush.pointed", color: .blue)
        }
        .pickerStyle(.menu)
        .tint(HomeTheme.secondary)
    }
}

/// A picker label that matches `ProfileRow` without its trailing detail.
private struct PreferenceLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
                .font(.body)
                .foregroundStyle(HomeTheme.text)
        } icon: {
            CategoryIconTile(systemImage: symbol, color: color, size: 30)
        }
        .labelStyle(CompactProfileLabelStyle())
    }
}

/// Loam follows the language iOS keeps for each app, so this opens Loam's page in Settings
/// instead of keeping a second choice of its own.
private struct LanguageRow: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            // Where the other rows show a chevron, this one shows that it leaves for the Settings app.
            HStack(spacing: 8) {
                ProfileRow("Language", symbol: "character.bubble", color: .orange, detail: Self.currentLanguage)
                Image(systemName: "arrow.up.forward.app")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Loam in the Settings app, where you can change its language")
    }

    private static var currentLanguage: String? {
        guard let code = Bundle.main.preferredLocalizations.first else { return nil }
        return Locale.current.localizedString(forIdentifier: code)?.capitalized(with: .current)
    }
}

private struct DefaultCurrencyRow: View {
    @AppStorage(AppPreferences.defaultCurrencyKey) private var defaultCurrency = "PLN"

    var body: some View {
        NavigationLink {
            DefaultCurrencySettingsView()
        } label: {
            ProfileRow("Default currency", symbol: "dollarsign.arrow.circlepath", color: .green, detail: AppPreferences.defaultCurrencyCode)
        }
    }
}

private struct TimeZoneRow: View {
    @AppStorage(AppPreferences.timeZoneKey) private var timeZoneIdentifier = ""

    var body: some View {
        NavigationLink {
            TimeZoneSettingsView()
        } label: {
            ProfileRow("Time zone", symbol: "globe", color: .teal, detail: AppPreferences.timeZoneName(timeZoneIdentifier))
        }
    }
}

private struct NotificationsRow: View {
    @EnvironmentObject private var pushStore: PushNotificationStore

    var body: some View {
        NavigationLink {
            NotificationSettingsView()
        } label: {
            ProfileRow("Notifications", symbol: "bell.badge", color: .red, detail: detail)
        }
    }

    private var detail: String? {
        switch pushStore.permission {
        case .allowed: String(localized: "On")
        case .denied: String(localized: "Off")
        case .unknown, .notDetermined: nil
        }
    }
}

private struct AppLockToggle: View {
    @EnvironmentObject private var appLock: AppLock
    /// Redraws the accent-tinted controls when the accent changes in Settings.
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue

    /// "Face ID lock", or "Passcode lock" on its own key so a language can inflect it.
    private var lockTitle: LocalizedStringKey {
        switch appLock.method {
        case .passcode, .unavailable: "Passcode lock"
        default: "\(appLock.method.title) lock"
        }
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { appLock.isEnabled },
            set: { enabled in Task { await appLock.setEnabled(enabled) } }
        )) {
            ProfileRow(lockTitle, symbol: appLock.method.symbolName, color: .green)
        }
        .tint(HomeTheme.accentFill)
        .disabled(appLock.isAuthenticating || (appLock.method == .unavailable && !appLock.isEnabled))
    }
}

/// Explains the app lock for the footer under it.
private struct AppLockFooter: View {
    @EnvironmentObject private var appLock: AppLock

    var body: some View {
        if appLock.method == .unavailable {
            Text("Set a passcode in iOS Settings to lock Loam.")
        } else if appLock.method == .passcode {
            Text("Ask for your iPhone passcode whenever you open Loam.")
        } else {
            Text("Ask for \(appLock.method.title) whenever you open Loam.")
        }
    }
}

private struct AnalyticsToggle: View {
    let userId: UUID
    @State private var analyticsConsent = false
    /// Redraws the accent-tinted controls when the accent changes in Settings.
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue

    var body: some View {
        Toggle(isOn: $analyticsConsent) {
            ProfileRow("Share usage analytics", symbol: "chart.bar", color: .indigo)
        }
        .tint(HomeTheme.accentFill)
        .task(id: userId) {
            analyticsConsent = Telemetry.hasAnalyticsConsent(for: userId)
        }
        .onChange(of: analyticsConsent) { _, granted in
            Telemetry.setAnalyticsConsent(granted, for: userId)
        }
    }
}

private struct CrashReportsToggle: View {
    @State private var enabled = Telemetry.crashReportsEnabled
    /// Redraws the accent-tinted controls when the accent changes in Settings.
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue

    var body: some View {
        Toggle(isOn: $enabled) {
            ProfileRow("Send crash reports", symbol: "ladybug", color: .orange)
        }
        .tint(HomeTheme.accentFill)
        .onChange(of: enabled) { _, newValue in
            Telemetry.setCrashReportsEnabled(newValue)
        }
    }
}

/// The account that can share usage analytics, or nil when the switch is hidden.
@MainActor
private func analyticsUserId(_ authSession: AuthSession) -> UUID? {
    guard let userId = authSession.userId, !authSession.usesDemoMode, Telemetry.isAnalyticsAvailable else { return nil }
    return userId
}

/// The app's version screen.
private struct AboutAppView: View {
    var body: some View {
        ProfileInfoView(title: "About the app", symbol: "app.badge", message: "Money, kept simple.", detail: "Loam keeps track of what you spend and what you share. Split an expense with a friend and you both see who owes whom, so settling up is easy.\n\nOnly you and the friends you split an expense with can see it.\n\n\(ProfileView.version)")
    }
}

private struct SignOutSection: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var appLock: AppLock
    @State private var showsSignOut = false
    @State private var isSigningOut = false

    var body: some View {
        Section {
            Button { showsSignOut = true } label: {
                HStack {
                    ProfileRow("Sign out", symbol: "rectangle.portrait.and.arrow.right", color: .red, destructive: true)
                    if isSigningOut { ProgressView() }
                }
            }
            .disabled(isSigningOut)
        }
        .listRowBackground(HomeTheme.surface)
        .confirmationDialog("Sign out of Loam?", isPresented: $showsSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                isSigningOut = true
                Task {
                    await authSession.signOut()
                    // The next person to sign in here starts without the lock.
                    if authSession.state == .signedOut { appLock.reset() }
                    isSigningOut = false
                }
            }
        } message: {
            Text("You can sign back in whenever you’re ready.")
        }
    }
}

struct ProfileView: View {
    static let avatarSize: CGFloat = 96

    @EnvironmentObject private var authSession: AuthSession
    @State private var webDestination: WebDestination?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProfileHeader()
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                // A little more room than between the rows below, so the header stands on its own.
                .listSectionSpacing(28)

                ProUpgradeSection()

                if authSession.deletionPending {
                    AccountDeletionSection()
                }

                Section {
                    NavigationLink { PersonalDetailsView() } label: {
                        ProfileRow("Personal details", symbol: "person.text.rectangle", color: .blue)
                    }
                    NavigationLink { FriendsView() } label: {
                        ProfileRow("Friends", symbol: "person.2", color: .teal)
                    }
                    CategoriesRow()
                    SubscriptionRow()
                }
                .listRowBackground(HomeTheme.surface)

                Section {
                    NavigationLink { AppSettingsView() } label: {
                        ProfileRow("Settings", symbol: "gearshape", color: .gray)
                    }
                    Button {
                        webDestination = .feedback
                    } label: {
                        ProfileRow("Give feedback", symbol: "star", color: .orange)
                    }
                    .accessibilityHint("Opens Loam's feedback board")
                    Link(destination: URL(string: "mailto:kprcode@icloud.com")!) {
                        ProfileRow("Contact support", symbol: "envelope", color: .blue)
                    }
                    .accessibilityHint("Opens an email addressed to Loam support")
                    NavigationLink {
                        AboutAndLegalView()
                    } label: {
                        ProfileRow("About & legal", symbol: "info.circle", color: .purple)
                    }
                }
                .listRowBackground(HomeTheme.surface)

                SignOutSection()

                #if DEBUG
                Section {
                    NavigationLink {
                        ProfileDeveloperView()
                    } label: {
                        ProfileRow("Developer", symbol: "hammer", color: .gray)
                    }
                }
                .listRowBackground(HomeTheme.surface)
                #endif
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 2, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $webDestination) { destination in
                SafariView(url: destination.url)
                    .ignoresSafeArea()
            }
        }
    }

    static var version: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return String(localized: "Version \(version) (\(build))")
    }
}

/// Every app preference, one tap below Profile.
private struct AppSettingsView: View {
    @EnvironmentObject private var authSession: AuthSession

    var body: some View {
        List {
            Section {
                AppearancePicker()
                AccentColorPicker()
            }
            .listRowBackground(HomeTheme.surface)

            Section {
                LanguageRow()
                DefaultCurrencyRow()
                TimeZoneRow()
                if !authSession.usesDemoMode {
                    NotificationsRow()
                }
            }
            .listRowBackground(HomeTheme.surface)

            if !authSession.usesDemoMode {
                Section {
                    AutoAcceptExpensesToggle()
                } footer: {
                    Text("Accept every expense a friend shares with you automatically, without reviewing it first.")
                }
                .listRowBackground(HomeTheme.surface)
            }

            Section {
                AppLockToggle()
                if let userId = analyticsUserId(authSession) {
                    AnalyticsToggle(userId: userId)
                }
                if Telemetry.isCrashReportingAvailable {
                    CrashReportsToggle()
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    AppLockFooter()
                    if Telemetry.isCrashReportingAvailable {
                        Text("Crash reports are not linked to your account. They hold your device model, iOS and app version and technical details, never your expenses.")
                    }
                    if analyticsUserId(authSession) != nil {
                        Text("Usage analytics are tied to a random account ID, never your email or name, and never include amounts or descriptions.")
                    }
                }
            }
            .listRowBackground(HomeTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The app's version and the legal pages.
private struct AboutAndLegalView: View {
    @State private var webDestination: WebDestination?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AboutAppView()
                } label: {
                    ProfileRow("About the app", symbol: "app.badge", color: .purple)
                }
                Button {
                    webDestination = .privacyPolicy
                } label: {
                    ProfileRow("Privacy Policy", symbol: "hand.raised", color: .blue)
                }
                .accessibilityHint("Opens Loam's privacy policy")
                Button {
                    webDestination = .termsOfUse
                } label: {
                    ProfileRow("Terms of Use", symbol: "doc.text", color: .gray)
                }
                .accessibilityHint("Opens Loam's terms of use")
            }
            .listRowBackground(HomeTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background)
        .navigationTitle("About & legal")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $webDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
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
        HStack(spacing: 12) {
            configuration.icon
            configuration.title
        }
    }
}

/// The Pro profile photo with the PRO mark hanging off its bottom edge. The mark tilts with the phone.
private struct ProProfileAvatar: View {
    let userId: UUID?
    var name: String?

    var body: some View {
        AvatarView(userId: userId, size: ProfileView.avatarSize, name: name)
            .overlay(alignment: .bottom) {
                TiltingProMark(height: 22)
                    .offset(y: 11)
                    .accessibilityLabel("Loam Pro")
            }
            // The mark hangs below the photo, so it needs room under it.
            .padding(.bottom, 11)
    }
}

/// The upgrade card at the top of Profile. Only free accounts see it.
private struct ProUpgradeSection: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    /// Redraws the card's accent wash when the accent changes in Settings.
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue
    @State private var showsPaywall = false

    var body: some View {
        if subscriptions.isAvailable && !subscriptions.isPro {
            Section {
                Button { showsPaywall = true } label: {
                    ProUpgradeCard()
                }
                .buttonStyle(.plain)
                .proPaywall(isPresented: $showsPaywall)
                .listRowBackground(ProUpgradeCard.background)
            }
        }
    }
}

/// A card that names what Pro unlocks and ends in an Upgrade button.
private struct ProUpgradeCard: View {
    /// Redraws the accent-tinted controls when the accent changes in Settings.
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue

    /// The row's surface washed with the accent, so the card stands apart from the plain rows below.
    static var background: some View {
        HomeTheme.surface
            .overlay(
                LinearGradient(
                    colors: [HomeTheme.solidAccent.opacity(0.16), HomeTheme.solidAccent.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProMark(height: 24)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Text("Free plan")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Loam Pro")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                // Names what Pro unlocks instead of repeating the paywall's tagline.
                Text("Unlimited friends, recurring bills and custom categories.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Upgrade to Loam Pro")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(HomeTheme.accentFill, in: Capsule())
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Upgrade to Loam Pro")
        .accessibilityHint("Unlimited friends, recurring bills and custom categories")
        .accessibilityAddTraits(.isButton)
    }
}

/// Pro opens the category editor; Free accounts see the paywall.
private struct CategoriesRow: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showsPaywall = false

    var body: some View {
        if subscriptions.isPro {
            NavigationLink {
                CategorySettingsView()
            } label: {
                ProfileRow("Categories", symbol: "square.grid.2x2", color: .orange)
            }
        } else {
            Button { showsPaywall = true } label: {
                HStack {
                    ProfileRow("Categories", symbol: "square.grid.2x2", color: .orange)
                    Spacer(minLength: 8)
                    ProBadge()
                }
            }
            .accessibilityHint("Custom categories need Loam Pro")
            .proPaywall(isPresented: $showsPaywall)
        }
    }
}

/// Always shown, so every account can check its plan.
private struct SubscriptionRow: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore

    var body: some View {
        NavigationLink {
            SubscriptionView()
        } label: {
            ProfileRow(
                "Subscription",
                symbol: "creditcard",
                color: .pink,
                detail: subscriptions.isPro ? "Loam Pro" : String(localized: "subscription-free", defaultValue: "Free", comment: "The Subscription row's value on the free plan")
            )
        }
    }
}

/// The account's plan. Free accounts can open the paywall from here; Pro accounts
/// manage their plan in RevenueCat's Customer Center.
private struct SubscriptionView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showsPaywall = false
    @State private var showsCustomerCenter = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ProMark(height: 32)
                        .saturation(subscriptions.isPro ? 1 : 0)
                        .opacity(subscriptions.isPro ? 1 : 0.6)
                        .accessibilityHidden(true)
                    VStack(spacing: 4) {
                        Text(subscriptions.isPro ? "You’re on Loam Pro" : "You’re not subscribed")
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                        Text(statusDetail)
                            .font(.subheadline)
                            .foregroundStyle(HomeTheme.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if subscriptions.isPro {
                    Button { showsCustomerCenter = true } label: {
                        ProfileRow("Manage subscription", symbol: "gearshape", color: .gray)
                    }
                } else {
                    Button { showsPaywall = true } label: {
                        ProfileRow("Upgrade to Loam Pro", symbol: "arrow.up.circle", color: .blue)
                    }
                    Button { subscriptions.presentCodeRedemption() } label: {
                        ProfileRow("Redeem code", symbol: "giftcard", color: .green)
                    }
                }
            }
            .listRowBackground(HomeTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background)
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .proPaywall(isPresented: $showsPaywall)
        .presentCustomerCenter(isPresented: $showsCustomerCenter)
    }

    private var statusDetail: String {
        guard subscriptions.isPro else {
            return String(localized: "You’re on the free plan. Upgrade to share every bill, with everyone.")
        }
        guard let entitlement = subscriptions.customerInfo?.entitlements[SubscriptionStore.entitlementId],
              let expiration = entitlement.expirationDate
        else { return String(localized: "Thanks for supporting Loam.") }
        let date = expiration.formatted(date: .long, time: .omitted)
        if entitlement.periodType == .trial {
            return entitlement.willRenew ? String(localized: "Free trial, Pro starts on \(date).") : String(localized: "Free trial, ends on \(date).")
        }
        return entitlement.willRenew ? String(localized: "Renews on \(date).") : String(localized: "Ends on \(date).")
    }
}

/// Icon-and-title row used across Profile. Internal so rows in other files, such as
/// `AutoAcceptExpensesToggle`, match its icon size and spacing.
struct ProfileRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    var detail: String? = nil
    var destructive = false

    init(_ title: LocalizedStringKey, symbol: String, color: Color, detail: String? = nil, destructive: Bool = false) {
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
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red : HomeTheme.text)
            } icon: {
                CategoryIconTile(systemImage: symbol, color: destructive ? .red : color, size: 30)
            }
            .labelStyle(CompactProfileLabelStyle())
            if let detail {
                Spacer(minLength: 8)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PersonalDetailsView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var appLock: AppLock
    @State private var name = ""
    @State private var isSaving = false
    @State private var isDeletingAccount = false
    @State private var showsDeleteConfirmation = false
    @State private var showsDiscardConfirmation = false
    @State private var hasLoadedName = false
    @State private var error: String?
    @State private var deletionAuthorization = AppleDeletionAuthorization()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isUploadingPhoto = false
    @State private var photoError: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving && !trimmedName.isEmpty && trimmedName != authSession.displayName
    }

    /// The photo uploads as soon as it's picked, so only the name can be left unsaved.
    private var hasUnsavedChanges: Bool {
        hasLoadedName && !isSaving && trimmedName != (authSession.displayName ?? "")
    }

    var body: some View {
        Form {
            photoHeader

            Section {
                LabeledContent("Name") {
                    TextField("Your name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { if canSave { save() } }
                }
                LabeledContent("E-mail") {
                    Text(authSession.email ?? String(localized: "Not provided"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Account")
            } footer: {
                Text(authSession.usesDemoMode
                     ? "Friends see your name on shared expenses. You’re using a local demo account."
                     : "Friends see your name on shared expenses. Your e-mail comes from your Apple Account and may be a private relay address.")
            }
            .listRowBackground(HomeTheme.surface)
            Section {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        Text("Delete account")
                        if isDeletingAccount { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
        .navigationTitle("Personal details")
        .navigationBarTitleDisplayMode(.inline)
        // A custom back button lets us ask before throwing away an unsaved name.
        // Hiding the system one also turns off swipe-back, which would skip the prompt.
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .alert("You have unsaved changes", isPresented: $showsDiscardConfirmation) {
            if canSave {
                Button("Save") { save() }
            }
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your new name hasn’t been saved yet.")
        }
        .disabled(isSaving || isDeletingAccount)
        .onAppear {
            name = authSession.displayName ?? ""
            hasLoadedName = true
        }
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
                        throw NSError(domain: "LoamAvatar", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Couldn't read that photo. Try another one.")])
                    }
                    try await AvatarStore.shared.upload(jpeg, for: userId)
                } catch { photoError = UserFacingError.message(for: error) }
            }
        }
        .errorToast($photoError)
        .errorToast($error)
        .confirmationDialog("Delete your account?", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                isDeletingAccount = true
                error = nil
                Task {
                    do {
                        // Cancelling this system prompt exits without touching the account.
                        let credential = try await deletionAuthorization.request()
                        try await authSession.deleteAccount(credential: credential)
                        // Whoever signs up next on this device starts without the lock.
                        appLock.reset()
                    } catch {
                        self.error = UserFacingError.message(for: error)
                    }
                    isDeletingAccount = false
                }
            }
        } message: {
            Text(authSession.usesDemoMode
                 ? "This permanently removes your on-device demo data. This can’t be undone."
                 : "Your sign-in, profile photo, private expenses and usage analytics will be removed. Shared expenses and balances remain for other participants under the name Deleted user. This can’t be undone.")
        }
        .toolbar {
            if hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        nameFocused = false
                        showsDiscardConfirmation = true
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Back")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text("Save") }
                }
                .disabled(!canSave)
            }
        }
    }

    private func save() {
        nameFocused = false
        isSaving = true
        error = nil
        Task {
            do {
                try await authSession.updateDisplayName(trimmedName)
                dismiss()
            } catch { self.error = UserFacingError.message(for: error) }
            isSaving = false
        }
    }
}

private extension PersonalDetailsView {
    /// A large, centred photo with an "Edit photo" link under it, as in Instagram, Beli and Gentler Streak.
    /// Photo and link form one button, so either one opens the picker.
    var photoHeader: some View {
        Section {
            Group {
                if authSession.usesDemoMode {
                    avatar
                } else {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        VStack(spacing: 12) {
                            avatar
                            Text(isUploadingPhoto ? "Uploading…" : "Edit photo")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(isUploadingPhoto)
                    .accessibilityLabel("Edit photo")
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
        .listRowBackground(HomeTheme.surface)
    }

    var avatar: some View {
        AvatarView(userId: authSession.userId, size: 104, name: trimmedName.isEmpty ? authSession.displayName : trimmedName)
            .overlay {
                if isUploadingPhoto {
                    Circle()
                        .fill(.black.opacity(0.35))
                        .overlay { ProgressView().tint(.white) }
                }
            }
    }

    static func avatarJPEG(from image: UIImage) -> Data? {
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
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("New expenses use this currency. Existing expenses keep the currency they were added in; totals convert them at the exchange rate of the day they were spent.")
            }
            .listRowBackground(HomeTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
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
                timeZoneRow(identifier: "", title: String(localized: "Device time zone"), subtitle: TimeZone.current.localizedName(for: .standard, locale: .current) ?? TimeZone.current.identifier)
            } footer: {
                Text("Used for calendar dates and recurring expenses.")
            }
            .listRowBackground(HomeTheme.surface)

            Section("Time zones") {
                ForEach(identifiers, id: \.self) { identifier in
                    timeZoneRow(
                        identifier: identifier,
                        title: AppPreferences.timeZoneName(identifier),
                        subtitle: identifier
                    )
                }
            }
            .listRowBackground(HomeTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
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
            .contentShape(.rect)
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
    let title: LocalizedStringKey
    let symbol: String
    let message: LocalizedStringKey
    let detail: LocalizedStringKey

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
                    .listRowBackground(HomeTheme.surface)
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
                    .listRowBackground(HomeTheme.surface)
                } else {
                    Section("Test accounts") {
                        Text(testAccountsUnavailableMessage)
                            .font(.footnote)
                            .foregroundStyle(HomeTheme.secondary)
                    }
                    .listRowBackground(HomeTheme.surface)
                }

                Section("Developer") {
                    Button("Clear expenses I created", role: .destructive) {
                        showClearAllExpensesConfirm = true
                    }
                }
                .listRowBackground(HomeTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
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
            return String(localized: "Back to \(name)")
        }
        return String(localized: "Back to my account")
    }

    private var testAccountsUnavailableMessage: String {
        if SupabaseConfig.environment != .testing {
            return String(localized: "Disabled outside the Debug testing configuration.")
        }
        if !SupabaseConfig.allowsTestAccounts {
            return String(localized: "The active Supabase URL does not match the allowlisted test project.")
        }
        return String(localized: "Add the Julia and Philip ID, email, and password variables to Secrets.xcconfig.")
    }

    private var clearExpensesConfirmationMessage: String {
        if SupabaseConfig.isConfigured {
            return String(localized: "Deletes synced expenses and recurring rules you created. Shared expenses created by others stay. This can’t be undone.")
        }
        return String(localized: "Deletes local demo expenses and recurring rules you created. This can’t be undone.")
    }
}
#endif

#Preview {
    ProfileView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
        .environmentObject(SubscriptionStore())
        .environmentObject(AppLock())
}
