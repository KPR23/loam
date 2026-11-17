import Foundation

/// A card payment as the Shortcuts "Transaction" automation hands it over: Wallet gives the
/// merchant and the amount with its currency code. Either can arrive empty, and the amount as zero.
struct WalletPayment: Equatable, Codable, Sendable {
    let money: Money
    let merchant: String?
    let category: ExpenseCategory
    let paidAt: Date

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
        let merchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
/// user can change later; anything unknown is Other.
enum MerchantCategory {
    /// Lowercased, accent-free fragments of merchant names. The first match wins.
    static let keywords: [(ExpenseCategory, [String])] = [
        (.groceries, ["zabka", "biedronka", "lidl", "auchan", "carrefour", "kaufland", "netto", "dino",
                      "stokrotka", "lewiatan", "aldi", "spar", "frisco", "delikatesy", "market", "grocer"]),
        (.dining, ["restaur", "bistro", "pizza", "kebab", "sushi", "burger", "mcdonald", "kfc", "starbucks",
                   "costa", "cafe", "kawiarnia", "coffee", "bar ", "pub", "wolt", "glovo", "pyszne", "uber eats"]),
        (.transport, ["uber", "bolt", "freenow", "free now", "taxi", "orlen", "shell", "bp ", "circle k",
                      "lotos", "moya", "pkp", "intercity", "koleje", "jakdojade", "ztm", "mpk", "parking", "skycash"]),
        (.health, ["apteka", "pharmacy", "gemini", "rossmann", "hebe", "lux med", "medicover", "enel-med"]),
        (.entertainment, ["cinema", "kino", "multikino", "helios", "spotify", "netflix", "steam", "playstation", "xbox"]),
        (.travel, ["hotel", "airbnb", "booking", "ryanair", "wizz", "lot polish", "airport", "lotnisko"]),
        (.utilities, ["orange", "play ", "plus ", "t-mobile", "pge", "tauron", "enea", "pgnig", "veolia"]),
        (.shopping, ["zara", "h&m", "reserved", "ikea", "media markt", "mediamarkt", "rtv euro", "empik",
                     "decathlon", "allegro", "amazon", "pepco", "castorama", "leroy merlin"]),
    ]

    static func guess(for merchant: String?) -> ExpenseCategory {
        guard let merchant else { return .other }
        // Padded so short keywords such as "bp " match at the end of a name too.
        let name = merchant.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l") + " "
        for (category, fragments) in keywords where fragments.contains(where: { name.contains($0) }) {
            return category
        }
        return .other
    }
}

/// What the notifications and Shortcuts say about a Wallet payment.
enum WalletPaymentText {
    static func title(_ payment: WalletPayment) -> String {
        "\(MoneyFormatter.string(from: payment.money)) · \(payment.merchant ?? payment.category.displayName)"
    }

    static func added(_ payment: WalletPayment) -> String {
        "Added to \(payment.category.displayName). Tap Undo if it wasn't yours."
    }

    static func askToAdd(_ payment: WalletPayment) -> String {
        "Add it to Loam as \(payment.category.displayName)?"
    }

    static func dialogAdded(_ payment: WalletPayment) -> String {
        "Added \(MoneyFormatter.string(from: payment.money)) for \(payment.merchant ?? payment.category.displayName)."
    }

    static let missingAmount = "Wallet didn't send the amount. Tap to add the expense yourself."
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
