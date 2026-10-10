import SwiftUI

/// An example shared expense, then the balance it leaves once the friend accepts it.
struct OnboardingSplitPreview: View {
    var isCurrent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsBalance = false

    private var currency: String { AppPreferences.defaultCurrencyCode }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: ExpenseCategory.dining.systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ExpenseCategory.dining.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dinner out")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(HomeTheme.text)
                    Text("Split with Julia · 50/50")
                        .font(.subheadline)
                        .foregroundStyle(HomeTheme.secondary)
                }
                Spacer(minLength: 8)
                Text(MoneyFormatter.string(from: Money(amountMinor: 240_00, currencyCode: currency)))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HomeTheme.text)
            }
            .padding(16)
            .background(HomeTheme.surface, in: RoundedRectangle(cornerRadius: 20))

            HStack(spacing: 12) {
                Text("J")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(HomeTheme.accent.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Julia owes you")
                        .font(.subheadline)
                        .foregroundStyle(HomeTheme.secondary)
                    Text(MoneyFormatter.string(from: Money(amountMinor: 120_00, currencyCode: currency)))
                        .font(.system(.title2, design: .rounded).bold())
                        .monospacedDigit()
                        .foregroundStyle(HomeTheme.text)
                }
                Spacer(minLength: 8)
                Label("Accepted", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }
            .padding(16)
            .background(HomeTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .opacity(showsBalance ? 1 : 0)
            .offset(y: showsBalance || reduceMotion ? 0 : 18)
        }
        .padding(.vertical, 24)
        // Example people and amounts; the page header says what they show.
        .accessibilityHidden(true)
        .onChange(of: isCurrent, initial: true) { _, current in
            revealBalance(current)
        }
    }

    private func revealBalance(_ current: Bool) {
        guard current else {
            showsBalance = false
            return
        }
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.5, dampingFraction: 0.8).delay(0.35)
        withAnimation(animation) { showsBalance = true }
    }
}

#Preview {
    OnboardingSplitPreview(isCurrent: true)
        .padding(24)
        .background(HomeTheme.background)
}
