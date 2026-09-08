import Foundation

enum CalendarDateCodec {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: Calendar.current.startOfDay(for: date))
    }

    static func date(from string: String) -> Date? {
        formatter.date(from: string).map { Calendar.current.startOfDay(for: $0) }
    }
}
