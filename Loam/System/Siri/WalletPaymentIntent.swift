import AppIntents
import Foundation

/// How a Wallet payment reaches Loam.
enum WalletPaymentMode: String, AppEnum {
    /// Saves it straight away and posts a notification with Undo.
    case addNow
    /// Posts a notification with Add; nothing is saved until it's tapped. With notifications
    /// turned off it adds right away instead.
    case askFirst

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static var caseDisplayRepresentations: [WalletPaymentMode: DisplayRepresentation] = [
        .addNow: "Add right away",
        .askFirst: "Ask me first",
    ]
}

/// Meant for a Shortcuts "Transaction" automation: pass the Wallet transaction's Amount, its
/// Currency Code and the Merchant into this action, and turn on Run Immediately.
struct LogWalletPaymentIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Wallet Payment"
    static var description = IntentDescription(
        "Adds an Apple Pay payment to Loam as a personal expense. Use it in a Transaction automation and pass in the transaction's amount, currency code and merchant."
    )
    // Apple Pay often runs while the iPhone is still locked. This only adds an expense and
    // reads nothing back, so it doesn't need the device or App Lock unlocked.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Amount")
    var amount: Double?

    @Parameter(title: "Currency Code")
    var currencyCode: String?

    @Parameter(title: "Merchant")
    var merchant: String?

    @Parameter(title: "Category", description: "Leave empty to guess from the merchant.")
    var category: ExpenseCategory?

    @Parameter(title: "Mode", default: .addNow)
    var mode: WalletPaymentMode

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) \(\.$currencyCode) at \(\.$merchant)") {
            \.$mode
            \.$category
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let userId = try await services.signedInUserId()
        let notifier = WalletPaymentNotifier.shared

        // A refund arrives as a negative amount; it isn't an expense.
        if let amount, amount < 0 {
            return .result(dialog: "\(WalletPaymentText.refundSkipped)")
        }
        let payment: WalletPayment
        do {
            payment = try WalletPayment.make(
                amount: amount,
                currencyCode: currencyCode,
                merchant: merchant,
                category: category,
                paidAt: Date()
            )
        } catch let LoamIntentError.unsupportedCurrency(code) {
            let text = WalletPaymentText.unsupportedCurrency(code)
            await notifier.postProblem(title: merchant ?? "Apple Pay payment", body: text, userId: userId)
            return .result(dialog: "\(text)")
        } catch {
            // Wallet sometimes sends an empty amount; don't lose the payment, ask for it.
            await notifier.postMissingAmount(merchant: merchant, userId: userId)
            return .result(dialog: "\(WalletPaymentText.missingAmount)")
        }

        // Without notifications there's nobody to ask: a Run Immediately automation can't
        // show a prompt, so the payment is added rather than lost.
        if mode == .askFirst, await notifier.canNotify() {
            await notifier.postAsk(payment, userId: userId)
            return .result(dialog: "\(WalletPaymentText.askToAdd(payment))")
        }
        let id = try await Self.save(payment, userId: userId)
        await notifier.postAdded(payment, expenseId: id, userId: userId)
        return .result(dialog: "\(WalletPaymentText.dialogAdded(payment))")
    }

    @MainActor
    static func save(_ payment: WalletPayment, userId: UUID) async throws -> UUID {
        try await AppServices.shared.expenseStore.addPersonal(
            amountMinor: payment.money.amountMinor,
            currency: payment.money.currencyCode,
            category: payment.category,
            title: payment.merchant,
            note: nil,
            spentAt: payment.paidAt,
            userId: userId,
            reloads: false
        )
    }
}
