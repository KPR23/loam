import Foundation

@MainActor
final class HouseholdStore: ObservableObject {
    @Published private(set) var testHousehold: HouseholdRecord?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    func ensureSplitHousehold(
        userId: UUID,
        userDisplayName: String,
        partners: [SplitPartnerOption]
    ) async throws -> HouseholdRecord {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let activeRepository = repository(for: partners)
        let household = try await activeRepository.ensureSplitHousehold(
            for: userId,
            userDisplayName: userDisplayName,
            partners: partners
        )
        testHousehold = household
        return household
    }

    func refresh(userId: UUID?) async {
        guard let userId else {
            testHousehold = nil
            return
        }

        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            testHousehold = try await activeRepository.fetchTestHousehold(for: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var activeRepository: HouseholdRepository {
        #if DEBUG
        if ExpenseRepositoryFactory.usesLocalStorage {
            return LocalHouseholdRepository()
        }
        #endif
        return HouseholdRepositoryFactory.make()
    }

    private func repository(for partners: [SplitPartnerOption]) -> HouseholdRepository {
        _ = partners
        return HouseholdRepositoryFactory.make()
    }
}
