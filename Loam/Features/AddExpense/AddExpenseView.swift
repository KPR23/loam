import SwiftUI

private enum AddExpenseStep {
    case amount
    case details
}

struct AddExpenseView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When set, the form edits this expense instead of creating a new one.
    private let existingExpense: ExpenseRecord?

    @State private var step: AddExpenseStep = .amount
    @State private var amountText = ""
    @State private var category: ExpenseCategory = .groceries
    @State private var title = ""
    @State private var note = ""
    @State private var location: ExpenseLocation?
    @State private var spentAt = Date()
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
    @State private var participantPercentages: [UUID: Int] = [:]
    @State private var participantAmountTexts: [UUID: String] = [:]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isSplitSheetPresented = false
    @State private var showsPaywall = false
    @FocusState private var amountFocused: Bool
    @FocusState private var titleFocused: Bool
    @FocusState private var noteFocused: Bool

    private var isEditing: Bool { existingExpense != nil }
    private var isSplit: Bool { !selectedPartnerUserIds.isEmpty }
    private var currencyCode: String { existingExpense?.currency ?? AppPreferences.defaultCurrencyCode }

    init(existingExpense: ExpenseRecord? = nil) {
        self.existingExpense = existingExpense
        guard let expense = existingExpense else { return }

        let myUserId = expense.createdBy
        let partnerUserIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: myUserId)
        let splitSeed = SplitFormSeed.from(expense: expense, myUserId: myUserId)

        _amountText = State(
            initialValue: MoneyFormatter.editableAmount(from: expense.money)
        )
        _category = State(initialValue: expense.category)
        _title = State(initialValue: expense.title ?? "")
        _note = State(initialValue: expense.note ?? "")
        _location = State(initialValue: expense.location)
        _spentAt = State(initialValue: expense.spentAt)
        _selectedPartnerUserIds = State(initialValue: partnerUserIds)
        _splitMode = State(initialValue: splitSeed.splitMode)
        _paidByUserId = State(initialValue: expense.paidBy)
        _myPercentage = State(initialValue: splitSeed.myPercentage)
        _myExactAmountText = State(initialValue: splitSeed.myExactAmountText)
        _participantPercentages = State(initialValue: splitSeed.participantPercentages)
        _participantAmountTexts = State(initialValue: splitSeed.participantAmountTexts)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .amount:
                    amountStep.transition(.opacity)
                case .details:
                    detailsStep.transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: step)
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task(id: step) {
                guard step == .amount else { return }
                await focusAmountField()
            }
            .sensoryFeedback(.error, trigger: errorMessage) { _, newValue in newValue != nil }
            .alert("Couldn’t save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .sheet(isPresented: $isSplitSheetPresented) {
            splitConfigurationSheet
        }
        .sensoryFeedback(.selection, trigger: amountText)
        .sensoryFeedback(.selection, trigger: isRepeating)
        .sensoryFeedback(.selection, trigger: repeatHasEndDate)
    }

    private var navigationTitle: String {
        switch step {
        case .amount:
            return isEditing ? "Edit expense" : "Add expense"
        case .details:
            return "Details"
        }
    }

    // MARK: - Amount step

    private var amountStep: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            amountDisplay

            Spacer(minLength: 0)

            GeometryReader { proxy in
                let spacing: CGFloat = 10
                let buttonWidth = (proxy.size.width - spacing) / 2
                VStack(spacing: spacing) {
                    ExpenseCategoryPicker(category: $category, style: .chip)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 44)

                    HStack(spacing: spacing) {
                        if !isEditing {
                            Button {
                                amountFocused = false
                                Task { await save() }
                            } label: {
                                Label("Quick add", systemImage: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.white, in: Capsule())
                            .disabled(!canContinue)
                            .accessibilityHint("Saves this expense without opening details")
                            .frame(width: buttonWidth, height: 44)
                        }

                        Button {
                            LoamFeedback.tap()
                            step = .details
                            amountFocused = false
                            titleFocused = false
                        } label: {
                            Label("Next", systemImage: "arrow.right")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(!canContinue)
                        .accessibilityLabel("Add details")
                        .frame(
                            width: isEditing ? proxy.size.width : buttonWidth,
                            height: 44
                        )
                    }
                }
            }
            .frame(height: 98)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
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

                Text(currencyCode)
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
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                amountFocused = true
            }
        )
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

                // An existing note stays editable after Pro lapses.
                if subscriptions.isPro || !note.isEmpty {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($noteFocused)
                } else {
                    Button { showsPaywall = true } label: {
                        HStack {
                            Text("Note (optional)").foregroundStyle(.tertiary)
                            Spacer()
                            ProBadge()
                        }
                    }
                }
            } header: {
                Text("Details")
            }

            if canShowSplitRow {
                Section {
                    Button {
                        LoamFeedback.tap()
                        isSplitSheetPresented = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: splitRowSystemImage)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 22)

                            Text("Split")
                                .foregroundStyle(.primary)

                            Spacer(minLength: 12)

                            Text(splitSummaryText)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Split")
                }
            }

            Section {
                ExpenseLocationPicker(location: $location)
            } header: {
                Text("Merchant")
            }

            if !isEditing {
                Section {
                    Toggle(isOn: repeatBinding) {
                        HStack {
                            Text("Repeat")
                            if !subscriptions.isPro { ProBadge() }
                        }
                    }

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
                } header: {
                    Text("Repeat")
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
            }
        }
        .proPaywall(isPresented: $showsPaywall)
        .onAppear {
            if paidByUserId == nil {
                paidByUserId = authSession.userId
            }
            // Never wipe partners while editing — Release has no partner picker, and clearing
            // would demote shared expenses to personal on Save.
            if !isEditing,
               isSplit,
               !SplitPartnerOption.isSplitAvailable(usesRemoteBackend: SupabaseConfig.isConfigured) {
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
                    LoamFeedback.tap()
                    dismiss()
                }
            }

        case .details:
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    LoamFeedback.tap()
                    step = .amount
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(isSaving)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    SavingActionLabel(title: "Save", isSaving: isSaving)
                }
                .fontWeight(.semibold)
                .disabled(isSaving)
            }
        }
    }

    // MARK: - Helpers

    private var splitPartners: [SplitPartnerOption] {
        guard let userId = authSession.userId else { return [] }
        if SupabaseConfig.isConfigured { return connectionStore.connections.filter { $0.userId != userId } }
        #if DEBUG
        return SplitPartnerOption.available(
            for: userId,
            savedMainAccount: authSession.savedMainAccountPartnerOption
        )
        #else
        return SplitPartnerOption.available(for: userId)
        #endif
    }

    private var recentSplitPartners: [SplitPartnerOption] {
        guard let userId = authSession.userId else { return [] }
        return SplitPartnerOption.recent(
            available: splitPartners,
            myUserId: userId,
            seedingFrom: expenseStore.expenses
        )
    }

    private var selectedSplitPartners: [SplitPartnerOption] {
        splitPartners.filter { selectedPartnerUserIds.contains($0.userId) }
    }

    private var canShowSplitRow: Bool {
        authSession.userId != nil && (SupabaseConfig.isConfigured || !splitPartners.isEmpty)
    }

    private var splitSummaryText: String {
        let partners = selectedSplitPartners
        guard !partners.isEmpty else { return "Not split" }
        if partners.count == 1, let partner = partners.first {
            return "With \(partner.displayName)"
        }
        return "\(partners.count) people"
    }

    private var splitRowSystemImage: String {
        guard let userId = authSession.userId else {
            return "arrow.trianglehead.branch"
        }
        if let paidByUserId, paidByUserId != userId {
            return "arrow.trianglehead.pull"
        }
        return "arrow.trianglehead.branch"
    }

    /// When split UI/partners aren't available, keep existing membership instead of clearing it.
    private var canChangeSplitMembership: Bool {
        guard SplitPartnerOption.isSplitAvailable(usesRemoteBackend: SupabaseConfig.isConfigured) else {
            return false
        }
        if SupabaseConfig.isConfigured {
            return connectionStore.hasLoadedConnections
                && !connectionStore.isLoading
                && connectionStore.lastError == nil
        }
        return !splitPartners.isEmpty
    }

    private var parsedMoney: Money? {
        Money(majorString: amountText, currencyCode: currencyCode)
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

    /// Turning Repeat on opens the paywall for accounts without Pro.
    private var repeatBinding: Binding<Bool> {
        Binding(
            get: { isRepeating },
            set: { isOn in
                if isOn && !subscriptions.isPro {
                    showsPaywall = true
                } else {
                    isRepeating = isOn
                }
            }
        )
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
        guard !Task.isCancelled else { return }
        amountFocused = true
    }

    @ViewBuilder
    private var splitConfigurationSheet: some View {
        if let userId = authSession.userId {
            splitConfigurationForm(userId: userId)
        }
    }

    private func splitConfigurationForm(userId: UUID) -> some View {
        NavigationStack {
            Form {
                SplitExpenseSection(
                    totalMinor: parsedMoney?.amountMinor ?? 0,
                    myUserId: userId,
                    myDisplayName: authSession.displayName ?? "You",
                    availablePartners: splitPartners,
                    currencyCode: currencyCode,
                    recentPartners: recentSplitPartners,
                    requiresPartner: false,
                    selectedPartnerUserIds: $selectedPartnerUserIds,
                    splitMode: $splitMode,
                    paidByUserId: Binding(
                        get: { paidByUserId ?? userId },
                        set: { paidByUserId = $0 }
                    ),
                    participantPercentages: $participantPercentages,
                    participantAmountTexts: $participantAmountTexts
                )
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle("Split expense")
            .task { await connectionStore.refresh(userId: userId) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isSplitSheetPresented = false
                    }
                    .fontWeight(.semibold)
                    .disabled(splitValidationError(userId: userId) != nil)
                }
            }
        }
    }

    private func splitValidationError(userId: UUID) -> String? {
        guard isSplit else { return nil }
        return SplitExpenseSection.validationError(
            totalMinor: parsedMoney?.amountMinor ?? 0,
            selectedPartnerCount: selectedPartnerUserIds.count,
            requiresPartner: true,
            splitMode: splitMode,
            participantUserIds: [userId] + Array(selectedPartnerUserIds),
            participantPercentages: participantPercentages,
            participantAmountTexts: participantAmountTexts
        )
    }

    private func save() async {
        guard !isSaving else { return }
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

        if let validationError = splitValidationError(userId: userId) {
            errorMessage = validationError
            return
        }

        do {
            if let existingExpense {
                try await saveEdit(
                    expense: existingExpense,
                    money: money,
                    userId: userId
                )
            } else {
                try await saveCreate(money: money, userId: userId)
            }
            LoamFeedback.success()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveCreate(money: Money, userId: UUID) async throws {
        let recurring: RecurringRuleRecord?
        if isRepeating {
            recurring = RecurringRuleRecord(
                ownerUserId: userId,
                amountMinor: money.amountMinor,
                currency: currencyCode,
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
            try await expenseStore.addSplit(
                amountMinor: money.amountMinor,
                currency: currencyCode,
                category: category,
                title: title.nilIfBlank,
                note: note,
                location: location,
                spentAt: spentAt,
                userId: userId,
                splitMode: splitMode,
                paidBy: paidByUserId ?? userId,
                partnerUserIds: partners.map(\.userId),
                myPercentage: myPercentage,
                myExactAmountMinor: Money(majorString: myExactAmountText)?.amountMinor,
                participantPercentages: participantPercentages,
                participantExactAmountMinors: participantExactAmountMinors,
                recurring: recurring
            )
        } else {
            try await expenseStore.addPersonal(
                amountMinor: money.amountMinor,
                currency: currencyCode,
                category: category,
                title: title.nilIfBlank,
                note: note,
                location: location,
                spentAt: spentAt,
                userId: userId,
                recurring: recurring
            )
        }
    }

    private func saveEdit(expense: ExpenseRecord, money: Money, userId: UUID) async throws {
        if shouldPreserveExistingSplit(for: expense) {
            try await saveEditPreservingSplit(expense: expense, money: money, userId: userId)
            return
        }

        if isSplit {
            let partners = selectedSplitPartners
            try await expenseStore.update(
                expenseId: expense.id,
                amountMinor: money.amountMinor,
                category: category,
                title: title.nilIfBlank,
                note: note,
                location: location,
                spentAt: spentAt,
                userId: userId,
                splitMode: splitMode,
                paidBy: paidByUserId ?? userId,
                partnerUserIds: partners.map(\.userId),
                myPercentage: myPercentage,
                myExactAmountMinor: Money(majorString: myExactAmountText, currencyCode: currencyCode)?.amountMinor,
                participantPercentages: participantPercentages,
                participantExactAmountMinors: participantExactAmountMinors
            )
        } else {
            try await expenseStore.update(
                expenseId: expense.id,
                amountMinor: money.amountMinor,
                category: category,
                title: title.nilIfBlank,
                note: note,
                location: location,
                spentAt: spentAt,
                userId: userId,
                splitMode: .equal,
                paidBy: userId,
                partnerUserIds: []
            )
        }
    }

    private func shouldPreserveExistingSplit(for expense: ExpenseRecord) -> Bool {
        expense.isShared && !canChangeSplitMembership
    }

    private func saveEditPreservingSplit(expense: ExpenseRecord, money: Money, userId: UUID) async throws {
        let partnerIds = Array(SplitPartnerOption.partnerUserIds(in: expense, myUserId: userId))
        guard !partnerIds.isEmpty else {
            throw ExpenseRepositoryError.invalidShares
        }

        try await expenseStore.update(
            expenseId: expense.id,
            amountMinor: money.amountMinor,
            category: category,
            title: title.nilIfBlank,
            note: note,
            location: location,
            spentAt: spentAt,
            userId: userId,
            splitMode: splitMode,
            paidBy: paidByUserId ?? expense.paidBy,
            partnerUserIds: partnerIds,
            myPercentage: myPercentage,
            myExactAmountMinor: Money(majorString: myExactAmountText, currencyCode: currencyCode)?.amountMinor,
            participantPercentages: participantPercentages,
            participantExactAmountMinors: participantExactAmountMinors
        )
    }

    private var participantExactAmountMinors: [UUID: Int] {
        participantAmountTexts.compactMapValues { Money(majorString: $0, currencyCode: currencyCode)?.amountMinor }
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
}
