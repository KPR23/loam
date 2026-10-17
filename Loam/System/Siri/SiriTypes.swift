import AppIntents
import Foundation

extension ExpenseCategory: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Category"
    static var caseDisplayRepresentations: [ExpenseCategory: DisplayRepresentation] = [
        .groceries: "Groceries",
        .dining: "Dining",
        .transport: "Transport",
        .housing: "Housing",
        .utilities: "Utilities",
        .health: "Health",
        .entertainment: "Entertainment",
        .shopping: "Shopping",
        .travel: "Travel",
        .other: "Other",
    ]
}

/// Screens Siri can open.
enum LoamScreen: String, AppEnum {
    case expenses
    case newExpense
    case balances
    case activity
    case profile

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static var caseDisplayRepresentations: [LoamScreen: DisplayRepresentation] = [
        .expenses: "Expenses",
        .newExpense: "New Expense",
        .balances: "Balances",
        .activity: "Activity",
        .profile: "Profile",
    ]
}

/// Who paid whom when settling up.
enum RepaymentDirection: String, AppEnum {
    case iPaidThem
    case theyPaidMe

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static var caseDisplayRepresentations: [RepaymentDirection: DisplayRepresentation] = [
        .iPaidThem: "I paid them",
        .theyPaidMe: "They paid me",
    ]
}

/// Someone the account can split with.
struct LoamFriendEntity: AppEntity, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Friend"
    static var defaultQuery = LoamFriendQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(_ option: SplitPartnerOption) {
        self.init(id: option.userId, name: option.displayName)
    }
}

struct LoamFriendQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [LoamFriendEntity] {
        let wanted = Set(identifiers)
        return await Self.friends().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [LoamFriendEntity] {
        LoamFriendMatcher.matches(for: string, in: await Self.friends())
    }

    func suggestedEntities() async throws -> [LoamFriendEntity] {
        await Self.friends()
    }

    /// Signed out, there is nobody to suggest.
    @MainActor
    private static func friends() async -> [LoamFriendEntity] {
        let services = AppServices.shared
        guard let userId = try? await services.signedInUserId() else { return [] }
        return await services.friends(userId: userId)
            .map(LoamFriendEntity.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum LoamFriendMatcher {
    /// A full name, or any word of it, so "Julia" finds "Julia Nowak". Ignores case and accents.
    static func matches(for query: String, in friends: [LoamFriendEntity]) -> [LoamFriendEntity] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return friends }
        let exact = friends.filter { normalized($0.name) == needle }
        if !exact.isEmpty { return exact }
        let byWord = friends.filter { friend in
            normalized(friend.name).split(separator: " ").contains { $0 == needle }
        }
        if !byWord.isEmpty { return byWord }
        return friends.filter { normalized($0.name).contains(needle) }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LoamIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case signedOut
    case unsupportedCurrency(String)
    case invalidAmount
    case noFriend
    case loadFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut:
            "Open Loam and sign in first."
        case let .unsupportedCurrency(code):
            "Loam doesn't support \(code). Use złoty, euros or dollars."
        case .invalidAmount:
            "The amount has to be more than zero."
        case .noFriend:
            "That person isn't one of your friends in Loam."
        case .loadFailed:
            "Loam couldn't load your expenses. Try again in a moment."
        }
    }
}

/// Turns a spoken amount into stored minor units without going through `Double`.
enum SiriAmount {
    /// One billion in major units; anything above is a misheard number.
    static let maximumMinor = 100_000_000_000

    static func money(from amount: IntentCurrencyAmount) throws -> Money {
        try money(amount: amount.amount, currencyCode: amount.currencyCode)
    }

    static func money(amount: Decimal, currencyCode: String) throws -> Money {
        let code = currencyCode.uppercased()
        guard AppPreferences.supportedCurrencies.contains(code) else {
            throw LoamIntentError.unsupportedCurrency(code)
        }
        var scaled = amount * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded > 0, rounded <= Decimal(maximumMinor) else { throw LoamIntentError.invalidAmount }
        return Money(amountMinor: NSDecimalNumber(decimal: rounded).intValue, currencyCode: code)
    }
}

/// What settling up with someone should record, from what was said and the current balance.
enum RepaymentPlan: Equatable {
    case record(RepaymentDirection, Money)
    case settledUp
    /// Balances in several currencies, or nothing owed the way that was said; an amount is needed.
    case needsAmount
    case needsDirection

    /// `balances` are the ones with this friend. Positive means they owe the viewer.
    static func make(balances: [PersonBalance], amount: Money?, direction: RepaymentDirection?) -> RepaymentPlan {
        let open = balances.filter { $0.amountMinor != 0 }
        guard let amount else {
            guard !open.isEmpty else { return .settledUp }
            guard open.count == 1, let balance = open.first else { return .needsAmount }
            let owed: RepaymentDirection = balance.amountMinor > 0 ? .theyPaidMe : .iPaidThem
            if let direction, direction != owed { return .needsAmount }
            return .record(owed, Money(amountMinor: abs(balance.amountMinor), currencyCode: balance.currencyCode))
        }
        if let direction { return .record(direction, amount) }
        guard let balance = open.first(where: { $0.currencyCode.uppercased() == amount.currencyCode }) else {
            return .needsDirection
        }
        return .record(balance.amountMinor > 0 ? .theyPaidMe : .iPaidThem, amount)
    }
}

/// What Siri says back. Kept apart from the actions so it can be tested.
enum SiriText {
    static func expenseAdded(_ money: Money, category: ExpenseCategory, title: String?, splitWith friend: String?) -> String {
        let what = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? category.displayName
        let amount = MoneyFormatter.string(from: money)
        if let friend {
            return "Added \(amount) for \(what), split equally with \(friend). They'll be asked to accept it."
        }
        return "Added \(amount) for \(what)."
    }

    static func monthlySpending(_ summary: MonthSpendSummary, category: ExpenseCategory?) -> String {
        var text: String
        if let category {
            let amount = summary.categoryBreakdown.first { $0.category == .builtIn(category) }?.amountMinor ?? 0
            let money = Money(amountMinor: amount, currencyCode: summary.totalMine.currencyCode)
            text = "You've spent \(MoneyFormatter.string(from: money)) on \(category.displayName) this month."
        } else {
            text = "You've spent \(MoneyFormatter.string(from: summary.totalMine)) this month"
            if summary.sharedShare.amountMinor > 0 {
                text += ", including \(MoneyFormatter.string(from: summary.sharedShare)) as your share of split expenses"
            }
            text += "."
        }
        if summary.unconvertedCount > 0 {
            let noun = summary.unconvertedCount == 1 ? "expense" : "expenses"
            text += " \(summary.unconvertedCount) \(noun) in another currency aren't counted yet."
        }
        return text
    }

    static func balances(_ snapshot: BalanceSnapshot, friend: LoamFriendEntity?) -> String {
        if let friend {
            let lines = snapshot.balances
                .filter { $0.personId == friend.id && $0.amountMinor != 0 }
                .map { balanceLine($0, name: friend.name) }
            var text = lines.isEmpty ? "You and \(friend.name) are settled up." : lines.joined(separator: " ")
            let awaiting = snapshot.awaiting(from: friend.id)
            if !awaiting.isEmpty {
                let amounts = awaiting.map { MoneyFormatter.string(from: $0.money) }.joined(separator: " and ")
                text += " Another \(amounts) is waiting for \(friend.name) to accept."
            }
            return text
        }

        let open = snapshot.balances.filter { $0.amountMinor != 0 }
        guard !open.isEmpty else { return "You're all settled up." }
        let summary: String
        switch (snapshot.owedToYou.isEmpty, snapshot.youOwe.isEmpty) {
        case (false, false): summary = "You're owed \(join(snapshot.owedToYou)) and you owe \(join(snapshot.youOwe))."
        case (false, true): summary = "You're owed \(join(snapshot.owedToYou))."
        default: summary = "You owe \(join(snapshot.youOwe))."
        }
        let people = open
            .sorted { abs($0.amountMinor) > abs($1.amountMinor) }
            .prefix(5)
            .map { balanceLine($0, name: $0.displayName) }
        return ([summary] + people).joined(separator: " ")
    }

    static func repaymentPrompt(_ direction: RepaymentDirection, money: Money, friend: String) -> String {
        let amount = MoneyFormatter.string(from: money)
        switch direction {
        case .iPaidThem: return "Record that you paid \(friend) \(amount)?"
        case .theyPaidMe: return "Record that \(friend) paid you \(amount)?"
        }
    }

    static func repaymentRecorded(_ direction: RepaymentDirection, money: Money, friend: String) -> String {
        let amount = MoneyFormatter.string(from: money)
        switch direction {
        case .iPaidThem: return "Recorded that you paid \(friend) \(amount)."
        case .theyPaidMe: return "Recorded that \(friend) paid you \(amount)."
        }
    }

    static func pendingExpenses(_ expenses: [ExpenseRecord]) -> String {
        guard !expenses.isEmpty else { return "Nothing is waiting for your answer." }
        let noun = expenses.count == 1 ? "expense is" : "expenses are"
        var creators: [UUID] = []
        for expense in expenses where !creators.contains(expense.createdBy) {
            creators.append(expense.createdBy)
        }
        let names = SplitPartnerOption.displayNames(for: creators, fallback: "a friend")
        return "\(expenses.count) \(noun) waiting for your answer, from \(names). Open Activity in Loam to review them."
    }

    private static func balanceLine(_ balance: PersonBalance, name: String) -> String {
        let amount = MoneyFormatter.string(from: balance.money)
        return balance.amountMinor > 0 ? "\(name) owes you \(amount)." : "You owe \(name) \(amount)."
    }

    private static func join(_ amounts: [Money]) -> String {
        amounts.map { MoneyFormatter.string(from: $0) }.joined(separator: " and ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
