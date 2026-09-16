import XCTest
@testable import Loam

final class DatePeriodTests: XCTestCase {
    func testShiftedByMonthsNextAndPrevious() {
        let period = DatePeriod.month(year: 2026, month: 9)

        XCTAssertEqual(period.shiftedByMonths(1), .month(year: 2026, month: 10))
        XCTAssertEqual(period.shiftedByMonths(-1), .month(year: 2026, month: 8))
    }

    func testShiftedByMonthsCrossesYearBoundary() {
        let december = DatePeriod.month(year: 2025, month: 12)
        let january = DatePeriod.month(year: 2026, month: 1)

        XCTAssertEqual(december.shiftedByMonths(1), january)
        XCTAssertEqual(january.shiftedByMonths(-1), december)
    }

    func testShiftedByMonthsZeroIsIdentity() {
        let period = DatePeriod.month(year: 2026, month: 3)
        XCTAssertEqual(period.shiftedByMonths(0), period)
    }
}
