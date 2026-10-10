import Foundation

@MainActor
final class BalanceStore: ObservableObject {
    @Published private(set) var snapshot = BalanceSnapshot.empty
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    private var accountId: UUID?

    func refresh(userId: UUID?) async {
        // Never show one account's balances to the next one on this device.
        if userId != accountId { snapshot = .empty; lastError = nil; accountId = userId }
        guard let userId else { return }
        isLoading = true; defer { isLoading = false }
        do {
            let fetched = try await BalanceRepositoryFactory.make().fetchBalances(for: userId)
            guard accountId == userId else { return }
            snapshot = fetched; lastError = nil
        } catch {
            // Leaving the tab cancels the load; that is not a failure.
            guard accountId == userId, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            lastError = error.localizedDescription
        }
    }

    /// Every shared expense and repayment between the viewer and one person, newest first.
    func history(with personId: UUID, userId: UUID) async throws -> [BalanceHistoryEntry] {
        try await BalanceRepositoryFactory.make().fetchHistory(for: userId, personId: personId)
    }

    func repay(to personId: UUID, amountMinor: Int, currencyCode: String, note: String?, paidAt: Date, userId: UUID) async throws {
        try await LoamErrorCapture.withCapture("balance.repayment_create_failed") {
            try await BalanceRepositoryFactory.make().createRepayment(from: userId, to: personId, amountMinor: amountMinor, currencyCode: currencyCode, note: note, paidAt: paidAt, operationId: UUID())
        }
        Telemetry.capture(.repaymentRecorded)
        await recordLocalRepayment(from: userId, to: personId, amountMinor: amountMinor, currencyCode: currencyCode, note: note)
        await refresh(userId: userId)
    }

    /// The backend records repayment activity itself; demo storage needs a local row.
    private func recordLocalRepayment(from userId: UUID, to personId: UUID, amountMinor: Int, currencyCode: String, note: String?) async {
        guard ExpenseRepositoryFactory.usesLocalStorage else { return }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let event = ActivityEvent(
            kind: .repaymentRecorded,
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
