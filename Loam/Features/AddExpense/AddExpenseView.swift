import SwiftUI

private enum AddExpenseStep {
    case amount
    case details
}

struct AddExpenseView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var householdStore: HouseholdStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: AddExpenseStep = .amount
    @State private var amountText = ""
    @State private var category: ExpenseCategory = .groceries
    @State private var title = ""
    @State private var note = ""
    @State private var spentAt = Date()
    @State private var isRepeating = false
    @State private var repeatInterval: RecurringIntervalUnit = .month
    @State private var isSplit = false
    @State private var selectedPartnerUserIds: Set<UUID> = []
    @State private var splitMode: SplitExpenseMode = .equal
    @State private var paidByUserId: UUID?
    @State private var myPercentage = 50
    @State private var myExactAmountText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var cancelTapCount = 0
    @State private var continueTapCount = 0
    @FocusState private var amountFocused: Bool
    @FocusState private var titleFocused: Bool
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

            amountDisplay
                .padding(.horizontal, 28)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    cancelTapCount += 1
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.65), trigger: cancelTapCount)

                Button {
                    continueTapCount += 1
                    step = .details
                    amountFocused = false
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)
                .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.75), trigger: continueTapCount)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
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
                TextField("Title (optional)", text: $title)
                    .textInputAutocapitalization(.sentences)
                    .focused($titleFocused)
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
            } footer: {
                Text("If you leave the title empty, the category name is shown instead.")
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

            if let userId = authSession.userId,
               !splitPartners.isEmpty {
                SplitExpenseSection(
                    totalMinor: parsedMoney?.amountMinor ?? 0,
                    myUserId: userId,
                    myDisplayName: authSession.displayName ?? "You",
                    availablePartners: splitPartners,
                    selectedPartnerUserIds: $selectedPartnerUserIds,
                    isSplit: $isSplit,
                    splitMode: $splitMode,
                    paidByUserId: Binding(
                        get: { paidByUserId ?? userId },
                        set: { paidByUserId = $0 }
                    ),
                    myPercentage: $myPercentage,
                    myExactAmountText: $myExactAmountText
                )
            }
        }
        .onChange(of: selectedPartnerUserIds) { _, newValue in
            if newValue.count != 1, splitMode != .equal {
                splitMode = .equal
            }
        }
        .onAppear {
            if paidByUserId == nil {
                paidByUserId = authSession.userId
            }
            if isSplit, !SplitPartnerOption.isSplitAvailable(usesRemoteBackend: SupabaseConfig.isConfigured) {
                isSplit = false
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

    private var splitPartners: [SplitPartnerOption] {
        guard let userId = authSession.userId else { return [] }
        #if DEBUG
        return SplitPartnerOption.available(
            for: userId,
            savedMainAccount: authSession.savedMainAccountPartnerOption
        )
        #else
        return SplitPartnerOption.available(for: userId)
        #endif
    }

    private var selectedSplitPartners: [SplitPartnerOption] {
        splitPartners.filter { selectedPartnerUserIds.contains($0.userId) }
    }

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

        if isSplit && isRepeating {
            errorMessage = "Recurring expenses cannot be split yet."
            return
        }

        if isSplit, let validationError = SplitExpenseSection.validationError(
            totalMinor: money.amountMinor,
            isSplit: isSplit,
            selectedPartnerCount: selectedPartnerUserIds.count,
            splitMode: selectedPartnerUserIds.count == 1 ? splitMode : .equal,
            myPercentage: myPercentage,
            myExactAmountText: myExactAmountText
        ) {
            errorMessage = validationError
            return
        }

        do {
            if isSplit {
                let partners = selectedSplitPartners
                let household = try await householdStore.ensureSplitHousehold(
                    userId: userId,
                    userDisplayName: authSession.displayName ?? "You",
                    partners: partners
                )
                try await expenseStore.addSplit(
                    amountMinor: money.amountMinor,
                    category: category,
                    title: title.nilIfBlank,
                    note: note,
                    spentAt: spentAt,
                    userId: userId,
                    householdId: household.id,
                    splitMode: partners.count == 1 ? splitMode : .equal,
                    paidBy: paidByUserId ?? userId,
                    partnerUserIds: partners.map(\.userId),
                    myPercentage: myPercentage,
                    myExactAmountMinor: Money(majorString: myExactAmountText)?.amountMinor
                )
            } else {
                let recurring: RecurringRuleRecord?
                if isRepeating {
                    recurring = RecurringRuleRecord(
                        ownerUserId: userId,
                        amountMinor: money.amountMinor,
                        category: category,
                        title: title.nilIfBlank,
                        note: note.nilIfBlank,
                        intervalUnit: repeatInterval,
                        nextOccurrence: spentAt
                    )
                } else {
                    recurring = nil
                }

                try await expenseStore.addPersonal(
                    amountMinor: money.amountMinor,
                    category: category,
                    title: title.nilIfBlank,
                    note: note,
                    spentAt: spentAt,
                    userId: userId,
                    recurring: recurring
                )
            }
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

#Preview {
    AddExpenseView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
        .environmentObject(HouseholdStore())
}
