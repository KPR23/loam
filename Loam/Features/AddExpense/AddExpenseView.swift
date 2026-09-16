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
    @State private var location: ExpenseLocation?
    @State private var spentAt: Date
    @State private var isRepeating = false
    @State private var repeatPreset: RecurringPreset = .monthly
    @State private var repeatInterval: RecurringIntervalUnit = .month
    @State private var repeatIntervalCount = 1
    @State private var repeatHasEndDate = false
    @State private var repeatEndDate = Date()
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

    private var isSplit: Bool { !selectedPartnerUserIds.isEmpty }

    /// - Parameter initialSpentAt: Default expense date (Home passes the first day of the viewed month).
    init(initialSpentAt: Date = Date()) {
        _spentAt = State(initialValue: Calendar.current.startOfDay(for: initialSpentAt))
    }

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

            Spacer(minLength: 0)

            GeometryReader { proxy in
                let spacing: CGFloat = 10
                let contentWidth = proxy.size.width - spacing
                HStack(spacing: spacing) {
                    ExpenseCategoryPicker(category: $category, style: .chip)
                        .frame(width: contentWidth * 0.75, height: proxy.size.height, alignment: .leading)

                    Button {
                        continueTapCount += 1
                        step = .details
                        amountFocused = false
                        titleFocused = false
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!canContinue)
                    .accessibilityLabel("Continue")
                    .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.75), trigger: continueTapCount)
                    .frame(width: contentWidth * 0.25, height: proxy.size.height)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
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
        ZStack {
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
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.42), value: amountDisplayValue)

            TextField("", text: sanitizedAmountBinding)
                .keyboardType(.decimalPad)
                .focused($amountFocused)
                .opacity(0.015)
                .accessibilityLabel("Amount")
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private var sanitizedAmountBinding: Binding<String> {
        Binding(
            get: { amountText },
            set: { amountText = Money.sanitizeTypingInput($0) }
        )
    }

    // MARK: - Details step

    private var detailsStep: some View {
        Form {
            Section {
                TextField("Title (optional)", text: $title)
                    .textInputAutocapitalization(.sentences)
                    .focused($titleFocused)

                DatePicker("Date", selection: $spentAt, displayedComponents: .date)
                ExpenseLocationPicker(location: $location)
            } footer: {
                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No title set — the category name will be shown instead.")
                }
            }

            Section {
                Toggle("Repeat", isOn: $isRepeating)

                if isRepeating {
                    Picker("Frequency", selection: $repeatPreset) {
                        ForEach(RecurringPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }

                    if repeatPreset == .custom {
                        Stepper(value: $repeatIntervalCount, in: 1...365, step: 1) {
                            Text("Every \(repeatIntervalCount)")
                        }
                        Picker("Unit", selection: $repeatInterval) {
                            ForEach(RecurringIntervalUnit.allCases) { unit in
                                Text(repeatIntervalCount == 1 ? unit.singularName : unit.pluralName)
                                    .tag(unit)
                            }
                        }
                    }

                    Toggle("Ends", isOn: $repeatHasEndDate)

                    if repeatHasEndDate {
                        DatePicker(
                            "End date",
                            selection: $repeatEndDate,
                            in: spentAt...,
                            displayedComponents: .date
                        )
                    }
                }
            } footer: {
                if isRepeating {
                    Text(repeatFooterText)
                }
            }
            .onChange(of: repeatPreset) { _, newValue in
                if let interval = newValue.interval {
                    repeatInterval = interval.unit
                    repeatIntervalCount = interval.count
                }
            }
            .onChange(of: spentAt) { _, newValue in
                if repeatEndDate < newValue {
                    repeatEndDate = newValue
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
                    requiresPartner: false,
                    selectedPartnerUserIds: $selectedPartnerUserIds,
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
                selectedPartnerUserIds = []
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        switch step {
        case .amount:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    cancelTapCount += 1
                    dismiss()
                }
                .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.65), trigger: cancelTapCount)
            }

        case .details:
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
        if amountText.hasSuffix(","), let money = Money(majorString: amountText) {
            return MoneyFormatter.typingAmount(from: money) + ","
        }
        if let money = parsedMoney {
            return MoneyFormatter.typingAmount(from: money)
        }
        return amountText
    }

    private var repeatScheduleDescription: String {
        repeatInterval.scheduleDescription(intervalCount: repeatIntervalCount).lowercased()
    }

    private var repeatFooterText: String {
        var text = "Creates a recurring expense like a subscription. Repeats \(repeatScheduleDescription), starting from the date above."
        if repeatHasEndDate {
            text += " Ends on \(repeatEndDate.formatted(date: .abbreviated, time: .omitted))."
        }
        return text
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

        if isSplit, let validationError = SplitExpenseSection.validationError(
            totalMinor: money.amountMinor,
            selectedPartnerCount: selectedPartnerUserIds.count,
            requiresPartner: true,
            splitMode: selectedPartnerUserIds.count == 1 ? splitMode : .equal,
            myPercentage: myPercentage,
            myExactAmountText: myExactAmountText
        ) {
            errorMessage = validationError
            return
        }

        do {
            let recurring: RecurringRuleRecord?
            if isRepeating {
                recurring = RecurringRuleRecord(
                    ownerUserId: userId,
                    amountMinor: money.amountMinor,
                    category: category,
                    title: title.nilIfBlank,
                    note: note.nilIfBlank,
                    location: location,
                    intervalUnit: repeatInterval,
                    intervalCount: max(1, repeatIntervalCount),
                    startDate: spentAt,
                    endDate: repeatHasEndDate ? repeatEndDate : nil
                )
            } else {
                recurring = nil
            }

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
                    location: location,
                    spentAt: spentAt,
                    userId: userId,
                    householdId: household.id,
                    splitMode: partners.count == 1 ? splitMode : .equal,
                    paidBy: paidByUserId ?? userId,
                    partnerUserIds: partners.map(\.userId),
                    myPercentage: myPercentage,
                    myExactAmountMinor: Money(majorString: myExactAmountText)?.amountMinor,
                    recurring: recurring
                )
            } else {
                try await expenseStore.addPersonal(
                    amountMinor: money.amountMinor,
                    category: category,
                    title: title.nilIfBlank,
                    note: note,
                    location: location,
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
