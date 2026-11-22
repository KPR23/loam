import SwiftUI

/// The center of Home's top bar: empty at the top of the list, where the arc shows the amount, and the
/// amount once the list scrolls.
struct HomeCollapsingTopBar: View {
    let amount: Money
    let isCollapsed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        collapsedAmount
            .opacity(isCollapsed ? 1 : 0)
            .scaleEffect(isCollapsed ? 1 : 0.94)
            .offset(y: isCollapsed ? 0 : 6)
            .accessibilityHidden(!isCollapsed)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
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

/// The month control on the leading side of Home's top bar. A "November 2026" pill at the top of the
/// list that folds into a calendar icon once the amount takes the center. It's a system toolbar item
/// like search, so the two always share the same glass height.
struct HomeTopBarMonthButton: View {
    let period: DatePeriod
    let isCollapsed: Bool
    let onPickMonth: () -> Void

    var body: some View {
        Button(action: { LoamFeedback.tap(); onPickMonth() }) {
            if isCollapsed {
                Image(systemName: "calendar")
            } else {
                HStack(spacing: 5) {
                    Text(period.displayTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(HomeTheme.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(HomeTheme.secondary)
                }
                .fixedSize()
            }
        }
        .modifier(PreGlassBorderedCapsule())
        .accessibilityLabel("Selected month, \(period.displayTitle)")
        .accessibilityHint("Opens month picker")
    }
}

/// Before iOS 26 toolbar buttons have no glass, so give the month the same bordered look as search.
private struct PreGlassBorderedCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

/// One scroll point where Home hands the amount from the arc to the top bar. The arc's amount, the bar's
/// amount and the top bar's month control all flip here together, with the same animation.
enum HomeTopBarCollapse {
    /// Collapse once the arc is mostly dissolved; expand a little earlier on the way back so a list
    /// resting near the threshold doesn't flicker between the two.
    static let collapseAt: CGFloat = 0.6
    static let expandAt: CGFloat = 0.45

    static func isCollapsed(after progress: CGFloat, was wasCollapsed: Bool) -> Bool {
        wasCollapsed ? progress > expandAt : progress >= collapseAt
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.32)
    }
}

/// Opens search on Home, at the trailing end of the top bar.
struct HomeTopBarSearchButton: View {
    let onSearch: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(action: { LoamFeedback.tap(); onSearch() }) {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search expenses")
        } else {
            Button(action: { LoamFeedback.tap(); onSearch() }) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Search expenses")
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
        amount: Money(amountMinor: 250_00, currencyCode: "PLN"),
        isCollapsed: false
    )
    .padding()
    .background(HomeTheme.background)
}

#Preview("Collapsed") {
    HomeCollapsingTopBar(
        amount: Money(amountMinor: 250_00, currencyCode: "PLN"),
        isCollapsed: true
    )
    .padding()
    .background(HomeTheme.background)
}

#Preview("Month picker") {
    MonthPickerSheet(period: .currentMonth) { _ in }
}
