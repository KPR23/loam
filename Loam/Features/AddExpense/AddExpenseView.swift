import SwiftUI

struct AddExpenseView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var category: ExpenseCategory = .groceries
    @State private var note = ""
    @State private var spentAt = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.leading)
                        .focused($amountFocused)
                        .accessibilityLabel("Amount")
                } header: {
                    Text("Amount")
                } footer: {
                    Text("PLN · amounts stored in grosze")
                }

                Section("Category") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(ExpenseCategory.allCases) { item in
                            categoryChip(item)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Details") {
                    DatePicker("Date", selection: $spentAt, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                }
            }
            .navigationTitle("Add expense")
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
                    .disabled(!canSave || isSaving)
                }
            }
            .onAppear { amountFocused = true }
            .alert("Couldn’t save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var canSave: Bool {
        Money(majorString: amountText)?.amountMinor ?? 0 > 0
    }

    private func categoryChip(_ item: ExpenseCategory) -> some View {
        let selected = category == item
        return Button {
            category = item
        } label: {
            VStack(spacing: 6) {
                Image(systemName: item.systemImage)
                Text(item.displayName)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func save() async {
        guard let userId = authSession.userId else {
            errorMessage = ExpenseRepositoryError.notSignedIn.localizedDescription
            return
        }
        guard let money = Money(majorString: amountText), money.amountMinor > 0 else {
            errorMessage = "Enter a valid amount."
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            try await expenseStore.addPersonal(
                amountMinor: money.amountMinor,
                category: category,
                note: note,
                spentAt: spentAt,
                userId: userId
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    AddExpenseView()
        .environmentObject(AuthSession())
        .environmentObject(ExpenseStore())
}
