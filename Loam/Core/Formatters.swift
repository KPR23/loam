import Foundation

enum MoneyFormatter {
    static func string(from money: Money, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = money.currencyCode
        formatter.locale = locale
        let fractionDigits = fractionDigits(for: money.amountMinor)
        formatter.minimumFractionDigits = fractionDigits.min
        formatter.maximumFractionDigits = fractionDigits.max

        let major = NSDecimalNumber(value: money.amountMinor).dividing(by: NSDecimalNumber(value: 100))
        return formatter.string(from: major) ?? "\(money.amountMinor) \(money.currencyCode)"
    }

    /// Hero amount without a currency suffix, e.g. `250` or `250,40`.
    static func heroAmount(from money: Money, locale: Locale = .current) -> String {
        let major = NSDecimalNumber(value: money.amountMinor).dividing(by: NSDecimalNumber(value: 100))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = true
        let fractionDigits = fractionDigits(for: money.amountMinor)
        formatter.minimumFractionDigits = fractionDigits.min
        formatter.maximumFractionDigits = fractionDigits.max
        return formatter.string(from: major) ?? "0"
    }

    private static func fractionDigits(for amountMinor: Int) -> (min: Int, max: Int) {
        amountMinor % 100 == 0 ? (0, 0) : (2, 2)
    }
}

enum DatePeriod: Equatable {
    case month(year: Int, month: Int)

    static var currentMonth: DatePeriod {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let year = components.year ?? calendar.component(.year, from: now)
        let month = components.month ?? calendar.component(.month, from: now)
        return .month(year: year, month: month)
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
