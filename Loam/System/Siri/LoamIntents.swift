import AppIntents
import Foundation

struct AddExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Expense"
    static var description = IntentDescription("Adds an expense to Loam, just for you or split equally with a friend.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Amount", requestValueDialog: "How much was it?")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Category")
    var category: ExpenseCategory?

    @Parameter(title: "Title")
    var title: String?

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Split With")
    var friend: LoamFriendEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) for \(\.$category)") {
            \.$title
            \.$date
            \.$friend
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let userId = try await services.signedInUserId()
        // Shortcuts can hand over an empty amount in the region's currency; ask instead of failing.
        guard let money = try? SiriAmount.money(from: amount) else {
            throw $amount.needsValueError(SiriAmount.askAgain)
        }
        let category = category ?? .other
        let spentAt = date ?? Date()

        if let friend {
            guard await services.friends(userId: userId).contains(where: { $0.userId == friend.id }) else {
                throw services.friendsFailedToLoad ? LoamIntentError.loadFailed : LoamIntentError.noFriend
            }
            try await services.expenseStore.addSplit(
                amountMinor: money.amountMinor,
                currency: money.currencyCode,
                category: category,
                title: title,
                note: nil,
                spentAt: spentAt,
                userId: userId,
                splitMode: .equal,
                paidBy: userId,
                partnerUserIds: [friend.id]
            )
        } else {
            try await services.expenseStore.addPersonal(
                amountMinor: money.amountMinor,
                currency: money.currencyCode,
                category: category,
                title: title,
                note: nil,
                spentAt: spentAt,
                userId: userId
            )
        }
        let text = SiriText.expenseAdded(money, category: category, title: title, splitWith: friend?.name)
        return .result(dialog: "\(text)")
    }
}

struct GetMonthlySpendingIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Monthly Spending"
    static var description = IntentDescription("Tells you how much you've spent this month, in total or in one category.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Category")
    var category: ExpenseCategory?

    static var parameterSummary: some ParameterSummary {
        Summary("Get this month's spending on \(\.$category)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let userId = try await services.signedInUserId()
        let summary = try await services.currentMonthSummary(userId: userId)
        let text = SiriText.monthlySpending(summary, category: category)
        return .result(dialog: "\(text)")
    }
}

struct GetBalancesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Balances"
    static var description = IntentDescription("Tells you who owes whom, overall or with one friend.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Friend")
    var friend: LoamFriendEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get balances with \(\.$friend)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let userId = try await services.signedInUserId()
        let snapshot = try await services.balances(userId: userId)
        let text = SiriText.balances(snapshot, friend: friend)
        return .result(dialog: "\(text)")
    }
}

struct SettleUpIntent: AppIntent {
    static var title: LocalizedStringResource = "Settle Up"
    static var description = IntentDescription("Records a repayment with a friend. Without an amount, it settles what you owe each other.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Friend", requestValueDialog: "Who are you settling up with?")
    var friend: LoamFriendEntity

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount?

    @Parameter(title: "Direction")
    var direction: RepaymentDirection?

    static var parameterSummary: some ParameterSummary {
        Summary("Settle up with \(\.$friend)") {
            \.$amount
            \.$direction
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let userId = try await services.signedInUserId()
        var requested: Money?
        if let amount, amount.amount > 0 {
            guard let money = try? SiriAmount.money(from: amount) else {
                throw $amount.needsValueError(SiriAmount.askAgain)
            }
            requested = money
        }
        let snapshot = try await services.balances(userId: userId)
        let plan = RepaymentPlan.make(
            balances: snapshot.balances.filter { $0.personId == friend.id },
            amount: requested,
            direction: direction
        )
        switch plan {
        case .settledUp:
            return .result(dialog: "\(SiriText.balances(snapshot, friend: friend))")
        case .needsAmount:
            throw $amount.needsValueError("How much did you settle with \(friend.name)?")
        case .nothingToSettle:
            let text = "There's nothing to settle that way. \(SiriText.balances(snapshot, friend: friend))"
            return .result(dialog: "\(text)")
        case let .exceedsBalance(direction, balance):
            let text = SiriText.repaymentLimit(direction, balance: balance, friend: friend.name)
            throw $amount.needsValueError("\(text)")
        case let .record(direction, money):
            let prompt = SiriText.repaymentPrompt(direction, money: money, friend: friend.name)
            try await requestConfirmation(result: .result(dialog: "\(prompt)"), confirmationActionName: .log)
            try await Self.record(direction, money: money, with: friend.id, userId: userId)
            let text = SiriText.repaymentRecorded(direction, money: money, friend: friend.name)
            return .result(dialog: "\(text)")
        }
    }

    /// Records the repayment once confirmed, the same way the Balances screen does.
    @MainActor
    static func record(_ direction: RepaymentDirection, money: Money, with friendId: UUID, userId: UUID) async throws {
        let balanceStore = AppServices.shared.balanceStore
        switch direction {
        case .iPaidThem:
            try await balanceStore.repay(to: friendId, amountMinor: money.amountMinor, currencyCode: money.currencyCode, note: nil, paidAt: Date(), userId: userId)
        case .theyPaidMe:
            try await balanceStore.receive(from: friendId, amountMinor: money.amountMinor, currencyCode: money.currencyCode, note: nil, paidAt: Date(), userId: userId)
        }
    }
}

struct GetPendingExpensesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Pending Expenses"
    static var description = IntentDescription("Tells you how many split expenses are waiting for your answer.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let userId = try await services.signedInUserId()
        // Loads friends' names for the answer.
        _ = await services.friends(userId: userId)
        let pending = try await services.pendingExpenses(userId: userId)
        return .result(dialog: "\(SiriText.pendingExpenses(pending))")
    }
}

struct OpenLoamScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Screen"
    static var description = IntentDescription("Opens Loam on Expenses, a new expense, Balances, Activity or Profile.")
    static var openAppWhenRun = true

    @Parameter(title: "Screen", requestValueDialog: "Which screen?")
    var screen: LoamScreen

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$screen)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Signed out, the app opens on sign-in; don't jump to the screen after a later sign-in.
        guard (try? await AppServices.shared.signedInUserId()) != nil else { return .result() }
        AppServices.shared.navigator.pendingScreen = screen
        return .result()
    }
}

struct LoamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddExpenseIntent(),
            phrases: [
                "Add an expense in \(.applicationName)",
                "Add expense in \(.applicationName)",
                "Log an expense in \(.applicationName)",
                "Add a \(\.$category) expense in \(.applicationName)",
                "Split an expense with \(\.$friend) in \(.applicationName)",
            ],
            shortTitle: "Add Expense",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: GetMonthlySpendingIntent(),
            phrases: [
                "How much have I spent in \(.applicationName)",
                "How much did I spend this month in \(.applicationName)",
                "Check my spending in \(.applicationName)",
                "How much did I spend on \(\.$category) in \(.applicationName)",
            ],
            shortTitle: "Monthly Spending",
            systemImageName: "chart.pie"
        )
        AppShortcut(
            intent: GetBalancesIntent(),
            phrases: [
                "Check my balances in \(.applicationName)",
                "Who owes me in \(.applicationName)",
                "Who do I owe in \(.applicationName)",
                "What's my balance with \(\.$friend) in \(.applicationName)",
            ],
            shortTitle: "Balances",
            systemImageName: "person.2"
        )
        AppShortcut(
            intent: SettleUpIntent(),
            phrases: [
                "Settle up in \(.applicationName)",
                "Record a repayment in \(.applicationName)",
                "Settle up with \(\.$friend) in \(.applicationName)",
            ],
            shortTitle: "Settle Up",
            systemImageName: "arrow.left.arrow.right"
        )
        AppShortcut(
            intent: GetPendingExpensesIntent(),
            phrases: [
                "Do I have pending expenses in \(.applicationName)",
                "Check pending expenses in \(.applicationName)",
            ],
            shortTitle: "Pending Expenses",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: OpenLoamScreenIntent(),
            phrases: [
                "Open \(\.$screen) in \(.applicationName)",
                "Show \(\.$screen) in \(.applicationName)",
            ],
            shortTitle: "Open Screen",
            systemImageName: "rectangle.portrait.and.arrow.right"
        )
    }
}
