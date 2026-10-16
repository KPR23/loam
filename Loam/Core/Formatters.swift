import Foundation

enum MoneyFormatter {
    /// Amount with its currency symbol where that currency usually puts it, e.g. `$12.50`,
    /// `€12.50` or `12.50 zł`. Only the digits follow `locale`: its own currency format would
    /// read `12,50 US$` or `12,50 USD` in Poland.
    static func string(from money: Money, locale: Locale = .current) -> String {
        let amount = decimalAmount(
            from: Money(amountMinor: abs(money.amountMinor), currencyCode: money.currencyCode),
            locale: locale,
            minimumFractionDigits: nil
        )
        let sign = money.amountMinor < 0 ? "-" : ""
        switch money.currencyCode {
        case "USD": return "\(sign)$\(amount)"
        case "EUR": return "\(sign)€\(amount)"
        case "PLN": return "\(sign)\(amount) zł"
        default: return "\(sign)\(amount) \(money.currencyCode)"
        }
    }

    /// Hero amount without a currency suffix, e.g. `250` or `250,40`.
    static func heroAmount(from money: Money, locale: Locale = .current) -> String {
        decimalAmount(from: money, locale: locale, minimumFractionDigits: nil)
    }

    /// Live typing display — no trailing zeros, e.g. `25,8` instead of `25,80`.
    static func typingAmount(from money: Money, locale: Locale = .current) -> String {
        decimalAmount(from: money, locale: locale, minimumFractionDigits: 0)
    }

    /// Seed for editable amount fields, in the exact form `Money.sanitizeTypingInput`
    /// produces, e.g. `1234,5`. Never grouped, so it parses back to the same amount.
    static func editableAmount(from money: Money) -> String {
        let major = money.amountMinor / 100
        let fraction = money.amountMinor % 100
        switch fraction {
        case 0: return "\(major)"
        case let tens where tens % 10 == 0: return "\(major),\(tens / 10)"
        default: return "\(major),\(String(format: "%02d", fraction))"
        }
    }

    private static func decimalAmount(
        from money: Money,
        locale: Locale,
        minimumFractionDigits: Int?
    ) -> String {
        let major = NSDecimalNumber(value: money.amountMinor).dividing(by: NSDecimalNumber(value: 100))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = true
        let fractionDigits = fractionDigits(for: money.amountMinor)
        if let minimumFractionDigits {
            formatter.minimumFractionDigits = minimumFractionDigits
            formatter.maximumFractionDigits = 2
        } else {
            formatter.minimumFractionDigits = fractionDigits.min
            formatter.maximumFractionDigits = fractionDigits.max
        }
        return formatter.string(from: major) ?? "0"
    }

    private static func fractionDigits(for amountMinor: Int) -> (min: Int, max: Int) {
        amountMinor % 100 == 0 ? (0, 0) : (2, 2)
    }
}

/// A calendar month in the app's selected time zone, matching how `spentAt` days are stored.
enum DatePeriod: Equatable {
    case month(year: Int, month: Int)

    static var currentMonth: DatePeriod {
        let calendar = AppPreferences.calendar
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let year = components.year ?? calendar.component(.year, from: now)
        let month = components.month ?? calendar.component(.month, from: now)
        return .month(year: year, month: month)
    }

    init(from date: Date) {
        let calendar = AppPreferences.calendar
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? calendar.component(.year, from: date)
        let month = components.month ?? calendar.component(.month, from: date)
        self = .month(year: year, month: month)
    }

    var anchorDate: Date {
        switch self {
        case let .month(year, month):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = 1
            return AppPreferences.calendar.date(from: components) ?? Date()
        }
    }

    static func startOfMonth(for date: Date) -> Date {
        DatePeriod(from: date).anchorDate
    }

    var displayTitle: String {
        switch self {
        case let .month(year, month):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = 1
            let date = AppPreferences.calendar.date(from: components) ?? Date()
            let formatter = DateFormatter()
            formatter.timeZone = AppPreferences.timeZone
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
            let calendar = AppPreferences.calendar
            let start = calendar.date(from: startComponents)!
            let endExclusive = calendar.date(byAdding: .month, value: 1, to: start)!
            return (start, endExclusive)
        }
    }
}
