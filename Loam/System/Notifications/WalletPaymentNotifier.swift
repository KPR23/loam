import UIKit
import UserNotifications

/// Local notifications for payments a Wallet automation logged: "added, Undo?" or "add it?".
/// Their buttons run in the background, so answering never opens the app.
@MainActor
final class WalletPaymentNotifier {
    static let shared = WalletPaymentNotifier()

    enum Category {
        static let added = "loam.wallet.added"
        static let ask = "loam.wallet.ask"
        static let missingAmount = "loam.wallet.missingAmount"
        static let info = "loam.wallet.info"
    }

    enum Action {
        static let undo = "loam.wallet.undo"
        static let add = "loam.wallet.add"
    }

    private enum Key {
        static let payment = "wallet_payment"
        static let expenseId = "wallet_expense_id"
        static let userId = "user_id"
    }

    private var center: UNUserNotificationCenter { .current() }

    private init() {}

    /// Called at launch, before any of these notifications can be answered.
    nonisolated static var categories: Set<UNNotificationCategory> {
        // Unlocking first keeps someone holding a locked phone from changing expenses.
        let undo = UNNotificationAction(identifier: Action.undo, title: String(localized: "Undo"), options: [.destructive, .authenticationRequired])
        let add = UNNotificationAction(identifier: Action.add, title: String(localized: "Add"), options: [.authenticationRequired])
        return [
            UNNotificationCategory(identifier: Category.added, actions: [undo], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.ask, actions: [add], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.missingAmount, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.info, actions: [], intentIdentifiers: []),
        ]
    }

    func canNotify() async -> Bool {
        guard !LaunchEnvironment.isAutomatedTest else { return false }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    func postAdded(_ payment: WalletPayment, expenseId: UUID, userId: UUID) async {
        await post(
            category: Category.added,
            title: WalletPaymentText.title(payment),
            body: WalletPaymentText.added(payment),
            userInfo: [Key.expenseId: expenseId.uuidString, Key.userId: userId.uuidString]
        )
    }

    func postAsk(_ payment: WalletPayment, userId: UUID) async {
        guard let data = try? JSONEncoder().encode(payment), let json = String(data: data, encoding: .utf8) else { return }
        await post(
            category: Category.ask,
            title: WalletPaymentText.title(payment),
            body: WalletPaymentText.askToAdd(payment),
            userInfo: [Key.payment: json, Key.userId: userId.uuidString]
        )
    }

    func postMissingAmount(merchant: String?, userId: UUID) async {
        let merchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
        await post(
            category: Category.missingAmount,
            title: (merchant?.isEmpty == false ? merchant : nil) ?? String(localized: "Apple Pay payment"),
            body: WalletPaymentText.missingAmount,
            userInfo: [Key.userId: userId.uuidString]
        )
    }

    /// A payment Loam can't save, such as one in a currency it doesn't use.
    func postProblem(title: String, body: String, userId: UUID) async {
        await post(category: Category.info, title: title, body: body, userInfo: [Key.userId: userId.uuidString])
    }

    private func post(category: String, title: String, body: String, userInfo: [String: String]) async {
        guard await canNotify() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        content.sound = nil
        // Wallet already shows its own banner for the payment, so an added one stays quiet. One
        // that waits for an answer shows a banner, or the payment is easily missed.
        content.interruptionLevel = category == Category.added ? .passive : .active
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: - Answers

    /// True when the response was one of these notifications, handled or not.
    func handle(category: String, action: String, userInfo: [String: String]) async -> Bool {
        guard [Category.added, Category.ask, Category.missingAmount, Category.info].contains(category) else { return false }
        let services = AppServices.shared
        // A notification left from another account does nothing.
        guard let owner = userInfo[Key.userId].flatMap(UUID.init(uuidString:)),
              let userId = try? await services.signedInUserId(), owner == userId else { return true }

        switch (category, action) {
        case (Category.added, Action.undo):
            guard let id = userInfo[Key.expenseId].flatMap(UUID.init(uuidString:)) else { return true }
            if !(await services.expenseStore.deleteSaved(id: id, userId: userId)) {
                await postProblem(title: String(localized: "Couldn't undo"), body: String(localized: "Open Loam to delete the expense yourself."), userId: userId)
            }
        case (Category.ask, Action.add), (Category.ask, UNNotificationDefaultActionIdentifier):
            guard let json = userInfo[Key.payment],
                  let payment = try? JSONDecoder().decode(WalletPayment.self, from: Data(json.utf8)) else { return true }
            let id: UUID
            do {
                id = try await LogWalletPaymentIntent.save(payment, userId: userId)
            } catch {
                LoamErrorCapture.capture("wallet_payment.add_failed")
                if action == Action.add {
                    // Tapping this one opens a new expense to add by hand.
                    await postProblem(title: WalletPaymentText.title(payment), body: String(localized: "Couldn't add this payment. Tap to add it yourself."), userId: userId)
                } else {
                    services.expenseStore.lastError = UserFacingError.message(for: error)
                    services.navigator.pendingScreen = .newExpense
                }
                return true
            }
            if action == Action.add {
                await postAdded(payment, expenseId: id, userId: userId)
            } else {
                // Tapping the banner adds it too, and opens Expenses to adjust it.
                services.navigator.pendingScreen = .expenses
            }
        case (Category.missingAmount, UNNotificationDefaultActionIdentifier), (Category.info, UNNotificationDefaultActionIdentifier):
            services.navigator.pendingScreen = .newExpense
        case (Category.added, UNNotificationDefaultActionIdentifier):
            services.navigator.pendingScreen = .expenses
        default:
            break
        }
        // Answered from a banner while Loam is open, so the list shows the change.
        if UIApplication.shared.applicationState == .active {
            await services.expenseStore.refresh(userId: userId)
        }
        return true
    }
}
