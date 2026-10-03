import Foundation

/// FK-only placeholder for split-expense development. Replace with real invites in Phase 2.
/// The Supabase seed is banned and cannot sign in; this UUID exists only for expense_share FKs.
enum TestPartner {
    static let userId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let displayName = "Alex (Test)"

    /// Demo/local mode always allows split. Remote Supabase split is DEBUG-only until invites ship.
    static func isSplitAvailable(usesRemoteBackend: Bool) -> Bool {
        if !usesRemoteBackend { return true }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
