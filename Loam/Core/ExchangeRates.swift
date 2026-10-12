import Foundation

/// Daily ECB reference rates, quoted per 1 EUR. An expense converts at the rate
/// of the day it was spent, so newer rates never change older totals.
struct ExchangeRates: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` → currency → units per 1 EUR.
    var days: [String: [String: Double]] = [:]
    /// `yyyy-MM` → when that month's rates were last downloaded.
    var fetchedAt: [String: Date] = [:]

    static let empty = ExchangeRates()

    /// Converts minor units at the rate of `date`, or of the closest earlier day:
    /// the ECB publishes nothing on weekends and holidays. Nil until rates for that time are loaded:
    /// an earlier day's rate only stands in once the date's month has been downloaded, or a later
    /// rate shows nothing was published in between, and never from more than `fallbackDays` before.
    func convert(_ amountMinor: Int, from source: String, to target: String, on date: Date, calendar: Calendar) -> Int? {
        let from = source.uppercased()
        let to = target.uppercased()
        if from == to { return amountMinor }
        let day = Self.dayKey(for: date, calendar: calendar)
        let earliest = calendar.date(byAdding: .day, value: -Self.fallbackDays, to: date).map { Self.dayKey(for: $0, calendar: calendar) } ?? day
        guard fetchedAt[String(day.prefix(7))] != nil || days.keys.contains(where: { $0 > day }),
              let key = days.keys.filter({ $0 <= day }).max(),
              key >= earliest,
              let table = days[key],
              let fromRate = from == "EUR" ? 1.0 : table[from],
              let toRate = to == "EUR" ? 1.0 : table[to],
              fromRate > 0
        else { return nil }
        return Int((Double(amountMinor) * toRate / fromRate).rounded())
    }

    /// Longer than any run of ECB closing days (Easter is four), shorter than a missing month.
    static let fallbackDays = 7

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

/// Downloads rates from Frankfurter (ECB data, no key) a month at a time and keeps
/// them on disk. Past months are fetched once; the current month at most a few
/// times a day, since the ECB publishes one rate per working day.
@MainActor
final class ExchangeRateStore: ObservableObject {
    static let shared = ExchangeRateStore()

    @Published private(set) var rates: ExchangeRates

    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    /// Covers a month that starts on a weekend or holiday with the last earlier rate.
    private static let leadDays = 7
    private var inFlight: Set<String> = []

    private init() {
        rates = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode(ExchangeRates.self, from: $0) } ?? .empty
    }

    /// Makes sure `period` can be converted. Fails quietly: totals just leave out what can't be converted yet.
    func ensureRates(for period: DatePeriod, now: Date = Date()) async {
        let calendar = AppPreferences.calendar
        let monthStart = period.anchorDate
        guard monthStart <= now,
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let start = calendar.date(byAdding: .day, value: -Self.leadDays, to: monthStart)
        else { return }
        let monthKey = String(ExchangeRates.dayKey(for: monthStart, calendar: calendar).prefix(7))
        if let fetched = rates.fetchedAt[monthKey],
           fetched >= nextMonth || now.timeIntervalSince(fetched) < Self.refreshInterval {
            return
        }
        guard inFlight.insert(monthKey).inserted else { return }
        defer { inFlight.remove(monthKey) }

        let end = min(calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? now, now)
        let range = "\(ExchangeRates.dayKey(for: start, calendar: calendar))..\(ExchangeRates.dayKey(for: end, calendar: calendar))"
        let symbols = AppPreferences.supportedCurrencies.filter { $0 != "EUR" }.joined(separator: ",")
        guard let url = URL(string: "https://api.frankfurter.dev/v1/\(range)?base=EUR&symbols=\(symbols)") else { return }

        struct Response: Decodable { let rates: [String: [String: Double]] }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            var updated = rates
            updated.days.merge(decoded.rates) { _, new in new }
            updated.fetchedAt[monthKey] = now
            rates = updated
            if let data = try? JSONEncoder().encode(updated) {
                try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: Self.fileURL, options: .atomic)
            }
        } catch {
            // Offline or rate-limited: the next refresh tries again.
        }
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exchange-rates.json")
    }
}
