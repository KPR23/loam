import Foundation
import Supabase
import UIKit

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
    /// When the server first failed it with an error worth retrying. Optional, so queues saved
    /// before this existed still load.
    var retryingSince: Date?
    /// Its send was cut off by iOS ending Loam, so the server may already have it as it was then.
    var wasInterrupted: Bool?
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
    /// `retrying` marks a change that was being sent and must go again: it came before anything
    /// queued for the same expense meanwhile, so it goes ahead of those rather than folding into them.
    static func enqueue(_ change: PendingChange, into queue: [PendingChangeEntry], sending sendingId: UUID? = nil, retrying: Bool = false) -> [PendingChangeEntry] {
        var queue = queue
        if retrying, let expenseId = change.expenseId,
           let index = queue.firstIndex(where: { $0.id != sendingId && $0.change.expenseId == expenseId }) {
            queue.insert(PendingChangeEntry(change: change), at: index)
            return queue
        }
        let waitingSave = queue.lastIndex { entry in
            guard entry.id != sendingId, case let .saveExpense(old, _, _) = entry.change else { return false }
            return old.id == change.expenseId
        }
        let sendingSameExpense = queue.contains { $0.id == sendingId && $0.change.expenseId == change.expenseId && change.expenseId != nil }

        switch change {
        case let .saveExpense(expense, isNew, rule):
            if let index = waitingSave, case let .saveExpense(_, wasNew, earlierRule) = queue[index].change {
                queue[index].change = .saveExpense(expense, isNew: wasNew, rule: earlierRule ?? rule)
                // It now carries an edit the server can't have yet.
                queue[index].wasInterrupted = nil
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

    static var willRetry: OfflineNotice {
        OfflineNotice(kind: .savedOffline, message: "Couldn't reach Loam. Saved on this device and trying again shortly.")
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
    /// Whether Loam is on screen, where a toast can tell the person about a failed change.
    var isActive: @MainActor () -> Bool = { UIApplication.shared.applicationState != .background }

    private var userId: UUID?
    private var sendingId: UUID?
    /// Changes being sent right now, outside the queue. Each is also written to the device
    /// (`inFlightKey`), so one cut off by iOS ending the app is sent again on the next launch.
    private var inFlight: [UUID: (userId: UUID, entry: PendingChangeEntry)] = [:]
    private var flushTask: Task<Int, Never>?
    /// Accounts signed out in this launch; their late saves must not make them current again.
    private var signedOutIds: Set<UUID> = []
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

    /// Sends a change now, keeping a copy on the device until the server answers, and asks iOS
    /// for time to finish when Loam leaves the screen. If iOS ends the app before the answer
    /// arrives, the next launch queues the copy and sends it again; the expense's own id and the
    /// repayment's operation id keep that second attempt from saving anything twice.
    func perform<Value>(_ change: PendingChange, userId: UUID, send: () async throws -> Value) async throws -> Value {
        // A late save for an account that is no longer signed in must not switch the queue to it.
        guard isEnabled(), self.userId == userId || (self.userId == nil && !signedOutIds.contains(userId)) else { return try await send() }
        load(userId)
        let entry = PendingChangeEntry(change: change)
        inFlight[entry.id] = (userId, entry)
        persistInFlight(userId)
        defer {
            if inFlight.removeValue(forKey: entry.id) != nil { persistInFlight(userId) }
        }
        do {
            return try await BackgroundTime.run("Save change") { try await send() }
        } catch {
            // The screen that started it shows the error, but not while Loam is in the background.
            // One worth retrying is queued by the caller (`retrying: true`), and one already queued
            // (a slow create) is retried from the queue, so neither is a failure yet.
            if !isActive(), !Self.shouldRetryLater(error), inFlight[entry.id] != nil {
                let reason = UserFacingError.message(for: error) ?? UserFacingError.fallback
                await SyncNotifier.shared.postFailure("\u{201C}\(change.title)\u{201D} wasn't saved. \(reason)", userId: userId)
            }
            throw error
        }
    }

    /// `announce` shows the "saved on this device" toast; it stays quiet when the change only
    /// waits its turn behind another one while online.
    /// `retrying` is for a change whose send just failed with an error worth retrying.
    func enqueue(_ change: PendingChange, userId: UUID, announce: Bool = true, retrying: Bool = false) {
        // A late change for a signed-out account waits in that account's queue, without showing it here.
        if self.userId != userId, self.userId != nil || signedOutIds.contains(userId) {
            let saved = OfflineCache.load([PendingChangeEntry].self, key: OfflineCache.pendingChangesKey, userId: userId) ?? []
            OfflineCache.save(PendingChange.enqueue(change, into: saved, retrying: retrying), key: OfflineCache.pendingChangesKey, userId: userId)
            return
        }
        load(userId)
        changes = PendingChange.enqueue(change, into: changes, sending: sendingId, retrying: retrying)
        persist(userId)
        // The queued copy now stands in for one still being sent, so a relaunch sends it once.
        let covered = inFlight.filter { $0.value.userId == userId && $0.value.entry.change == change }.keys
        if !covered.isEmpty {
            covered.forEach { inFlight[$0] = nil }
            persistInFlight(userId)
        }
        if announce {
            savedOfflineCount += 1
            if isOnline() {
                // Online, so the server had a hiccup: try again soon rather than waiting for a reconnect.
                notice = .willRetry
                scheduleRetry(userId: userId)
            } else {
                notice = .savedOffline
            }
        }
    }

    private var retryTask: Task<Void, Never>?

    private func scheduleRetry(userId: UUID) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.userId == userId else { return }
            await self.flush(userId: userId)
        }
    }

    /// Sends waiting changes in order and returns how many reached the server. Stops at the
    /// first one that can't connect; drops one the server refuses and says so.
    @discardableResult
    func flush(userId: UUID) async -> Int {
        // A second caller waits for the sync already running, so it sees the saved result.
        if let running = flushTask { return await running.value }
        // Its own task, so a screen closing mid-sync doesn't cancel the requests.
        let task = Task { await BackgroundTime.run("Sync changes") { await self.performFlush(userId: userId) } }
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
        if let userId { signedOutIds.insert(userId) }
        retryTask?.cancel()
        userId = nil
        changes = []
        savedVersions = [:]
        notice = nil
        SyncNotifier.shared.clearWaitingReminder()
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
                try await send(entry.change, userId: userId, wasInterrupted: entry.wasInterrupted == true)
                synced += 1
            } catch {
                if Self.shouldRetryLater(error) && !hasRetriedTooLong(entry, after: error) {
                    // Waiting on a connection or a session is fine for any time; a server that keeps
                    // failing the change isn't. Losing the connection starts the count again.
                    let since: Date? = Self.isServerFailure(error) ? (entry.retryingSince ?? Date()) : nil
                    if changes.first?.id == entry.id, changes[0].retryingSince != since,
                       Self.isServerFailure(error) || Connectivity.isOfflineError(error) {
                        changes[0].retryingSince = since
                        persist(userId)
                    }
                    break
                }
                failures.append(PendingChange.failureMessage(for: entry.change, error: error))
                LoamErrorCapture.capture("offline.sync_failed")
            }
            guard self.userId == userId else { break }
            changes.removeAll { $0.id == entry.id }
            persist(userId)
        }

        if let first = failures.first {
            let message = failures.count == 1 ? first : "\(failures.count) offline changes couldn't sync. \(first)"
            notice = .failed(message)
            // A toast is missed while Loam is in the background.
            if !isActive() { await SyncNotifier.shared.postFailure(message, userId: userId) }
        } else if synced > 0 {
            notice = .synced(synced)
        }
        return synced
    }

    private func send(_ change: PendingChange, userId: UUID, wasInterrupted: Bool = false) async throws {
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
                    // A create cut off by iOS reached the server; anything changed since is newer than it.
                    if existing.hasSameContent(as: expense) || wasInterrupted {
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
            do {
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
            } catch let error as PostgrestError where error.code == "23505" {
                // Another attempt with the same operation id saved it at the same moment.
                return
            }
        }
    }

    /// Lost connections, cancelled requests, an expired session and a server that is briefly
    /// down or busy keep the change for the next try. Only a real refusal drops it.
    static func shouldRetryLater(_ error: Error) -> Bool {
        if Connectivity.isOfflineError(error) || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return true
        }
        if let error = error as? HTTPError {
            let status = error.response.statusCode
            return status == 401 || status == 408 || status == 429 || status >= 500
        }
        if error is AuthError { return true }
        if let error = error as? PostgrestError {
            // No code: a gateway or rate limit answered, not the database.
            guard let code = error.code else { return true }
            // PGRST0xx: the API can't reach the database; PGRST3xx: the session's token;
            // 08, 53, 57: connection, resources, shutdown or timeout;
            // 40001 and 40P01: a clash with another write that succeeds on a retry.
            return code.hasPrefix("PGRST0") || code.hasPrefix("PGRST3")
                || ["08", "53", "57"].contains(String(code.prefix(2))) || code == "40001" || code == "40P01"
        }
        return false
    }

    /// How long the server may keep failing a change before it is dropped with a message,
    /// so one change can't hold up everything behind it for good.
    static let retryLimit: TimeInterval = 24 * 60 * 60

    /// The server answered, or failed to, rather than the connection, the session or a cancellation.
    private static func isServerFailure(_ error: Error) -> Bool {
        if Connectivity.isOfflineError(error) || error is CancellationError || error is AuthError { return false }
        if let error = error as? URLError { return error.code != .cancelled }
        if let status = (error as? HTTPError)?.response.statusCode { return status != 401 }
        if let code = (error as? PostgrestError)?.code { return !code.hasPrefix("PGRST3") }
        return true
    }

    private func hasRetriedTooLong(_ entry: PendingChangeEntry, after error: Error) -> Bool {
        guard Self.isServerFailure(error), let since = entry.retryingSince else { return false }
        return Date().timeIntervalSince(since) > Self.retryLimit
    }

    /// Changes still on the device: queued, or being sent right now.
    func waitingCount(for userId: UUID) -> Int {
        load(userId)
        return changes.count + inFlight.values.filter { $0.userId == userId }.count
    }

    private func load(_ userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        signedOutIds.remove(userId)
        savedVersions = [:]
        changes = OfflineCache.load([PendingChangeEntry].self, key: OfflineCache.pendingChangesKey, userId: userId) ?? []
        recoverInterruptedSends(userId)
    }

    /// Changes whose send was cut off, by iOS ending Loam or a crash, join the queue in the order
    /// they were made. Ones still being sent in this launch are left to finish.
    private func recoverInterruptedSends(_ userId: UUID) {
        let running = Set(inFlight.values.filter { $0.userId == userId }.map(\.entry.id))
        let saved = OfflineCache.load([PendingChangeEntry].self, key: OfflineCache.inFlightKey, userId: userId) ?? []
        let queued = Set(changes.map(\.change))
        let interrupted = saved.filter { !running.contains($0.id) && !queued.contains($0.change) }.map { entry in
            var entry = entry
            entry.wasInterrupted = true
            return entry
        }
        guard !saved.isEmpty else { return }
        // They went straight to the server, so nothing queued for the same expense came first.
        changes = interrupted + changes
        persist(userId)
        persistInFlight(userId)
    }

    private func persistInFlight(_ userId: UUID) {
        let entries = inFlight.values.filter { $0.userId == userId }.map(\.entry).sorted { $0.queuedAt < $1.queuedAt }
        if entries.isEmpty {
            OfflineCache.remove(key: OfflineCache.inFlightKey, userId: userId)
        } else {
            OfflineCache.save(entries, key: OfflineCache.inFlightKey, userId: userId)
        }
    }

    private func persist(_ userId: UUID) {
        if changes.isEmpty {
            OfflineCache.remove(key: OfflineCache.pendingChangesKey, userId: userId)
            // Nothing is waiting any more, so a "not synced yet" reminder would be wrong.
            if !inFlight.values.contains(where: { $0.userId == userId }) { SyncNotifier.shared.clearWaitingReminder() }
        } else {
            OfflineCache.save(changes, key: OfflineCache.pendingChangesKey, userId: userId)
        }
    }
}
