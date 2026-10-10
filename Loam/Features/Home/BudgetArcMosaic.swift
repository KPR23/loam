import SwiftUI

/// Drawn in Canvas so tiles snap on left→right without a colour crossfade.
struct BudgetArcMosaic: View, Animatable {
    var layout: BudgetArcLayout
    var categoryBreakdown: [CategorySpendSlice]
    var reveal: Double

    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let tiles = layout.makeTiles(in: size)
            let total = tiles.count

            for (index, tile) in tiles.enumerated() {
                let category = BudgetArcFill.category(
                    forTile: index,
                    total: total,
                    slices: categoryBreakdown
                )
                let lit = category != nil
                    && BudgetArcFill.coverage(index: index, total: total, progress: reveal) > 0.5
                let color = lit ? category!.color : HomeTheme.tileEmpty

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
}
