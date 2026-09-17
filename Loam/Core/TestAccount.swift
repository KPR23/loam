import Foundation

#if DEBUG
/// Preset test personas for switching accounts and split testing in debug builds.
enum TestAccount: String, CaseIterable, Identifiable {
    case julia
    case philip

    var id: String { rawValue }

    var userId: UUID? {
        UUID(uuidString: configurationValue(named: userIdKey))
    }

    var email: String {
        configurationValue(named: emailKey)
    }

    var password: String {
        configurationValue(named: passwordKey)
    }

    var isConfigured: Bool {
        userId != nil && !email.isEmpty && !password.isEmpty
    }

    var device: SupabaseClientProvider.Device {
        switch self {
        case .julia: .julia
        case .philip: .philip
        }
    }

    var displayName: String {
        switch self {
        case .julia: "Julia"
        case .philip: "Philip"
        }
    }

    static func contains(userId: UUID) -> Bool {
        configured.contains { $0.userId == userId }
    }

    static var configured: [TestAccount] {
        guard SupabaseConfig.allowsTestAccounts else { return [] }
        return allCases.filter(\.isConfigured)
    }

    private var userIdKey: String {
        "LOAM_TEST_\(rawValue.uppercased())_USER_ID"
    }

    private var emailKey: String {
        "LOAM_TEST_\(rawValue.uppercased())_EMAIL"
    }

    private var passwordKey: String {
        "LOAM_TEST_\(rawValue.uppercased())_PASSWORD"
    }

    private func configurationValue(named key: String) -> String {
        (ProcessInfo.processInfo.environment[key]
            ?? Bundle.main.object(forInfoDictionaryKey: key) as? String
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
