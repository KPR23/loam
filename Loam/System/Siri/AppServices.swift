import Foundation

/// The stores the screens and the Siri actions share. Siri can run an action while the app is in
/// the background, before any screen exists, so the stores live here rather than in a view.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let authSession = AuthSession()
    let expenseStore = ExpenseStore()
    let balanceStore = BalanceStore()
    let connectionStore = ConnectionStore()
    let navigator = AppNavigator()

    /// Replaces the friend lookup, so tests never reach the backend.
    var friendsOverride: [SplitPartnerOption]?

    private init() {}

    /// The signed-in account, after the launch sign-in check has finished.
    func signedInUserId() async throws -> UUID {
        await authSession.bootstrapIfNeeded()
        // An expired access token refreshes just after launch; give it a moment.
        if authSession.state != .signedIn, SupabaseClientProvider.shared != nil {
            for _ in 0..<30 where authSession.state != .signedIn {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard authSession.state == .signedIn, let userId = authSession.userId else {
            throw LoamIntentError.signedOut
        }
        return userId
    }

    /// The people this account can split with, the same list Add Expense offers.
    func friends(userId: UUID) async -> [SplitPartnerOption] {
        if let friendsOverride { return friendsOverride }
        if ExpenseRepositoryFactory.usesLocalStorage {
            #if DEBUG
            return SplitPartnerOption.available(for: userId, savedMainAccount: authSession.savedMainAccountPartnerOption)
            #else
            return SplitPartnerOption.available(for: userId)
            #endif
        }
        await connectionStore.refresh(userId: userId)
        return connectionStore.connections.filter { $0.userId != userId }
    }

    /// This month's totals, in the default currency.
    func currentMonthSummary(userId: UUID) async throws -> MonthSpendSummary {
        let period = DatePeriod.currentMonth
        // Refreshing the store also adds recurring expenses that came due, and keeps Home current.
        if expenseStore.period == period {
            await expenseStore.refresh(userId: userId)
            if expenseStore.lastError != nil { throw LoamIntentError.loadFailed }
            return expenseStore.summary
        }
        let expenses = try await ExpenseRepositoryFactory.make().fetchExpenses(for: userId, in: period)
        await ExchangeRateStore.shared.ensureRates(for: period)
        return ExpenseStore.makeSummary(expenses: expenses, userId: userId, rates: ExchangeRateStore.shared.rates)
    }

    func balances(userId: UUID) async throws -> BalanceSnapshot {
        try await BalanceRepositoryFactory.make().fetchBalances(for: userId)
    }

    /// Expenses other people added that still wait for this account's answer.
    func pendingExpenses(userId: UUID) async throws -> [ExpenseRecord] {
        try await ExpenseRepositoryFactory.make().fetchPendingAcceptance(for: userId)
    }
}

/// Screens a Siri action asked to show. The tab view consumes it once it is on screen.
@MainActor
final class AppNavigator: ObservableObject {
    @Published var pendingScreen: LoamScreen?
}
