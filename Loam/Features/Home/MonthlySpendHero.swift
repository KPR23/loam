import SwiftUI

struct MonthlySpendHero: View {
    var amount: Money
    var categoryBreakdown: [CategorySpendSlice] = []
    var sharedShare: Money
    /// Bump when Expenses becomes visible again; only used to recover a stuck arc.
    var reloadToken: Int = 0
    var collapseProgress: CGFloat = 0
    var layout: BudgetArcLayout = .dots
    @Binding var displayedReveal: Double

    @State private var amountSize: CGFloat = 46

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        reveal: displayedReveal,
                        tileShape: .circle,
                        collapse: reduceMotion ? 0 : easedCollapse
                    )
                    .opacity(reduceMotion ? 1 - easedCollapse : 1)

                    // One stack whose size follows the hidden probes, so a new amount rolls its digits
                    // like typing does instead of `ViewThatFits` swapping in a different view.
                    amountStack(amount: amount, size: amountSize, maxWidth: maxLabelWidth, shrinksToFit: true)
                        .frame(width: maxLabelWidth)
                        .background { amountSizeProbe(maxWidth: maxLabelWidth) }
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

            if let sharedCaption {
                Text(sharedCaption)
                    .font(.footnote)
                    .foregroundStyle(HomeTheme.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(1 - easedCollapse)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityBreakdownValue)
        .task(id: categoryBreakdown) {
            await animateReveal(to: hasCategoryMix ? 1 : 0)
        }
        .onChange(of: reloadToken) { _, _ in
            guard hasCategoryMix, displayedReveal < 1 else { return }
            Task { await animateReveal(to: 1) }
        }
    }

    /// Nil when nothing is shared or the amounts are in different currencies.
    private var sharedCaption: String? {
        guard sharedShare.amountMinor > 0,
              amount.amountMinor > 0,
              sharedShare.currencyCode == amount.currencyCode else { return nil }
        if sharedShare.amountMinor >= amount.amountMinor {
            return "all of it is shared"
        }
        return "of which \(MoneyFormatter.string(from: sharedShare)) is shared"
    }

    private var accessibilityTitle: String {
        let spent = "You spent \(MoneyFormatter.string(from: amount)) this month"
        guard let sharedCaption else { return spent }
        return "\(spent), \(sharedCaption)"
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

    /// The largest size the amount fits at, reported through `HeroAmountSizeKey`.
    private func amountSizeProbe(maxWidth: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            amountSizeCandidate(size: 46, maxWidth: maxWidth)
            amountSizeCandidate(size: 40, maxWidth: maxWidth)
            amountSizeCandidate(size: 34, maxWidth: maxWidth)
            amountSizeCandidate(size: 28, maxWidth: maxWidth)
            amountSizeCandidate(size: 23, maxWidth: maxWidth, shrinksToFit: true)
        }
        .hidden()
        .accessibilityHidden(true)
        .onPreferenceChange(HeroAmountSizeKey.self) { size in
            guard let size else { return }
            amountSize = size
        }
    }

    private func amountSizeCandidate(size: CGFloat, maxWidth: CGFloat, shrinksToFit: Bool = false) -> some View {
        amountStack(amount: amount, size: size, maxWidth: maxWidth, shrinksToFit: shrinksToFit)
            .preference(key: HeroAmountSizeKey.self, value: size)
    }

    /// The sizes ask for their full width, so `ViewThatFits` skips one that wouldn't fit instead of
    /// truncating it; only the smallest may shrink further, rather than end in an ellipsis.
    private func amountStack(amount money: Money, size: CGFloat, maxWidth: CGFloat, shrinksToFit: Bool = false) -> some View {
        let heroAmount = MoneyFormatter.heroAmount(from: money)
        let amountValue = Double(money.amountMinor) / 100.0

        return VStack(spacing: 4) {
            Text(heroAmount)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HomeTheme.text)
                .contentTransition(.numericText(value: amountValue))
                .lineLimit(1)
                .minimumScaleFactor(shrinksToFit ? 0.4 : 1)
                .fixedSize(horizontal: !shrinksToFit, vertical: false)
            Text(money.currencyCode)
                .font(.system(size: max(14, size * 0.33), weight: .semibold, design: .rounded))
                .foregroundStyle(HomeTheme.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: shrinksToFit ? maxWidth : nil)
        .animation(reduceMotion ? nil : .smooth(duration: 0.42), value: amountValue)
    }

    @MainActor
    private func animateReveal(to target: Double) async {
        let clamped = BudgetArcFill.clamp(target)

        if reduceMotion {
            displayedReveal = clamped
            return
        }

        if clamped == 0 {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                displayedReveal = 0
            }
            return
        }

        if displayedReveal == clamped {
            return
        }

        withAnimation(.linear(duration: 1.05)) {
            displayedReveal = clamped
        }
    }
}

private struct HeroAmountSizeKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
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
        sharedShare: Money(amountMinor: 0, currencyCode: "PLN"),
        displayedReveal: .constant(1)
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
        sharedShare: Money(amountMinor: 40_00, currencyCode: "PLN"),
        displayedReveal: .constant(1)
    )
    .padding(20)
    .background(HomeTheme.background)
}
