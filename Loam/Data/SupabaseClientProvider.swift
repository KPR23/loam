import Foundation
import Supabase

enum SupabaseConfig {
    /// Replace via xcconfig / Secrets before shipping. Empty disables live client.
    static let url = ProcessInfo.processInfo.environment["SUPABASE_URL"]
        ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
        ?? ""

    static let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
        ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
        ?? ""

    static var isConfigured: Bool {
        guard let url = URL(string: url), !anonKey.isEmpty else { return false }
        return url.host != nil
    }
}

enum SupabaseClientProvider {
    static let shared: SupabaseClient? = {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: SupabaseConfig.url) else {
            return nil
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: SupabaseConfig.anonKey)
    }()
}
