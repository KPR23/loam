import SwiftUI
import UniformTypeIdentifiers

/// Imports a Splitwise CSV export: expenses become splits with people without an account,
/// repayments land in Balances history.
struct SplitwiseImportView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var balanceStore: BalanceStore
    @EnvironmentObject private var navigator: AppNavigator
    @ObservedObject private var importer = SplitwiseImporter.shared
    @Environment(\.dismiss) private var dismiss

    private typealias Target = SplitwiseImport.Target

    @State private var showsImporter = false
    @State private var export: SplitwiseImport.Export?
    @State private var meIndex: Int?
    @State private var targets: [Int: Target] = [:]
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
                    } header: {
                        Text("Summary")
                    } footer: {
                        Text("Expenses you already have (same day, amount and shares) are skipped, so importing again doesn’t duplicate anything. Also skipped: expenses paid by more than one person, expenses that don’t involve you and currencies Loam doesn’t support.")
                    }
                    .listRowBackground(HomeTheme.surface)
                }
            }

        }
        .scrollContentBackground(.hidden)
        .background(HomeTheme.background.ignoresSafeArea())
        .navigationTitle("Import from Splitwise")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { picked in
            load(picked)
        }
        .safeAreaInset(edge: .bottom) { importBar }
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

    @ViewBuilder
    private var importBar: some View {
        if let export, let meIndex {
            let involved = SplitwiseImport.involvedPeople(in: export, meIndex: meIndex)
            let blocked = hasDuplicateTargets(export: export, involved: involved) || importer.isRunning || authSession.userId == nil
            let plan = SplitwiseImport.plan(export, meIndex: meIndex, me: authSession.userId ?? UUID(), mapping: previewMapping(export: export, meIndex: meIndex))
            VStack(spacing: 8) {
                Button { startImport(export: export, meIndex: meIndex, involved: involved) } label: {
                    Text("Import \(plan.expenses.count + plan.payments.count) items")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(blocked)
                if importer.isRunning {
                    Text("An import is already running.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func startImport(export: SplitwiseImport.Export, meIndex: Int, involved: [Int]) {
        guard let me = authSession.userId else { return }
        var chosen: [Int: Target] = [:]
        for column in involved { chosen[column] = binding(for: column, export: export).wrappedValue }
        importer.start(
            export: export, meIndex: meIndex, me: me, targets: chosen,
            accountIds: Set(friends.filter { !$0.isPlaceholder }.map(\.userId)),
            connectionStore: connectionStore, expenseStore: expenseStore, balanceStore: balanceStore
        )
        // Back to the main screen; the progress stays on top while it uploads.
        navigator.pendingScreen = .expenses
        dismiss()
    }
}
