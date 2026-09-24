import XCTest
@testable import Loam

final class CalendarDateCodecTests: LocalStorageTestCase {
    func testRoundTrip() {
        let date = day(2026, 9, 7)
        XCTAssertEqual(CalendarDateCodec.string(from: date), "2026-09-07")
        XCTAssertEqual(CalendarDateCodec.date(from: "2026-09-07"), date)
    }

    func testRejectsNonCalendarStrings() {
        XCTAssertNil(CalendarDateCodec.date(from: ""))
        XCTAssertNil(CalendarDateCodec.date(from: "07.09.2026"))
        XCTAssertNil(CalendarDateCodec.date(from: "2026-09-07T10:00:00Z"))
    }

    func testUsesTheSelectedTimeZoneForTheCalendarDay() {
        // 23:30 UTC on Sep 7 is already Sep 8 in Kiritimati (UTC+14).
        let instant = ISO8601DateFormatter().date(from: "2026-09-07T23:30:00Z")!
        setTimeZonePreference("UTC")
        XCTAssertEqual(CalendarDateCodec.string(from: instant), "2026-09-07")
        setTimeZonePreference("Pacific/Kiritimati")
        XCTAssertEqual(CalendarDateCodec.string(from: instant), "2026-09-08")
    }
}

final class DatePeriodTests: LocalStorageTestCase {
    func testMonthRangeIsInclusiveStartExclusiveEnd() {
        let range = DatePeriod.month(year: 2026, month: 2).dateRange
        XCTAssertEqual(range.start, day(2026, 2, 1))
        XCTAssertEqual(range.endExclusive, day(2026, 3, 1))
    }

    func testDecemberRangeEndsInTheNextYear() {
        let range = DatePeriod.month(year: 2026, month: 12).dateRange
        XCTAssertEqual(range.endExclusive, day(2027, 1, 1))
    }

    func testPeriodFromDateAndStartOfMonth() {
        XCTAssertEqual(DatePeriod(from: day(2026, 9, 30)), .month(year: 2026, month: 9))
        XCTAssertEqual(DatePeriod.startOfMonth(for: day(2026, 9, 30)), day(2026, 9, 1))
    }

    /// Expenses are stored as days in the selected time zone, so the month
    /// filter must use the same calendar or month-edge expenses move months.
    func testMonthBoundariesFollowTheSelectedTimeZone() async throws {
        for zone in ["Pacific/Kiritimati", "Pacific/Honolulu"] {
            setTimeZonePreference(zone)
            let repository = LocalExpenseRepository()
            let firstOfMonth = personalExpense(1_00, spentAt: day(2026, 9, 1))
            let lastOfMonth = personalExpense(2_00, spentAt: day(2026, 8, 31))
            _ = try await repository.create(firstOfMonth)
            _ = try await repository.create(lastOfMonth)

            let september = try await repository.fetchExpenses(for: TestUser.alice, in: .month(year: 2026, month: 9))
            let august = try await repository.fetchExpenses(for: TestUser.alice, in: .month(year: 2026, month: 8))
            XCTAssertEqual(september.map(\.id), [firstOfMonth.id], zone)
            XCTAssertEqual(august.map(\.id), [lastOfMonth.id], zone)
            XCTAssertEqual(DatePeriod(from: firstOfMonth.spentAt), .month(year: 2026, month: 9), zone)

            try await repository.delete(id: firstOfMonth.id)
            try await repository.delete(id: lastOfMonth.id)
        }
    }
}

final class AppPreferencesTests: LocalStorageTestCase {
    func testUnsupportedOrMissingCurrencyFallsBackToPLN() {
        XCTAssertEqual(AppPreferences.defaultCurrencyCode, "PLN")
        UserDefaults.standard.set("eur", forKey: AppPreferences.defaultCurrencyKey)
        XCTAssertEqual(AppPreferences.defaultCurrencyCode, "EUR")
        UserDefaults.standard.set("GBP", forKey: AppPreferences.defaultCurrencyKey)
        XCTAssertEqual(AppPreferences.defaultCurrencyCode, "PLN")
    }

    func testUnknownTimeZoneFollowsTheDevice() {
        XCTAssertEqual(AppPreferences.timeZone(for: ""), .current)
        XCTAssertEqual(AppPreferences.timeZone(for: "Mars/Olympus_Mons"), .current)
        XCTAssertEqual(AppPreferences.timeZone(for: "Europe/Warsaw").identifier, "Europe/Warsaw")
    }
}
