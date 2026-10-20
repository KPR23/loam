import SwiftUI

/// The switches behind push notifications. Each governs a group of Activity
/// event kinds; the backend applies the same grouping when it decides what to send.
enum NotificationCategory: String, CaseIterable, Identifiable, Sendable {
    case requests
    case replies
    case changes
    case repayments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requests: "Requests"
        case .replies: "Replies"
        case .changes: "Changes"
        case .repayments: "Repayments"
        }
    }

    var detail: String {
        switch self {
        case .requests: "A friend shares an expense with you or suggests changes to one."
        case .replies: "A friend accepts or declines your expense or your suggested changes."
        case .changes: "A shared expense is edited or deleted, or you're removed from it."
        case .repayments: "A friend records or reverses a repayment to you."
        }
    }

    /// Outline glyphs, like the rows in Profile.
    var symbolName: String {
        switch self {
        case .requests: "tray.and.arrow.down"
        case .replies: "arrowshape.turn.up.left"
        case .changes: "pencil"
        case .repayments: RepaymentRecord.symbolName
        }
    }

    /// Matches the Activity badges of the events in this category.
    var tint: Color {
        switch self {
        case .requests: .blue
        case .replies: .green
        case .changes: .orange
        case .repayments: .teal
        }
    }

    init(kind: ActivityEventKind) {
        switch kind {
        case .shared, .proposalCreated: self = .requests
        case .accepted, .rejected, .proposalAccepted, .proposalRejected, .autoAccepted: self = .replies
        case .edited, .participantRemoved, .deleted, .proposalSuperseded: self = .changes
        case .repaymentRecorded, .repaymentReversed, .repaymentReceived: self = .repayments
        }
    }
}

struct NotificationPreferences: Equatable, Codable, Sendable {
    var requests = true
    var replies = true
    var changes = true
    var repayments = true

    subscript(category: NotificationCategory) -> Bool {
        get {
            switch category {
            case .requests: requests
            case .replies: replies
            case .changes: changes
            case .repayments: repayments
            }
        }
        set {
            switch category {
            case .requests: requests = newValue
            case .replies: replies = newValue
            case .changes: changes = newValue
            case .repayments: repayments = newValue
            }
        }
    }
}

/// Where tapping a push should land, read from the payload the backend sends.
struct NotificationRoute: Equatable, Sendable {
    let userId: UUID?
    let eventId: UUID?
    let expenseId: UUID?

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["event_id"] != nil else { return nil }
        func uuid(_ key: String) -> UUID? { (userInfo[key] as? String).flatMap(UUID.init(uuidString:)) }
        self.init(userId: uuid("user_id"), eventId: uuid("event_id"), expenseId: uuid("expense_id"))
    }

    init(userId: UUID?, eventId: UUID?, expenseId: UUID?) {
        self.userId = userId; self.eventId = eventId; self.expenseId = expenseId
    }
}
