import Foundation

actor LocalHouseholdRepository: HouseholdRepository {
    private let defaultsKey = "loam.local.household"
    private var cache: HouseholdRecord?

    func ensureTestHousehold(
        for userId: UUID,
        userDisplayName: String
    ) async throws -> HouseholdRecord {
        if let existing = try load(),
           existing.members.contains(where: { $0.userId == userId }),
           existing.members.contains(where: { $0.userId == TestPartner.userId }) {
            return existing
        }

        let householdId = UUID()
        let household = HouseholdRecord(
            id: householdId,
            name: TestPartner.householdName,
            createdBy: userId,
            members: [
                HouseholdMemberRecord(
                    householdId: householdId,
                    userId: userId,
                    displayName: userDisplayName
                ),
                HouseholdMemberRecord(
                    householdId: householdId,
                    userId: TestPartner.userId,
                    displayName: TestPartner.displayName
                ),
            ]
        )
        try save(household)
        return household
    }

    private func load() throws -> HouseholdRecord? {
        if let cache { return cache }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }
        let decoded = try JSONDecoder().decode(HouseholdRecord.self, from: data)
        cache = decoded
        return decoded
    }

    private func save(_ household: HouseholdRecord) throws {
        let data = try JSONEncoder().encode(household)
        UserDefaults.standard.set(data, forKey: defaultsKey)
        cache = household
    }
}
