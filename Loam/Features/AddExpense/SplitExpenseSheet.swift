import SwiftUI

private struct SplitFormState: Equatable {
    var selectedPartnerUserIds: Set<UUID>
    var splitMode: SplitExpenseMode
    var paidByUserId: UUID
    var myPercentage: Int
    var myExactAmountText: String

    static func from(expense: ExpenseRecord, myUserId: UUID) -> SplitFormState {
        let partnerUserIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: myUserId)
        let seed = SplitFormSeed.from(expense: expense, myUserId: myUserId)
        return SplitFormState(
            selectedPartnerUserIds: partnerUserIds,
            splitMode: seed.splitMode,
            paidByUserId: expense.paidBy,
            myPercentage: seed.myPercentage,
            myExactAmountText: seed.myExactAmountText
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

    private var selectedSplitPartners: [SplitPartnerOption] {
        splitPartners.filter { formState.selectedPartnerUserIds.contains($0.userId) }
    }

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
                    if expense.hasCustomTitle {
                        LabeledContent("Title") {
                            Text(expense.displayTitle)
                                .font(.system(.body, design: .rounded))
                        }
                    }
                    LabeledContent("Category") {
                        HStack(spacing: 6) {
                            Image(systemName: expense.category.systemImage)
                            Text(expense.category.displayName)
                                .font(.system(.body, design: .rounded))
                        }
                        .foregroundStyle(expense.category.color)
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
                    availablePartners: splitPartners,
                    requiresPartner: true,
                    selectedPartnerUserIds: $formState.selectedPartnerUserIds,
                    splitMode: $formState.splitMode,
                    paidByUserId: $formState.paidByUserId,
                    myPercentage: $formState.myPercentage,
                    myExactAmountText: $formState.myExactAmountText
                )
            }
            .onChange(of: formState.selectedPartnerUserIds) { _, newValue in
                if newValue.count != 1, formState.splitMode != .equal {
                    formState.splitMode = .equal
                }
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
        let effectiveMode = formState.selectedPartnerUserIds.count == 1 ? formState.splitMode : .equal

        if let validationError = SplitExpenseSection.validationError(
            totalMinor: expense.amountMinor,
            selectedPartnerCount: formState.selectedPartnerUserIds.count,
            requiresPartner: true,
            splitMode: effectiveMode,
            myPercentage: formState.myPercentage,
            myExactAmountText: formState.myExactAmountText
        ) {
            errorMessage = validationError
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let partners = selectedSplitPartners
            let household = try await householdStore.ensureSplitHousehold(
                userId: myUserId,
                userDisplayName: authSession.displayName ?? "You",
                partners: partners
            )
            try await expenseStore.applySplit(
                to: expense.id,
                userId: myUserId,
                householdId: household.id,
                splitMode: effectiveMode,
                paidBy: formState.paidByUserId,
                partnerUserIds: partners.map(\.userId),
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
