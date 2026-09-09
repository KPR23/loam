import Foundation
import Supabase

actor SupabaseHouseholdRepository: HouseholdRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func ensureTestHousehold(
        for userId: UUID,
        userDisplayName: String
    ) async throws -> HouseholdRecord {
        if let existing = try await fetchTestHousehold(for: userId) {
            return existing
        }
        return try await createTestHousehold(for: userId, userDisplayName: userDisplayName)
    }

    private func fetchTestHousehold(for userId: UUID) async throws -> HouseholdRecord? {
        let memberRows: [HouseholdMemberDTO] = try await client
            .from("household_member")
            .select("*, household(*)")
            .eq("user_id", value: userId)
            .execute()
            .value

        guard let match = memberRows.first(where: { row in
            row.household?.name == TestPartner.householdName
        }) else {
            return nil
        }

        let householdId = match.householdId
        let allMembers: [HouseholdMemberDTO] = try await client
            .from("household_member")
            .select()
            .eq("household_id", value: householdId)
            .execute()
            .value

        guard let household = match.household else { return nil }
        return HouseholdRecord(
            id: household.id,
            name: household.name,
            currency: household.currency,
            createdBy: household.createdBy,
            members: allMembers.map { $0.toRecord() }
        )
    }

    private func createTestHousehold(
        for userId: UUID,
        userDisplayName: String
    ) async throws -> HouseholdRecord {
        let householdId = UUID()

        _ = try await client
            .from("household")
            .insert(HouseholdInsertDTO(
                id: householdId,
                name: TestPartner.householdName,
                currency: "PLN",
                createdBy: userId
            ))
            .execute()

        // RLS: partner row requires owner role, so insert self first, then partner.
        _ = try await client
            .from("household_member")
            .insert(
                HouseholdMemberInsertDTO(
                    householdId: householdId,
                    userId: userId,
                    displayName: userDisplayName,
                    role: "owner"
                )
            )
            .execute()

        _ = try await client
            .from("household_member")
            .insert(
                HouseholdMemberInsertDTO(
                    householdId: householdId,
                    userId: TestPartner.userId,
                    displayName: TestPartner.displayName,
                    role: "member"
                )
            )
            .execute()

        return HouseholdRecord(
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
    }
}

private struct HouseholdInsertDTO: Encodable {
    let id: UUID
    let name: String
    let currency: String
    let created_by: UUID

    init(id: UUID, name: String, currency: String, createdBy: UUID) {
        self.id = id
        self.name = name
        self.currency = currency
        self.created_by = createdBy
    }
}

private struct HouseholdMemberInsertDTO: Encodable {
    let household_id: UUID
    let user_id: UUID
    let display_name: String
    let role: String

    init(householdId: UUID, userId: UUID, displayName: String, role: String) {
        self.household_id = householdId
        self.user_id = userId
        self.display_name = displayName
        self.role = role
    }
}

private struct HouseholdDTO: Decodable {
    let id: UUID
    let name: String
    let currency: String
    let createdBy: UUID

    enum CodingKeys: String, CodingKey {
        case id, name, currency
        case createdBy = "created_by"
    }
}

private struct HouseholdMemberDTO: Decodable {
    let id: UUID
    let householdId: UUID
    let userId: UUID
    let displayName: String
    let household: HouseholdDTO?

    enum CodingKeys: String, CodingKey {
        case id, household
        case householdId = "household_id"
        case userId = "user_id"
        case displayName = "display_name"
    }

    func toRecord() -> HouseholdMemberRecord {
        HouseholdMemberRecord(
            id: id,
            householdId: householdId,
            userId: userId,
            displayName: displayName
        )
    }
}
