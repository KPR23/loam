import Foundation

#if DEBUG
/// Preset test personas for switching accounts and split testing in debug builds.
enum TestAccount: String, CaseIterable, Identifiable {
    case julia
    case philip

    var id: UUID { userId }

    var userId: UUID {
        switch self {
        case .julia:
            UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        case .philip:
            UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        }
    }

    var displayName: String {
        switch self {
        case .julia: "Julia"
        case .philip: "Philip"
        }
    }

    static func contains(userId: UUID) -> Bool {
        allCases.contains { $0.userId == userId }
    }
}
#endif
