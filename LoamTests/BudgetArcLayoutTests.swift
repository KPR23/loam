import XCTest
@testable import Loam

final class BudgetArcLayoutTests: XCTestCase {
    private let canvas = CGSize(width: 360, height: 260)
    private let layout = BudgetArcLayout()

    func testTileCountMatchesRowsTimesColumns() {
        let tiles = layout.makeTiles(in: canvas)
        XCTAssertEqual(tiles.count, layout.rowCount * layout.columnCount)
        XCTAssertEqual(Set(tiles.map(\.row)), Set(0..<layout.rowCount))
    }

    func testFillOrderSweepsFromLeftHornToRight() {
        let tiles = layout.makeTiles(in: canvas)
        let ts = tiles.map(\.t)
        for pair in zip(ts, ts.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1 + 0.000_1)
        }
        XCTAssertLessThan(tiles.first!.point.x, canvas.width / 2)
        XCTAssertGreaterThan(tiles.last!.point.x, canvas.width / 2)
    }

    func testColumnsShareAnAngleAcrossRows() {
        let tiles = layout.makeTiles(in: canvas)
        let column = tiles.filter { $0.column == 4 }
        XCTAssertEqual(column.count, layout.rowCount)
        let rotations = Set(column.map(\.rotationDegrees))
        XCTAssertEqual(rotations.count, 1)
    }

    func testTileBaseFacesTheArcCentre() {
        let tiles = layout.makeTiles(in: canvas)
        // Even column counts have no exact apex; the nearest tile still faces the arc centre.
        let apex = tiles.min(by: { abs($0.t - 0.5) < abs($1.t - 0.5) })!
        let apexDegrees = layout.startDegrees - layout.sweepDegrees * apex.t
        XCTAssertEqual(apex.rotationDegrees, 90 - apexDegrees, accuracy: 0.000_1)
        XCTAssertEqual(tiles.first!.rotationDegrees, 90 - layout.startDegrees, accuracy: 0.000_1)
        XCTAssertEqual(tiles.last!.rotationDegrees, 90 - layout.endDegrees, accuracy: 0.000_1)
    }

    func testRotatedTilesStayInsideTheCanvas() {
        let tiles = layout.makeTiles(in: canvas)
        for tile in tiles {
            let reach = tile.size * CGFloat(2.0.squareRoot()) / 2
            XCTAssertGreaterThanOrEqual(tile.point.x, reach - 0.5)
            XCTAssertLessThanOrEqual(tile.point.x, canvas.width - reach + 0.5)
            XCTAssertGreaterThanOrEqual(tile.point.y, reach - 0.5)
            XCTAssertLessThanOrEqual(tile.point.y, canvas.height - reach + 0.5)
        }
    }

    func testOuterRowIsLargerThanInner() {
        let tiles = layout.makeTiles(in: canvas)
        let inner = tiles.first { $0.row == 0 }!
        let outer = tiles.first { $0.row == layout.rowCount - 1 }!
        XCTAssertEqual(inner.size, layout.squareSize)
        XCTAssertEqual(outer.size, layout.outerSquareSize)
        XCTAssertGreaterThan(outer.size, inner.size)
    }

    func testLabelAnchorIsHorizontallyCenteredInBowl() {
        let anchor = layout.labelAnchor(in: canvas)
        XCTAssertEqual(anchor.x, canvas.width / 2, accuracy: 0.001)
        XCTAssertGreaterThan(anchor.y, canvas.height * 0.45)
        XCTAssertLessThan(anchor.y, canvas.height * 0.72)
    }

    func testLabelMaxWidthClearsInnerHornTiles() {
        let maxWidth = layout.labelMaxWidth(in: canvas)
        XCTAssertLessThan(maxWidth, canvas.width - 80)
        XCTAssertGreaterThan(maxWidth, 100)

        let tiles = layout.makeTiles(in: canvas)
        let innerHornTiles = tiles.filter { $0.row == 0 && ($0.column == 0 || $0.column == layout.columnCount - 1) }
        XCTAssertEqual(innerHornTiles.count, 2)

        let left = innerHornTiles.min(by: { $0.point.x < $1.point.x })!
        let right = innerHornTiles.max(by: { $0.point.x < $1.point.x })!
        let innerReach = layout.squareSize * CGFloat(2).squareRoot() / 2
        let safeSpan = (right.point.x - innerReach) - (left.point.x + innerReach) - 24
        XCTAssertEqual(maxWidth, max(72, safeSpan), accuracy: 0.5)
    }

    func testSeventyPercentLightsMostTilesButNotAll() {
        let total = layout.makeTiles(in: canvas).count
        let filled = BudgetArcFill.filledCount(total: total, progress: 0.70)
        XCTAssertEqual(filled, Int((Double(total) * 0.70).rounded(.down)))
        XCTAssertGreaterThan(filled, 0)
        XCTAssertLessThan(filled, total)
    }

    func testCoverageClampsAndPartiallyFillsTheLeadingTile() {
        XCTAssertEqual(BudgetArcFill.coverage(index: 0, total: 10, progress: 0), 0)
        XCTAssertEqual(BudgetArcFill.coverage(index: 9, total: 10, progress: 1), 1, accuracy: 0.000_1)
        XCTAssertEqual(BudgetArcFill.coverage(index: 6, total: 10, progress: 0.70), 1, accuracy: 0.000_1)
        XCTAssertEqual(BudgetArcFill.coverage(index: 7, total: 10, progress: 0.70), 0, accuracy: 0.000_1)
        XCTAssertEqual(BudgetArcFill.coverage(index: 0, total: 10, progress: 0.05), 0.5, accuracy: 0.000_1)
        XCTAssertEqual(BudgetArcFill.coverage(index: 0, total: 10, progress: 2), 1, accuracy: 0.000_1)
        XCTAssertEqual(BudgetArcFill.filledCount(total: 0, progress: 0.70), 0)
    }

    func testColourBandSwitchesEveryThird() {
        let slices = [
            CategorySpendSlice(category: .groceries, amountMinor: 50),
            CategorySpendSlice(category: .dining, amountMinor: 30),
            CategorySpendSlice(category: .transport, amountMinor: 20),
        ]
        let total = 36
        let counts = BudgetArcFill.tileCounts(total: total, slices: slices)
        XCTAssertEqual(counts[.groceries], 18)
        XCTAssertEqual(counts[.dining], 11)
        XCTAssertEqual(counts[.transport], 7)
        XCTAssertEqual(counts.values.reduce(0, +), total)

        XCTAssertEqual(BudgetArcFill.category(forTile: 0, total: total, slices: slices), .groceries)
        XCTAssertEqual(BudgetArcFill.category(forTile: 17, total: total, slices: slices), .groceries)
        XCTAssertEqual(BudgetArcFill.category(forTile: 18, total: total, slices: slices), .dining)
        XCTAssertEqual(BudgetArcFill.category(forTile: 28, total: total, slices: slices), .dining)
        XCTAssertEqual(BudgetArcFill.category(forTile: 29, total: total, slices: slices), .transport)
        XCTAssertNil(BudgetArcFill.category(forTile: 0, total: total, slices: []))
    }
}

final class MoneyFormatterHeroTests: XCTestCase {
    func testWholeZlotyDropsFraction() {
        let amount = MoneyFormatter.heroAmount(
            from: Money(amountMinor: 250_00, currencyCode: "PLN"),
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(amount, "250")
    }

    func testGroszeKeepTwoFractionDigits() {
        let amount = MoneyFormatter.heroAmount(
            from: Money(amountMinor: 250_40, currencyCode: "PLN"),
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(amount, "250.40")
    }

    func testTypingAmountDropsTrailingZero() {
        let amount = MoneyFormatter.typingAmount(
            from: Money(amountMinor: 2580, currencyCode: "PLN"),
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(amount, "25.8")
    }
}
