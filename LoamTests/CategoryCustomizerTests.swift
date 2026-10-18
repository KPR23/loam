import XCTest
@testable import Loam

final class CategoryCustomizerTests: XCTestCase {
    func testPickingTheBuiltInColorKeepsFollowingTheDefault() {
        let style = CategoryStyleOverride(colorHex: ExpenseCategory.groceries.defaultColorHex)
        XCTAssertNil(style.normalized(for: .groceries).colorHex)
        XCTAssertTrue(style.normalized(for: .groceries).isEmpty)
    }

    func testBuiltInColorMatchIgnoresCase() {
        let style = CategoryStyleOverride(colorHex: ExpenseCategory.groceries.defaultColorHex.lowercased())
        XCTAssertNil(style.normalized(for: .groceries).colorHex)
    }

    func testAnotherCategorysColorIsKept() {
        let hex = ExpenseCategory.dining.defaultColorHex
        let style = CategoryStyleOverride(name: "Food", colorHex: hex)
        XCTAssertEqual(style.normalized(for: .groceries), style)
    }

    func testSavedOverridesDropBuiltInColors() {
        let saved: [String: CategoryStyleOverride] = [
            "groceries": CategoryStyleOverride(colorHex: ExpenseCategory.groceries.defaultColorHex),
            "dining": CategoryStyleOverride(name: "Eating out", colorHex: ExpenseCategory.dining.defaultColorHex),
            "transport": CategoryStyleOverride(colorHex: ExpenseCategory.health.defaultColorHex),
            "retired": CategoryStyleOverride(colorHex: "1FA85A")
        ]

        let normalized = CategoryCustomizer.normalized(saved)

        XCTAssertNil(normalized["groceries"])
        XCTAssertEqual(normalized["dining"], CategoryStyleOverride(name: "Eating out"))
        XCTAssertEqual(normalized["transport"], saved["transport"])
        XCTAssertEqual(normalized["retired"], saved["retired"])
    }
}
