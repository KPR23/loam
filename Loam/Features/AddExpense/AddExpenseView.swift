import SwiftUI

private enum AddExpenseStep {
    case amount
    case details
}

struct AddExpenseView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: AddExpenseStep = .amount
    @State private var amountText = ""
    @State private var category: ExpenseCategory = .groceries
    @State private var note = ""
    @State private var spentAt = Date()
    @State private var isRepeating = false
    @State private var repeatInterval: RecurringIntervalUnit = .month
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var cancelTapCount = 0
    @State private var continueTapCount = 0
    @FocusState private var amountFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .amount:
                    amountStep
                case .details:
                    detailsStep
                }
            }
            .navigationTitle(step == .amount ? "Add expense" : "Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task(id: step) {
                guard step == .amount else { return }
                await focusAmountField()
            }
            .alert("Couldn’t save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .sensoryFeedback(.selection, trigger: amountText)
    }

    // MARK: - Amount step

    private var amountStep: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 32) {
                amountDisplay

                HStack(spacing: 12) {
                    Button("Cancel") {
                        cancelTapCount += 1
                        dismiss()
                    }
                    .buttonStyle(AmountStepButtonStyle(role: .secondary))
                    .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.65), trigger: cancelTapCount)

                    Button("Continue") {
                        continueTapCount += 1
                        step = .details
                        amountFocused = false
                    }
                    .buttonStyle(AmountStepButtonStyle(role: .primary))
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.45)
                    .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.75), trigger: continueTapCount)
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            amountFocused = true
        }
    }

    private var amountDisplay: some View {
        ZStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(amountDisplayText)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(parsedMoney != nil || !amountText.isEmpty ? .primary : .tertiary)
                    .contentTransition(.numericText(value: amountDisplayValue))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text("PLN")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.42), value: amountDisplayValue)

            TextField("", text: $amountText)
                .keyboardType(.decimalPad)
                .focused($amountFocused)
                .opacity(0.015)
                .accessibilityLabel("Amount")
        }
    }

    // MARK: - Details step

    private var detailsStep: some View {
        Form {
            Section {
                DatePicker("Date", selection: $spentAt, displayedComponents: .date)
            }

            Section {
                Picker("Category", selection: $category) {
                    ForEach(ExpenseCategory.allCases) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .font(.body)
                                .foregroundStyle(item.color)
                                .frame(width: 22, alignment: .center)
                            Text(item.displayName)
                        }
                        .tag(item)
                    }
                }
            }

            Section {
                Toggle("Repeat", isOn: $isRepeating)

                if isRepeating {
                    Picker("Frequency", selection: $repeatInterval) {
                        ForEach(RecurringIntervalUnit.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                }
            } footer: {
                if isRepeating {
                    Text("Creates a recurring expense like a subscription. The next charge is scheduled from the date above.")
                }
            }

            Section {
                TextField("Note (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($noteFocused)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if step == .details {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    step = .amount
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .fontWeight(.semibold)
                .disabled(isSaving)
            }
        }
    }

    // MARK: - Helpers

    private var parsedMoney: Money? {
        Money(majorString: amountText)
    }

    private var canContinue: Bool {
        (parsedMoney?.amountMinor ?? 0) > 0
    }

    private var amountDisplayValue: Double {
        Double(parsedMoney?.amountMinor ?? 0) / 100.0
    }

    private var amountDisplayText: String {
        if amountText.isEmpty {
            return "0"
        }
        if let money = parsedMoney {
            return MoneyFormatter.typingAmount(from: money)
        }
        return amountText
    }

    private func focusAmountField() async {
        try? await Task.sleep(for: .milliseconds(400))
        amountFocused = true
    }

    private func save() async {
        guard let userId = authSession.userId else {
            errorMessage = ExpenseRepositoryError.notSignedIn.localizedDescription
            return
        }
        guard let money = parsedMoney, money.amountMinor > 0 else {
            errorMessage = "Enter a valid amount."
            step = .amount
            await focusAmountField()
            return
        }

        isSaving = true
        defer { isSaving = false }

        let recurring: RecurringRuleRecord?
        if isRepeating {
            recurring = RecurringRuleRecord(
                ownerUserId: userId,
                amountMinor: money.amountMinor,
                category: category,
                note: note.nilIfBlank,
                intervalUnit: repeatInterval,
                nextOccurrence: spentAt
            )
        } else {
            recurring = nil
        }

        do {
            try await expenseStore.addPersonal(
                amountMinor: money.amountMinor,
                category: category,
                note: note,
                spentAt: spentAt,
                userId: userId,
                recurring: recurring
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AmountStepButtonStyle: ButtonStyle {
    enum Role {
        case secondary
        case primary
    }

    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(role == .primary ? 0.12 : 0.06))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch role {
        case .primary:
            return isPressed ? Color.primary.opacity(0.82) : Color.primary
        case .secondary:
            return isPressed ? Color(.tertiarySystemGroupedBackground) : Color(.secondarySystemGroupedBackground)
        }
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch role {
        case .primary:
            return Color(.systemBackground).opacity(isPressed ? 0.9 : 1)
        case .secondary:
            return Color.primary.opacity(isPressed ? 0.72 : 1)
        }
    }
}

#Preview {
    AddExpenseView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
