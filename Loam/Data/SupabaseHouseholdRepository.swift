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
        let household: HouseholdDTO = try await client
            .rpc(
                "ensure_test_household",
                params: ["p_display_name": userDisplayName]
            )
            .single()
            .execute()
            .value

        let members = try await fetchMembers(householdId: household.id)
        try validateCompleteTestHousehold(members: members, userId: userId)

        return HouseholdRecord(
            id: household.id,
            name: household.name,
            currency: household.currency,
            createdBy: household.createdBy,
            members: members
        )
    }

    private func fetchMembers(householdId: UUID) async throws -> [HouseholdMemberRecord] {
        let rows: [HouseholdMemberDTO] = try await client
            .from("household_member")
            .select()
            .eq("household_id", value: householdId)
            .execute()
            .value

        return rows.map { $0.toRecord() }
    }

    private func validateCompleteTestHousehold(
        members: [HouseholdMemberRecord],
        userId: UUID
    ) throws {
        let hasUser = members.contains(where: { $0.userId == userId })
        let hasPartner = members.contains(where: { $0.userId == TestPartner.userId })

        guard hasUser, hasPartner else {
            throw HouseholdRepositoryError.incompleteSetup
        }
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

    enum CodingKeys: String, CodingKey {
        case id
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
