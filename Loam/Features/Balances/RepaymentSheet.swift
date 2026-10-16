import SwiftUI

/// Records money paid outside Loam, either by the viewer to someone they owe or
/// to the viewer by someone who owes them. Laid out like the amount step of
/// Add expense: who it's for, a large amount, then actions.
struct RepaymentSheet: View {
    /// Open balances in either direction; each is one person in one currency.
    let balances: [PersonBalance]

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var balanceStore: BalanceStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: String
    @State private var amountText = ""
    @State private var note = ""
    @State private var paidAt = Date()
    @State private var isSaving = false
        @State private var errorMessage: String?
    @FocusState private var amountFocused: Bool
    @FocusState private var noteFocused: Bool

    init(balances: [PersonBalance], selected: PersonBalance? = nil) {
        self.balances = balances
        let initial = selected ?? balances.first
        _selectedId = State(initialValue: initial?.id ?? "")
        _amountText = State(initialValue: initial.map { MoneyFormatter.editableAmount(from: $0.money) } ?? "")
    }

    /// Nil once the chosen balance is gone (settled elsewhere, say). Never falls back to someone
    /// else, or an amount typed for one person could be recorded against another.
    private var target: PersonBalance? {
        balances.first { $0.id == selectedId }
    }

    /// The other person owes the viewer, so the money came in rather than went out.
    /// Settling usually means the whole balance, so that is where the amount starts.
    private var fullAmountText: String {
        target.map { MoneyFormatter.editableAmount(from: $0.money) } ?? ""
    }

    private var isReceiving: Bool { (target?.amountMinor ?? 0) > 0 }

    private var parsedMoney: Money? {
        guard let target else { return nil }
        return Money(majorString: amountText, currencyCode: target.currencyCode)
    }

    private var exceedsDebt: Bool {
        guard let target, let parsedMoney else { return false }
        return parsedMoney.amountMinor > target.money.amountMinor
    }

    private var canSave: Bool {
        (parsedMoney?.amountMinor ?? 0) > 0 && !exceedsDebt
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let target {
                    recipientPicker(target)
                        .padding(.top, 8)
                    dateButton
                        .padding(.top, 10)

                    Spacer(minLength: 0)

                    AmountEntryField(
                        text: $amountText,
                        currencyCode: target.currencyCode,
                        focus: $amountFocused,
                        isInvalid: exceedsDebt
                    )
                    debtCaption(target)
                        .padding(.top, 10)

                    Spacer(minLength: 0)

                    controls
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                } else {
                    LoamEmptyState(
                        title: balances.isEmpty ? "Nothing left to settle" : "That balance changed",
                        message: balances.isEmpty
                            ? "Nobody owes anything right now."
                            : "It was settled or updated while you were away. Choose who it was with.",
                        systemImage: "checkmark.circle"
                    ) {
                        if !balances.isEmpty {
                            Menu {
                                recipientOptions
                            } label: {
                                Label("Choose a person", systemImage: "person.crop.circle")
                                    .fontWeight(.semibold)
                            }
                            .menuStyle(.button)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle("Record repayment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        LoamFeedback.tap()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                amountFocused = true
            }
            // A new recipient or currency, or the old one disappearing, restarts at the full balance.
            .onChange(of: target?.id) { _, _ in amountText = fullAmountText }
            .alert("Couldn’t record repayment", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Recipient

    @ViewBuilder
    private func recipientPicker(_ target: PersonBalance) -> some View {
        if balances.count > 1 {
            Menu {
                recipientOptions
            } label: {
                recipientChip(target, showsChevron: true)
            }
            .accessibilityLabel("\(isReceiving ? "Received from" : "Paying") \(target.displayName)")
            .accessibilityHint("Choose who the repayment was with")
        } else {
            recipientChip(target, showsChevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private var recipientOptions: some View {
        Picker("Person", selection: $selectedId) {
            ForEach(balances) { balance in
                Text("\(balance.displayName) · \(balance.direction.lowercased()) \(MoneyFormatter.string(from: balance.money))").tag(balance.id)
            }
        }
    }

    private func recipientChip(_ target: PersonBalance, showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            AvatarView(userId: target.personId, size: 28, name: target.displayName)
            Text("\(isReceiving ? "From" : "To") \(target.displayName)")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(HomeTheme.text)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HomeTheme.secondary)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, showsChevron ? 12 : 14)
        .padding(.vertical, 4)
        .background(HomeTheme.surface, in: Capsule())
    }

    // MARK: - Amount context

    private func debtCaption(_ target: PersonBalance) -> some View {
        HStack(spacing: 8) {
            if exceedsDebt {
                Text(isReceiving ? "That’s more than they owe you" : "That’s more than you owe")
                    .foregroundStyle(.red)
            } else {
                Text("\(target.direction) \(MoneyFormatter.string(from: target.money))")
                    .foregroundStyle(HomeTheme.secondary)
            }
        }
        .font(.system(.footnote, design: .rounded).weight(.medium))
        .monospacedDigit()
        .animation(.easeInOut(duration: 0.18), value: exceedsDebt)
    }

    // MARK: - Date

    private var dateButton: some View {
        DatePicker("Paid on", selection: $paidAt, in: ...Date(), displayedComponents: .date)
            .labelsHidden()
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HomeTheme.secondary)
                        .accessibilityHidden(true)
                    TextField("Add a note", text: $note)
                        .font(.subheadline)
                        .submitLabel(.done)
                        .focused($noteFocused)
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(HomeTheme.surface, in: Capsule())
            }

            Button {
                amountFocused = false
                noteFocused = false
                Task { await save() }
            } label: {
                SavingActionLabel(title: "Record repayment", isSaving: isSaving)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(HomeTheme.accentFill)
            .buttonBorderShape(.capsule)
            .frame(height: 52)
            .disabled(!canSave || isSaving)
        }
    }

    private func save() async {
        guard !isSaving, let target, let money = parsedMoney, let userId = authSession.userId else { return }
        isSaving = true
        defer { isSaving = false }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if isReceiving {
                try await balanceStore.receive(
                    from: target.personId,
                    amountMinor: money.amountMinor,
                    currencyCode: target.currencyCode,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    paidAt: paidAt,
                    userId: userId
                )
            } else {
                try await balanceStore.repay(
                    to: target.personId,
                    amountMinor: money.amountMinor,
                    currencyCode: target.currencyCode,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    paidAt: paidAt,
                    userId: userId
                )
            }
            LoamFeedback.success()
            dismiss()
        } catch {
            LoamFeedback.error()
            errorMessage = error.localizedDescription
        }
    }
}
