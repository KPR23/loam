import Foundation

@MainActor
final class BalanceStore: ObservableObject {
    @Published private(set) var snapshot = BalanceSnapshot.empty
    @Published private(set) var isLoading = false
    @Published var lastError: String? {
        // Every failure reaches the person as a toast, wherever they are in the app.
        didSet { if let lastError { ToastCenter.shared.showError(lastError) } }
    }
    private var accountId: UUID?
    /// Keeps repayments made offline until they sync; tests use their own.
    var sync: OfflineSync = .shared

    private static let cacheKey = "balances"

    func refresh(userId: UUID?) async {
        // Never show one account's balances to the next one on this device.
        if userId != accountId { snapshot = .empty; lastError = nil; accountId = userId }
        guard let userId else { return }
        isLoading = true; defer { isLoading = false }
        // Repayments made offline go first, so the balances below include them.
        await sync.flush(userId: userId)
        guard !sync.isEnabled() || sync.isOnline() else { return showSavedCopy(userId: userId) }
        do {
            let fetched = try await BalanceRepositoryFactory.make().fetchBalances(for: userId)
            guard accountId == userId else { return }
            snapshot = fetched; lastError = nil
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
            return history
        } catch where sync.isEnabled() && Connectivity.isOfflineError(error) {
            guard let saved = OfflineCache.load([BalanceHistoryEntry].self, key: key, userId: userId) else { throw error }
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
            try await send()
            return true
        } catch where sync.isEnabled() && Connectivity.isOfflineError(error) {
            sync.enqueue(change, userId: userId)
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
            actorName: SplitPartnerOption.displayName(for: userId, fallback: "You"),
            recipientId: personId,
            recipientName: SplitPartnerOption.displayName(for: personId),
            expenseTitle: trimmedNote.isEmpty ? "Repayment" : trimmedNote,
            category: .other,
            affectedShareMinor: amountMinor,
            expenseTotalMinor: amountMinor,
            currency: currencyCode
        )
        try? await ActivityRepositoryFactory.make().record(event, audience: [userId, personId])
    }
}
