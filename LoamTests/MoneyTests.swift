import XCTest
@testable import Loam

final class MoneyTests: XCTestCase {
    func testParsesDotAndCommaDecimals() {
        XCTAssertEqual(Money(majorString: "12.34")?.amountMinor, 1234)
        XCTAssertEqual(Money(majorString: "12,5")?.amountMinor, 1250)
        XCTAssertEqual(Money(majorString: " 7 ")?.amountMinor, 700)
    }

    func testTrailingSeparatorMeansWholeUnits() {
        XCTAssertEqual(Money(majorString: "12,")?.amountMinor, 1200)
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(Money(majorString: ""))
        XCTAssertNil(Money(majorString: "1.234"))
        XCTAssertNil(Money(majorString: ",5"))
        XCTAssertNil(Money(majorString: "12a"))
        XCTAssertNil(Money(majorString: "12 zł"))
        XCTAssertNil(Money(majorString: "-12"))
        XCTAssertNil(Money(majorString: "12;34"))
        XCTAssertNil(Money(majorString: "1,234.50"))
    }

    func testRejectsAmountsTooLargeToStoreInsteadOfCrashing() {
        // 19 digits fit in Int, but not once converted to minor units.
        XCTAssertNil(Money(majorString: "9223372036854775807"))
        XCTAssertNil(Money(majorString: "92233720368547758,08"))
    }

    func testCurrencyCodeIsNormalized() {
        XCTAssertEqual(Money(amountMinor: 1, currencyCode: "eur").currencyCode, "EUR")
        XCTAssertEqual(Money(majorString: "1", currencyCode: "usd")?.currencyCode, "USD")
    }

    func testArithmeticAndOrdering() {
        let a = Money(amountMinor: 100, currencyCode: "PLN")
        let b = Money(amountMinor: 50, currencyCode: "PLN")
        XCTAssertEqual((a + b).amountMinor, 150)
        XCTAssertEqual((b - a).amountMinor, -50)
        XCTAssertLessThan(b, a)
    }

    func testSanitizeTypingInputKeepsOneCommaAndTwoFractionDigits() {
        XCTAssertEqual(Money.sanitizeTypingInput("12a.3b4c5"), "12,34")
        XCTAssertEqual(Money.sanitizeTypingInput("..,,5"), "0,5")
        XCTAssertEqual(Money.sanitizeTypingInput("1,2,3"), "1,23")
        XCTAssertEqual(Money.sanitizeTypingInput(""), "")
    }
}

final class MoneyFormatterTests: XCTestCase {
    private let english = Locale(identifier: "en_US_POSIX")

    func testHeroAmountDropsFractionOnlyForWholeUnits() {
        XCTAssertEqual(MoneyFormatter.heroAmount(from: Money(amountMinor: 250_00), locale: english), "250")
        XCTAssertEqual(MoneyFormatter.heroAmount(from: Money(amountMinor: 250_40), locale: english), "250.40")
    }

    func testTypingAmountDropsTrailingZero() {
        XCTAssertEqual(MoneyFormatter.typingAmount(from: Money(amountMinor: 25_80), locale: english), "25.8")
    }

    func testCurrencyStringUsesTheMoneyCurrency() {
        let text = MoneyFormatter.string(from: Money(amountMinor: 12_50, currencyCode: "EUR"), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(text, "€12.50")
    }

    func testEditableAmountIsWhatTheUserWouldHaveTyped() {
        XCTAssertEqual(MoneyFormatter.editableAmount(from: Money(amountMinor: 0)), "0")
        XCTAssertEqual(MoneyFormatter.editableAmount(from: Money(amountMinor: 12_00)), "12")
        XCTAssertEqual(MoneyFormatter.editableAmount(from: Money(amountMinor: 12_50)), "12,5")
        XCTAssertEqual(MoneyFormatter.editableAmount(from: Money(amountMinor: 12_05)), "12,05")
        XCTAssertEqual(MoneyFormatter.editableAmount(from: Money(amountMinor: 1_234_567_89)), "1234567,89")
    }

    /// Edit forms seed their text fields from stored amounts, and the field
    /// sanitizes and parses that text again on save. Grouped text broke this:
    /// "1,234.5" (en) was sanitized to "1,23", and "1 234,5" (pl) did not parse.
    func testEditableAmountRoundTripsThroughTypingAndParsing() {
        for amountMinor in [0, 5, 99_99, 1_000_00, 1_234_50, 12_345_67] {
            let money = Money(amountMinor: amountMinor)
            let text = Money.sanitizeTypingInput(MoneyFormatter.editableAmount(from: money))
            XCTAssertEqual(Money(majorString: text)?.amountMinor, amountMinor, "\(amountMinor) became \(text)")
        }
    }
}
