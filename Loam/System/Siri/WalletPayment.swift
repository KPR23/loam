import Foundation

/// A card payment as the Shortcuts "Transaction" automation hands it over: Wallet gives the
/// merchant and the amount with its currency code. Either can arrive empty, and the amount as zero.
struct WalletPayment: Equatable, Codable, Sendable {
    let money: Money
    let merchant: String?
    let category: ExpenseCategory
    /// Set when the payment is filed under one of the member's own categories; `category` is `.other` then.
    var customCategory: CustomCategory? = nil
    let paidAt: Date

    var spendCategory: SpendCategory {
        customCategory.map(SpendCategory.custom) ?? .builtIn(category)
    }

    /// The same payment filed under `category`.
    func filed(under category: SpendCategory) -> WalletPayment {
        WalletPayment(money: money, merchant: merchant, category: category.builtInCategory, customCategory: category.customCategory, paidAt: paidAt)
    }

    /// Nil when Wallet sent no usable amount, so the caller asks the user instead of guessing.
    static func make(
        amount: Double?,
        currencyCode: String?,
        merchant: String?,
        category: ExpenseCategory?,
        paidAt: Date
    ) throws -> WalletPayment {
        guard let amount, amount.isFinite, amount > 0 else { throw LoamIntentError.invalidAmount }
        let code = currency(from: currencyCode)
        // Through the string, so 12.3 stays 12.30 and never becomes 12.29999.
        let decimal = Decimal(string: String(amount), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(amount)
        let money = try SiriAmount.money(amount: decimal, currencyCode: code)
        let raw = merchant?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // A known chain gets its clean name, so "LIDL SP. Z O.O. 123" is saved as "Lidl".
        let merchant = MerchantBrand.match(raw)?.name ?? raw
        return WalletPayment(
            money: money,
            merchant: merchant,
            category: category ?? MerchantCategory.guess(for: merchant),
            paidAt: paidAt
        )
    }

    /// Wallet sends an ISO code; a symbol or nothing at all falls back to the default currency.
    static func currency(from raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed.lowercased() {
        case "": return AppPreferences.defaultCurrencyCode
        case "zł", "zl", "pln": return "PLN"
        case "€", "eur": return "EUR"
        case "$", "us$", "usd": return "USD"
        default: return trimmed.uppercased()
        }
    }
}

/// Picks a category from the merchant's name. Wallet only gives the name, so this is a guess the
/// user can change later: a known chain's category first (`MerchantBrand`), then generic words
/// like "restauracja" or "apteka"; anything unknown is Other.
enum MerchantCategory {
    /// Lowercased, accent-free words for places that aren't one chain. A keyword matches whole
    /// words of the name, in order; its last word may also start a longer one when it has five or
    /// more letters ("restaur" matches "Restauracja", but "spar" doesn't match "Sparkasse"). The
    /// first match wins, so specific words come before generic ones.
    static let keywords: [(ExpenseCategory, [String])] = [
        (.dining, ["restaur", "bistro", "pizza", "pizzeria", "kebab", "sushi", "burger", "cafe", "kawiarnia",
                   "coffee", "piekarnia", "cukiernia", "bar", "pub"]),
        (.groceries, ["delikatesy", "supermarket", "grocer", "warzywniak"]),
        (.transport, ["taxi", "koleje", "pkp", "ztm", "mpk", "parking", "stacja paliw"]),
        (.health, ["apteka", "pharmacy", "przychodnia", "dentyst"]),
        (.entertainment, ["cinema", "kino"]),
        (.travel, ["hotel", "hostel", "airport", "lotnisko"]),
    ]

    static func guess(for merchant: String?) -> ExpenseCategory {
        if let brand = MerchantBrand.match(merchant) { return brand.category }
        guard let merchant else { return .other }
        let name = words(merchant)
        for (category, phrases) in keywords where phrases.contains(where: { matches(words($0), in: name) }) {
            return category
        }
        return .other
    }

    /// Lowercased, accent-free words, split on anything that isn't a letter or digit.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func matches(_ keyword: [String], in name: [String]) -> Bool {
        guard !keyword.isEmpty, keyword.count <= name.count else { return false }
        for start in 0...(name.count - keyword.count) {
            let found = keyword.indices.allSatisfy { index in
                let word = name[start + index]
                let wanted = keyword[index]
                if word == wanted { return true }
                return index == keyword.count - 1 && wanted.count >= 5 && word.hasPrefix(wanted)
            }
            if found { return true }
        }
        return false
    }
}

/// What the notifications and Shortcuts say about a Wallet payment.
enum WalletPaymentText {
    static func title(_ payment: WalletPayment) -> String {
        "\(MoneyFormatter.string(from: payment.money)) · \(payment.merchant ?? payment.spendCategory.displayName)"
    }

    static func added(_ payment: WalletPayment) -> String {
        "Added to \(payment.spendCategory.displayName). Tap Undo if it wasn't yours."
    }

    static func askToAdd(_ payment: WalletPayment) -> String {
        "Add it to Loam as \(payment.spendCategory.displayName)?"
    }

    static func dialogAdded(_ payment: WalletPayment) -> String {
        "Added \(MoneyFormatter.string(from: payment.money)) for \(payment.merchant ?? payment.spendCategory.displayName)."
    }

    static let missingAmount = "Wallet didn't send the amount. Tap to add the expense yourself."

    static let refundSkipped = "That was a refund, so nothing was added."

    static func unsupportedCurrency(_ code: String) -> String {
        "Loam can't save payments in \(code) yet. Tap to add it in złoty, euros or dollars."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
