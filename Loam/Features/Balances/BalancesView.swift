import SwiftUI

struct BalancesView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var balanceStore: BalanceStore
    @State private var repaymentTarget: PersonBalance?
    @State private var amountText = ""
    @State private var note = ""
    @State private var paidAt = Date()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summary
                        .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                Section {
                    if balanceStore.isLoading && balanceStore.snapshot.balances.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if balanceStore.snapshot.balances.isEmpty {
                        emptyState
                    } else {
                        ForEach(balanceStore.snapshot.balances) { balance in
                            if balance.amountMinor < 0 {
                                Button {
                                    LoamFeedback.tap()
                                    repaymentTarget = balance
                                    amountText = ""
                                    note = ""
                                    paidAt = Date()
                                } label: {
                                    personRow(balance)
                                }
                                .buttonStyle(LoamPressStyle())
                                .accessibilityHint("Record a repayment to \(balance.displayName)")
                            } else {
                                personRow(balance)
                            }
                        }
                    }
                } header: {
                    Text("People")
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                } footer: {
                    if !balanceStore.snapshot.youOwe.isEmpty {
                        Text("Tap someone you owe to record a repayment.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 2, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .navigationTitle("Balances")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: authSession.userId) { await balanceStore.refresh(userId: authSession.userId) }
            .refreshable { await balanceStore.refresh(userId: authSession.userId) }
        }
        .sheet(item: $repaymentTarget) { target in repaymentSheet(target) }
        .alert("Couldn’t record repayment", isPresented: Binding(
            get: { balanceStore.lastError != nil },
            set: { if !$0 { balanceStore.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(balanceStore.lastError ?? "")
        }
    }

    private var summary: some View {
        VStack(spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    totals("You owe", monies: balanceStore.snapshot.youOwe, symbol: "arrow.up.right")
                    totals("Owed to you", monies: balanceStore.snapshot.owedToYou, symbol: "arrow.down.left")
                }
                VStack(spacing: 24) {
                    totals("You owe", monies: balanceStore.snapshot.youOwe, symbol: "arrow.up.right")
                    totals("Owed to you", monies: balanceStore.snapshot.owedToYou, symbol: "arrow.down.left")
                }
            }
            Text("Shared expenses, settled together.")
                .font(.footnote)
                .foregroundStyle(HomeTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func totals(_ title: String, monies: [Money], symbol: String) -> some View {
        return VStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(HomeTheme.secondary)
            if monies.isEmpty {
                Text("—")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(HomeTheme.text)
            } else {
                ForEach(monies, id: \.currencyCode) { money in
                    VStack(spacing: 2) {
                        Text(MoneyFormatter.heroAmount(from: money))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(HomeTheme.text)
                        Text(money.currencyCode)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(HomeTheme.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(monies.map { MoneyFormatter.string(from: $0) }.joined(separator: ", "))")
    }

    private func personRow(_ balance: PersonBalance) -> some View {
        HStack(spacing: 12) {
            AvatarView(userId: balance.personId, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(balance.displayName)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(HomeTheme.text)
                Text(balance.direction)
                    .font(.caption)
                    .foregroundStyle(HomeTheme.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(MoneyFormatter.string(from: balance.money))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HomeTheme.text)
                if balance.amountMinor < 0 {
                    Text("Record repayment")
                        .font(.caption)
                        .foregroundStyle(HomeTheme.accent)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(HomeTheme.accent)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text("All settled up")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(HomeTheme.text)
            Text("Balances appear here once shared expenses are accepted.")
                .font(.subheadline)
                .foregroundStyle(HomeTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func repaymentSheet(_ target: PersonBalance) -> some View {
        NavigationStack {
            Form {
                Section("Payment to \(target.displayName) in \(target.currencyCode)") {
                    TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                    DatePicker("Paid on", selection: $paidAt, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                }
                Section { Text("This records a payment made outside Loam. It reduces the balance only; it never creates an expense.").font(.footnote).foregroundStyle(.secondary) }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle("Record repayment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { LoamFeedback.tap(); repaymentTarget = nil }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await saveRepayment(target) } } label: { SavingActionLabel(title: "Save", isSaving: isSaving) }.disabled(isSaving || (Money(majorString: amountText, currencyCode: target.currencyCode)?.amountMinor ?? 0) <= 0)
                }
            }
        }
    }

    private func saveRepayment(_ target: PersonBalance) async {
        guard !isSaving else { return }
        guard let userId = authSession.userId, let money = Money(majorString: amountText, currencyCode: target.currencyCode) else { return }
        isSaving = true; defer { isSaving = false }
        do { try await balanceStore.repay(to: target.personId, amountMinor: money.amountMinor, currencyCode: target.currencyCode, note: note.nilIfBlank, paidAt: paidAt, userId: userId); LoamFeedback.success(); repaymentTarget = nil }
        catch { LoamFeedback.error(); balanceStore.lastError = error.localizedDescription }
    }
}

private extension String { var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self } }

#Preview {
    BalancesView().environmentObject(AuthSession()).environmentObject(BalanceStore())
}
