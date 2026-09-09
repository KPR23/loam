import SwiftUI

private struct SplitFormState: Equatable {
    var splitMode: SplitExpenseMode
    var paidByUserId: UUID
    var myPercentage: Int
    var myExactAmountText: String

    static func from(expense: ExpenseRecord, myUserId: UUID) -> SplitFormState {
        let partnerUserId = TestPartner.userId
        let myShare = expense.shares.first(where: { $0.userId == myUserId })?.amountMinor ?? expense.amountMinor
        let partnerShare = expense.shares.first(where: { $0.userId == partnerUserId })?.amountMinor

        if expense.isShared,
           let partnerShare,
           myShare * 2 == expense.amountMinor,
           partnerShare * 2 == expense.amountMinor {
            return SplitFormState(
                splitMode: .equal,
                paidByUserId: expense.paidBy,
                myPercentage: 50,
                myExactAmountText: ""
            )
        }

        if expense.isShared, expense.amountMinor > 0 {
            let pct = Int(round(Double(myShare) / Double(expense.amountMinor) * 100))
            if pct > 0, pct < 100 {
                return SplitFormState(
                    splitMode: .percentage,
                    paidByUserId: expense.paidBy,
                    myPercentage: pct,
                    myExactAmountText: ""
                )
            }
            return SplitFormState(
                splitMode: .exactAmount,
                paidByUserId: expense.paidBy,
                myPercentage: 50,
                myExactAmountText: MoneyFormatter.typingAmount(
                    from: Money(amountMinor: myShare, currencyCode: expense.currency)
                )
            )
        }

        return SplitFormState(
            splitMode: .equal,
            paidByUserId: expense.paidBy,
            myPercentage: 50,
            myExactAmountText: ""
        )
    }
}

struct SplitExpenseSheet: View {
    let expense: ExpenseRecord
    let myUserId: UUID

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var householdStore: HouseholdStore
    @Environment(\.dismiss) private var dismiss

    @State private var formState: SplitFormState
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(expense: ExpenseRecord, myUserId: UUID) {
        self.expense = expense
        self.myUserId = myUserId
        _formState = State(initialValue: SplitFormState.from(expense: expense, myUserId: myUserId))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Amount") {
                        Text(MoneyFormatter.string(from: expense.money))
                            .monospacedDigit()
                    }
                    LabeledContent("Category") {
                        Text(expense.category.displayName)
                    }
                    LabeledContent("Date") {
                        Text(expense.spentAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let note = expense.note, !note.isEmpty {
                        LabeledContent("Note") {
                            Text(note)
                        }
                    }
                }

                SplitExpenseSection(
                    totalMinor: expense.amountMinor,
                    myUserId: myUserId,
                    myDisplayName: authSession.displayName ?? "You",
                    partnerUserId: TestPartner.userId,
                    partnerDisplayName: TestPartner.displayName,
                    isSplit: .constant(true),
                    splitMode: $formState.splitMode,
                    paidByUserId: $formState.paidByUserId,
                    myPercentage: $formState.myPercentage,
                    myExactAmountText: $formState.myExactAmountText
                )
            }
            .navigationTitle(expense.isShared ? "Edit split" : "Split expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving)
                }
            }
            .alert("Couldn’t save split", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() async {
        if let validationError = SplitExpenseSection.validationError(
            totalMinor: expense.amountMinor,
            splitMode: formState.splitMode,
            myPercentage: formState.myPercentage,
            myExactAmountText: formState.myExactAmountText
        ) {
            errorMessage = validationError
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let household = try await householdStore.ensureTestHousehold(
                userId: myUserId,
                userDisplayName: authSession.displayName ?? "You"
            )
            try await expenseStore.applySplit(
                to: expense.id,
                userId: myUserId,
                householdId: household.id,
                splitMode: formState.splitMode,
                paidBy: formState.paidByUserId,
                partnerUserId: TestPartner.userId,
                myPercentage: formState.myPercentage,
                myExactAmountMinor: Money(majorString: formState.myExactAmountText)?.amountMinor
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    let userId = UUID()
    SplitExpenseSheet(
        expense: ExpenseRecord(
            amountMinor: 4200,
            category: .groceries,
            note: "Weekly shop",
            paidBy: userId,
            createdBy: userId,
            shares: [ExpenseShareRecord(userId: userId, amountMinor: 4200)]
        ),
        myUserId: userId
    )
    .environmentObject(AuthSession())
    .environmentObject(ExpenseStore())
    .environmentObject(HouseholdStore())
}
