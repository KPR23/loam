import SwiftUI

private struct ProposeEditFormState: Equatable {
    var amountText: String
    var category: ExpenseCategory
    var title: String
    var note: String
    var location: ExpenseLocation?
    var spentAt: Date
    var selectedPartnerUserIds: Set<UUID>
    var splitMode: SplitExpenseMode
    var paidByUserId: UUID
    var myPercentage: Int
    var myExactAmountText: String
    var participantPercentages: [UUID: Int]
    var participantAmountTexts: [UUID: String]
    var message: String

    static func from(expense: ExpenseRecord, myUserId: UUID) -> ProposeEditFormState {
        let partnerUserIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: myUserId)
        let splitSeed = SplitFormSeed.from(expense: expense, myUserId: myUserId)
        return ProposeEditFormState(
            amountText: Money.sanitizeTypingInput(MoneyFormatter.typingAmount(from: expense.money)),
            category: expense.category,
            title: expense.title ?? "",
            note: expense.note ?? "",
            location: expense.location,
            spentAt: expense.spentAt,
            selectedPartnerUserIds: partnerUserIds,
            splitMode: splitSeed.splitMode,
            paidByUserId: expense.paidBy,
            myPercentage: splitSeed.myPercentage,
            myExactAmountText: splitSeed.myExactAmountText,
            participantPercentages: splitSeed.participantPercentages,
            participantAmountTexts: splitSeed.participantAmountTexts,
            message: ""
        )
    }
}

struct ProposeEditSheet: View {
    let expense: ExpenseRecord
    let myUserId: UUID

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @Environment(\.dismiss) private var dismiss

    @State private var formState: ProposeEditFormState
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var splitPartners: [SplitPartnerOption] {
        #if DEBUG
        SplitPartnerOption.available(
            for: myUserId,
            savedMainAccount: authSession.savedMainAccountPartnerOption
        )
        #else
        SplitPartnerOption.available(for: myUserId)
        #endif
    }

    private var recentSplitPartners: [SplitPartnerOption] {
        SplitPartnerOption.recent(
            available: splitPartners,
            myUserId: myUserId,
            seedingFrom: expenseStore.expenses
        )
    }

    init(expense: ExpenseRecord, myUserId: UUID) {
        self.expense = expense
        self.myUserId = myUserId
        _formState = State(initialValue: ProposeEditFormState.from(expense: expense, myUserId: myUserId))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your suggested changes will be sent to the expense owner. Nothing changes until they approve.")
                        .font(.footnote)
                        .foregroundStyle(HomeTheme.secondary)
                }

                Section("Amount") {
                    HStack {
                        TextField("0,00", text: sanitizedAmountBinding)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                        Text(expense.currency)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Details") {
                    TextField("Title (optional)", text: $formState.title)
                        .textInputAutocapitalization(.sentences)
                    ExpenseCategoryPicker(category: $formState.category)
                    DatePicker("Date", selection: $formState.spentAt, displayedComponents: .date)
                    ExpenseLocationPicker(location: $formState.location)
                    TextField("Note", text: $formState.note, axis: .vertical)
                        .lineLimit(2...4)
                }

                SplitExpenseSection(
                    totalMinor: Money(majorString: formState.amountText, currencyCode: expense.currency)?.amountMinor ?? 0,
                    myUserId: myUserId,
                    myDisplayName: authSession.displayName ?? "You",
                    availablePartners: splitPartners,
                    currencyCode: expense.currency,
                    recentPartners: recentSplitPartners,
                    requiresPartner: true,
                    selectedPartnerUserIds: $formState.selectedPartnerUserIds,
                    splitMode: $formState.splitMode,
                    paidByUserId: $formState.paidByUserId,
                    participantPercentages: $formState.participantPercentages,
                    participantAmountTexts: $formState.participantAmountTexts
                )

                Section("Message to owner") {
                    TextField("Optional note explaining your changes", text: $formState.message, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle("Suggest changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { LoamFeedback.tap(); dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        SavingActionLabel(title: "Send", isSaving: isSaving)
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving || validationError != nil)
                }
            }
            .sensoryFeedback(.error, trigger: errorMessage) { _, newValue in newValue != nil }
            .alert("Couldn't send proposal", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var sanitizedAmountBinding: Binding<String> {
        Binding(
            get: { formState.amountText },
            set: { formState.amountText = Money.sanitizeTypingInput($0) }
        )
    }

    private func submit() async {
        guard !isSaving else { return }
        guard let amountMinor = Money(majorString: formState.amountText, currencyCode: expense.currency)?.amountMinor, amountMinor > 0 else {
            errorMessage = "Enter a valid amount."
            return
        }

        if let validationError {
            errorMessage = validationError
            return
        }

        let partnerIds = Array(formState.selectedPartnerUserIds)
        let shares = SplitCalculator.split(
            totalMinor: amountMinor,
            mode: formState.splitMode,
            myUserId: myUserId,
            partnerUserIds: partnerIds,
            paidByUserId: formState.paidByUserId,
            myPercentage: formState.myPercentage,
            myExactAmountMinor: Money(majorString: formState.myExactAmountText, currencyCode: expense.currency)?.amountMinor,
            participantPercentages: formState.participantPercentages,
            participantExactAmountMinors: participantExactAmountMinors
        )

        isSaving = true
        defer { isSaving = false }

        do {
            let trimmedTitle = formState.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNote = formState.note.trimmingCharacters(in: .whitespacesAndNewlines)
            try await expenseStore.proposeEdit(
                for: expense,
                userId: myUserId,
                amountMinor: amountMinor,
                category: formState.category,
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                location: formState.location,
                spentAt: formState.spentAt,
                paidBy: formState.paidByUserId,
                shares: shares.map { ExpenseShareRecord(userId: $0.userId, amountMinor: $0.amountMinor) },
                message: formState.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            LoamFeedback.success()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var validationError: String? {
        guard let amountMinor = Money(majorString: formState.amountText, currencyCode: expense.currency)?.amountMinor,
              amountMinor > 0 else {
            return "Enter a valid amount."
        }
        return SplitExpenseSection.validationError(
            totalMinor: amountMinor,
            selectedPartnerCount: formState.selectedPartnerUserIds.count,
            requiresPartner: true,
            splitMode: formState.splitMode,
            participantUserIds: [myUserId] + Array(formState.selectedPartnerUserIds),
            participantPercentages: formState.participantPercentages,
            participantAmountTexts: formState.participantAmountTexts
        )
    }

    private var participantExactAmountMinors: [UUID: Int] {
        formState.participantAmountTexts.compactMapValues { Money(majorString: $0, currencyCode: expense.currency)?.amountMinor }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
