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
                    HStack {
                        total("You owe", amount: balanceStore.snapshot.youOweMinor, tint: .red)
                        Divider()
                        total("Owed to you", amount: balanceStore.snapshot.owedToYouMinor, tint: .green)
                    }
                    .padding(.vertical, 6)
                }

                Section("People") {
                    if balanceStore.snapshot.balances.isEmpty {
                        ContentUnavailableView("No balances", systemImage: "scale.3d", description: Text("Accepted shared purchases and repayments will appear here."))
                    } else {
                        ForEach(balanceStore.snapshot.balances) { balance in
                            Button { repaymentTarget = balance; amountText = ""; note = ""; paidAt = Date() } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(balance.displayName).foregroundStyle(.primary)
                                        Text(balance.direction).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(MoneyFormatter.string(from: balance.money))
                                        .font(.body.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(balance.amountMinor >= 0 ? .green : .red)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(balance.amountMinor >= 0)
                        }
                    }
                }
            }
            .navigationTitle("Balances")
            .task(id: authSession.userId) { await balanceStore.refresh(userId: authSession.userId) }
            .refreshable { await balanceStore.refresh(userId: authSession.userId) }
        }
        .sheet(item: $repaymentTarget) { target in repaymentSheet(target) }
    }

    private func total(_ title: String, amount: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(MoneyFormatter.string(from: Money(amountMinor: amount, currencyCode: "PLN")))
                .font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(tint)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func repaymentSheet(_ target: PersonBalance) -> some View {
        NavigationStack {
            Form {
                Section("Payment to \(target.displayName)") {
                    TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                    DatePicker("Paid on", selection: $paidAt, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                }
                Section { Text("This records a payment made outside Loam. It reduces the balance only; it never creates an expense.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Record repayment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { repaymentTarget = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveRepayment(target) } }.disabled(isSaving || (Money(majorString: amountText)?.amountMinor ?? 0) <= 0)
                }
            }
        }
    }

    private func saveRepayment(_ target: PersonBalance) async {
        guard let userId = authSession.userId, let money = Money(majorString: amountText) else { return }
        isSaving = true; defer { isSaving = false }
        do { try await balanceStore.repay(to: target.personId, amountMinor: money.amountMinor, note: note.nilIfBlank, paidAt: paidAt, userId: userId); repaymentTarget = nil }
        catch { balanceStore.lastError = error.localizedDescription }
    }
}

private extension String { var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self } }

#Preview {
    BalancesView().environmentObject(AuthSession()).environmentObject(BalanceStore())
}
