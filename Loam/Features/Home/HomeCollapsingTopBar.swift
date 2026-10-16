import SwiftUI

private struct HomeGlassCapsuleButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(iOS 26, *) {
            Button(action: action, label: label)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

struct HomeCollapsingTopBar: View {
    let period: DatePeriod
    let amount: Money
    let collapseProgress: CGFloat
    let onPickMonth: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pickerOut = HomeCollapsePhase.monthPickerOut.progress(collapseProgress)
        let amountIn = HomeCollapsePhase.barAmountIn.progress(collapseProgress)

        ZStack {
            monthPickerButton
                .opacity(1 - pickerOut)
                .scaleEffect(1 - 0.06 * pickerOut)
                .blur(radius: pickerOut * 2)

            collapsedAmount
                .opacity(amountIn)
                .scaleEffect(0.94 + 0.06 * amountIn)
                .offset(y: (1 - amountIn) * 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    private var monthPickerButton: some View {
        HomeGlassCapsuleButton(action: { LoamFeedback.tap(); onPickMonth() }) {
            monthPickerLabel
        }
        .accessibilityLabel("Selected month, \(period.displayTitle)")
        .accessibilityHint("Opens month picker")
    }

    private var monthPickerLabel: some View {
        HStack(spacing: 5) {
            Text(period.displayTitle)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(HomeTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(HomeTheme.secondary)
        }
    }

    private var collapsedAmount: some View {
        let amountValue = Double(amount.amountMinor) / 100.0

        return HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(MoneyFormatter.heroAmount(from: amount))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HomeTheme.text)
                .contentTransition(.numericText(value: amountValue))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(amount.currencyCode)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(HomeTheme.secondary)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.42), value: amountValue)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You spent \(MoneyFormatter.string(from: amount)) this month")
    }
}

/// Slices of the scroll collapse, so the hero amount hands off to the bar as the arc closes on its crown.
enum HomeCollapsePhase {
    case heroAmountOut
    case monthPickerOut
    case barAmountIn

    private var window: ClosedRange<CGFloat> {
        switch self {
        // Holds while the horns dissolve, then leaves with the crown.
        case .heroAmountOut: 0.3...0.8
        case .monthPickerOut: 0...0.6
        // Starts once the hero amount is mostly gone, so the two never read as a double.
        case .barAmountIn: 0.55...1
        }
    }

    /// Eased 0...1 within this phase's window of the overall collapse.
    func progress(_ collapse: CGFloat) -> CGFloat {
        let t = min(max((collapse - window.lowerBound) / (window.upperBound - window.lowerBound), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

struct HomeTopBarCalendarButton: View {
    let period: DatePeriod
    let onPickMonth: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(action: { LoamFeedback.tap(); onPickMonth() }) {
                Image(systemName: "calendar")
            }
            .accessibilityLabel("Selected month, \(period.displayTitle)")
            .accessibilityHint("Opens month picker")
        } else {
            Button(action: { LoamFeedback.tap(); onPickMonth() }) {
                Image(systemName: "calendar")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Selected month, \(period.displayTitle)")
            .accessibilityHint("Opens month picker")
        }
    }
}

struct MonthPickerSheet: View {
    let period: DatePeriod
    let onSelect: (DatePeriod) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMonth: Int
    @State private var selectedYear: Int

    private let years: [Int]
    private let monthNames: [String]

    init(period: DatePeriod, onSelect: @escaping (DatePeriod) -> Void) {
        self.period = period
        self.onSelect = onSelect

        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        years = Array((currentYear - 20)...currentYear)
        monthNames = calendar.monthSymbols

        switch period {
        case let .month(year, month):
            _selectedYear = State(initialValue: year)
            _selectedMonth = State(initialValue: month)
        }
    }

    private var selectedPeriod: DatePeriod {
        .month(year: selectedYear, month: selectedMonth)
    }

    private var isCurrentMonthSelected: Bool {
        selectedPeriod == .currentMonth
    }

    private func selectCurrentMonth() {
        let calendar = AppPreferences.calendar
        let now = Date()
        selectedYear = calendar.component(.year, from: now)
        selectedMonth = calendar.component(.month, from: now)
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("Month", selection: $selectedMonth) {
                    ForEach(1...12, id: \.self) { month in
                        Text(monthNames[month - 1]).tag(month)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("Year", selection: $selectedYear) {
                    ForEach(years, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .labelsHidden()
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected month, \(selectedPeriod.displayTitle)")
            .navigationTitle("Choose month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("This month") {
                        selectCurrentMonth()
                    }
                    .disabled(isCurrentMonthSelected)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSelect(selectedPeriod)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedMonth)
        .sensoryFeedback(.selection, trigger: selectedYear)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }
}

private struct HomeHeroScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct HomeScrollCollapseModifier: ViewModifier {
    @Binding var collapseProgress: CGFloat

    @State private var baselineOffset: CGFloat?

    private let collapseDistance: CGFloat = 150

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(HomeHeroScrollOffsetKey.self) { minY in
                guard let minY else { return }

                if baselineOffset == nil {
                    baselineOffset = minY
                }

                guard let baselineOffset else { return }

                let scrolled = baselineOffset - minY
                collapseProgress = min(max(scrolled / collapseDistance, 0), 1)
            }
    }
}

extension View {
    func trackHomeScrollCollapse(_ collapseProgress: Binding<CGFloat>) -> some View {
        modifier(HomeScrollCollapseModifier(collapseProgress: collapseProgress))
    }

    func reportHomeHeroScrollOffset() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: HomeHeroScrollOffsetKey.self,
                    value: geometry.frame(in: .named("homeScroll")).minY
                )
            }
        }
    }

    func homeTranslucentNavigationBar(collapseProgress: CGFloat) -> some View {
        modifier(HomeTranslucentNavBarModifier(collapseProgress: collapseProgress))
    }
}

private struct HomeTranslucentNavBarModifier: ViewModifier {
    let collapseProgress: CGFloat

    private var barMaterial: Material {
        collapseProgress > 0.04 ? .ultraThinMaterial : .bar
    }

    func body(content: Content) -> some View {
        content
            .toolbarBackground(barMaterial, for: .navigationBar)
    }
}

#Preview("Expanded") {
    HomeCollapsingTopBar(
        period: .currentMonth,
        amount: Money(amountMinor: 250_00, currencyCode: "PLN"),
        collapseProgress: 0,
        onPickMonth: {}
    )
    .padding()
    .background(HomeTheme.background)
}

#Preview("Collapsed") {
    HomeCollapsingTopBar(
        period: .currentMonth,
        amount: Money(amountMinor: 250_00, currencyCode: "PLN"),
        collapseProgress: 1,
        onPickMonth: {}
    )
    .padding()
    .background(HomeTheme.background)
}

#Preview("Month picker") {
    MonthPickerSheet(period: .currentMonth) { _ in }
}
