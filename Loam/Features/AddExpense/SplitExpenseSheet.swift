import SwiftUI

private struct SplitFormState: Equatable {
    var selectedPartnerUserIds: Set<UUID>
    var splitMode: SplitExpenseMode
    var paidByUserId: UUID
    var myPercentage: Int
    var myExactAmountText: String
    var participantPercentages: [UUID: Int]
    var participantAmountTexts: [UUID: String]

    static func from(expense: ExpenseRecord, myUserId: UUID) -> SplitFormState {
        let partnerUserIds = SplitPartnerOption.partnerUserIds(in: expense, myUserId: myUserId)
        let seed = SplitFormSeed.from(expense: expense, myUserId: myUserId)
        return SplitFormState(
            selectedPartnerUserIds: partnerUserIds,
            splitMode: seed.splitMode,
            paidByUserId: expense.paidBy,
            myPercentage: seed.myPercentage,
            myExactAmountText: seed.myExactAmountText,
            participantPercentages: seed.participantPercentages,
            participantAmountTexts: seed.participantAmountTexts
        )
    }
}

struct SplitExpenseSheet: View {
    let expense: ExpenseRecord
    let myUserId: UUID

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var formState: SplitFormState
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var splitPartners: [SplitPartnerOption] {
        if SupabaseConfig.isConfigured { return connectionStore.connections.filter { $0.userId != myUserId } }
        #if DEBUG
        return SplitPartnerOption.available(
            for: myUserId,
            savedMainAccount: authSession.savedMainAccountPartnerOption
        )
        #else
        return SplitPartnerOption.available(for: myUserId)
        #endif
    }

    private var selectedSplitPartners: [SplitPartnerOption] {
        splitPartners.filter { formState.selectedPartnerUserIds.contains($0.userId) }
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
        _formState = State(initialValue: SplitFormState.from(expense: expense, myUserId: myUserId))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let note = expense.note, !note.isEmpty {
                    Section {
                        LabeledContent("Note") {
                            Text(note)
                        }
                    }
                    .listRowBackground(HomeTheme.surface)
                }

                SplitExpenseSection(
                    totalMinor: expense.amountMinor,
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
            }
            .scrollContentBackground(.hidden)
            .background(HomeTheme.background.ignoresSafeArea())
            .task { await connectionStore.refresh(userId: myUserId) }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle(expense.isShared ? "Edit split" : "Split expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { LoamFeedback.tap(); dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        SavingActionLabel(title: "Save", isSaving: isSaving)
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving || validationError != nil)
                }
            }
            .errorToast($errorMessage)
        }
    }

    private func save() async {
        guard !isSaving else { return }
        if let validationError {
            errorMessage = validationError
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let partners = selectedSplitPartners
            try await expenseStore.applySplit(
                to: expense.id,
                userId: myUserId,
                splitMode: formState.splitMode,
                paidBy: formState.paidByUserId,
                partnerUserIds: partners.map(\.userId),
                myPercentage: formState.myPercentage,
                myExactAmountMinor: Money(majorString: formState.myExactAmountText)?.amountMinor,
                participantPercentages: formState.participantPercentages,
                participantExactAmountMinors: participantExactAmountMinors,
                undoable: true
            )
            LoamFeedback.success()
            dismiss()
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private var validationError: String? {
        SplitExpenseSection.validationError(
            totalMinor: expense.amountMinor,
            selectedPartnerCount: formState.selectedPartnerUserIds.count,
            requiresPartner: true,
            splitMode: formState.splitMode,
            participantUserIds: [myUserId] + Array(formState.selectedPartnerUserIds),
            participantPercentages: formState.participantPercentages,
            participantAmountTexts: formState.participantAmountTexts
        )
    }

    private var participantExactAmountMinors: [UUID: Int] {
        formState.participantAmountTexts.compactMapValues { Money(majorString: $0)?.amountMinor }
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
}
