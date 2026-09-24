import XCTest
@testable import Loam

final class RecurringMaterializerTests: XCTestCase {
    private let owner = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let calendar = Calendar.current

    func testDailyDueDatesFromStartThroughToday() {
        let start = date(2026, 9, 10)
        let through = date(2026, 9, 13)
        let rule = makeRule(unit: .day, count: 1, next: start)

        let dates = RecurringMaterializer.dueDates(for: rule, through: through, calendar: calendar)

        XCTAssertEqual(dates, [
            date(2026, 9, 10),
            date(2026, 9, 11),
            date(2026, 9, 12),
            date(2026, 9, 13),
        ])
    }

    func testWeeklySkipsFutureOccurrences() {
        let rule = makeRule(unit: .week, count: 1, next: date(2026, 9, 1))
        let dates = RecurringMaterializer.dueDates(for: rule, through: date(2026, 9, 15), calendar: calendar)

        XCTAssertEqual(dates, [
            date(2026, 9, 1),
            date(2026, 9, 8),
            date(2026, 9, 15),
        ])
    }

    func testInactiveRuleYieldsNoDates() {
        var rule = makeRule(unit: .day, count: 1, next: date(2026, 9, 1))
        rule.isActive = false
        XCTAssertTrue(RecurringMaterializer.dueDates(for: rule, through: date(2026, 9, 10), calendar: calendar).isEmpty)
    }

    func testEndDateStopsFutureOccurrences() {
        let rule = makeRule(
            unit: .day,
            count: 1,
            next: date(2026, 9, 1),
            endDate: date(2026, 9, 3)
        )
        let dates = RecurringMaterializer.dueDates(for: rule, through: date(2026, 9, 10), calendar: calendar)

        XCTAssertEqual(dates, [
            date(2026, 9, 1),
            date(2026, 9, 2),
            date(2026, 9, 3),
        ])
    }

    func testSkippedDatesAreNotMaterialized() {
        var rule = makeRule(unit: .day, count: 1, next: date(2026, 9, 1))
        rule.skipOccurrence(on: date(2026, 9, 2))
        let dates = RecurringMaterializer.dueDates(for: rule, through: date(2026, 9, 4), calendar: calendar)

        XCTAssertEqual(dates, [
            date(2026, 9, 1),
            date(2026, 9, 3),
            date(2026, 9, 4),
        ])
    }

    func testMonthEndRuleStaysOnLastDayOfMonth() {
        let rule = makeRule(unit: .month, count: 1, next: date(2027, 1, 31))
        let dates = RecurringMaterializer.dueDates(for: rule, through: date(2027, 5, 31), calendar: calendar)

        XCTAssertEqual(dates, [
            date(2027, 1, 31),
            date(2027, 2, 28),
            date(2027, 3, 31),
            date(2027, 4, 30),
            date(2027, 5, 31),
        ])
        XCTAssertEqual(rule.nextOccurrence(after: date(2027, 5, 31), calendar: calendar), date(2027, 6, 30))
    }

    func testLeapDayYearlyRuleReturnsOnLeapYears() {
        let rule = makeRule(unit: .year, count: 1, next: date(2028, 2, 29))
        let dates = RecurringMaterializer.dueDates(for: rule, through: date(2032, 3, 1), calendar: calendar)

        XCTAssertEqual(dates, [
            date(2028, 2, 29),
            date(2029, 2, 28),
            date(2030, 2, 28),
            date(2031, 2, 28),
            date(2032, 2, 29),
        ])
    }

    func testDriftedNextOccurrenceSnapsToSchedule() {
        // Stored by the old stepping: Jan 31, Feb 28, then Mar 28.
        var rule = makeRule(unit: .month, count: 1, next: date(2027, 1, 31))
        rule.nextOccurrence = date(2027, 3, 28)
        let dates = RecurringMaterializer.dueDates(for: rule, through: date(2027, 4, 30), calendar: calendar)

        XCTAssertEqual(dates, [date(2027, 3, 31), date(2027, 4, 30)])
    }

    func testDefaultCalendarUsesSelectedPreferenceTimeZone() {
        let defaults = UserDefaults.standard
        let priorTimeZone = defaults.object(forKey: AppPreferences.timeZoneKey)
        defer {
            if let priorTimeZone {
                defaults.set(priorTimeZone, forKey: AppPreferences.timeZoneKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.timeZoneKey)
            }
        }
        defaults.set("Pacific/Kiritimati", forKey: AppPreferences.timeZoneKey)

        let calendar = AppPreferences.calendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let rule = makeRule(unit: .day, count: 1, next: start)
        let through = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))!

        XCTAssertEqual(RecurringMaterializer.dueDates(for: rule, through: through), [
            start,
            calendar.date(byAdding: .day, value: 1, to: start)!,
        ])
    }

    func testOccurrencePreservesRuleSplitWithoutHistoricalExpense() {
        let partner = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        var rule = makeRule(unit: .day, count: 1, next: date(2026, 9, 1))
        rule.amountMinor = 1000
        rule.title = "Internet"
        rule.shares = [ExpenseShareRecord(userId: owner, amountMinor: 600), ExpenseShareRecord(userId: partner, amountMinor: 400)]
        let occurrence = RecurringMaterializer.occurrenceExpense(
            rule: rule,
            spentAt: date(2026, 9, 2)
        )

        XCTAssertEqual(occurrence.amountMinor, 1000)
        XCTAssertEqual(occurrence.title, "Internet")
        XCTAssertEqual(occurrence.recurringId, rule.id)
        XCTAssertEqual(occurrence.spentAt, date(2026, 9, 2))
        XCTAssertEqual(occurrence.shares.map(\.amountMinor).sorted(), [400, 600])
    }

    private func makeRule(
        unit: RecurringIntervalUnit,
        count: Int,
        next: Date,
        endDate: Date? = nil
    ) -> RecurringRuleRecord {
        RecurringRuleRecord(
            ownerUserId: owner,
            amountMinor: 500,
            category: .other,
            intervalUnit: unit,
            intervalCount: count,
            startDate: next,
            endDate: endDate
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
