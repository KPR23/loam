import Foundation

actor LocalHouseholdRepository: HouseholdRepository {
    private let defaultsKey = "loam.local.households"
    private let legacyDefaultsKey = "loam.local.household"
    private var cache: [HouseholdRecord]?

    func fetchTestHousehold(for userId: UUID) async throws -> HouseholdRecord? {
        try loadAll().first { household in
            household.members.contains(where: { $0.userId == userId }) && household.members.count > 1
        }
    }

    func ensureSplitHousehold(
        for userId: UUID,
        userDisplayName: String,
        partners: [SplitPartnerOption]
    ) async throws -> HouseholdRecord {
        let partnerIds = Set(partners.map(\.userId))
        guard !partnerIds.isEmpty else {
            throw HouseholdRepositoryError.incompleteSetup
        }

        let expectedMemberIds = partnerIds.union([userId])
        var households = try loadAll()
        if let existing = households.first(where: { Set($0.members.map(\.userId)) == expectedMemberIds }) {
            return existing
        }

        let householdId = UUID()
        var members = [
            HouseholdMemberRecord(
                householdId: householdId,
                userId: userId,
                displayName: userDisplayName
            ),
        ]
        members.append(contentsOf: partners.map { partner in
            HouseholdMemberRecord(
                householdId: householdId,
                userId: partner.userId,
                displayName: partner.displayName
            )
        })

        let household = HouseholdRecord(
            id: householdId,
            name: "Shared expenses",
            createdBy: userId,
            members: members
        )
        households.append(household)
        try saveAll(households)
        return household
    }

    private func loadAll() throws -> [HouseholdRecord] {
        if let cache { return cache }

        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            let decoded = try JSONDecoder().decode([HouseholdRecord].self, from: data)
            cache = decoded
            return decoded
        }

        if let legacyData = UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let legacyHousehold = try? JSONDecoder().decode(HouseholdRecord.self, from: legacyData) {
            cache = [legacyHousehold]
            return [legacyHousehold]
        }

        cache = []
        return []
    }

    private func saveAll(_ households: [HouseholdRecord]) throws {
        let data = try JSONEncoder().encode(households)
        UserDefaults.standard.set(data, forKey: defaultsKey)
        cache = households
    }
}
