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
    @Environment(\.scenePhase) private var scenePhase
    @State private var history: [BalanceHistoryEntry] = []
    @State private var hasLoaded = false
    /// Bumped by every load; only the newest may update the screen.
    @State private var historyRequest = 0
    @State private var loadError: String?
    @State private var showsRepayment = false

    private var balances: [PersonBalance] {
        balanceStore.snapshot.balances.filter { $0.personId == person.personId }
    }

    private var debts: [PersonBalance] {
        balances.filter { $0.amountMinor < 0 }
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 16, trailing: 0))
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
        .toolbar {
            // The name and face appear once, up here, so the page below can lead with the balance.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    AvatarView(userId: person.personId, size: 28, name: person.displayName)
                        .accessibilityHidden(true)
                    Text(person.displayName)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(HomeTheme.text)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
        }
        // Reload whenever balances change, e.g. after a repayment or a pull to refresh.
        .task(id: balanceStore.snapshot) { await loadHistory() }
        // A friend can accept or decline while the app is away without changing any balance.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadHistory() } }
        }
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
        VStack(spacing: 16) {
            standing

            if !debts.isEmpty {
                Button {
                    LoamFeedback.tap()
                    showsRepayment = true
                } label: {
                    Text("Record repayment")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: 280, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(HomeTheme.accentFill)
                .buttonBorderShape(.capsule)
                .accessibilityHint("Records money you paid \(person.displayName) outside Loam")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var standing: some View {
        if balances.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityHidden(true)
                Text("All settled up")
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.green.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 10) {
                ForEach(balances) { balance in
                    VStack(spacing: 2) {
                        Text(balance.amountMinor > 0 ? "Owes you" : "You owe")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundStyle(BalanceTone.color(for: balance.amountMinor))
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(MoneyFormatter.heroAmount(from: balance.money))
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(HomeTheme.text)
                                .contentTransition(.numericText(value: Double(balance.money.amountMinor)))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(balance.currencyCode)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
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
                        BalanceHistoryRow(entry: entry)
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

    /// Loads overlap (foreground, balance changes, pull to refresh), so a slower earlier
    /// request must not replace rows a newer one already showed, such as a new repayment.
    private func loadHistory() async {
        guard let userId = authSession.userId else { return }
        historyRequest += 1
        let request = historyRequest
        do {
            let loaded = try await balanceStore.history(with: person.personId, userId: userId)
            guard request == historyRequest else { return }
            history = loaded
            loadError = nil
        } catch {
            // Leaving the screen cancels the load; that is not a failure.
            guard request == historyRequest,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
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

    /// Pending and declined shares, and reversed repayments, don't move the balance.
    private var counts: Bool {
        switch entry.kind {
        case .purchase: entry.purchaseStatus == .accepted
        case .repayment: true
        case .reversal: false
        }
    }

    /// Servers without per-row currencies get the bare number; guessing would mislabel
    /// settled or mixed-currency history.
    private var amountText: String {
        if let currencyCode = entry.currencyCode {
            return MoneyFormatter.string(from: Money(amountMinor: abs(entry.amountMinor), currencyCode: currencyCode))
        }
        return (Decimal(abs(entry.amountMinor)) / 100).formatted(.number.precision(.fractionLength(2)))
    }

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(HomeTheme.text)
                    .lineLimit(2)
                Text(entry.occurredAt.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption)
                    .foregroundStyle(HomeTheme.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .strikethrough(!counts)
                    .foregroundStyle(counts ? HomeTheme.text : HomeTheme.tertiary)
                    .accessibilityLabel(entry.currencyCode == nil ? "\(amountText), currency unavailable" : amountText)
                Text(status)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(statusColor)
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
            Image(systemName: entry.kind == .reversal ? "arrow.uturn.backward.circle.fill" : "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(entry.kind == .reversal ? HomeTheme.tertiary : BalanceTone.color(for: -entry.amountMinor))
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
        }
    }

    /// Short enough to sit under the amount; the page title already names the person.
    private var status: String {
        switch entry.kind {
        case .purchase:
            switch entry.purchaseStatus {
            case .pending: return "Awaiting"
            case .rejected: return "Declined"
            default: return entry.amountMinor > 0 ? "You lent" : "You borrowed"
            }
        case .repayment:
            return entry.amountMinor > 0 ? "You paid" : "Paid you"
        case .reversal:
            return "Reversed"
        }
    }

    private var statusColor: Color {
        switch entry.kind {
        case .purchase:
            switch entry.purchaseStatus {
            case .pending: return .orange
            case .rejected: return HomeTheme.tertiary
            default: return BalanceTone.color(for: entry.amountMinor)
            }
        case .repayment, .reversal:
            return HomeTheme.secondary
        }
    }
}
