import Foundation

enum HouseholdRepositoryError: LocalizedError {
    case notConfigured
    case notFound
    case incompleteSetup

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Household storage is not available."
        case .notFound: "Household not found."
        case .incompleteSetup: "Household setup is incomplete. Try again."
        }
    }
}

protocol HouseholdRepository: Sendable {
    /// Returns the user's existing test household without creating one.
    func fetchTestHousehold(for userId: UUID) async throws -> HouseholdRecord?

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
