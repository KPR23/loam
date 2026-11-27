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
        amount: Decimal?,
        currencyCode: String?,
        merchant: String?,
        category: ExpenseCategory?,
        paidAt: Date
    ) throws -> WalletPayment {
        guard let amount, amount.isFinite, amount > 0 else { throw LoamIntentError.invalidAmount }
        let money = try SiriAmount.money(amount: amount, currencyCode: currency(from: currencyCode))
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
    /// Lowercased, accent-free merchant words. A keyword matches whole words of the name, in order;
    /// its last word may also start a longer one when it has five or more letters ("restaur"
    /// matches "Restauracja", but "spar" doesn't match "Sparkasse"). The first match wins, so
    /// specific names come before generic ones.
    static let keywords: [(ExpenseCategory, [String])] = [
        (.dining, ["uber eats", "wolt", "glovo", "pyszne", "restaur", "bistro", "pizza", "kebab", "sushi",
                   "burger", "mcdonald", "kfc", "starbucks", "costa coffee", "cafe", "kawiarnia", "coffee",
                   "bar", "pub"]),
        (.groceries, ["zabka", "biedronka", "lidl", "auchan", "carrefour", "kaufland", "netto", "dino",
                      "stokrotka", "lewiatan", "aldi", "spar", "frisco", "delikatesy", "supermarket", "grocer"]),
        (.transport, ["uber", "bolt", "freenow", "free now", "taxi", "orlen", "shell", "bp", "circle k",
                      "lotos", "moya", "pkp", "intercity", "koleje", "jakdojade", "ztm", "mpk", "parking", "skycash"]),
        (.health, ["apteka", "pharmacy", "rossmann", "hebe", "lux med", "medicover", "enel med"]),
        (.entertainment, ["cinema", "kino", "multikino", "helios", "spotify", "netflix", "steam", "playstation", "xbox"]),
        (.travel, ["hotel", "airbnb", "booking", "ryanair", "wizz", "airport", "lotnisko"]),
        (.utilities, ["orange", "t mobile", "pge", "tauron", "enea", "pgnig", "veolia"]),
        (.shopping, ["zara", "reserved", "ikea", "media markt", "mediamarkt", "rtv euro", "empik",
                     "decathlon", "allegro", "amazon", "pepco", "castorama", "leroy merlin"]),
    ]

    static func guess(for merchant: String?) -> ExpenseCategory {
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
        "\(MoneyFormatter.string(from: payment.money)) · \(payment.merchant ?? payment.category.displayName)"
    }

    static func added(_ payment: WalletPayment) -> String {
        String(localized: "Added to \(payment.category.displayName). Tap Undo if it wasn't yours.")
    }

    static func askToAdd(_ payment: WalletPayment) -> String {
        String(localized: "Add it to Loam as \(payment.category.displayName)?")
    }

    static func dialogAdded(_ payment: WalletPayment) -> String {
        String(localized: "Added \(MoneyFormatter.string(from: payment.money)) for \(payment.merchant ?? payment.category.displayName).")
    }

    static let missingAmount = String(localized: "Wallet didn't send the amount. Tap to add the expense yourself.")

    static let refundSkipped = String(localized: "That was a refund, so nothing was added.")

    static func unsupportedCurrency(_ code: String) -> String {
        String(localized: "Loam can't save payments in \(code) yet. Tap to add it in złoty, euros or dollars.")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
