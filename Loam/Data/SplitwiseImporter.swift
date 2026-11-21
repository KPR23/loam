import Foundation

/// Runs a Splitwise import in the background, so the person can leave the import screen and
/// keep using the app while it uploads. One import at a time.
@MainActor
final class SplitwiseImporter: ObservableObject {
    static let shared = SplitwiseImporter()

    struct Progress: Equatable {
        var done: Int
        var total: Int
        var step: String
    }

    @Published private(set) var progress: Progress?
    /// The summary of the last import, shown until dismissed.
    @Published private(set) var finished: String?

    var isRunning: Bool { progress != nil }

    func dismissResult() { finished = nil }

    func start(
        export: SplitwiseImport.Export,
        meIndex: Int,
        me: UUID,
        targets: [Int: SplitwiseImport.Target],
        accountIds: Set<UUID>,
        connectionStore: ConnectionStore,
        expenseStore: ExpenseStore,
        balanceStore: BalanceStore
    ) {
        guard !isRunning else { return }
        finished = nil
        progress = Progress(done: 0, total: 0, step: "Preparing")
        Task {
            let message = await run(
                export: export, meIndex: meIndex, me: me, targets: targets, accountIds: accountIds,
                connectionStore: connectionStore
            )
            await expenseStore.refresh(userId: me)
            await balanceStore.refresh(userId: me)
            progress = nil
            finished = message
        }
    }

    private func run(
        export: SplitwiseImport.Export,
        meIndex: Int,
        me: UUID,
        targets: [Int: SplitwiseImport.Target],
        accountIds: Set<UUID>,
        connectionStore: ConnectionStore
    ) async -> String {
        do {
            var mapping: [Int: UUID] = [:]
            for column in SplitwiseImport.involvedPeople(in: export, meIndex: meIndex) {
                switch targets[column] ?? .new {
                case .existing(let id): mapping[column] = id
                case .new: mapping[column] = try await connectionStore.createPlaceholder(name: export.people[column]).userId
                }
            }
            let plan = SplitwiseImport.plan(export, meIndex: meIndex, me: me, mapping: mapping, pendingUsers: accountIds)
            let expenses = ExpenseRepositoryFactory.make()

            progress = Progress(done: 0, total: 0, step: "Checking what you already have")
            var existing: [ExpenseRecord] = []
            let months = Set(plan.expenses.map { DatePeriod(from: $0.expense.spentAt).anchorDate })
            for month in months.sorted() {
                existing += try await expenses.fetchExpenses(for: me, in: DatePeriod(from: month))
            }
            let (fresh, duplicates) = SplitwiseImport.newExpenses(plan.expenses, existing: existing)

            enum Step { case expense(ExpenseRecord), payment(SplitwiseImport.PlannedPayment) }
            var steps: [(Date, Int, Step)] = fresh.map { ($0.expense.spentAt, $0.order, Step.expense($0.expense)) }
            steps += plan.payments.map { ($0.date, $0.order, Step.payment($0)) }
            // File order within a day: the server accepts a repayment only while the balance owes it.
            steps.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }

            let balances = BalanceRepositoryFactory.make()
            var created = 0, payments = 0, failedExpenses = 0, failedPayments = 0
            progress = Progress(done: 0, total: steps.count, step: "Importing")
            for (index, (_, _, step)) in steps.enumerated() {
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
                progress = Progress(done: index + 1, total: steps.count, step: "Importing")
            }

            var message = "Imported \(created) expenses and \(payments) repayments."
            if duplicates > 0 { message += " Skipped \(duplicates) you already had." }
            if failedExpenses > 0 { message += " \(failedExpenses) expenses failed; import again to retry them." }
            if failedPayments > 0 { message += " \(failedPayments) repayments couldn’t be recorded yet. Repayments with friends only work once they accept the expenses; import again afterwards." }
            return message
        } catch {
            return "Import stopped: \(UserFacingError.message(for: error)) Nothing was lost; import again to continue."
        }
    }
}
