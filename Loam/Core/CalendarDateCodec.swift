import Foundation

enum CalendarDateCodec {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = AppPreferences.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.timeZone = AppPreferences.timeZone
        return formatter.string(from: AppPreferences.calendar.startOfDay(for: date))
    }

    static func date(from string: String) -> Date? {
        formatter.timeZone = AppPreferences.timeZone
        return formatter.date(from: string).map { AppPreferences.calendar.startOfDay(for: $0) }
    }
}
