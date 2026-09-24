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
    case repaymentRecorded = "repayment_recorded"
    case repaymentReversed = "repayment_reversed"

    var isRepayment: Bool { self == .repaymentRecorded || self == .repaymentReversed }
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
    /// Parallel to `recipientNames` when the backend provides it; empty for older rows.
    let recipientIds: [UUID]
    let expenseId: UUID?
    let repaymentId: UUID?
    let expenseTitle: String
    let category: ExpenseCategory
    let affectedShareMinor: Int
    let expenseTotalMinor: Int
    let currency: String

    enum CodingKeys: String, CodingKey {
        case id, occurredAt, kind, actorId, actorName, recipientId, recipientName, recipientNames, recipientIds
        case expenseId, repaymentId, expenseTitle, category, affectedShareMinor, expenseTotalMinor, currency
    }

    init(id: UUID = UUID(), occurredAt: Date = Date(), kind: ActivityEventKind, actorId: UUID, actorName: String, recipientId: UUID? = nil, recipientName: String? = nil, recipientNames: [String] = [], recipientIds: [UUID] = [], expenseId: UUID? = nil, repaymentId: UUID? = nil, expenseTitle: String, category: ExpenseCategory, affectedShareMinor: Int, expenseTotalMinor: Int, currency: String) {
        self.id = id; self.occurredAt = occurredAt; self.kind = kind; self.actorId = actorId; self.actorName = actorName
        self.recipientId = recipientId; self.recipientName = recipientName; self.expenseId = expenseId
        self.recipientNames = recipientNames.isEmpty ? (recipientName.map { [$0] } ?? []) : recipientNames
        self.recipientIds = recipientIds.isEmpty ? (recipientId.map { [$0] } ?? []) : recipientIds
        self.repaymentId = repaymentId
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
        recipientIds = try values.decodeIfPresent([UUID].self, forKey: .recipientIds)
            ?? (recipientId.map { [$0] } ?? [])
        expenseId = try values.decodeIfPresent(UUID.self, forKey: .expenseId)
        repaymentId = try values.decodeIfPresent(UUID.self, forKey: .repaymentId)
        expenseTitle = try values.decode(String.self, forKey: .expenseTitle)
        category = try values.decode(ExpenseCategory.self, forKey: .category)
        affectedShareMinor = try values.decode(Int.self, forKey: .affectedShareMinor)
        expenseTotalMinor = try values.decode(Int.self, forKey: .expenseTotalMinor)
        currency = try values.decode(String.self, forKey: .currency)
    }

    func sentence(viewerId: UUID) -> String {
        let actorIsViewer = actorId == viewerId
        let actor = actorIsViewer ? "You" : actorName
        let recipient = recipientId == viewerId ? "you" : (recipientName ?? "a participant")
        switch kind {
        case .shared:
            return "\(actor) shared an expense with \(list(recipientMentions(viewerId: viewerId)))"
        case .accepted:
            return "\(actor) accepted \(Self.possessive(recipient)) expense"
        case .rejected:
            return "\(actor) declined \(Self.possessive(recipient)) expense"
        case .proposalAccepted:
            return "\(actor) accepted \(Self.possessive(recipient)) suggested changes"
        case .proposalRejected:
            return "\(actor) declined \(Self.possessive(recipient)) suggested changes"
        case .edited:
            return "\(actor) edited a shared expense"
        case .participantRemoved:
            // Remote rows only reach the removed people; local rows also reach the actor.
            let removed = actorIsViewer ? list(recipientMentions(viewerId: viewerId)) : "you"
            return "\(actor) removed \(removed) from an expense"
        case .deleted:
            return "\(actor) deleted a shared expense"
        case .proposalCreated:
            if recipientId == nil { return "\(actor) suggested changes" }
            return "\(actor) suggested changes to \(Self.possessive(recipient)) expense"
        case .autoAccepted:
            return "\(Self.possessive(actor)) expense was accepted automatically"
        case .proposalSuperseded:
            return "\(Self.possessive(actor)) suggested changes were replaced"
        case .repaymentRecorded:
            return actorIsViewer
                ? "You recorded a repayment to \(recipientName ?? "someone")"
                : "\(actor) recorded a repayment to you"
        case .repaymentReversed:
            return actorIsViewer
                ? "You reversed a repayment to \(recipientName ?? "someone")"
                : "\(actor) reversed a repayment to you"
        }
    }

    /// Recipient names with the viewer as "you", listed first.
    private func recipientMentions(viewerId: UUID) -> [String] {
        guard !recipientNames.isEmpty else { return [recipientId == viewerId ? "you" : (recipientName ?? "a participant")] }
        guard recipientIds.count == recipientNames.count else { return recipientNames }
        var others: [String] = []
        var includesViewer = false
        for (id, name) in zip(recipientIds, recipientNames) {
            if id == viewerId { includesViewer = true } else { others.append(name) }
        }
        return includesViewer ? ["you"] + others : others
    }

    private static func possessive(_ name: String) -> String {
        switch name {
        case "you": return "your"
        case "You": return "Your"
        default: return name.hasSuffix("s") ? "\(name)'" : "\(name)'s"
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
        case .repaymentRecorded: return "banknote.fill"
        case .repaymentReversed: return "arrow.uturn.backward.circle.fill"
        }
    }
}

struct ActivityPage: Sendable {
    let events: [ActivityEvent]
    let hasMore: Bool
    /// ID of the last row the backend returned for this page, including rows
    /// this client could not show, so paging never stalls on them.
    let nextCursor: UUID?
}
