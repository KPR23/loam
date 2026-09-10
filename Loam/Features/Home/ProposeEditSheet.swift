import SwiftUI

private struct ProposeEditFormState: Equatable {
    var amountText: String
    var category: ExpenseCategory
    var note: String
    var spentAt: Date
    var selectedPartnerUserIds: Set<UUID>
    var splitMode: SplitExpenseMode
    var paidByUserId: UUID
    var myPercentage: Int
    var myExactAmountText: String
    var message: String

    static func from(expense: ExpenseRecord, myUserId: UUID) -> ProposeEditFormState {
        ProposeEditFormState(
            amountText: MoneyFormatter.typingAmount(from: expense.money),
            category: expense.category,
            note: expense.note ?? "",
            spentAt: expense.spentAt,
            selectedPartnerUserIds: SplitPartnerOption.partnerUserIds(in: expense, myUserId: myUserId),
            splitMode: .equal,
            paidByUserId: expense.paidBy,
            myPercentage: 50,
            myExactAmountText: "",
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
                    TextField("0,00", text: $formState.amountText)
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                }

                Section("Details") {
                    Picker("Category", selection: $formState.category) {
                        ForEach(ExpenseCategory.allCases, id: \.self) { category in
                            Label(category.displayName, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }
                    DatePicker("Date", selection: $formState.spentAt, displayedComponents: .date)
                    TextField("Note", text: $formState.note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let amountMinor = Money(majorString: formState.amountText)?.amountMinor {
                    SplitExpenseSection(
                        totalMinor: amountMinor,
                        myUserId: myUserId,
                        myDisplayName: authSession.displayName ?? "You",
                        availablePartners: splitPartners,
                        selectedPartnerUserIds: $formState.selectedPartnerUserIds,
                        isSplit: .constant(true),
                        splitMode: $formState.splitMode,
                        paidByUserId: $formState.paidByUserId,
                        myPercentage: $formState.myPercentage,
                        myExactAmountText: $formState.myExactAmountText
                    )
                }

                Section("Message to owner") {
                    TextField("Optional note explaining your changes", text: $formState.message, axis: .vertical)
                        .lineLimit(2...4)
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

    private func submit() async {
        guard let amountMinor = Money(majorString: formState.amountText)?.amountMinor, amountMinor > 0 else {
            errorMessage = "Enter a valid amount."
            return
        }

        let effectiveMode = formState.selectedPartnerUserIds.count == 1 ? formState.splitMode : .equal
        if let validationError = SplitExpenseSection.validationError(
            totalMinor: amountMinor,
            isSplit: true,
            selectedPartnerCount: formState.selectedPartnerUserIds.count,
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
            let trimmedNote = formState.note.trimmingCharacters(in: .whitespacesAndNewlines)
            try await expenseStore.proposeEdit(
                for: expense,
                userId: myUserId,
                amountMinor: amountMinor,
                category: formState.category,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
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
