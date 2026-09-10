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

    /// Returns an existing split household for the user or creates one with the selected partners.
    func ensureSplitHousehold(
        for userId: UUID,
        userDisplayName: String,
        partners: [SplitPartnerOption]
    ) async throws -> HouseholdRecord
}

enum HouseholdRepositoryFactory {
    static func make() -> HouseholdRepository {
        if ExpenseRepositoryFactory.usesLocalStorage {
            return LocalHouseholdRepository()
        }
        return SupabaseHouseholdRepository(client: SupabaseClientProvider.shared!)
    }
}
