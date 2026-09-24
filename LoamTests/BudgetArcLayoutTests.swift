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

    func testLabelAnchorIsHorizontallyCenteredInBowl() {
        let anchor = layout.labelAnchor(in: canvas)
        XCTAssertEqual(anchor.x, canvas.width / 2, accuracy: 0.001)
        XCTAssertGreaterThan(anchor.y, canvas.height * 0.45)
        XCTAssertLessThan(anchor.y, canvas.height * 0.72)
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

    func testLabelFitsBetweenTheHornsOnAnyReasonableCanvas() {
        for width in [320.0, 360.0, 430.0] {
            let size = CGSize(width: width, height: 260)
            XCTAssertLessThan(layout.labelMaxWidth(in: size), width - 80)
            XCTAssertGreaterThanOrEqual(layout.labelMaxWidth(in: size), 72)
        }
    }

    func testEmptyCanvasDrawsNothingAndKeepsTheLabelCentred() {
        XCTAssertTrue(layout.makeTiles(in: .zero).isEmpty)
        XCTAssertEqual(layout.labelAnchor(in: CGSize(width: 0, height: 100)).y, 58, accuracy: 0.001)
    }

    func testTileCountsAlwaysFillEveryTile() {
        let slices = [
            CategorySpendSlice(category: .groceries, amountMinor: 1),
            CategorySpendSlice(category: .dining, amountMinor: 1),
            CategorySpendSlice(category: .transport, amountMinor: 1),
        ]
        for total in 1...40 {
            XCTAssertEqual(BudgetArcFill.tileCounts(total: total, slices: slices).values.reduce(0, +), total)
        }
        XCTAssertTrue(BudgetArcFill.tileCounts(total: 36, slices: [CategorySpendSlice(category: .groceries, amountMinor: 0)]).isEmpty)
    }
}
