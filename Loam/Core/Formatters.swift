import Foundation

enum MoneyFormatter {
    static func string(from money: Money, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = money.currencyCode
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2

        let major = NSDecimalNumber(value: money.amountMinor).dividing(by: NSDecimalNumber(value: 100))
        return formatter.string(from: major) ?? "\(money.amountMinor) \(money.currencyCode)"
    }

    /// Compact hero pair, e.g. `("250", "PLN")`. Whole złoty drop the fraction.
    static func heroParts(from money: Money, locale: Locale = .current) -> (amount: String, currency: String) {
        let major = NSDecimalNumber(value: money.amountMinor).dividing(by: NSDecimalNumber(value: 100))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = true
        if money.amountMinor % 100 == 0 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        } else {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        }
        let amount = formatter.string(from: major) ?? "0"
        return (amount, money.currencyCode)
    }
}

enum DatePeriod: Equatable {
    case month(year: Int, month: Int)

    static var currentMonth: DatePeriod {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        return .month(year: components.year!, month: components.month!)
    }

    var displayTitle: String {
        switch self {
        case let .month(year, month):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = 1
            let date = Calendar.current.date(from: components) ?? Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: date)
        }
    }

    /// Inclusive start / exclusive end as calendar dates (YYYY-MM-DD semantics).
    var dateRange: (start: Date, endExclusive: Date) {
        switch self {
        case let .month(year, month):
            var startComponents = DateComponents()
            startComponents.year = year
            startComponents.month = month
            startComponents.day = 1
            let start = Calendar.current.date(from: startComponents)!
            let endExclusive = Calendar.current.date(byAdding: .month, value: 1, to: start)!
            return (start, endExclusive)
        }
    }
}
