import SwiftUI

/// Drawn in Canvas so tiles snap on left→right without a colour crossfade.
struct BudgetArcMosaic: View, Animatable {
    var layout: BudgetArcLayout
    var categoryBreakdown: [CategorySpendSlice]
    var reveal: Double
    var tileShape: TileShape = .roundedSquare
    /// 0...1 as the hero collapses: the arc closes in on its crown, the horns dissolving first.
    var collapse: Double = 0

    enum TileShape { case roundedSquare, circle }

    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let tiles = layout.makeTiles(in: size, gather: collapse)
            let total = tiles.count

            for (index, tile) in tiles.enumerated() {
                let dissolve = Self.dissolve(t: tile.t, collapse: collapse)
                guard dissolve < 1 else { continue }

                var context = context
                context.opacity = 1 - dissolve
                // Shrink about the tile's centre so it stays on the curve.
                let tile = tile.scaled(by: 1 - 0.55 * dissolve)

                let category = BudgetArcFill.category(
                    forTile: index,
                    total: total,
                    slices: categoryBreakdown
                )
                let lit = category != nil
                    && BudgetArcFill.coverage(index: index, total: total, progress: reveal) > 0.5
                let color = lit ? category!.color : HomeTheme.tileEmpty

                if tileShape == .circle {
                    let half = tile.size / 2
                    context.fill(
                        Path(ellipseIn: CGRect(x: tile.point.x - half, y: tile.point.y - half, width: tile.size, height: tile.size)),
                        with: .color(color)
                    )
                    continue
                }

                let half = tile.size / 2
                let corner = CGSize(width: max(3, tile.size * 0.2), height: max(3, tile.size * 0.2))
                var path = Path(
                    roundedRect: CGRect(
                        x: -half,
                        y: -half,
                        width: tile.size,
                        height: tile.size
                    ),
                    cornerSize: corner,
                    style: .continuous
                )
                path = path.applying(
                    CGAffineTransform(rotationAngle: tile.rotationDegrees * .pi / 180)
                )
                path = path.applying(
                    CGAffineTransform(translationX: tile.point.x, y: tile.point.y)
                )
                context.fill(path, with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }

    /// Horns start dissolving straight away; the crown waits for the second half of the collapse.
    private static func dissolve(t: Double, collapse: Double) -> Double {
        guard collapse > 0 else { return 0 }
        let distanceFromCrown = abs(t - 0.5) * 2
        let delay = (1 - distanceFromCrown) * 0.5
        let local = min(max((collapse - delay) / 0.5, 0), 1)
        return local * local * (3 - 2 * local)
    }
}

private extension BudgetArcTile {
    func scaled(by factor: CGFloat) -> BudgetArcTile {
        BudgetArcTile(
            id: id,
            row: row,
            column: column,
            size: size * factor,
            t: t,
            point: point,
            rotationDegrees: rotationDegrees
        )
    }
}
