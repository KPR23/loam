import SwiftUI

/// Records money paid outside Loam to someone the viewer owes. Laid out like
/// the amount step of Add expense: who it's for, a large amount, then actions.
struct RepaymentSheet: View {
    /// Balances the viewer owes; each is one person in one currency.
    let debts: [PersonBalance]

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

    init(debts: [PersonBalance], selected: PersonBalance? = nil) {
        self.debts = debts
        _selectedId = State(initialValue: (selected ?? debts.first)?.id ?? "")
    }

    /// Nil once the chosen balance is gone (settled elsewhere, say). Never falls back to someone
    /// else, or an amount typed for one person could be recorded against another.
    private var target: PersonBalance? {
        debts.first { $0.id == selectedId }
    }

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
                        title: debts.isEmpty ? "Nothing left to repay" : "That balance changed",
                        message: debts.isEmpty
                            ? "You don’t owe anyone right now."
                            : "It was settled or updated while you were away. Choose who you paid.",
                        systemImage: "checkmark.circle"
                    ) {
                        if !debts.isEmpty {
                            Menu {
                                recipientOptions
                            } label: {
                                Label("Choose who you paid", systemImage: "person.crop.circle")
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
            // A new recipient or currency, or the old one disappearing, starts the amount over.
            .onChange(of: target?.id) { _, _ in amountText = "" }
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
        if debts.count > 1 {
            Menu {
                recipientOptions
            } label: {
                recipientChip(target, showsChevron: true)
            }
            .accessibilityLabel("Paying \(target.displayName)")
            .accessibilityHint("Choose who you paid")
        } else {
            recipientChip(target, showsChevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private var recipientOptions: some View {
        Picker("Pay", selection: $selectedId) {
            ForEach(debts) { debt in
                Text("\(debt.displayName) · \(MoneyFormatter.string(from: debt.money))").tag(debt.id)
            }
        }
    }

    private func recipientChip(_ target: PersonBalance, showsChevron: Bool) -> some View {
        HStack(spacing: 8) {
            AvatarView(userId: target.personId, size: 28, name: target.displayName)
            Text("To \(target.displayName)")
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
                Text("That’s more than you owe")
                    .foregroundStyle(.red)
            } else {
                Text("You owe \(MoneyFormatter.string(from: target.money))")
                    .foregroundStyle(HomeTheme.secondary)
            }

            Button {
                LoamFeedback.selection()
                amountText = MoneyFormatter.editableAmount(from: target.money)
            } label: {
                Text("Pay in full")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(HomeTheme.accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(HomeTheme.accent)
            }
            .buttonStyle(LoamPressStyle())
            .opacity(parsedMoney?.amountMinor == target.money.amountMinor ? 0 : 1)
            .accessibilityHidden(parsedMoney?.amountMinor == target.money.amountMinor)
        }
        .font(.system(.footnote, design: .rounded).weight(.medium))
        .monospacedDigit()
        .animation(.easeInOut(duration: 0.18), value: exceedsDebt)
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
                .frame(height: 44)
                .background(HomeTheme.surface, in: Capsule())

                DatePicker("Paid on", selection: $paidAt, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("Paid on")
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
            .frame(height: 44)
            .disabled(!canSave || isSaving)
        }
    }

    private func save() async {
        guard !isSaving, let target, let money = parsedMoney, let userId = authSession.userId else { return }
        isSaving = true
        defer { isSaving = false }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await balanceStore.repay(
                to: target.personId,
                amountMinor: money.amountMinor,
                currencyCode: target.currencyCode,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                paidAt: paidAt,
                userId: userId
            )
            LoamFeedback.success()
            dismiss()
        } catch {
            LoamFeedback.error()
            errorMessage = error.localizedDescription
        }
    }
}
