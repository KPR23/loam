import Foundation

/// Something the user did offline that still has to reach the server.
enum PendingChange: Codable, Hashable, Sendable {
    /// A new expense (with its rule when it repeats), or an edit to one the user created.
    case saveExpense(ExpenseRecord, isNew: Bool, rule: RecurringRuleRecord?)
    case deleteExpense(ExpenseRecord, recurringMode: RecurringDeletionMode?)
    /// The copy the answer was given on; the answer is not sent if the share changed since.
    case respondToShare(ExpenseRecord, action: ExpenseShareResponseAction)
    case repayment(PendingRepayment)

    var expenseId: UUID? {
        switch self {
        case let .saveExpense(expense, _, _), let .deleteExpense(expense, _), let .respondToShare(expense, _): expense.id
        case .repayment: nil
        }
    }

    var title: String {
        switch self {
        case let .saveExpense(expense, _, _), let .deleteExpense(expense, _), let .respondToShare(expense, _): expense.displayTitle
        case let .repayment(repayment): repayment.note?.isEmpty == false ? repayment.note! : "Repayment"
        }
    }
}

struct PendingRepayment: Codable, Hashable, Sendable {
    /// Sent with the repayment, so a retry after a lost answer can't record it twice.
    var operationId = UUID()
    var personId: UUID
    /// The person paid the user, rather than the user paying them.
    var isReceived: Bool
    var amountMinor: Int
    var currencyCode: String
    var note: String?
    var paidAt: Date
}

struct PendingChangeEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var queuedAt = Date()
    var change: PendingChange
}

enum PendingChangeError: LocalizedError {
    case changedBeforeSync

    var errorDescription: String? {
        "It changed before your answer was sent. Review it again."
    }
}

extension PendingChange {
    /// Adds a change to the queue, folding it into an earlier one for the same expense so the
    /// server gets one final version. The entry being sent right now is left alone.
    static func enqueue(_ change: PendingChange, into queue: [PendingChangeEntry], sending sendingId: UUID? = nil) -> [PendingChangeEntry] {
        var queue = queue
        let waitingSave = queue.lastIndex { entry in
            guard entry.id != sendingId, case let .saveExpense(old, _, _) = entry.change else { return false }
            return old.id == change.expenseId
        }
        let sendingSameExpense = queue.contains { $0.id == sendingId && $0.change.expenseId == change.expenseId && change.expenseId != nil }

        switch change {
        case let .saveExpense(expense, isNew, rule):
            if let index = waitingSave, case let .saveExpense(_, wasNew, earlierRule) = queue[index].change {
                queue[index].change = .saveExpense(expense, isNew: wasNew, rule: earlierRule ?? rule)
                return queue
            }
            // The create on its way to the server makes this an edit of it.
            queue.append(PendingChangeEntry(change: .saveExpense(expense, isNew: isNew && !sendingSameExpense, rule: sendingSameExpense ? nil : rule)))
        case let .deleteExpense(expense, _):
            if let index = waitingSave, case let .saveExpense(_, wasNew, _) = queue[index].change {
                queue.remove(at: index)
                // Never reached the server, so there is nothing to delete there.
                if wasNew && !sendingSameExpense { return queue }
            }
            queue.removeAll { $0.id != sendingId && $0.change.expenseId == expense.id }
            queue.append(PendingChangeEntry(change: change))
        case let .respondToShare(expense, _):
            queue.removeAll { entry in
                guard entry.id != sendingId, case let .respondToShare(old, _) = entry.change else { return false }
                return old.id == expense.id
            }
            queue.append(PendingChangeEntry(change: change))
        case .repayment:
            queue.append(PendingChangeEntry(change: change))
        }
        return queue
    }

    /// Shows queued changes on top of the server's (or the saved) list, so nothing done offline
    /// disappears before it syncs. Applying a change twice gives the same list. Lists that hold
    /// only expenses opened elsewhere pass `addsMissing: false`, so they only update their own.
    static func apply(_ changes: [PendingChange], to expenses: [ExpenseRecord], userId: UUID, period: DatePeriod?, addsMissing: Bool = true) -> [ExpenseRecord] {
        var expenses = expenses
        for change in changes {
            switch change {
            case let .saveExpense(expense, _, _):
                let index = expenses.firstIndex { $0.id == expense.id }
                let belongs = period?.contains(expense.spentAt) ?? true
                switch (index, belongs) {
                case let (index?, true): expenses[index] = expense
                case let (index?, false): expenses.remove(at: index)
                case (nil, true): if addsMissing { expenses.append(expense) }
                case (nil, false): break
                }
            case let .deleteExpense(expense, _):
                expenses.removeAll { $0.id == expense.id }
            case let .respondToShare(expense, action):
                guard let index = expenses.firstIndex(where: { $0.id == expense.id }),
                      let shareIndex = expenses[index].shares.firstIndex(where: { $0.userId == userId }),
                      expenses[index].shares[shareIndex].status == .pending else { continue }
                if action == .reject {
                    // Rejected shares leave the list, as they do on the server.
                    expenses.remove(at: index)
                } else {
                    expenses[index].shares[shareIndex].status = .accepted
                    expenses[index].shares[shareIndex].respondedAt = Date()
                }
            case .repayment:
                continue
            }
        }
        return expenses.sorted { lhs, rhs in
            lhs.spentAt != rhs.spentAt ? lhs.spentAt > rhs.spentAt : lhs.createdAt > rhs.createdAt
        }
    }

    /// A short line for the toast when a change couldn't be synced and was dropped.
    static func failureMessage(for change: PendingChange, error: Error) -> String {
        let reason: String
        if isConflict(error) {
            reason = "It changed on another device."
        } else if error.localizedDescription.localizedCaseInsensitiveContains("not found") {
            reason = "It was deleted."
        } else {
            reason = error.localizedDescription
        }
        return "\u{201C}\(change.title)\u{201D} couldn't sync. \(reason)"
    }

    /// The server rejects a save whose expected version is out of date.
    static func isConflict(_ error: Error) -> Bool {
        if (error as? ExpenseRepositoryError) == .conflict { return true }
        return error.localizedDescription.localizedCaseInsensitiveContains("changed. Refresh")
    }
}

extension ExpenseRecord {
    /// Same amounts, details and split, whatever the version or timestamps.
    func hasSameContent(as other: ExpenseRecord) -> Bool {
        func split(_ expense: ExpenseRecord) -> [UUID: Int] {
            Dictionary(expense.shares.map { ($0.userId, $0.amountMinor) }, uniquingKeysWith: +)
        }
        return amountMinor == other.amountMinor
            && currency.uppercased() == other.currency.uppercased()
            && spendCategory == other.spendCategory
            && (title ?? "") == (other.title ?? "")
            && (note ?? "") == (other.note ?? "")
            && location == other.location
            && AppPreferences.calendar.isDate(spentAt, inSameDayAs: other.spentAt)
            && paidBy == other.paidBy
            && split(self) == split(other)
    }
}

/// A message for the toast about changes kept on the device.
struct OfflineNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case savedOffline
        case wentOffline
        case synced
        case failed
    }

    let id = UUID()
    let kind: Kind
    let message: String

    // Each notice is new, so a second one restarts the toast's timer.
    static var savedOffline: OfflineNotice {
        OfflineNotice(kind: .savedOffline, message: "Saved on this device. It will sync when you're back online.")
    }

    static var wentOffline: OfflineNotice {
        OfflineNotice(kind: .wentOffline, message: "You're offline. Changes will sync when you're back online.")
    }

    static func synced(_ count: Int) -> OfflineNotice {
        OfflineNotice(kind: .synced, message: count == 1 ? "Back online. Your change is synced." : "Back online. \(count) changes are synced.")
    }

    static func failed(_ message: String) -> OfflineNotice {
        OfflineNotice(kind: .failed, message: message)
    }

    @MainActor var toast: Toast {
        switch kind {
        case .savedOffline: .info(message)
        case .wentOffline: .warning(message)
        case .synced: .success(message)
        case .failed: .error(message)
        }
    }
}

/// Keeps changes made offline on the device and sends them, in order, once there's a connection.
@MainActor
final class OfflineSync: ObservableObject {
    static let shared = OfflineSync()

    @Published private(set) var changes: [PendingChangeEntry] = []
    /// Each new notice is shown as a toast.
    @Published var notice: OfflineNotice? {
        didSet { if let notice { ToastCenter.shared.show(notice.toast) } }
    }
    @Published private(set) var isSyncing = false

    /// Replaced in tests.
    var isOnline: @MainActor () -> Bool = { Connectivity.shared.isOnline }
    /// Demo storage lives on the device already, so it never queues.
    var isEnabled: () -> Bool = { !ExpenseRepositoryFactory.usesLocalStorage }
    var makeExpenseRepository: () -> any ExpenseRepository = { ExpenseRepositoryFactory.make() }
    var makeBalanceRepository: () -> any BalanceRepository = { BalanceRepositoryFactory.make() }

    private var userId: UUID?
    private var sendingId: UUID?
    private var flushTask: Task<Int, Never>?
    /// How many changes have been saved on the device with a toast, so a screen can tell its action was one.
    private(set) var savedOfflineCount = 0
    /// The version the server gave each expense this device saved, so a queued edit
    /// that follows another one expects the version the first edit produced.
    private var savedVersions: [UUID: Int] = [:]

    var pendingExpenseIds: Set<UUID> { Set(changes.compactMap(\.change.expenseId)) }

    func pendingChanges(for userId: UUID) -> [PendingChange] {
        load(userId)
        return changes.map(\.change)
    }

    /// True when a change has to wait on the device: there's no connection, or an earlier
    /// change to the same expense is still waiting, so both reach the server in order.
    func shouldQueue(_ change: PendingChange, userId: UUID) -> Bool {
        guard isEnabled() else { return false }
        load(userId)
        if !isOnline() { return true }
        guard let expenseId = change.expenseId else { return false }
        return changes.contains { $0.change.expenseId == expenseId }
    }

    /// `announce` shows the "saved on this device" toast; it stays quiet when the change only
    /// waits its turn behind another one while online.
    func enqueue(_ change: PendingChange, userId: UUID, announce: Bool = true) {
        load(userId)
        changes = PendingChange.enqueue(change, into: changes, sending: sendingId)
        persist(userId)
        if announce {
            savedOfflineCount += 1
            notice = .savedOffline
        }
    }

    /// Sends waiting changes in order and returns how many reached the server. Stops at the
    /// first one that can't connect; drops one the server refuses and says so.
    @discardableResult
    func flush(userId: UUID) async -> Int {
        // A second caller waits for the sync already running, so it sees the saved result.
        if let running = flushTask { return await running.value }
        // Its own task, so a screen closing mid-sync doesn't cancel the requests.
        let task = Task { await self.performFlush(userId: userId) }
        flushTask = task
        let synced = await task.value
        flushTask = nil
        return synced
    }

    /// Confirms an action, unless it was saved on the device since `count`: that toast already
    /// says so, and a success toast would replace it.
    func showSuccess(_ message: String, unlessSavedOfflineSince count: Int) {
        guard savedOfflineCount == count else { return }
        ToastCenter.shared.showSuccess(message)
    }

    /// An account switch or sign-out stops using the previous account's queue.
    func reset() {
        userId = nil
        changes = []
        savedVersions = [:]
        notice = nil
    }

    private func performFlush(userId: UUID) async -> Int {
        guard isEnabled(), isOnline(), !isSyncing else { return 0 }
        load(userId)
        guard !changes.isEmpty else { return 0 }
        isSyncing = true
        defer {
            isSyncing = false
            sendingId = nil
            // Once everything is sent, later edits start from the version the screens loaded.
            if changes.isEmpty { savedVersions = [:] }
        }

        var synced = 0
        var failures: [String] = []
        while self.userId == userId, let entry = changes.first {
            sendingId = entry.id
            do {
                try await send(entry.change, userId: userId)
                synced += 1
            } catch {
                if Self.shouldRetryLater(error) { break }
                failures.append(PendingChange.failureMessage(for: entry.change, error: error))
                LoamErrorCapture.capture("offline.sync_failed")
            }
            guard self.userId == userId else { break }
            changes.removeAll { $0.id == entry.id }
            persist(userId)
        }

        if let first = failures.first {
            notice = .failed(failures.count == 1 ? first : "\(failures.count) offline changes couldn't sync. \(first)")
        } else if synced > 0 {
            notice = .synced(synced)
        }
        return synced
    }

    private func send(_ change: PendingChange, userId: UUID) async throws {
        let repository = makeExpenseRepository()
        switch change {
        case let .saveExpense(expense, isNew, rule):
            if isNew {
                do {
                    let saved: ExpenseRecord
                    if let rule {
                        saved = try await repository.createRecurringExpense(expense, rule: rule)
                    } else {
                        saved = try await repository.create(expense)
                    }
                    savedVersions[saved.id] = saved.version
                } catch where PendingChange.isConflict(error) {
                    // A retry after the first attempt's answer was lost finds the expense already there.
                    guard let existing = try await repository.fetchExpenses(ids: [expense.id]).first,
                          existing.createdBy == userId else { throw error }
                    if existing.hasSameContent(as: expense) {
                        savedVersions[existing.id] = existing.version
                    } else {
                        // An edit made while the first attempt's answer was lost rides on this create.
                        var edited = expense
                        edited.version = existing.version
                        let saved = try await repository.update(edited)
                        savedVersions[saved.id] = saved.version
                    }
                }
            } else {
                var expense = expense
                if let version = savedVersions[expense.id] { expense.version = version }
                do {
                    let saved = try await repository.update(expense)
                    savedVersions[saved.id] = saved.version
                } catch where PendingChange.isConflict(error) {
                    // Already saved by an attempt whose answer was lost; anything else is a real conflict.
                    guard let current = try await repository.fetchExpenses(ids: [expense.id]).first,
                          current.hasSameContent(as: expense) else { throw error }
                    savedVersions[current.id] = current.version
                }
            }
        case let .deleteExpense(expense, recurringMode):
            try await repository.delete(id: expense.id)
            savedVersions[expense.id] = nil
            if let recurringId = expense.recurringId, let recurringMode {
                try await ExpenseStore.applyRecurringDeletion(
                    recurringId: recurringId,
                    occurrenceDate: expense.spentAt,
                    mode: recurringMode,
                    repository: repository
                )
            }
        case let .respondToShare(expense, action):
            // Deleted, or answered on another device: nothing left to answer.
            guard let current = try await repository.fetchExpenses(ids: [expense.id]).first,
                  let share = current.shareRecord(for: userId),
                  share.status == .pending else { return }
            // An answer covers the amount it was given for, never a changed one.
            guard share.amountMinor == expense.shareRecord(for: userId)?.amountMinor else {
                throw PendingChangeError.changedBeforeSync
            }
            try await repository.respondToShare(expenseId: expense.id, userId: userId, action: action)
        case let .repayment(repayment):
            let balances = makeBalanceRepository()
            if repayment.isReceived {
                try await balances.createReceivedRepayment(
                    from: repayment.personId, to: userId, amountMinor: repayment.amountMinor,
                    currencyCode: repayment.currencyCode, note: repayment.note, paidAt: repayment.paidAt,
                    operationId: repayment.operationId
                )
            } else {
                try await balances.createRepayment(
                    from: userId, to: repayment.personId, amountMinor: repayment.amountMinor,
                    currencyCode: repayment.currencyCode, note: repayment.note, paidAt: repayment.paidAt,
                    operationId: repayment.operationId
                )
            }
        }
    }

    /// Lost connections and cancelled requests keep the change for the next try.
    private static func shouldRetryLater(_ error: Error) -> Bool {
        Connectivity.isOfflineError(error)
            || error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }

    private func load(_ userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        savedVersions = [:]
        changes = OfflineCache.load([PendingChangeEntry].self, key: OfflineCache.pendingChangesKey, userId: userId) ?? []
    }

    private func persist(_ userId: UUID) {
        if changes.isEmpty {
            OfflineCache.remove(key: OfflineCache.pendingChangesKey, userId: userId)
        } else {
            OfflineCache.save(changes, key: OfflineCache.pendingChangesKey, userId: userId)
        }
    }
}
