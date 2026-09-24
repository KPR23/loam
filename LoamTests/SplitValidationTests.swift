import XCTest
@testable import Loam

final class SplitValidationTests: XCTestCase {
    private let alice = TestUser.alice
    private let bob = TestUser.bob

    private func error(
        total: Int = 1000,
        partners: Int = 1,
        requiresPartner: Bool = false,
        mode: SplitExpenseMode,
        percentages: [UUID: Int] = [:],
        amounts: [UUID: String] = [:]
    ) -> String? {
        SplitExpenseSection.validationError(
            totalMinor: total,
            selectedPartnerCount: partners,
            requiresPartner: requiresPartner,
            splitMode: mode,
            participantUserIds: [alice, bob],
            participantPercentages: percentages,
            participantAmountTexts: amounts
        )
    }

    func testNoPartnerIsOnlyAnErrorWhenSplittingIsRequired() {
        XCTAssertNil(error(partners: 0, mode: .equal))
        XCTAssertEqual(error(partners: 0, requiresPartner: true, mode: .equal), "Select at least one person to split with.")
    }

    func testSplitNeedsAPositiveTotal() {
        XCTAssertEqual(error(total: 0, mode: .equal), "Enter a valid amount.")
    }

    func testEqualSplitIsAlwaysValid() {
        XCTAssertNil(error(mode: .equal))
    }

    func testPercentagesMustCoverEveryoneAndTotal100() {
        XCTAssertNil(error(mode: .percentage, percentages: [alice: 30, bob: 70]))
        XCTAssertEqual(error(mode: .percentage, percentages: [alice: 100]), "Enter a percentage for every person.")
        XCTAssertEqual(error(mode: .percentage, percentages: [alice: 100, bob: 0]), "Enter a percentage for every person.")
        XCTAssertEqual(error(mode: .percentage, percentages: [alice: 80, bob: 40]), "Percentage shares must total 100%.")
    }

    func testExactAmountsMustCoverEveryoneAndMatchTheTotal() {
        XCTAssertNil(error(mode: .exactAmount, amounts: [alice: "4", bob: "6"]))
        XCTAssertEqual(error(mode: .exactAmount, amounts: [alice: "4"]), "Enter an amount for every person.")
        XCTAssertEqual(error(mode: .exactAmount, amounts: [alice: "4", bob: "abc"]), "Enter an amount for every person.")
        XCTAssertEqual(error(mode: .exactAmount, amounts: [alice: "8,00", bob: "4,00"]), "Exact shares must total the expense amount.")
    }
}
