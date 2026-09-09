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

        // One RPC keeps share replacement in a single DB transaction. Separate HTTP
        // updates commit individually and trip the deferred share-sum trigger early.
        _ = try await client
            .rpc(
                "update_expense_with_shares",
                params: UpdateExpenseWithSharesParams(from: expense)
            )
            .execute()

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

private struct UpdateExpenseWithSharesParams: Encodable, Sendable {
    let pExpenseId: UUID
    let pAmountMinor: Int
    let pCurrency: String
    let pCategory: ExpenseCategory
    let pNote: String?
    let pSpentAt: String
    let pPaidBy: UUID
    let pHouseholdId: UUID?
    let pRecurringId: UUID?
    let pShares: [ShareParam]

    enum CodingKeys: String, CodingKey {
        case pExpenseId = "p_expense_id"
        case pAmountMinor = "p_amount_minor"
        case pCurrency = "p_currency"
        case pCategory = "p_category"
        case pNote = "p_note"
        case pSpentAt = "p_spent_at"
        case pPaidBy = "p_paid_by"
        case pHouseholdId = "p_household_id"
        case pRecurringId = "p_recurring_id"
        case pShares = "p_shares"
    }

    init(from expense: ExpenseRecord) {
        pExpenseId = expense.id
        pAmountMinor = expense.amountMinor
        pCurrency = expense.currency
        pCategory = expense.category
        pNote = expense.note
        pSpentAt = CalendarDateCodec.string(from: expense.spentAt)
        pPaidBy = expense.paidBy
        pHouseholdId = expense.householdId
        pRecurringId = expense.recurringId
        pShares = expense.shares.map { ShareParam(userId: $0.userId, amountMinor: $0.amountMinor) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pExpenseId, forKey: .pExpenseId)
        try container.encode(pAmountMinor, forKey: .pAmountMinor)
        try container.encode(pCurrency, forKey: .pCurrency)
        try container.encode(pCategory, forKey: .pCategory)
        if let pNote {
            try container.encode(pNote, forKey: .pNote)
        } else {
            try container.encodeNil(forKey: .pNote)
        }
        try container.encode(pSpentAt, forKey: .pSpentAt)
        try container.encode(pPaidBy, forKey: .pPaidBy)
        if let pHouseholdId {
            try container.encode(pHouseholdId, forKey: .pHouseholdId)
        } else {
            try container.encodeNil(forKey: .pHouseholdId)
        }
        if let pRecurringId {
            try container.encode(pRecurringId, forKey: .pRecurringId)
        } else {
            try container.encodeNil(forKey: .pRecurringId)
        }
        try container.encode(pShares, forKey: .pShares)
    }
}

private struct ShareParam: Encodable, Sendable {
    let userId: UUID
    let amountMinor: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case amountMinor = "amount_minor"
    }
}
