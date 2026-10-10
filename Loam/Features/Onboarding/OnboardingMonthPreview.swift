import SwiftUI

/// The real Home hero with an example month. It fills again each time the page comes into view.
struct OnboardingMonthPreview: View {
    var isCurrent: Bool

    @State private var reveal = 0.0

    private static let example: [CategorySpendSlice] = [
        CategorySpendSlice(category: .housing, amountMinor: 1_200_00),
        CategorySpendSlice(category: .groceries, amountMinor: 620_00),
        CategorySpendSlice(category: .dining, amountMinor: 330_00),
        CategorySpendSlice(category: .transport, amountMinor: 196_00),
        CategorySpendSlice(category: .entertainment, amountMinor: 140_00),
    ]

    private static var total: Int {
        example.reduce(0) { $0 + $1.amountMinor }
    }

    var body: some View {
        MonthlySpendHero(
            amount: Money(amountMinor: isCurrent ? Self.total : 0, currencyCode: AppPreferences.defaultCurrencyCode),
            categoryBreakdown: isCurrent ? Self.example : [],
            sharedShare: Money(amountMinor: isCurrent ? 312_00 : 0, currencyCode: AppPreferences.defaultCurrencyCode),
            displayedReveal: $reveal
        )
        // Example numbers; the page header says what they show.
        .accessibilityHidden(true)
    }
}

#Preview {
    OnboardingMonthPreview(isCurrent: true)
        .padding(24)
        .background(HomeTheme.background)
}
