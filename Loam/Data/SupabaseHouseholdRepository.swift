import Foundation
import Supabase

actor SupabaseHouseholdRepository: HouseholdRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchTestHousehold(for userId: UUID) async throws -> HouseholdRecord? {
        let rows: [HouseholdDTO] = try await client
            .from("household")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value

        for household in rows {
            let members = try await fetchMembers(householdId: household.id)
            guard members.contains(where: { $0.userId == userId }) else {
                continue
            }

            return HouseholdRecord(
                id: household.id,
                name: household.name,
                currency: household.currency,
                createdBy: household.createdBy,
                members: members
            )
        }

        return nil
    }

    func ensureSplitHousehold(
        for userId: UUID,
        userDisplayName: String,
        partners: [SplitPartnerOption]
    ) async throws -> HouseholdRecord {
        guard !partners.isEmpty else {
            throw HouseholdRepositoryError.incompleteSetup
        }

        let household: HouseholdDTO = try await client
            .rpc(
                "ensure_split_household",
                params: EnsureSplitHouseholdParams(
                    displayName: userDisplayName,
                    partnerIds: partners.map(\.userId)
                )
            )
            .single()
            .execute()
            .value

        let members = try await fetchMembers(householdId: household.id)
        try validateCompleteHousehold(
            members: members,
            expectedUserIds: Set([userId] + partners.map(\.userId))
        )

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

    private func validateCompleteHousehold(
        members: [HouseholdMemberRecord],
        expectedUserIds: Set<UUID>
    ) throws {
        guard Set(members.map(\.userId)) == expectedUserIds else {
            throw HouseholdRepositoryError.incompleteSetup
        }
    }
}

private struct EnsureSplitHouseholdParams: Encodable {
    let displayName: String
    let partnerIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case displayName = "p_display_name"
        case partnerIds = "p_partner_ids"
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
