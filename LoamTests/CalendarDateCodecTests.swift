import XCTest
@testable import Loam

final class CalendarDateCodecTests: XCTestCase {
    func testRoundTrip() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 7
        let date = Calendar.current.date(from: components)!
        let string = CalendarDateCodec.string(from: date)
        XCTAssertEqual(string, "2026-09-07")
        let parsed = CalendarDateCodec.date(from: string)
        XCTAssertEqual(Calendar.current.startOfDay(for: parsed!), Calendar.current.startOfDay(for: date))
    }
}
