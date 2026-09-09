import Foundation

enum HouseholdRepositoryError: LocalizedError {
    case notConfigured
    case notFound

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Household storage is not available."
        case .notFound: "Household not found."
        }
    }
}

protocol HouseholdRepository: Sendable {
    /// Returns an existing test household for the user or creates one with the test partner.
    func ensureTestHousehold(
        for userId: UUID,
        userDisplayName: String
    ) async throws -> HouseholdRecord
}

enum HouseholdRepositoryFactory {
    static func make() -> HouseholdRepository {
        if SupabaseClientProvider.shared != nil {
            return SupabaseHouseholdRepository(client: SupabaseClientProvider.shared!)
        }
        return LocalHouseholdRepository()
    }
}
