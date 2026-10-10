import SwiftUI

/// Someone the viewer shares expenses with, opened from Balances.
struct BalancePerson: Hashable {
    let personId: UUID
    let displayName: String
}

/// One person's profile: where the two of you stand, and every shared
/// expense and repayment between you.
struct PersonBalanceView: View {
    let person: BalancePerson

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var balanceStore: BalanceStore
    @State private var history: [BalanceHistoryEntry] = []
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var showsRepayment = false

    private var balances: [PersonBalance] {
        balanceStore.snapshot.balances.filter { $0.personId == person.personId }
    }

    private var debts: [PersonBalance] {
        balances.filter { $0.amountMinor < 0 }
    }

    /// Falls back to the balance's currency for servers that don't send one per row.
    private var fallbackCurrency: String {
        balances.first?.currencyCode ?? AppPreferences.defaultCurrencyCode
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            historySections
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 2, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
        .navigationTitle(person.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Reload whenever balances change, e.g. after a repayment or a pull to refresh.
        .task(id: balanceStore.snapshot) { await loadHistory() }
        .refreshable {
            await balanceStore.refresh(userId: authSession.userId)
            await loadHistory()
        }
        .sheet(isPresented: $showsRepayment) {
            RepaymentSheet(debts: debts)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            AvatarView(userId: person.personId, size: 84, name: person.displayName)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

            Text(person.displayName)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(HomeTheme.text)
                .multilineTextAlignment(.center)

            standing

            if !debts.isEmpty {
                Button {
                    LoamFeedback.tap()
                    showsRepayment = true
                } label: {
                    Label("Record repayment", systemImage: "arrow.up.right")
                        .labelStyle(.prominentButton)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: 280, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 4)
                .accessibilityHint("Records money you paid \(person.displayName) outside Loam")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var standing: some View {
        if balances.isEmpty {
            Label("All settled up", systemImage: "checkmark.seal.fill")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.12), in: Capsule())
        } else {
            VStack(spacing: 10) {
                ForEach(balances) { balance in
                    VStack(spacing: 2) {
                        Text(balance.amountMinor > 0 ? "Owes you" : "You owe")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundStyle(BalanceTone.color(for: balance.amountMinor))
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(MoneyFormatter.heroAmount(from: balance.money))
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(HomeTheme.text)
                                .contentTransition(.numericText(value: Double(balance.money.amountMinor)))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(balance.currencyCode)
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(HomeTheme.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(balance.direction) \(MoneyFormatter.string(from: balance.money))")
                }
            }
            .animation(.smooth, value: balances)
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySections: some View {
        if !hasLoaded {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
            }
        } else if let loadError, history.isEmpty {
            Section {
                LoamEmptyState(title: "Couldn’t load history", message: loadError, systemImage: "exclamationmark.triangle") {
                    Button {
                        Task { await loadHistory() }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .fontWeight(.semibold)
                    }
                }
            }
        } else if history.isEmpty {
            Section {
                LoamEmptyState(
                    title: "Nothing shared yet",
                    message: "Expenses you split with \(person.displayName) and repayments between you will show up here.",
                    systemImage: "clock.arrow.circlepath"
                )
            }
        } else {
            ForEach(monthGroups, id: \.month) { group in
                Section {
                    ForEach(group.entries) { entry in
                        BalanceHistoryRow(entry: entry, personName: person.displayName, fallbackCurrency: fallbackCurrency)
                    }
                } header: {
                    Text(group.month.formatted(.dateTime.month(.wide).year()))
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
    }

    private var monthGroups: [(month: Date, entries: [BalanceHistoryEntry])] {
        let calendar = AppPreferences.calendar
        let grouped = Dictionary(grouping: history) { entry in
            calendar.dateInterval(of: .month, for: entry.occurredAt)?.start ?? entry.occurredAt
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private func loadHistory() async {
        guard let userId = authSession.userId else { return }
        do {
            history = try await balanceStore.history(with: person.personId, userId: userId)
            loadError = nil
        } catch {
            // Leaving the screen cancels the load; that is not a failure.
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }
}

/// Green when money comes back to the viewer, orange when the viewer owes.
enum BalanceTone {
    static func color(for amountMinor: Int) -> Color {
        amountMinor > 0 ? .green : .orange
    }
}

private struct BalanceHistoryRow: View {
    let entry: BalanceHistoryEntry
    let personName: String
    let fallbackCurrency: String

    /// Pending and declined shares, and reversed repayments, don't move the balance.
    private var counts: Bool {
        switch entry.kind {
        case .purchase: entry.status == nil || entry.status == .accepted
        case .repayment: true
        case .reversal: false
        }
    }

    private var money: Money {
        Money(amountMinor: abs(entry.amountMinor), currencyCode: entry.currencyCode ?? fallbackCurrency)
    }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(HomeTheme.text)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormatter.string(from: money))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .strikethrough(!counts)
                    .foregroundStyle(counts ? HomeTheme.text : HomeTheme.tertiary)
                Text(entry.occurredAt.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(HomeTheme.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if entry.kind == .purchase {
            let category = entry.category ?? .other
            Image(systemName: category.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(category.color)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
        } else {
            Image(systemName: entry.kind == .reversal ? "arrow.uturn.backward" : "banknote")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(entry.kind == .reversal ? HomeTheme.tertiary : BalanceTone.color(for: -entry.amountMinor))
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
        }
    }

    private var subtitle: String {
        switch entry.kind {
        case .purchase:
            switch entry.status {
            case .pending: return "Awaiting acceptance"
            case .rejected: return "Declined"
            default: return entry.amountMinor > 0 ? "You lent" : "You borrowed"
            }
        case .repayment:
            return entry.amountMinor > 0 ? "You paid \(personName)" : "\(personName) paid you"
        case .reversal:
            return "Repayment reversed"
        }
    }

    private var subtitleColor: Color {
        switch entry.kind {
        case .purchase:
            switch entry.status {
            case .pending: return .orange
            case .rejected: return HomeTheme.tertiary
            default: return BalanceTone.color(for: entry.amountMinor)
            }
        case .repayment, .reversal:
            return HomeTheme.secondary
        }
    }
}
