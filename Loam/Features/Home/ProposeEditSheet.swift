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
                    totalMinor: Money(majorString: formState.amountText)?.amountMinor ?? 0,
                    myUserId: myUserId,
                    myDisplayName: authSession.displayName ?? "You",
                    availablePartners: splitPartners,
                    recentPartners: recentSplitPartners,
                    requiresPartner: true,
                    selectedPartnerUserIds: $formState.selectedPartnerUserIds,
                    splitMode: $formState.splitMode,
                    paidByUserId: $formState.paidByUserId,
                    myPercentage: $formState.myPercentage,
                    myExactAmountText: $formState.myExactAmountText
                )

                Section("Message to owner") {
                    TextField("Optional note explaining your changes", text: $formState.message, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .onChange(of: formState.selectedPartnerUserIds) { _, newValue in
                if newValue.count != 1, formState.splitMode != .equal {
                    formState.splitMode = .equal
                }
            }
            .navigationTitle("Suggest changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await submit() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving)
                }
            }
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
        guard let amountMinor = Money(majorString: formState.amountText)?.amountMinor, amountMinor > 0 else {
            errorMessage = "Enter a valid amount."
            return
        }

        let effectiveMode = formState.selectedPartnerUserIds.count == 1 ? formState.splitMode : .equal
        if let validationError = SplitExpenseSection.validationError(
            totalMinor: amountMinor,
            selectedPartnerCount: formState.selectedPartnerUserIds.count,
            requiresPartner: true,
            splitMode: effectiveMode,
            myPercentage: formState.myPercentage,
            myExactAmountText: formState.myExactAmountText
        ) {
            errorMessage = validationError
            return
        }

        let partnerIds = Array(formState.selectedPartnerUserIds)
        let shares = SplitCalculator.split(
            totalMinor: amountMinor,
            mode: effectiveMode,
            myUserId: myUserId,
            partnerUserIds: partnerIds,
            paidByUserId: formState.paidByUserId,
            myPercentage: formState.myPercentage,
            myExactAmountMinor: Money(majorString: formState.myExactAmountText)?.amountMinor
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
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
