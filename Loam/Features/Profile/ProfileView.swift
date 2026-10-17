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
            throw NSError(domain: "LoamAvatar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign in to add a profile photo."])
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

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var pushStore: PushNotificationStore
    @AppStorage("loam.appearance") private var appearance: AppAppearance = .system
    @AppStorage("loam.accentColor") private var accentColor: AppAccentColor = .blue
    @AppStorage(AppPreferences.defaultCurrencyKey) private var defaultCurrency = "PLN"
    @AppStorage(AppPreferences.timeZoneKey) private var timeZoneIdentifier = ""
    @State private var analyticsConsent = false
    @State private var showsSignOut = false
    @State private var isSigningOut = false
    @State private var webDestination: WebDestination?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        AvatarView(userId: authSession.userId, size: 72)
                        // The PRO mark hangs off the photo's bottom edge, so it needs room below.
                        .overlay(alignment: .bottom) {
                            if subscriptions.isPro {
                                ProMark(height: 22)
                                    .offset(y: 11)
                                    .accessibilityLabel("Loam Pro")
                            }
                        }
                        .padding(.bottom, subscriptions.isPro ? 10 : 0)
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

                ProUpgradeSection()

                Section("Account") {
                    NavigationLink {
                        PersonalDetailsView()
                    } label: {
                        ProfileRow("Personal details", symbol: "person.text.rectangle", color: .blue)
                    }
                    NavigationLink { FriendsView() } label: {
                        ProfileRow("Friends", symbol: "person.2", color: .teal)
                    }
                    SubscriptionRow()
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
                    .task { await authSession.watchDeletionStatus() }
                }

                themeSection
                preferencesSection
                if let userId = authSession.userId, !authSession.usesDemoMode, Telemetry.isAnalyticsAvailable {
                    privacySection(userId: userId)
                }

                Section {
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
                        ProfileInfoView(title: "About the app", symbol: "app.badge", message: "A little clarity. Every day.", detail: "A calmer place for your expenses, shared moments, and everything in between.\n\n\(Self.version)")
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

                Section {
                    Button { showsSignOut = true } label: {
                        HStack {
                            ProfileRow("Sign out", symbol: "rectangle.portrait.and.arrow.right", color: .red, destructive: true)
                            if isSigningOut { ProgressView() }
                        }
                    }
                    .disabled(isSigningOut)
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
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
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
            .sheet(item: $webDestination) { destination in
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
                ProfileRow("Default currency", symbol: "dollarsign.arrow.circlepath", color: .green, detail: AppPreferences.defaultCurrencyCode)
            }
            if !authSession.usesDemoMode {
                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    ProfileRow("Notifications", symbol: "bell.badge", color: .red, detail: notificationsDetail)
                }
            }
            NavigationLink {
                TimeZoneSettingsView()
            } label: {
                ProfileRow("Time zone", symbol: "globe", color: .teal, detail: AppPreferences.timeZoneName(timeZoneIdentifier))
            }
            CategoriesRow()
            if !authSession.usesDemoMode {
                AutoAcceptExpensesToggle()
            }
        } header: {
            Text("Preferences")
        } footer: {
            if !authSession.usesDemoMode {
                Text("Accept every expense a friend shares with you automatically, without reviewing it first.")
            }
        }
    }

    private var notificationsDetail: String? {
        switch pushStore.permission {
        case .allowed: "On"
        case .denied: "Off"
        case .unknown, .notDetermined: nil
        }
    }

    private func privacySection(userId: UUID) -> some View {
        Section {
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
        } header: {
            Text("Privacy")
        } footer: {
            Text("No amounts, descriptions or names are ever included. Crash reports are always sent.")
        }
    }

    private func preferenceLabel(_ title: String, symbol: String, color: Color) -> some View {
        Label {
            Text(title)
                .font(.body)
                .foregroundStyle(HomeTheme.text)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
        }
        .labelStyle(CompactProfileLabelStyle())
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
        case .complete: "Your account and private data have been deleted. Usage analytics are erased by our analytics provider, which can take a few days."
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

/// The upgrade banner at the top of Profile. Only free accounts see it.
private struct ProUpgradeSection: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showsPaywall = false

    var body: some View {
        if subscriptions.isAvailable && !subscriptions.isPro {
            Section {
                Button { showsPaywall = true } label: {
                    ProUpgradeBanner()
                }
                .buttonStyle(LoamPressStyle())
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .proPaywall(isPresented: $showsPaywall)
            }
        }
    }
}

/// A clay tile in the PRO mark's style: a pale accent face lit from the top left,
/// with a slightly darker edge showing below it. The copy sits on the left and a solid
/// "Get Pro" pill on the right makes it read as something to tap.
private struct ProUpgradeBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        // The tile mixes the accent into its face, so black stays black, or white on dark surfaces.
        let accent = HomeTheme.solidAccent == .black && isDark ? Color.white : HomeTheme.solidAccent
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        // A pale face glares against dark surfaces, so dark mode shades the accent toward black instead.
        let face = isDark ? ProMark.shaded(of: accent, blackness: 0.62) : ProMark.pastel(of: accent)
        let edge = isDark ? ProMark.shaded(of: accent, blackness: 0.78) : ProMark.pastel(of: accent, whiteness: 0.72)

        // Large text sizes don't fit the pill beside the copy, so it drops below instead.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                copy(accent: accent)
                Spacer(minLength: 4)
                getProPill(accent: accent, isDark: isDark)
            }
            VStack(alignment: .leading, spacing: 12) {
                copy(accent: accent)
                getProPill(accent: accent, isDark: isDark)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                // Thickness: a slightly darker copy just below the face.
                shape
                    .fill(edge)
                    .offset(y: 4)
                // Face: lit from the top left, shaded toward the bottom right, like soft plastic.
                shape
                    .fill(
                        face
                            .shadow(.inner(color: .white.opacity(isDark ? 0.18 : 0.9), radius: 6, x: 3, y: 4))
                            .shadow(.inner(color: (isDark ? Color.black : accent).opacity(0.22), radius: 10, x: -4, y: -6))
                    )
            }
        }
        .padding(.bottom, 4)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Upgrade to Loam Pro")
        .accessibilityHint("Share every bill, with everyone")
        .accessibilityAddTraits(.isButton)
    }

    private func copy(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Upgrade to Loam Pro")
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(
                    accent.shadow(.inner(color: .white.opacity(0.55), radius: 1, x: 0.5, y: 1))
                )
            Text("Share every bill, with everyone")
                .font(.footnote)
                .foregroundStyle(accent.opacity(0.75))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func getProPill(accent: Color, isDark: Bool) -> some View {
        // White text on the accent, except when the accent itself is white (black accent in dark mode).
        let label: Color = HomeTheme.solidAccent == .black && isDark ? .black : .white

        return HStack(spacing: 4) {
            Text("Get Pro")
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
        }
        .font(.system(.subheadline, design: .rounded).weight(.bold))
        .foregroundStyle(label)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(accent.shadow(.inner(color: .white.opacity(0.3), radius: 2, x: 1, y: 1.5)))
        )
        .shadow(color: accent.opacity(isDark ? 0 : 0.25), radius: 6, y: 3)
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
                detail: subscriptions.isPro ? "Loam Pro" : "Free"
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
                }
            }
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
            return "You’re on the free plan. Upgrade to share every bill, with everyone."
        }
        guard let entitlement = subscriptions.customerInfo?.entitlements[SubscriptionStore.entitlementId],
              let expiration = entitlement.expirationDate
        else { return "Thanks for supporting Loam." }
        let date = expiration.formatted(date: .long, time: .omitted)
        if entitlement.periodType == .trial {
            return entitlement.willRenew ? "Free trial, Pro starts on \(date)." : "Free trial, ends on \(date)."
        }
        return entitlement.willRenew ? "Renews on \(date)." : "Ends on \(date)."
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
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red : HomeTheme.text)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
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
    @State private var name = ""
    @State private var isSaving = false
    @State private var isDeletingAccount = false
    @State private var showsDeleteConfirmation = false
    @State private var error: String?
    @State private var deletionAuthorization = AppleDeletionAuthorization()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isUploadingPhoto = false
    @State private var photoError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if !authSession.usesDemoMode {
                photoSection
            }
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
                 : "Your sign-in, profile photo, private expenses and usage analytics will be removed. Shared expenses and balances remain for other participants under the name Deleted user. This can’t be undone.")
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

private extension PersonalDetailsView {
    var photoSection: some View {
        Section {
            HStack(spacing: 16) {
                AvatarView(userId: authSession.userId, size: 56, name: authSession.displayName)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    HStack(spacing: 8) {
                        Text("Change photo")
                        if isUploadingPhoto { ProgressView() }
                    }
                }
                .disabled(isUploadingPhoto)
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
        .environmentObject(SubscriptionStore())
}
