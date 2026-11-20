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

    private var friends: [SplitPartnerOption] { connectionStore.connections }

    private func suggestion(for column: Int, export: SplitwiseImport.Export) -> Target {
        let candidates = friends.map { SplitwiseImport.Candidate(id: $0.userId, name: $0.displayName) }
        return SplitwiseImport.suggestMatch(for: export.people[column], in: candidates).map(Target.existing) ?? .new
    }

    /// Two Splitwise people can't be the same Loam person.
    private func hasDuplicateTargets(export: SplitwiseImport.Export, involved: [Int]) -> Bool {
        let ids = involved.compactMap { column -> UUID? in
            if case .existing(let id) = binding(for: column, export: export).wrappedValue { return id }
            return nil
        }
        return Set(ids).count != ids.count
    }

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
                    Section {
                        ForEach(involved, id: \.self) { column in
                            Picker(export.people[column], selection: binding(for: column, export: export)) {
                                Text("Add as new person").tag(Target.new)
                                ForEach(friends) { Text($0.isPlaceholder ? $0.displayName : "\($0.displayName) (friend)").tag(Target.existing($0.userId)) }
                            }
                        }
                    } header: {
                        Text("People")
                    } footer: {
                        Text(hasDuplicateTargets(export: export, involved: involved)
                             ? "Two people are matched to the same person. Pick a different one."
                             : "We matched names to your friends where we could. Friends with an account get the expenses to accept, so they receive a notification; people without an account get them right away.")
                    }
                    .listRowBackground(HomeTheme.surface)

                    Section {
                        summary(export: export, meIndex: meIndex)
                        Button { Task { await runImport(export: export, meIndex: meIndex, involved: involved) } } label: {
                            if isImporting { ProgressView() } else { Text("Import") }
                        }
                        .disabled(isImporting || hasDuplicateTargets(export: export, involved: involved))
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
                targets[column] ?? suggestion(for: column, export: export)
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
            let myName = authSession.displayName ?? ""
            meIndex = export?.people.indices.first { SplitwiseImport.suggestMatch(for: export!.people[$0], in: [.init(id: UUID(), name: myName)]) != nil }
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
            let accountIds = Set(friends.filter { !$0.isPlaceholder }.map(\.userId))
            let plan = SplitwiseImport.plan(export, meIndex: meIndex, me: me, mapping: mapping, pendingUsers: accountIds)
            let expenses = ExpenseRepositoryFactory.make()
            let existing = Set(try await expenses.fetchExpenses(ids: plan.expenses.map(\.expense.id)).map(\.id))
            // Replay in date order, expenses before repayments on the same day: the server only
            // accepts a repayment while the balance at that point owes it.
            enum Step { case expense(ExpenseRecord), payment(SplitwiseImport.PlannedPayment) }
            var steps: [(Date, Int, Step)] = plan.expenses.filter { !existing.contains($0.expense.id) }.map { ($0.expense.spentAt, 0, Step.expense($0.expense)) }
            steps += plan.payments.map { ($0.date, 1, Step.payment($0)) }
            steps.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            let balances = BalanceRepositoryFactory.make()
            var created = 0
            var payments = 0
            var failedExpenses = 0
            var failedPayments = 0
            for (_, _, step) in steps {
                switch step {
                case .expense(let expense):
                    do { _ = try await expenses.create(expense); created += 1 } catch { failedExpenses += 1 }
                case .payment(let payment):
                    do {
                        if payment.isReceived {
                            try await balances.createReceivedRepayment(from: payment.personId, to: me, amountMinor: payment.amountMinor, currencyCode: payment.currency, note: payment.note, paidAt: payment.date, operationId: payment.operationId)
                        } else {
                            try await balances.createRepayment(from: me, to: payment.personId, amountMinor: payment.amountMinor, currencyCode: payment.currency, note: payment.note, paidAt: payment.date, operationId: payment.operationId)
                        }
                        payments += 1
                    } catch { failedPayments += 1 }
                }
            }
            await expenseStore.refresh(userId: me)
            await balanceStore.refresh(userId: me)
            let alreadyThere = existing.count
            result = "Imported \(created) expenses and \(payments) repayments."
                + (alreadyThere > 0 ? " \(alreadyThere) were already imported." : "")
                + (failedExpenses > 0 ? " \(failedExpenses) expenses failed, import again to retry them." : "")
                + (failedPayments > 0 ? " \(failedPayments) repayments couldn’t be recorded yet. Repayments with friends only work once they accept the expenses; import again afterwards." : "")
            ToastCenter.shared.showSuccess("Splitwise import finished")
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}
