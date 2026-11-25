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
    /// The person who was paid recorded it, so the actor is the receiver.
    case repaymentReceived = "repayment_received"

    var isRepayment: Bool { self == .repaymentRecorded || self == .repaymentReversed || self == .repaymentReceived }
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

    /// Each case spells out who did what to whom, so every language can phrase "you" and
    /// another person's name its own way.
    func sentence(viewerId: UUID) -> String {
        let byViewer = actorId == viewerId
        let toViewer = recipientId == viewerId
        let actor = actorName
        let recipient = recipientName ?? String(localized: "a participant")
        let someone = recipientName ?? String(localized: "someone")
        switch kind {
        case .shared:
            let people = list(recipientMentions(viewerId: viewerId))
            return byViewer
                ? String(localized: "You shared an expense with \(people)")
                : String(localized: "\(actor) shared an expense with \(people)")
        case .accepted:
            switch (byViewer, toViewer) {
            case (true, true): return String(localized: "You accepted your expense")
            case (true, false): return String(localized: "You accepted \(recipient)'s expense")
            case (false, true): return String(localized: "\(actor) accepted your expense")
            case (false, false): return String(localized: "\(actor) accepted \(recipient)'s expense")
            }
        case .rejected:
            switch (byViewer, toViewer) {
            case (true, true): return String(localized: "You declined your expense")
            case (true, false): return String(localized: "You declined \(recipient)'s expense")
            case (false, true): return String(localized: "\(actor) declined your expense")
            case (false, false): return String(localized: "\(actor) declined \(recipient)'s expense")
            }
        case .proposalAccepted:
            switch (byViewer, toViewer) {
            case (true, true): return String(localized: "You accepted your suggested changes")
            case (true, false): return String(localized: "You accepted \(recipient)'s suggested changes")
            case (false, true): return String(localized: "\(actor) accepted your suggested changes")
            case (false, false): return String(localized: "\(actor) accepted \(recipient)'s suggested changes")
            }
        case .proposalRejected:
            switch (byViewer, toViewer) {
            case (true, true): return String(localized: "You declined your suggested changes")
            case (true, false): return String(localized: "You declined \(recipient)'s suggested changes")
            case (false, true): return String(localized: "\(actor) declined your suggested changes")
            case (false, false): return String(localized: "\(actor) declined \(recipient)'s suggested changes")
            }
        case .edited:
            return byViewer
                ? String(localized: "You edited a shared expense")
                : String(localized: "\(actor) edited a shared expense")
        case .participantRemoved:
            // Remote rows only reach the removed people; local rows also reach the actor.
            if byViewer {
                let removed = list(recipientMentions(viewerId: viewerId))
                return String(localized: "You removed \(removed) from an expense")
            }
            return String(localized: "\(actor) removed you from an expense")
        case .deleted:
            return byViewer
                ? String(localized: "You deleted a shared expense")
                : String(localized: "\(actor) deleted a shared expense")
        case .proposalCreated:
            if recipientId == nil {
                return byViewer ? String(localized: "You suggested changes") : String(localized: "\(actor) suggested changes")
            }
            switch (byViewer, toViewer) {
            case (true, true): return String(localized: "You suggested changes to your expense")
            case (true, false): return String(localized: "You suggested changes to \(recipient)'s expense")
            case (false, true): return String(localized: "\(actor) suggested changes to your expense")
            case (false, false): return String(localized: "\(actor) suggested changes to \(recipient)'s expense")
            }
        case .autoAccepted:
            return byViewer
                ? String(localized: "Your expense was accepted automatically")
                : String(localized: "\(actor)'s expense was accepted automatically")
        case .proposalSuperseded:
            return byViewer
                ? String(localized: "Your suggested changes were replaced")
                : String(localized: "\(actor)'s suggested changes were replaced")
        case .repaymentRecorded:
            return byViewer
                ? String(localized: "You recorded a repayment to \(someone)")
                : String(localized: "\(actor) recorded a repayment to you")
        case .repaymentReceived:
            return byViewer
                ? String(localized: "You recorded a repayment from \(someone)")
                : String(localized: "\(actor) recorded a repayment from you")
        case .repaymentReversed:
            return byViewer
                ? String(localized: "You reversed a repayment to \(someone)")
                : String(localized: "\(actor) reversed a repayment to you")
        }
    }

    /// Feed sentence that names the expense in bold, e.g. "Anna accepted **Dinner**".
    /// `sentence(viewerId:)` stays title-free for the expense's own history.
    func headline(viewerId: UUID) -> AttributedString {
        let byViewer = actorId == viewerId
        let toViewer = recipientId == viewerId
        let actor = actorName
        let recipient = recipientName ?? String(localized: "a participant")
        // Stands in for the title, so a translation can put it anywhere in the sentence.
        let title = Self.titleSlot
        let text: String
        switch kind {
        case .shared:
            let people = list(recipientMentions(viewerId: viewerId))
            text = byViewer
                ? String(localized: "You shared \(title) with \(people)")
                : String(localized: "\(actor) shared \(title) with \(people)")
        case .accepted:
            text = byViewer ? String(localized: "You accepted \(title)") : String(localized: "\(actor) accepted \(title)")
        case .rejected:
            text = byViewer ? String(localized: "You declined \(title)") : String(localized: "\(actor) declined \(title)")
        case .proposalAccepted:
            switch (byViewer, toViewer) {
            case (true, true): text = String(localized: "You accepted your changes to \(title)")
            case (true, false): text = String(localized: "You accepted \(recipient)'s changes to \(title)")
            case (false, true): text = String(localized: "\(actor) accepted your changes to \(title)")
            case (false, false): text = String(localized: "\(actor) accepted \(recipient)'s changes to \(title)")
            }
        case .proposalRejected:
            switch (byViewer, toViewer) {
            case (true, true): text = String(localized: "You declined your changes to \(title)")
            case (true, false): text = String(localized: "You declined \(recipient)'s changes to \(title)")
            case (false, true): text = String(localized: "\(actor) declined your changes to \(title)")
            case (false, false): text = String(localized: "\(actor) declined \(recipient)'s changes to \(title)")
            }
        case .edited:
            text = byViewer ? String(localized: "You edited \(title)") : String(localized: "\(actor) edited \(title)")
        case .participantRemoved:
            if byViewer {
                let removed = list(recipientMentions(viewerId: viewerId))
                text = String(localized: "You removed \(removed) from \(title)")
            } else {
                text = String(localized: "\(actor) removed you from \(title)")
            }
        case .deleted:
            text = byViewer ? String(localized: "You deleted \(title)") : String(localized: "\(actor) deleted \(title)")
        case .proposalCreated:
            text = byViewer
                ? String(localized: "You suggested changes to \(title)")
                : String(localized: "\(actor) suggested changes to \(title)")
        case .autoAccepted:
            text = String(localized: "\(title) was accepted automatically")
        case .proposalSuperseded:
            text = byViewer
                ? String(localized: "Your changes to \(title) were replaced")
                : String(localized: "\(actor)'s changes to \(title) were replaced")
        case .repaymentRecorded:
            let someone = recipientName ?? String(localized: "someone")
            return AttributedString(byViewer ? String(localized: "You paid \(someone) back") : String(localized: "\(actor) paid you back"))
        case .repaymentReceived:
            let someone = recipientName ?? String(localized: "Someone")
            return AttributedString(byViewer ? String(localized: "\(someone) paid you back") : String(localized: "You paid \(actor) back"))
        case .repaymentReversed:
            let someone = recipientName ?? String(localized: "someone")
            return AttributedString(byViewer
                ? String(localized: "You reversed a repayment to \(someone)")
                : String(localized: "\(actor) reversed a repayment to you"))
        }
        return Self.emphasizing(expenseTitle, in: text)
    }

    private static let titleSlot = "\u{FFFC}"

    /// Puts the bold title where the translated sentence has `titleSlot`.
    private static func emphasizing(_ expenseTitle: String, in text: String) -> AttributedString {
        var title = AttributedString(expenseTitle)
        title.inlinePresentationIntent = .stronglyEmphasized
        guard let slot = text.range(of: titleSlot) else { return AttributedString(text) }
        return AttributedString(String(text[..<slot.lowerBound])) + title + AttributedString(String(text[slot.upperBound...]))
    }

    /// Recipient names with the viewer as "you", listed first.
    private func recipientMentions(viewerId: UUID) -> [String] {
        let you = String(localized: "you", comment: "The person using the app, in a list of people")
        guard !recipientNames.isEmpty else { return [recipientId == viewerId ? you : (recipientName ?? String(localized: "a participant"))] }
        guard recipientIds.count == recipientNames.count else { return recipientNames }
        var others: [String] = []
        var includesViewer = false
        for (id, name) in zip(recipientIds, recipientNames) {
            if id == viewerId { includesViewer = true } else { others.append(name) }
        }
        return includesViewer ? [you] + others : others
    }

    private func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return String(localized: "a participant")
        case 1: return names[0]
        case 2: return String(localized: "\(names[0]) and \(names[1])")
        default:
            let more = names.count - 2
            return String(localized: "\(names[0]), \(names[1]) and \(more) more")
        }
    }

    var symbolName: String {
        switch kind {
        case .shared: return "person.2.fill"
        case .accepted, .proposalAccepted, .autoAccepted: return "checkmark.circle.fill"
        case .rejected, .proposalRejected: return "xmark.circle.fill"
        case .edited, .proposalCreated: return "pencil.circle.fill"
        case .participantRemoved, .deleted, .proposalSuperseded: return "trash.circle.fill"
        case .repaymentRecorded, .repaymentReceived: return "\(RepaymentRecord.symbolName).circle.fill"
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
