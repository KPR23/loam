import Foundation

enum ActivityEventKind: String, Codable, Sendable {
    case shared = "shared"
    case accepted = "accepted"
    case rejected = "rejected"
    case edited = "edited"
    case participantRemoved = "participant_removed"
    case deleted = "deleted"
    case proposalCreated = "proposal_created"
    case proposalAccepted = "proposal_accepted"
    case proposalRejected = "proposal_rejected"
    case autoAccepted = "auto_accepted"
    case proposalSuperseded = "proposal_superseded"
}

struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let occurredAt: Date
    let kind: ActivityEventKind
    let actorId: UUID
    let actorName: String
    let recipientId: UUID?
    let recipientName: String?
    let recipientNames: [String]
    let expenseId: UUID?
    let expenseTitle: String
    let category: ExpenseCategory
    let affectedShareMinor: Int
    let expenseTotalMinor: Int
    let currency: String

    enum CodingKeys: String, CodingKey {
        case id, occurredAt, kind, actorId, actorName, recipientId, recipientName, recipientNames
        case expenseId, expenseTitle, category, affectedShareMinor, expenseTotalMinor, currency
    }

    init(id: UUID = UUID(), occurredAt: Date = Date(), kind: ActivityEventKind, actorId: UUID, actorName: String, recipientId: UUID? = nil, recipientName: String? = nil, recipientNames: [String] = [], expenseId: UUID? = nil, expenseTitle: String, category: ExpenseCategory, affectedShareMinor: Int, expenseTotalMinor: Int, currency: String) {
        self.id = id; self.occurredAt = occurredAt; self.kind = kind; self.actorId = actorId; self.actorName = actorName
        self.recipientId = recipientId; self.recipientName = recipientName; self.expenseId = expenseId
        self.recipientNames = recipientNames.isEmpty ? (recipientName.map { [$0] } ?? []) : recipientNames
        self.expenseTitle = expenseTitle; self.category = category; self.affectedShareMinor = affectedShareMinor
        self.expenseTotalMinor = expenseTotalMinor; self.currency = currency
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        kind = try values.decode(ActivityEventKind.self, forKey: .kind)
        actorId = try values.decode(UUID.self, forKey: .actorId)
        actorName = try values.decode(String.self, forKey: .actorName)
        recipientId = try values.decodeIfPresent(UUID.self, forKey: .recipientId)
        recipientName = try values.decodeIfPresent(String.self, forKey: .recipientName)
        recipientNames = try values.decodeIfPresent([String].self, forKey: .recipientNames)
            ?? (recipientName.map { [$0] } ?? [])
        expenseId = try values.decodeIfPresent(UUID.self, forKey: .expenseId)
        expenseTitle = try values.decode(String.self, forKey: .expenseTitle)
        category = try values.decode(ExpenseCategory.self, forKey: .category)
        affectedShareMinor = try values.decode(Int.self, forKey: .affectedShareMinor)
        expenseTotalMinor = try values.decode(Int.self, forKey: .expenseTotalMinor)
        currency = try values.decode(String.self, forKey: .currency)
    }

    func sentence(viewerId: UUID) -> String {
        let actor = actorId == viewerId ? "You" : actorName
        let recipient = recipientId == viewerId ? "you" : (recipientName ?? "a participant")
        switch kind {
        case .shared:
            let names = recipientNames.map { $0 == recipientName && recipientId == viewerId ? "you" : $0 }
            return "\(actor) shared an expense with \(list(names.isEmpty ? [recipientName ?? "a participant"] : names))"
        case .accepted, .rejected, .proposalAccepted, .proposalRejected:
            switch kind {
            case .accepted: return "\(actor) accepted \(recipient)'s expense"
            case .rejected: return "\(actor) rejected \(recipient)'s expense"
            case .proposalAccepted: return "\(actor) accepted \(recipient)'s proposal"
            default: return "\(actor) rejected \(recipient)'s proposal"
            }
        case .edited: return "\(actor) edited a shared expense"
        case .participantRemoved: return "\(actor) removed \(recipient) from an expense"
        case .deleted: return "\(actor) deleted a shared expense"
        case .proposalCreated: return "\(actor) proposed an edit"
        case .autoAccepted: return "\(actor)'s expense was accepted automatically"
        case .proposalSuperseded: return "\(actor)'s proposal was superseded"
        }
    }

    private func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "a participant"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    var symbolName: String {
        switch kind {
        case .shared: return "person.2.fill"
        case .accepted, .proposalAccepted, .autoAccepted: return "checkmark.circle.fill"
        case .rejected, .proposalRejected: return "xmark.circle.fill"
        case .edited, .proposalCreated: return "pencil.circle.fill"
        case .participantRemoved, .deleted, .proposalSuperseded: return "trash.circle.fill"
        }
    }
}

struct ActivityPage: Sendable {
    let events: [ActivityEvent]
    let hasMore: Bool
}
