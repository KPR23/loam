import Foundation
import Supabase

actor SupabaseExpenseRepository: ExpenseRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchExpenses(for userId: UUID, in period: DatePeriod) async throws -> [ExpenseRecord] {
        let (start, endExclusive) = period.dateRange
        let startString = CalendarDateCodec.string(from: start)
        let endString = CalendarDateCodec.string(from: endExclusive)

        let rows: [ExpenseDTO] = try await client
            .from("expense")
            .select("*, expense_share(*)")
            .gte("spent_at", value: startString)
            .lt("spent_at", value: endString)
            .order("spent_at", ascending: false)
            .order("created_at", ascending: false)
            .execute()
            .value

        return rows
            .compactMap { $0.toRecord() }
            .filter { $0.shares.contains(where: { $0.userId == userId }) }
    }

    func createRecurringRule(_ rule: RecurringRuleRecord) async throws -> RecurringRuleRecord {
        _ = try await client
            .from("recurring_rule")
            .insert(RecurringRuleInsertDTO(from: rule))
            .execute()
        return rule
    }

    func create(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        try validate(expense)

        // Two-step insert: nested `expense_share` in the expense body fails with
        // PGRST "could not find the expense_share column … in the schema cache".
        _ = try await client
            .from("expense")
            .insert(ExpenseInsertDTO(from: expense))
            .execute()

        let sharePayload = expense.shares.map {
            ExpenseShareInsertDTO(
                id: $0.id,
                expenseId: expense.id,
                userId: $0.userId,
                amountMinor: $0.amountMinor
            )
        }

        do {
            _ = try await client
                .from("expense_share")
                .insert(sharePayload)
                .execute()
        } catch {
            // Avoid orphan expense rows if share insert fails (e.g. sum trigger).
            _ = try? await client
                .from("expense")
                .delete()
                .eq("id", value: expense.id)
                .execute()
            throw error
        }

        return try await fetchExpense(id: expense.id)
    }

    func update(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        try validate(expense)

        // Update expense first, then shares — keeps share-sum trigger valid between requests.
        _ = try await client
            .from("expense")
            .update(ExpenseUpdateDTO(from: expense))
            .eq("id", value: expense.id)
            .execute()

        for share in expense.shares {
            struct ShareAmount: Encodable {
                let amount_minor: Int
            }
            _ = try await client
                .from("expense_share")
                .update(ShareAmount(amount_minor: share.amountMinor))
                .eq("expense_id", value: expense.id)
                .eq("user_id", value: share.userId)
                .execute()
        }

        return try await fetchExpense(id: expense.id)
    }

    func delete(id: UUID) async throws {
        try await client
            .from("expense")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    private func fetchExpense(id: UUID) async throws -> ExpenseRecord {
        let row: ExpenseDTO = try await client
            .from("expense")
            .select("*, expense_share(*)")
            .eq("id", value: id)
            .single()
            .execute()
            .value

        guard let record = row.toRecord() else {
            throw ExpenseRepositoryError.notFound
        }
        return record
    }

    private func validate(_ expense: ExpenseRecord) throws {
        let sum = expense.shares.reduce(0) { $0 + $1.amountMinor }
        guard sum == expense.amountMinor else {
            throw ExpenseRepositoryError.invalidShares
        }
    }
}
