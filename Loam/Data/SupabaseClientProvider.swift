import Foundation
import Supabase

enum SupabaseConfig {
    enum Environment: String {
        case production
        case testing
    }

    static let url: String = {
        let raw = ProcessInfo.processInfo.environment["SUPABASE_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
            ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static let anonKey: String = {
        let raw = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
            ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static var isConfigured: Bool {
        configurationIssue == nil
    }

    static var environment: Environment {
        let raw = (ProcessInfo.processInfo.environment["LOAM_ENVIRONMENT"]
            ?? Bundle.main.object(forInfoDictionaryKey: "LOAM_ENVIRONMENT") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return Environment(rawValue: raw ?? "") ?? .production
    }

    static var testProjectURL: String {
        ((Bundle.main.object(forInfoDictionaryKey: "LOAM_TEST_SUPABASE_URL") as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Test personas are deliberately fail-closed: a debug build must explicitly
    /// identify itself as testing and match the allowlisted test project exactly.
    static var allowsTestAccounts: Bool {
        #if DEBUG
        return isConfigured
            && environment == .testing
            && !testProjectURL.isEmpty
            && normalizedProjectURL(url) == normalizedProjectURL(testProjectURL)
        #else
        return false
        #endif
    }

    /// Human-readable reason when the backend client is off (debug / setup).
    static var configurationIssue: String? {
        configurationIssue(url: url, anonKey: anonKey)
    }

    static func configurationIssue(url: String, anonKey: String) -> String? {
        if url.isEmpty || anonKey.isEmpty || url == "https:" {
            return "Missing SUPABASE_URL / SUPABASE_ANON_KEY in the app bundle. Set them in Loam/Config/Config.xcconfig and clean build."
        }
        if url.contains("YOUR_PROJECT") || anonKey == "your-anon-key" {
            return "Replace placeholders in Loam/Config/Config.xcconfig with Project URL + anon/publishable key."
        }
        if anonKey.hasPrefix("sb_secret") {
            return "You pasted the secret key. Use the anon / publishable key instead (Settings → API)."
        }
        if !(anonKey.hasPrefix("eyJ") || anonKey.hasPrefix("sb_publishable")) {
            return "Unexpected key format. Use anon JWT (eyJ…) or sb_publishable_… — not the service_role/secret key."
        }
        guard let parsed = URL(string: url),
              parsed.scheme == "https" || parsed.scheme == "http",
              parsed.host != nil else {
            return "SUPABASE_URL is invalid after xcconfig expansion."
        }
        return nil
    }

    private static func normalizedProjectURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}

enum SupabaseClientProvider {
    enum Device: String, CaseIterable {
        case main
        #if DEBUG
        case julia
        case philip
        #endif
    }

    private static let lock = NSLock()
    private static var selectedDevice: Device = .main

    static var activeDevice: Device {
        lock.lock()
        defer { lock.unlock() }
        return selectedDevice
    }

    static var shared: SupabaseClient? {
        client(for: activeDevice)
    }

    static func activate(_ device: Device) {
        lock.lock()
        selectedDevice = device
        lock.unlock()
    }

    static func client(for device: Device) -> SupabaseClient? {
        switch device {
        case .main:
            return mainClient
        #if DEBUG
        case .julia:
            return juliaClient
        case .philip:
            return philipClient
        #endif
        }
    }

    private static let mainClient = makeClient(storageSuffix: nil)
    #if DEBUG
    private static let juliaClient = makeClient(storageSuffix: "loam-testing-julia")
    private static let philipClient = makeClient(storageSuffix: "loam-testing-philip")
    #endif

    private static func makeClient(storageSuffix: String?) -> SupabaseClient? {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: SupabaseConfig.url) else {
            return nil
        }

        let storageKey = storageSuffix.map { suffix in
            let projectRef = url.host?.split(separator: ".").first.map(String.init) ?? "project"
            return "sb-\(projectRef)-auth-token-\(suffix)"
        }

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: SupabaseConfig.anonKey,
            options: SupabaseClientOptions(
                auth: .init(
                    storageKey: storageKey,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }
}
