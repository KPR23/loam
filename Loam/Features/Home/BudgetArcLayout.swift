import CoreGraphics
import Foundation

/// One tile on the monthly spend arc. Positions are in the view's coordinate space.
struct BudgetArcTile: Equatable, Identifiable {
    let id: Int
    let row: Int
    let column: Int
    /// Side length of this tile (outer row can be larger).
    let size: CGFloat
    /// 0 at the left horn, 1 at the right horn.
    let t: Double
    let point: CGPoint
    /// Clockwise degrees so the tile's base faces the centre of the arc.
    let rotationDegrees: Double
}

/// Geometry for a few concentric rows of squares following a top-facing arc.
struct BudgetArcLayout: Equatable {
    var rowCount: Int = 2
    var columnCount: Int = 18
    var squareSize: CGFloat = 17.5
    /// Outer (top) row is a touch larger than the inner one.
    var outerSquareSize: CGFloat = 20
    var rowGap: CGFloat = 9
    /// Left horn, a little below the horizon so the arc reads as a bowl.
    var startDegrees: Double = 198
    /// Right horn, mirrored.
    var endDegrees: Double = -18
    /// Odd rows shift half a column so their tiles fall between those of the rows beside them.
    var staggersOddRows = false
    /// Extra room between the outermost row and the one inside it.
    var outerRowExtraGap: CGFloat = 0
    var horizontalInset: CGFloat = 16
    var topInset: CGFloat = 10
    /// Vertical placement of the circle origin, 0 = top.
    var centerYRatio: CGFloat = 0.72

    /// Round dots in three rows that grow outward; the middle row sits in the gaps of its neighbours.
    static let dots = BudgetArcLayout(
        rowCount: 3,
        columnCount: 16,
        squareSize: 11,
        outerSquareSize: 20,
        rowGap: 6,
        staggersOddRows: true,
        outerRowExtraGap: 3
    )

    var sweepDegrees: Double { startDegrees - endDegrees }

    /// How much of the sweep a full `gather` takes away.
    static let maxGatherSweepReduction = 0.32

    /// Half the diagonal of the largest tile — reach from its centre.
    var tileReach: CGFloat { outerSquareSize * CGFloat(2.0.squareRoot()) / 2 }

    func squareSize(forRow row: Int) -> CGFloat {
        guard rowCount > 1 else { return outerSquareSize }
        return squareSize + (outerSquareSize - squareSize) * CGFloat(row) / CGFloat(rowCount - 1)
    }

    /// Centre-to-centre distance between consecutive rows.
    var rowPitch: CGFloat {
        (squareSize + outerSquareSize) / 2 + rowGap
    }

    private func arcGeometry(in size: CGSize) -> (center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat)? {
        guard size.width > 0, size.height > 0, rowCount > 0, columnCount > 0 else { return nil }

        let center = CGPoint(x: size.width / 2, y: size.height * centerYRatio)
        let pitch = rowPitch
        let widthLimited = (size.width / 2) - horizontalInset - tileReach
        let topLimited = center.y - topInset - tileReach
        let outerRadius = max(tileReach, min(widthLimited, topLimited))
        let innerRadius = max(tileReach, outerRadius - CGFloat(rowCount - 1) * pitch - outerRowExtraGap)
        return (center, innerRadius, outerRadius)
    }

    /// Visual centre for the hero amount — inside the arc bowl, clear of the tile ring.
    func labelAnchor(in size: CGSize) -> CGPoint {
        guard let geometry = arcGeometry(in: size) else {
            return CGPoint(x: size.width / 2, y: size.height * 0.58)
        }

        // Lower in the bowl — more breathing room below the tile ring.
        let y = geometry.center.y - geometry.innerRadius * 0.08
        return CGPoint(x: geometry.center.x, y: y)
    }

    /// Horizontal space for the hero amount — clears the inner horn tiles.
    func labelMaxWidth(in size: CGSize) -> CGFloat {
        guard let geometry = arcGeometry(in: size) else {
            return size.width * 0.52
        }

        let center = geometry.center
        let innerRadius = geometry.innerRadius
        let start = startDegrees * .pi / 180
        let end = endDegrees * .pi / 180
        let innerReach = squareSize * CGFloat(2).squareRoot() / 2

        let leftHornCenterX = center.x + innerRadius * cos(start)
        let rightHornCenterX = center.x + innerRadius * cos(end)
        let padding: CGFloat = 24
        let width = (rightHornCenterX - leftHornCenterX) - (2 * innerReach) - padding
        return max(72, width)
    }

    /// `gather` (0...1) pulls the horns up along the circle toward the crown, narrowing the sweep.
    func makeTiles(in size: CGSize, gather: Double = 0) -> [BudgetArcTile] {
        guard let geometry = arcGeometry(in: size) else { return [] }

        let center = geometry.center
        let innerRadius = geometry.innerRadius
        let pitch = rowPitch
        let crownDegrees = (startDegrees + endDegrees) / 2
        let sweepScale = 1 - Self.maxGatherSweepReduction * min(max(gather, 0), 1)

        var tiles: [BudgetArcTile] = []
        var nextID = 0

        // Columns share an angle across rows, so a column lights up as one radial spoke.
        for column in 0..<columnCount {
            for row in 0..<rowCount {
                let shifted = staggersOddRows && row % 2 == 1
                if shifted && column == columnCount - 1 { continue }

                let position = Double(column) + (shifted ? 0.5 : 0)
                let t = columnCount == 1 ? 0.5 : position / Double(columnCount - 1)
                let degrees = crownDegrees + (startDegrees - sweepDegrees * t - crownDegrees) * sweepScale
                let angle = degrees * .pi / 180
                let tileSize = squareSize(forRow: row)
                let radius = innerRadius + CGFloat(row) * pitch + (row == rowCount - 1 ? outerRowExtraGap : 0)
                let point = CGPoint(
                    x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y - radius * CGFloat(sin(angle))
                )
                tiles.append(
                    BudgetArcTile(
                        id: nextID,
                        row: row,
                        column: column,
                        size: tileSize,
                        t: t,
                        point: point,
                        rotationDegrees: 90 - degrees
                    )
                )
                nextID += 1
            }
        }

        // The staggered rows interleave within a column, so emit in left-to-right order: reveal and
        // category bands go by array index and must not double back.
        return tiles
            .sorted { ($0.t, $0.row) < ($1.t, $1.row) }
            .enumerated()
            .map { index, tile in
                BudgetArcTile(
                    id: index,
                    row: tile.row,
                    column: tile.column,
                    size: tile.size,
                    t: tile.t,
                    point: tile.point,
                    rotationDegrees: tile.rotationDegrees
                )
            }
    }
}

enum BudgetArcFill {
    /// How fully tile `index` should light up for a 0...1 reveal ratio.
    static func coverage(index: Int, total: Int, progress: Double) -> Double {
        guard total > 0, index >= 0, index < total else { return 0 }
        let exact = Double(total) * clamp(progress)
        let i = Double(index)
        if i + 1 <= exact { return 1 }
        if i >= exact { return 0 }
        return exact - i
    }

    static func filledCount(total: Int, progress: Double) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(total) * clamp(progress)).rounded(.down))
    }

    /// Maps each tile to a category based on spending share (largest categories first, left→right).
    static func category(forTile index: Int, total: Int, slices: [CategorySpendSlice]) -> SpendCategory? {
        guard total > 0, index >= 0, index < total, !slices.isEmpty else { return nil }

        let counts = tileCounts(total: total, slices: slices)
        var cursor = 0
        for slice in slices {
            let count = counts[slice.category] ?? 0
            if index < cursor + count {
                return slice.category
            }
            cursor += count
        }
        return nil
    }

    static func tileCounts(total: Int, slices: [CategorySpendSlice]) -> [SpendCategory: Int] {
        guard total > 0, !slices.isEmpty else { return [:] }

        let totalAmount = slices.reduce(0) { $0 + $1.amountMinor }
        guard totalAmount > 0 else { return [:] }

        var allocations: [(category: SpendCategory, count: Int, remainder: Double)] = []
        var assigned = 0

        for slice in slices {
            let exact = Double(total) * Double(slice.amountMinor) / Double(totalAmount)
            let floor = Int(exact.rounded(.down))
            allocations.append((slice.category, floor, exact - Double(floor)))
            assigned += floor
        }

        var remaining = total - assigned
        let ranked = allocations.enumerated().sorted { lhs, rhs in
            if lhs.element.remainder != rhs.element.remainder {
                return lhs.element.remainder > rhs.element.remainder
            }
            return lhs.offset < rhs.offset
        }
        for (originalIndex, _) in ranked where remaining > 0 {
            allocations[originalIndex].count += 1
            remaining -= 1
        }

        return Dictionary(uniqueKeysWithValues: allocations.map { ($0.category, $0.count) })
    }

    static func clamp(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
}
