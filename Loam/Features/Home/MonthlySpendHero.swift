import SwiftUI

/// Placeholder until a real monthly budget is stored.
enum MonthlyBudgetPlaceholder {
    static let progress: Double = 0.70
}

struct MonthlySpendHero: View {
    var amount: Money
    var progress: Double = MonthlyBudgetPlaceholder.progress
    var sharedShare: Money
    /// Bump when Expenses becomes visible again so the arc reloads.
    var reloadToken: Int = 0
    var collapseProgress: CGFloat = 0
    var layout: BudgetArcLayout = BudgetArcLayout()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedProgress: Double = 0

    /// Side inset so the amount never kisses the arc horns.
    private let amountSideInset: CGFloat = 96

    private var easedCollapse: CGFloat {
        let t = min(max(collapseProgress, 0), 1)
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        let heroAmount = MoneyFormatter.heroAmount(from: amount)
        let percent = Int((BudgetArcFill.clamp(progress) * 100).rounded())

        VStack(spacing: 10) {
            ZStack {
                BudgetArcMosaic(layout: layout, progress: displayedProgress)

                VStack(spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        amountStack(amount: heroAmount, currency: amount.currencyCode, size: 62)
                        amountStack(amount: heroAmount, currency: amount.currencyCode, size: 54)
                        amountStack(amount: heroAmount, currency: amount.currencyCode, size: 46)
                        amountStack(amount: heroAmount, currency: amount.currencyCode, size: 38)
                        amountStack(amount: heroAmount, currency: amount.currencyCode, size: 32)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, amountSideInset)
                    .opacity(1 - easedCollapse)
                    .scaleEffect(1 - 0.12 * easedCollapse, anchor: .center)
                    .blur(radius: easedCollapse * 3)

                    Text("\(percent)% of budget")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeTheme.tertiary)
                        .padding(.horizontal, amountSideInset)
                        .opacity(1 - easedCollapse)
                }
                // Keep the figure in the open bowl under the arc, not overlapping it.
                .offset(y: 40 + easedCollapse * 10)
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
        .accessibilityValue("\(percent) percent of budget")
        .onAppear { playFill(progress) }
        .onChange(of: progress) { _, newValue in
            playFill(newValue)
        }
        .onChange(of: reloadToken) { _, _ in
            playFill(progress)
        }
    }

    private func amountStack(amount: String, currency: String, size: CGFloat) -> some View {
        VStack(spacing: 4) {
            Text(currency)
                .font(.system(size: max(13, size * 0.28), weight: .semibold, design: .rounded))
                .foregroundStyle(HomeTheme.secondary)
            Text(amount)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HomeTheme.text)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func playFill(_ target: Double) {
        let clamped = BudgetArcFill.clamp(target)
        Task { @MainActor in
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                displayedProgress = 0
            }

            guard !reduceMotion else {
                displayedProgress = clamped
                return
            }

            try? await Task.sleep(for: .milliseconds(20))
            withAnimation(.linear(duration: 1.05)) {
                displayedProgress = clamped
            }
        }
    }
}

/// Drawn in Canvas so tiles snap on left→right without a colour crossfade.
private struct BudgetArcMosaic: View, Animatable {
    var layout: BudgetArcLayout
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let tiles = layout.makeTiles(in: size)
            let total = tiles.count

            for (index, tile) in tiles.enumerated() {
                let lit = BudgetArcFill.coverage(index: index, total: total, progress: progress) > 0.5
                let color = lit
                    ? bandColor(BudgetArcFill.band(index: index, total: total))
                    : HomeTheme.tileEmpty

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

    private func bandColor(_ band: Int) -> Color {
        switch band {
        case 0: return HomeTheme.tileFirstThird
        case 1: return HomeTheme.tileSecondThird
        default: return HomeTheme.tileFinalThird
        }
    }
}

#Preview {
    MonthlySpendHero(
        amount: Money(amountMinor: 250_00, currencyCode: "PLN"),
        progress: 0.70,
        sharedShare: Money(amountMinor: 40_00, currencyCode: "PLN")
    )
    .padding(20)
    .background(HomeTheme.background)
}
