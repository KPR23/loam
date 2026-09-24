import XCTest
@testable import Loam

/// A configuration issue silently switches the app to on-device demo storage,
/// so a shipped build must only reach it for genuinely unusable values.
final class SupabaseConfigTests: XCTestCase {
    private let url = "https://abcdxyz.supabase.co"

    private func issue(url: String? = nil, key: String) -> String? {
        SupabaseConfig.configurationIssue(url: url ?? self.url, anonKey: key)
    }

    func testPublishableAndAnonKeysAreAccepted() {
        XCTAssertNil(issue(key: "sb_publishable_abc123"))
        XCTAssertNil(issue(key: "eyJhbGciOiJIUzI1NiJ9.payload.signature"))
    }

    func testMissingOrPlaceholderValuesAreRejected() {
        XCTAssertNotNil(issue(url: "", key: "sb_publishable_abc"))
        XCTAssertNotNil(issue(key: ""))
        // xcconfig treats `//` as a comment, leaving only the scheme.
        XCTAssertNotNil(issue(url: "https:", key: "sb_publishable_abc"))
        XCTAssertNotNil(issue(url: "https://YOUR_PROJECT.supabase.co", key: "sb_publishable_abc"))
        XCTAssertNotNil(issue(key: "your-anon-key"))
    }

    func testSecretKeysAreNeverUsedByTheApp() {
        XCTAssertEqual(issue(key: "sb_secret_abc"), "You pasted the secret key. Use the anon / publishable key instead (Settings → API).")
        XCTAssertNotNil(issue(key: "service_role_abc"))
    }

    func testURLMustBeAnHTTPAddress() {
        XCTAssertNotNil(issue(url: "abcdxyz.supabase.co", key: "sb_publishable_abc"))
        XCTAssertNotNil(issue(url: "ftp://abcdxyz.supabase.co", key: "sb_publishable_abc"))
    }
}
