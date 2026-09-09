import Foundation

struct HouseholdMemberRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var householdId: UUID
    var userId: UUID
    var displayName: String

    init(
        id: UUID = UUID(),
        householdId: UUID,
        userId: UUID,
        displayName: String
    ) {
        self.id = id
        self.householdId = householdId
        self.userId = userId
        self.displayName = displayName
    }
}

struct HouseholdRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var currency: String
    var createdBy: UUID
    var members: [HouseholdMemberRecord]

    init(
        id: UUID = UUID(),
        name: String,
        currency: String = "PLN",
        createdBy: UUID,
        members: [HouseholdMemberRecord] = []
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.createdBy = createdBy
        self.members = members
    }
}
