import SwiftUI
import UniformTypeIdentifiers

/// Imports a Splitwise CSV export: expenses become splits with people without an account,
/// repayments land in Balances history.
struct SplitwiseImportView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var balanceStore: BalanceStore

    private enum Target: Hashable {
        case new
        case existing(UUID)
    }

    @State private var showsImporter = false
    @State private var export: SplitwiseImport.Export?
    @State private var meIndex: Int?
    @State private var targets: [Int: Target] = [:]
    @State private var isImporting = false
    @State private var result: String?
    @State private var error: String?

    private var placeholders: [SplitPartnerOption] { connectionStore.connections.filter(\.isPlaceholder) }

    var body: some View {
        List {
            Section {
                Button { showsImporter = true } label: {
                    Label(export == nil ? "Choose Splitwise CSV" : "Choose another file", systemImage: "doc.badge.plus")
                }
            } footer: {
                Text("In Splitwise, open your friend, tap Export as spreadsheet and save the CSV. Everyone in the file is added as a person without an account, so nobody gets notifications.")
            }
            .listRowBackground(HomeTheme.surface)

            if let export {
                Section("Which one are you?") {
                    Picker("You", selection: $meIndex) {
                        Text("Choose").tag(Int?.none)
                        ForEach(export.people.indices, id: \.self) { Text(export.people[$0]).tag(Int?.some($0)) }
                    }
                }
                .listRowBackground(HomeTheme.surface)

                if let meIndex {
                    let involved = SplitwiseImport.involvedPeople(in: export, meIndex: meIndex)
                    Section("People") {
                        ForEach(involved, id: \.self) { column in
                            Picker(export.people[column], selection: binding(for: column, export: export)) {
                                Text("Add as new person").tag(Target.new)
                                ForEach(placeholders) { Text($0.displayName).tag(Target.existing($0.userId)) }
                            }
                        }
                    }
                    .listRowBackground(HomeTheme.surface)

                    Section {
                        summary(export: export, meIndex: meIndex)
                        Button { Task { await runImport(export: export, meIndex: meIndex, involved: involved) } } label: {
                            if isImporting { ProgressView() } else { Text("Import") }
                        }
                        .disabled(isImporting)
                    } header: {
                        Text("Summary")
                    } footer: {
                        Text("Importing the same file again won’t create duplicates. Expenses paid by more than one person and expenses that don’t involve you are skipped.")
                    }
                    .listRowBackground(HomeTheme.surface)
                }
            }

            if let result {
                Section { Text(result) }.listRowBackground(HomeTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
        .navigationTitle("Import from Splitwise")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { picked in
            load(picked)
        }
        .errorToast($error)
        .task { await connectionStore.refresh(userId: authSession.userId) }
    }

    @ViewBuilder
    private func summary(export: SplitwiseImport.Export, meIndex: Int) -> some View {
        let plan = SplitwiseImport.plan(export, meIndex: meIndex, me: authSession.userId ?? UUID(), mapping: previewMapping(export: export, meIndex: meIndex))
        LabeledContent("Expenses", value: "\(plan.expenses.count)")
        LabeledContent("Repayments", value: "\(plan.payments.count)")
        if !plan.skipped.isEmpty { LabeledContent("Skipped", value: "\(plan.skipped.count)") }
    }

    private func previewMapping(export: SplitwiseImport.Export, meIndex: Int) -> [Int: UUID] {
        Dictionary(uniqueKeysWithValues: export.people.indices.filter { $0 != meIndex }.map { ($0, UUID()) })
    }

    private func binding(for column: Int, export: SplitwiseImport.Export) -> Binding<Target> {
        Binding(
            get: {
                if let chosen = targets[column] { return chosen }
                let match = placeholders.first { $0.displayName.caseInsensitiveCompare(export.people[column]) == .orderedSame }
                return match.map { .existing($0.userId) } ?? .new
            },
            set: { targets[column] = $0 }
        )
    }

    private func load(_ picked: Result<URL, Error>) {
        result = nil
        do {
            let url = try picked.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw SplitwiseImport.ParseError.notSplitwise }
            export = try SplitwiseImport.parse(text)
            meIndex = nil
            targets = [:]
        } catch {
            export = nil
            self.error = UserFacingError.message(for: error)
        }
    }

    private func runImport(export: SplitwiseImport.Export, meIndex: Int, involved: [Int]) async {
        guard let me = authSession.userId else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            var mapping: [Int: UUID] = [:]
            for column in involved {
                switch binding(for: column, export: export).wrappedValue {
                case .existing(let id): mapping[column] = id
                case .new: mapping[column] = try await connectionStore.createPlaceholder(name: export.people[column]).userId
                }
            }
            let plan = SplitwiseImport.plan(export, meIndex: meIndex, me: me, mapping: mapping)
            let expenses = ExpenseRepositoryFactory.make()
            let existing = Set(try await expenses.fetchExpenses(ids: plan.expenses.map(\.expense.id)).map(\.id))
            var created = 0
            var failed = 0
            for planned in plan.expenses where !existing.contains(planned.expense.id) {
                do { _ = try await expenses.create(planned.expense); created += 1 } catch { failed += 1 }
            }
            let balances = BalanceRepositoryFactory.make()
            var payments = 0
            for payment in plan.payments.sorted(by: { $0.date < $1.date }) {
                do {
                    if payment.isReceived {
                        try await balances.createReceivedRepayment(from: payment.personId, to: me, amountMinor: payment.amountMinor, currencyCode: payment.currency, note: payment.note, paidAt: payment.date, operationId: payment.operationId)
                    } else {
                        try await balances.createRepayment(from: me, to: payment.personId, amountMinor: payment.amountMinor, currencyCode: payment.currency, note: payment.note, paidAt: payment.date, operationId: payment.operationId)
                    }
                    payments += 1
                } catch { failed += 1 }
            }
            await expenseStore.refresh(userId: me)
            await balanceStore.refresh(userId: me)
            let alreadyThere = existing.count
            result = "Imported \(created) expenses and \(payments) repayments."
                + (alreadyThere > 0 ? " \(alreadyThere) were already imported." : "")
                + (failed > 0 ? " \(failed) failed, import again to retry them." : "")
            ToastCenter.shared.showSuccess("Splitwise import finished")
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}
