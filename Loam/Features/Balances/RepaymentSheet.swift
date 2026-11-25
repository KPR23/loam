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
    @State private var showsDatePicker = false
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
                    Spacer(minLength: 0)

                    AmountEntryField(
                        text: $amountText,
                        currencyCode: target.currencyCode,
                        focus: $amountFocused,
                        isInvalid: exceedsDebt
                    )
                    debtCaption(target)
                        .padding(.top, 6)
                    detailSentence(target)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

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
            .background(HomeTheme.background)
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
            .errorToast($errorMessage)
        }
        // Like Add expense, the keyboard stays up under the actions, so the floating hide button
        // would sit on Record repayment. Tapping outside the fields still hides the keyboard.
        .hidesFloatingKeyboardButton()
    }

    // MARK: - Recipient and date

    /// One line under the amount that reads as a sentence, "Paid to Philip · Today, 24 Nov",
    /// where the name and the date are tappable chips. Wraps onto two lines when it doesn't fit.
    private func detailSentence(_ target: PersonBalance) -> some View {
        let name = recipientMenu(target) {
            sentenceToken(target.displayName, showsChevron: showsRecipientChevron) {
                AvatarView(userId: target.personId, size: 22, name: target.displayName)
            }
        }
        .buttonStyle(.plain)
        let lead = Text(isReceiving ? "Received from" : "Paid to").foregroundStyle(HomeTheme.secondary)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                lead
                name
                Text("·").foregroundStyle(HomeTheme.tertiary)
                dateToken
            }
            VStack(spacing: 6) {
                HStack(spacing: 6) { lead; name }
                HStack(spacing: 6) { Text("on").foregroundStyle(HomeTheme.secondary); dateToken }
            }
        }
        .font(.system(.body, design: .rounded).weight(.medium))
    }

    /// A tinted capsule for the tappable parts of the sentence, led by the person's avatar or a calendar glyph.
    private func sentenceToken<Leading: View>(
        _ title: String,
        showsChevron: Bool,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 6) {
            leading()
            Text(title)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
        }
        .fontWeight(.semibold)
        .foregroundStyle(HomeTheme.solidAccent)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(HomeTheme.solidAccent.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }

    /// Wraps a recipient label in the person picker when there is more than one open balance.
    @ViewBuilder
    private func recipientMenu<Label: View>(_ target: PersonBalance, @ViewBuilder label: () -> Label) -> some View {
        if balances.count > 1 {
            Menu {
                recipientOptions
            } label: {
                label()
            }
            .accessibilityLabel("\(isReceiving ? "Received from" : "Paying") \(target.displayName)")
            .accessibilityHint("Choose who the repayment was with")
        } else {
            label()
                .accessibilityElement(children: .combine)
        }
    }

    private var showsRecipientChevron: Bool { balances.count > 1 }

    private var recipientOptions: some View {
        Picker("Person", selection: $selectedId) {
            ForEach(balances) { balance in
                Text("\(balance.displayName) · \(balance.direction.lowercased()) \(MoneyFormatter.string(from: balance.money))").tag(balance.id)
            }
        }
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

    private var dateToken: some View {
        Button(action: openDatePicker) {
            sentenceToken(paidOnText, showsChevron: false) {
                Image(systemName: "calendar")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Paid on \(paidOnText)")
        .accessibilityHint("Choose the day of the repayment")
        .popover(isPresented: $showsDatePicker) { datePickerPopover }
    }

    private var paidOnText: String { DaySectionTitle.string(for: paidAt, showsYearOutsideCurrent: true) }

    private func openDatePicker() {
        LoamFeedback.tap()
        amountFocused = false
        noteFocused = false
        showsDatePicker = true
    }

    private var datePickerPopover: some View {
        DatePicker("Paid on", selection: $paidAt, in: ...Date(), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(.horizontal, 12)
            .frame(width: 320)
            .presentationCompactAdaptation(.popover)
            .onChange(of: paidAt) { _, _ in showsDatePicker = false }
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
            errorMessage = UserFacingError.message(for: error)
        }
    }
}
