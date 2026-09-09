import Foundation

@MainActor
final class HouseholdStore: ObservableObject {
    @Published private(set) var testHousehold: HouseholdRecord?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let repository: HouseholdRepository

    init(repository: HouseholdRepository = HouseholdRepositoryFactory.make()) {
        self.repository = repository
    }

    func ensureTestHousehold(userId: UUID, userDisplayName: String) async throws -> HouseholdRecord {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let household = try await repository.ensureTestHousehold(
            for: userId,
            userDisplayName: userDisplayName
        )
        testHousehold = household
        return household
    }

    func refresh(userId: UUID?, userDisplayName: String?) async {
        guard let userId, let userDisplayName else {
            testHousehold = nil
            return
        }

        do {
            _ = try await ensureTestHousehold(userId: userId, userDisplayName: userDisplayName)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
