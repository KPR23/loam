import Foundation

@MainActor
final class BalanceStore: ObservableObject {
    @Published private(set) var snapshot = BalanceSnapshot.empty
    @Published private(set) var isLoading = false
    /// Whether the first load for this account has finished, so views show a placeholder rather
    /// than an empty state in the gap before it starts and while it runs.
    @Published private(set) var hasLoaded = false
    @Published var lastError: String? {
        // Every failure reaches the person as a toast, wherever they are in the app.
        didSet { if let lastError { ToastCenter.shared.showError(lastError) } }
    }
    private var accountId: UUID?
    /// Keeps repayments made offline until they sync; tests use their own.
    var sync: OfflineSync = .shared

    private static let cacheKey = "balances"

    /// Loads once per account; later visits keep what is on screen until a pull to refresh.
    func loadIfNeeded(userId: UUID?) async {
        guard !(hasLoaded && accountId == userId && !isStale) else { return }
        await refresh(userId: userId)
    }

    /// A person's history as last loaded in this run, shown at once while a newer one loads.
    func cachedHistory(with personId: UUID) -> [BalanceHistoryEntry]? { historyCache[personId] }
    private var historyCache: [UUID: [BalanceHistoryEntry]] = [:]
    private var staleHistoryIds: Set<UUID> = []
    /// Set when expenses changed since the balances loaded; the next visit loads them again, with the old ones still showing.
    private var staleEpoch = 0
    private var loadedEpoch = 0
    private var isStale: Bool { staleEpoch != loadedEpoch }

    /// Expenses changed (an edit, an accepted share), so balances and histories are out of date.
    func markStale() {
        guard hasLoaded else { return }
        staleEpoch += 1
        staleHistoryIds = Set(historyCache.keys)
    }

    func isHistoryStale(for personId: UUID) -> Bool { staleHistoryIds.contains(personId) }

    func refresh(userId: UUID?) async {
        // Never show one account's balances to the next one on this device.
        if userId != accountId { snapshot = .empty; hasLoaded = false; lastError = nil; accountId = userId; historyCache = [:] }
        guard let userId else { return }
        isLoading = true
        let epoch = staleEpoch
        // A load cancelled by leaving the tab hasn't finished, so the placeholder stays for the next one.
        defer { isLoading = false; if accountId == userId, !Task.isCancelled { hasLoaded = true } }
        // Repayments made offline go first, so the balances below include them.
        await sync.flush(userId: userId)
        guard !sync.isEnabled() || sync.isOnline() else { return showSavedCopy(userId: userId) }
        do {
            let fetched = try await BalanceRepositoryFactory.make().fetchBalances(for: userId)
            guard accountId == userId else { return }
            snapshot = fetched; lastError = nil
            // Only a finished load clears the flag; one cancelled by leaving the tab leaves it set.
            // Histories can have changed whether or not the totals did, so they load again on their next visit.
            loadedEpoch = epoch
            staleHistoryIds = Set(historyCache.keys)
            if sync.isEnabled() { OfflineCache.save(fetched, key: Self.cacheKey, userId: userId) }
        } catch where sync.isEnabled() && Connectivity.isOfflineError(error) {
            guard accountId == userId else { return }
            showSavedCopy(userId: userId)
        } catch {
            // Leaving the tab cancels the load; that is not a failure.
            guard accountId == userId, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            lastError = UserFacingError.message(for: error)
        }
    }

    /// Balances as last loaded. Repayments made offline count once they sync.
    private func showSavedCopy(userId: UUID) {
        if let saved = OfflineCache.load(BalanceSnapshot.self, key: Self.cacheKey, userId: userId) { snapshot = saved }
        lastError = nil
    }

    /// Every shared expense and repayment between the viewer and one person, newest first.
    func history(with personId: UUID, userId: UUID) async throws -> [BalanceHistoryEntry] {
        let key = "history-\(personId.uuidString.lowercased())"
        do {
            let history = try await BalanceRepositoryFactory.make().fetchHistory(for: userId, personId: personId)
            if sync.isEnabled() { OfflineCache.save(history, key: key, userId: userId) }
            if accountId == userId { historyCache[personId] = history; staleHistoryIds.remove(personId) }
            return history
        } catch where sync.isEnabled() && Connectivity.isOfflineError(error) {
            guard let saved = OfflineCache.load([BalanceHistoryEntry].self, key: key, userId: userId) else { throw error }
            if accountId == userId { historyCache[personId] = saved }
            return saved
        }
    }

    func repay(to personId: UUID, amountMinor: Int, currencyCode: String, note: String?, paidAt: Date, userId: UUID) async throws {
        let repayment = PendingRepayment(personId: personId, isReceived: false, amountMinor: amountMinor, currencyCode: currencyCode, note: note, paidAt: paidAt)
        let sent = try await sendOrQueue(repayment, userId: userId) {
            try await LoamErrorCapture.withCapture("balance.repayment_create_failed") {
                try await BalanceRepositoryFactory.make().createRepayment(from: userId, to: personId, amountMinor: amountMinor, currencyCode: currencyCode, note: note, paidAt: paidAt, operationId: repayment.operationId)
            }
        }
        Telemetry.capture(.repaymentRecorded)
        guard sent else { return }
        await recordLocalRepayment(kind: .repaymentRecorded, userId: userId, personId: personId, amountMinor: amountMinor, currencyCode: currencyCode, note: note)
        await refresh(userId: userId)
    }

    /// The viewer is owed money and records that `personId` paid them.
    func receive(from personId: UUID, amountMinor: Int, currencyCode: String, note: String?, paidAt: Date, userId: UUID) async throws {
        let repayment = PendingRepayment(personId: personId, isReceived: true, amountMinor: amountMinor, currencyCode: currencyCode, note: note, paidAt: paidAt)
        let sent = try await sendOrQueue(repayment, userId: userId) {
            try await LoamErrorCapture.withCapture("balance.repayment_create_failed") {
                try await BalanceRepositoryFactory.make().createReceivedRepayment(from: personId, to: userId, amountMinor: amountMinor, currencyCode: currencyCode, note: note, paidAt: paidAt, operationId: repayment.operationId)
            }
        }
        Telemetry.capture(.repaymentRecorded)
        guard sent else { return }
        await recordLocalRepayment(kind: .repaymentReceived, userId: userId, personId: personId, amountMinor: amountMinor, currencyCode: currencyCode, note: note)
        await refresh(userId: userId)
    }

    /// Records the repayment, or keeps it on the device when there's no connection. Its operation ID
    /// goes with it, so a retry after a lost answer can't record it twice. Returns false when kept.
    private func sendOrQueue(_ repayment: PendingRepayment, userId: UUID, send: () async throws -> Void) async throws -> Bool {
        let change = PendingChange.repayment(repayment)
        if sync.shouldQueue(change, userId: userId) {
            sync.enqueue(change, userId: userId)
            return false
        }
        do {
            // Kept on the device while it's sent, so leaving Loam mid-save can't lose it.
            try await sync.perform(change, userId: userId, send: send)
            return true
        } catch where sync.isEnabled() && OfflineSync.shouldRetryLater(error) {
            // No connection, or a server hiccup: kept on the device and sent again later.
            sync.enqueue(change, userId: userId, retrying: true)
            return false
        }
    }

    /// The backend records repayment activity itself; demo storage needs a local row.
    private func recordLocalRepayment(kind: ActivityEventKind, userId: UUID, personId: UUID, amountMinor: Int, currencyCode: String, note: String?) async {
        guard ExpenseRepositoryFactory.usesLocalStorage else { return }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let event = ActivityEvent(
            kind: kind,
            actorId: userId,
            actorName: SplitPartnerOption.displayName(for: userId, fallback: String(localized: "You")),
            recipientId: personId,
            recipientName: SplitPartnerOption.displayName(for: personId),
            expenseTitle: trimmedNote.isEmpty ? String(localized: "Repayment") : trimmedNote,
            category: .other,
            affectedShareMinor: amountMinor,
            expenseTotalMinor: amountMinor,
            currency: currencyCode
        )
        try? await ActivityRepositoryFactory.make().record(event, audience: [userId, personId])
    }
}
