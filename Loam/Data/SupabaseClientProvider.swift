import Foundation
import Supabase

enum SupabaseConfig {
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

    /// Human-readable reason when the backend client is off (debug / setup).
    static var configurationIssue: String? {
        if url.isEmpty || anonKey.isEmpty || url == "https:" {
            return "Missing SUPABASE_URL / SUPABASE_ANON_KEY in the app bundle. Clean build after fixing Secrets.xcconfig."
        }
        if url.contains("YOUR_PROJECT") || anonKey == "your-anon-key" {
            return "Replace placeholders in Loam/Config/Secrets.xcconfig with Project URL + anon/publishable key."
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
}

enum SupabaseClientProvider {
    static let shared: SupabaseClient? = {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: SupabaseConfig.url) else {
            return nil
        }
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: SupabaseConfig.anonKey,
            options: SupabaseClientOptions(
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
    }()
}
