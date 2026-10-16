import SwiftUI

/// The Home budget arc with the wordmark where the month total sits, so the first
/// screens look like the product rather than a separate brand.
struct LoamArcMark: View {
    /// A typical month, largest category first, as Home draws it.
    static let brandMix: [CategorySpendSlice] = [
        CategorySpendSlice(category: .housing, amountMinor: 32),
        CategorySpendSlice(category: .groceries, amountMinor: 24),
        CategorySpendSlice(category: .dining, amountMinor: 16),
        CategorySpendSlice(category: .transport, amountMinor: 12),
        CategorySpendSlice(category: .entertainment, amountMinor: 9),
        CategorySpendSlice(category: .utilities, amountMinor: 7),
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = 0.0

    private let layout = BudgetArcLayout.dots

    var body: some View {
        GeometryReader { geometry in
            let anchor = layout.labelAnchor(in: geometry.size)

            ZStack {
                BudgetArcMosaic(layout: layout, categoryBreakdown: Self.brandMix, reveal: reveal, tileShape: .circle)

                Text("Loam")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeTheme.text)
                    .position(x: anchor.x, y: anchor.y)
            }
        }
        .frame(height: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loam")
        .accessibilityAddTraits(.isHeader)
        .task { await fill() }
    }

    private func fill() async {
        guard reveal < 1 else { return }
        guard !reduceMotion else {
            reveal = 1
            return
        }
        // Let the screen settle before the tiles light up.
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(.linear(duration: 1.05)) { reveal = 1 }
    }
}

#Preview {
    LoamArcMark()
        .padding(20)
        .background(HomeTheme.background)
}
