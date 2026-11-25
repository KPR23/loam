import SwiftUI
import UniformTypeIdentifiers

/// Reviews a Splitwise CSV export before importing it: expenses become splits with people
/// without an account, repayments land in Balances history. Friends opens the file picker
/// first and shows this screen as a sheet (`SplitwiseImportSheet`) with the parsed file.
struct SplitwiseImportView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @EnvironmentObject private var balanceStore: BalanceStore
    @EnvironmentObject private var navigator: AppNavigator
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @ObservedObject private var importer = SplitwiseImporter.shared
    @Environment(\.dismiss) private var dismiss

    private typealias Target = SplitwiseImport.Target

    @State private var showsImporter = false
    @State private var export: SplitwiseImport.Export?
    @State private var hasSuggestedMe = false
    @State private var meIndex: Int?
    @State private var targets: [Int: Target] = [:]
    @State private var error: String?
    @State private var showsPaywall = false

    init(export: SplitwiseImport.Export) {
        _export = State(initialValue: export)
    }

    private var friends: [SplitPartnerOption] { connectionStore.connections }

    /// Reads a picked file into an export. Shared with Friends, which picks the file before this screen opens.
    static func readExport(from picked: Result<URL, Error>) throws -> SplitwiseImport.Export {
        let url = try picked.get()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw SplitwiseImport.ParseError.notSplitwise }
        return try SplitwiseImport.parse(text)
    }

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
                    ProfileRow("Choose another file", symbol: "doc.badge.plus", color: .teal)
                }
            } footer: {
                Text("Everyone in the file is added as a person without an account, so nobody gets notifications.")
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
                                ForEach(friends) { Text($0.isPlaceholder ? $0.displayName : String(localized: "\($0.displayName) (friend)")).tag(Target.existing($0.userId)) }
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
        .proPaywall(isPresented: $showsPaywall)
        .task { await connectionStore.refresh(userId: authSession.userId) }
        .onAppear {
            guard !hasSuggestedMe else { return }
            hasSuggestedMe = true
            suggestMe()
        }
    }

    /// Preselects the column whose name matches the signed-in user.
    private func suggestMe() {
        guard let export else { meIndex = nil; return }
        let me = [SplitwiseImport.Candidate(id: UUID(), name: authSession.displayName ?? "")]
        meIndex = export.people.indices.first { SplitwiseImport.suggestMatch(for: export.people[$0], in: me) != nil }
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
        // Picking another file that fails keeps the current one instead of emptying the screen.
        do {
            export = try Self.readExport(from: picked)
            suggestMe()
            targets = [:]
        } catch CocoaError.userCancelled {
            return
        } catch {
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
        // People without an account, new or already added, are a Loam Pro feature. Matching
        // everyone to friends with an account works on any plan.
        let placeholderIds = Set(friends.filter(\.isPlaceholder).map(\.userId))
        let needsPro = chosen.values.contains { target in
            switch target {
            case .new: true
            case let .existing(id): placeholderIds.contains(id)
            }
        }
        if !subscriptions.isPro, needsPro {
            showsPaywall = true
            return
        }
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

/// Presents the review screen in its own navigation stack, with a Cancel button.
struct SplitwiseImportSheet: View {
    let export: SplitwiseImport.Export
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SplitwiseImportView(export: export)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
        .presentationDragIndicator(.visible)
    }
}

extension SplitwiseImportView {
    /// Screenshot runs can't drive the system file picker, so `-splitwiseSample` skips it and opens the
    /// sheet with this built-in export instead.
    static var sampleExport: SplitwiseImport.Export? {
        guard LaunchEnvironment.isUITesting, ProcessInfo.processInfo.arguments.contains("-splitwiseSample") else { return nil }
        return try? SplitwiseImport.parse("""
        Date,Description,Category,Cost,Currency,Julia,Philip,Marta Kowalska

        2026-09-02,Dinner,Dining out,90.00,PLN,60.00,-30.00,-30.00
        2026-09-14,Groceries,Groceries,45.00,PLN,-22.50,45.00,-22.50
        2026-10-03,Philip paid Julia,Payment,30.00,PLN,30.00,-30.00,0.00
        """)
    }
}
