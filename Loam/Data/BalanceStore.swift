import Foundation

@MainActor
final class BalanceStore: ObservableObject {
    @Published private(set) var snapshot = BalanceSnapshot.empty
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    func refresh(userId: UUID?) async {
        guard let userId else { snapshot = .empty; return }
        isLoading = true; defer { isLoading = false }
        do { snapshot = try await BalanceRepositoryFactory.make().fetchBalances(for: userId); lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    func repay(to personId: UUID, amountMinor: Int, currencyCode: String, note: String?, paidAt: Date, userId: UUID) async throws {
        try await LoamErrorCapture.withCapture("balance.repayment_create_failed") {
            try await BalanceRepositoryFactory.make().createRepayment(from: userId, to: personId, amountMinor: amountMinor, currencyCode: currencyCode, note: note, paidAt: paidAt, operationId: UUID())
        }
        await refresh(userId: userId)
    }
}
