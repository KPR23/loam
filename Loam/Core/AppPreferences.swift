import Foundation

enum AppPreferences {
    static let defaultCurrencyKey = "loam.defaultCurrency"
    static let timeZoneKey = "loam.timeZone"

    static let supportedCurrencies = ["PLN", "EUR", "USD"]

    static var defaultCurrencyCode: String {
        let saved = UserDefaults.standard.string(forKey: defaultCurrencyKey) ?? "PLN"
        return supportedCurrencies.contains(saved.uppercased()) ? saved.uppercased() : "PLN"
    }

    /// An empty identifier means follow the device's current time zone.
    static func timeZone(for identifier: String) -> TimeZone {
        guard !identifier.isEmpty, let zone = TimeZone(identifier: identifier) else {
            return .current
        }
        return zone
    }

    static var timeZone: TimeZone {
        timeZone(for: UserDefaults.standard.string(forKey: timeZoneKey) ?? "")
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func currencyName(_ code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code
    }

    static func timeZoneName(_ identifier: String) -> String {
        guard !identifier.isEmpty else { return "Device time zone" }
        return TimeZone(identifier: identifier)?.localizedName(for: .standard, locale: .current) ?? identifier
    }
}
