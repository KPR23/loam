import SwiftUI

struct MonthlySpendHero: View {
    var amount: Money
    var categoryBreakdown: [CategorySpendSlice] = []
    var sharedShare: Money
    /// Bump when Expenses becomes visible again so the arc reloads.
    var reloadToken: Int = 0
    var collapseProgress: CGFloat = 0
    var layout: BudgetArcLayout = BudgetArcLayout()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedReveal: Double = 0

    private var easedCollapse: CGFloat {
        let t = min(max(collapseProgress, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private var hasCategoryMix: Bool {
        !categoryBreakdown.isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let anchor = layout.labelAnchor(in: geometry.size)
                let maxLabelWidth = layout.labelMaxWidth(in: geometry.size)
                let collapseYOffset = easedCollapse * 8

                ZStack {
                    BudgetArcMosaic(
                        layout: layout,
                        categoryBreakdown: categoryBreakdown,
                        reveal: displayedReveal
                    )

                    ViewThatFits(in: .horizontal) {
                        amountStack(amount: amount, size: 46, maxWidth: maxLabelWidth)
                        amountStack(amount: amount, size: 40, maxWidth: maxLabelWidth)
                        amountStack(amount: amount, size: 34, maxWidth: maxLabelWidth)
                        amountStack(amount: amount, size: 28, maxWidth: maxLabelWidth)
                        amountStack(amount: amount, size: 23, maxWidth: maxLabelWidth)
                    }
                    .frame(width: maxLabelWidth)
                    .position(
                        x: anchor.x,
                        y: anchor.y + collapseYOffset
                    )
                    .opacity(1 - easedCollapse)
                    .scaleEffect(1 - 0.12 * easedCollapse, anchor: .center)
                    .blur(radius: easedCollapse * 3)
                }
            }
            .frame(height: 260)

            if sharedShare.amountMinor > 0 {
                Text("of which \(MoneyFormatter.string(from: sharedShare)) is shared")
                    .font(.footnote)
                    .foregroundStyle(HomeTheme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You spent \(MoneyFormatter.string(from: amount)) this month")
        .accessibilityValue(accessibilityBreakdownValue)
        .onAppear { playReveal(hasCategoryMix ? 1 : 0) }
        .onChange(of: categoryBreakdown) { _, _ in
            playReveal(hasCategoryMix ? 1 : 0)
        }
        .onChange(of: reloadToken) { _, _ in
            playReveal(hasCategoryMix ? 1 : 0)
        }
    }

    private var accessibilityBreakdownValue: String {
        guard hasCategoryMix else { return "No spending yet" }
        let totalMinor = categoryBreakdown.reduce(0) { $0 + $1.amountMinor }
        guard totalMinor > 0 else { return "No spending yet" }

        return categoryBreakdown.map { slice in
            let percent = Int((Double(slice.amountMinor) / Double(totalMinor) * 100).rounded())
            return "\(slice.category.displayName) \(percent) percent"
        }
        .joined(separator: ", ")
    }

    private func amountStack(amount money: Money, size: CGFloat, maxWidth: CGFloat) -> some View {
        let heroAmount = MoneyFormatter.heroAmount(from: money)
        let amountValue = Double(money.amountMinor) / 100.0

        return VStack(spacing: 4) {
            Text(heroAmount)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HomeTheme.text)
                .contentTransition(.numericText(value: amountValue))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(money.currencyCode)
                .font(.system(size: max(14, size * 0.33), weight: .semibold, design: .rounded))
                .foregroundStyle(HomeTheme.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: maxWidth)
        .animation(reduceMotion ? nil : .smooth(duration: 0.42), value: amountValue)
    }

    private func playReveal(_ target: Double) {
        let clamped = BudgetArcFill.clamp(target)
        Task { @MainActor in
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                displayedReveal = 0
            }

            guard !reduceMotion else {
                displayedReveal = clamped
                return
            }

            try? await Task.sleep(for: .milliseconds(20))
            withAnimation(.linear(duration: 1.05)) {
                displayedReveal = clamped
            }
        }
    }
}

/// Drawn in Canvas so tiles snap on left→right without a colour crossfade.
private struct BudgetArcMosaic: View, Animatable {
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

#Preview("Long amount") {
    MonthlySpendHero(
        amount: Money(amountMinor: 488_406, currencyCode: "PLN"),
        categoryBreakdown: [
            CategorySpendSlice(category: .housing, amountMinor: 300_000),
            CategorySpendSlice(category: .groceries, amountMinor: 120_000),
            CategorySpendSlice(category: .entertainment, amountMinor: 68_406),
        ],
        sharedShare: Money(amountMinor: 0, currencyCode: "PLN")
    )
    .padding(20)
    .background(HomeTheme.background)
}

#Preview {
    MonthlySpendHero(
        amount: Money(amountMinor: 250_00, currencyCode: "PLN"),
        categoryBreakdown: [
            CategorySpendSlice(category: .groceries, amountMinor: 125_00),
            CategorySpendSlice(category: .dining, amountMinor: 75_00),
            CategorySpendSlice(category: .transport, amountMinor: 50_00),
        ],
        sharedShare: Money(amountMinor: 40_00, currencyCode: "PLN")
    )
    .padding(20)
    .background(HomeTheme.background)
}
