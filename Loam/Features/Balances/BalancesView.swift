import SwiftUI

struct BalancesView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var balanceStore: BalanceStore
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsRepayment = false
    @State private var showAddFriend = false

    private var snapshot: BalanceSnapshot { balanceStore.snapshot }
    private var debts: [PersonBalance] { snapshot.balances.filter { $0.amountMinor < 0 } }
    private var credits: [PersonBalance] { snapshot.balances.filter { $0.amountMinor > 0 } }

    /// Connections with nothing outstanding, so their history stays one tap away.
    private var settledPeople: [SplitPartnerOption] {
        let open = Set(snapshot.balances.map(\.personId))
        return connectionStore.connections.filter { !open.contains($0.userId) }
    }

    private var isEmpty: Bool { snapshot.balances.isEmpty && connectionStore.connections.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if balanceStore.isLoading && snapshot.balances.isEmpty {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                            .listRowBackground(Color.clear)
                    }
                } else if isEmpty {
                    Section { emptyState }
                } else {
                    Section {
                        BalancesHero(snapshot: snapshot)
                            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: debts.isEmpty ? 8 : 18, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                        if !debts.isEmpty {
                            repaymentButton
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }

                    peopleSection("Owed to you", balances: credits)
                    peopleSection("You owe", balances: debts)

                    if !settledPeople.isEmpty {
                        Section {
                            ForEach(settledPeople) { person in
                                NavigationLink(value: BalancePerson(personId: person.userId, displayName: person.displayName)) {
                                    BalancePersonRow(personId: person.userId, name: person.displayName, caption: "Settled up", captionColor: HomeTheme.tertiary) {
                                        EmptyView()
                                    }
                                }
                            }
                        } header: {
                            sectionHeader("Settled up")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 2, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle("Balances")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: BalancePerson.self) { person in
                PersonBalanceView(person: person)
            }
            .toolbar {
                if !isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            LoamFeedback.tap()
                            showAddFriend = true
                        } label: {
                            Label("Add a friend", systemImage: "person.badge.plus")
                        }
                    }
                }
            }
            .task(id: authSession.userId) { await balanceStore.refresh(userId: authSession.userId) }
            .refreshable { await balanceStore.refresh(userId: authSession.userId) }
            // Others accept shares and record repayments while the app is in the background.
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await balanceStore.refresh(userId: authSession.userId) } } }
        }
        .sheet(isPresented: $showsRepayment) {
            RepaymentSheet(debts: debts)
        }
        .sheet(isPresented: $showAddFriend) {
            NavigationStack {
                AddFriendView { _ in }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAddFriend = false }
                        }
                    }
            }
        }
        .alert("Couldn’t load balances", isPresented: Binding(
            get: { balanceStore.lastError != nil },
            set: { if !$0 { balanceStore.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(balanceStore.lastError ?? "")
        }
    }

    private var repaymentButton: some View {
        Button {
            LoamFeedback.tap()
            showsRepayment = true
        } label: {
            Label("Record repayment", systemImage: "arrow.up.right")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 20)
        .accessibilityHint("Records money you paid someone outside Loam")
    }

    @ViewBuilder
    private func peopleSection(_ title: String, balances: [PersonBalance]) -> some View {
        if !balances.isEmpty {
            Section {
                ForEach(balances) { balance in
                    NavigationLink(value: BalancePerson(personId: balance.personId, displayName: balance.displayName)) {
                        BalancePersonRow(
                            personId: balance.personId,
                            name: balance.displayName,
                            caption: balance.direction,
                            captionColor: BalanceTone.color(for: balance.amountMinor)
                        ) {
                            Text(MoneyFormatter.string(from: balance.money))
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(HomeTheme.text)
                        }
                    }
                }
            } header: {
                sectionHeader(title)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .textCase(nil)
    }

    private var emptyState: some View {
        LoamEmptyState(
            title: "No balances yet",
            message: "Connect with a friend using a code, then split an expense with them. Once they accept it, who owes whom shows up here.",
            systemImage: "person.2"
        ) {
            Button {
                Telemetry.capture(.emptyStateActionTapped(.balances))
                showAddFriend = true
            } label: {
                Label("Add a friend", systemImage: "person.badge.plus")
                    .fontWeight(.semibold)
            }
        }
        .onAppear { Telemetry.capture(.emptyStateViewed(.balances)) }
    }
}

// MARK: - Hero

/// The net position across everyone, with how it splits between what's owed in each direction.
private struct BalancesHero: View {
    let snapshot: BalanceSnapshot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct CurrencyPosition: Identifiable {
        let currencyCode: String
        let owedMinor: Int
        let oweMinor: Int
        var id: String { currencyCode }
        var netMinor: Int { owedMinor - oweMinor }
    }

    /// The default currency first, so the hero leads with the one people use.
    private var positions: [CurrencyPosition] {
        let codes = Set(snapshot.owedToYou.map(\.currencyCode) + snapshot.youOwe.map(\.currencyCode))
        let preferred = AppPreferences.defaultCurrencyCode
        return codes.sorted { ($0 == preferred ? 0 : 1, $0) < ($1 == preferred ? 0 : 1, $1) }.map { code in
            CurrencyPosition(
                currencyCode: code,
                owedMinor: snapshot.owedToYou.first { $0.currencyCode == code }?.amountMinor ?? 0,
                oweMinor: snapshot.youOwe.first { $0.currencyCode == code }?.amountMinor ?? 0
            )
        }
    }

    var body: some View {
        if let primary = positions.first {
            VStack(spacing: 18) {
                net(primary)
                breakdown(primary)
                    .padding(.horizontal, 20)
                if positions.count > 1 {
                    otherCurrencies(Array(positions.dropFirst()))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.42), value: snapshot)
        } else {
            settled
        }
    }

    private func net(_ position: CurrencyPosition) -> some View {
        let money = Money(amountMinor: abs(position.netMinor), currencyCode: position.currencyCode)
        return VStack(spacing: 4) {
            Text(netTitle(position.netMinor))
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(HomeTheme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MoneyFormatter.heroAmount(from: money))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(HomeTheme.text)
                    .contentTransition(.numericText(value: Double(money.amountMinor)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(position.currencyCode)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeTheme.secondary)
            }
            .padding(.horizontal, 28)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(netTitle(position.netMinor)), \(MoneyFormatter.string(from: money))")
    }

    private func netTitle(_ netMinor: Int) -> String {
        if netMinor > 0 { return "You’re owed overall" }
        if netMinor < 0 { return "You owe overall" }
        return "You’re even overall"
    }

    private func breakdown(_ position: CurrencyPosition) -> some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let total = max(position.owedMinor + position.oweMinor, 1)
                let gap: CGFloat = position.owedMinor > 0 && position.oweMinor > 0 ? 4 : 0
                let available = proxy.size.width - gap
                HStack(spacing: gap) {
                    if position.owedMinor > 0 {
                        Capsule()
                            .fill(Color.green.gradient)
                            .frame(width: available * CGFloat(position.owedMinor) / CGFloat(total))
                    }
                    if position.oweMinor > 0 {
                        Capsule()
                            .fill(Color.orange.gradient)
                            .frame(width: available * CGFloat(position.oweMinor) / CGFloat(total))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            HStack(alignment: .top) {
                legend("Owed to you", minor: position.owedMinor, currencyCode: position.currencyCode, color: .green, alignment: .leading)
                Spacer(minLength: 12)
                legend("You owe", minor: position.oweMinor, currencyCode: position.currencyCode, color: .orange, alignment: .trailing)
            }
        }
    }

    private func legend(_ title: String, minor: Int, currencyCode: String, color: Color, alignment: HorizontalAlignment) -> some View {
        let money = Money(amountMinor: minor, currencyCode: currencyCode)
        return VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
            }
            .font(.system(.caption, design: .rounded).weight(.medium))
            .foregroundStyle(HomeTheme.secondary)
            Text(MoneyFormatter.string(from: money))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(minor > 0 ? HomeTheme.text : HomeTheme.tertiary)
                .contentTransition(.numericText(value: Double(minor)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(MoneyFormatter.string(from: money))")
    }

    private func otherCurrencies(_ others: [CurrencyPosition]) -> some View {
        HStack(spacing: 8) {
            ForEach(others) { position in
                let money = Money(amountMinor: abs(position.netMinor), currencyCode: position.currencyCode)
                Text("\(position.netMinor < 0 ? "You owe" : "Owed") \(MoneyFormatter.string(from: money))")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(BalanceTone.color(for: position.netMinor))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(BalanceTone.color(for: position.netMinor).opacity(0.12), in: Capsule())
            }
        }
    }

    private var settled: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 64, height: 64)
                .background(Color.green.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text("All settled up")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(HomeTheme.text)
            Text("Nobody owes anything right now. Open a friend to see what you’ve shared.")
                .font(.subheadline)
                .foregroundStyle(HomeTheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .onAppear { Telemetry.capture(.emptyStateViewed(.balancesSettled)) }
    }
}

// MARK: - Rows

private struct BalancePersonRow<Trailing: View>: View {
    let personId: UUID
    let name: String
    let caption: String
    let captionColor: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(userId: personId, size: 40, name: name)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(HomeTheme.text)
                    .lineLimit(1)
                Text(caption)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(captionColor)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows your history with \(name)")
    }
}

#Preview {
    BalancesView().environmentObject(AuthSession()).environmentObject(BalanceStore()).environmentObject(ConnectionStore())
}
