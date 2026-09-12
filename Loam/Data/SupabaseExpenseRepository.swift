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
            .filter { expense in
                guard let share = expense.shareRecord(for: userId) else { return false }
                return share.status != .rejected
            }
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
                amountMinor: $0.amountMinor,
                status: $0.status,
                respondedAt: $0.respondedAt,
                acceptedViaTrust: $0.acceptedViaTrust
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

    func respondToShare(expenseId: UUID, userId: UUID, action: ExpenseShareResponseAction) async throws {
        // RPC uses auth.uid() and updates only that user's expense_share row.
        // Other participants' pending shares are left unchanged.
        _ = userId
        _ = try await client
            .rpc(
                "respond_to_expense_share",
                params: RespondToShareParams(expenseId: expenseId, action: action.rawValue)
            )
            .execute()
    }

    func fetchExpenses(ids: [UUID]) async throws -> [ExpenseRecord] {
        guard !ids.isEmpty else { return [] }

        let rows: [ExpenseDTO] = try await client
            .from("expense")
            .select("*, expense_share(*)")
            .in("id", values: ids.map(\.uuidString))
            .execute()
            .value

        return rows.compactMap { $0.toRecord() }
    }

    func fetchPendingProposals(for userId: UUID) async throws -> [ExpenseEditProposal] {
        let rows: [ExpenseEditProposalDTO] = try await client
            .from("expense_edit_proposal")
            .select()
            .eq("status", value: ExpenseProposalStatus.pending.rawValue)
            .order("created_at", ascending: false)
            .execute()
            .value

        return rows.compactMap { $0.toRecord() }
            .filter { proposal in
                proposal.proposedBy == userId || proposalNeedsCreatorReview(proposal, userId: userId)
            }
    }

    func createEditProposal(_ proposal: ExpenseEditProposal, expenseId: UUID) async throws -> ExpenseEditProposal {
        let params = CreateEditProposalParams(proposal: proposal, expenseId: expenseId)
        let proposalId: UUID = try await client
            .rpc("create_expense_edit_proposal", params: params)
            .execute()
            .value

        let row: ExpenseEditProposalDTO = try await client
            .from("expense_edit_proposal")
            .select()
            .eq("id", value: proposalId)
            .single()
            .execute()
            .value

        guard let record = row.toRecord() else {
            throw ExpenseRepositoryError.notFound
        }
        return record
    }

    func respondToProposal(proposalId: UUID, accept: Bool) async throws {
        _ = try await client
            .rpc(
                "respond_to_edit_proposal",
                params: RespondToProposalParams(proposalId: proposalId, accept: accept)
            )
            .execute()
    }

    func fetchTrustedUserIds(for userId: UUID, householdId: UUID) async throws -> Set<UUID> {
        struct TrustRow: Decodable {
            let trustedUserId: UUID

            enum CodingKeys: String, CodingKey {
                case trustedUserId = "trusted_user_id"
            }
        }

        let rows: [TrustRow] = try await client
            .from("expense_share_trust")
            .select("trusted_user_id")
            .eq("user_id", value: userId)
            .eq("household_id", value: householdId)
            .execute()
            .value

        return Set(rows.map(\.trustedUserId))
    }

    func addTrust(for userId: UUID, trustedUserId: UUID, householdId: UUID) async throws {
        struct TrustInsert: Encodable {
            let userId: UUID
            let trustedUserId: UUID
            let householdId: UUID

            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case trustedUserId = "trusted_user_id"
                case householdId = "household_id"
            }
        }

        _ = try await client
            .from("expense_share_trust")
            .insert(TrustInsert(userId: userId, trustedUserId: trustedUserId, householdId: householdId))
            .execute()
    }

    private func proposalNeedsCreatorReview(_ proposal: ExpenseEditProposal, userId: UUID) -> Bool {
        // Kept for client-side filtering; server RLS already scopes rows.
        proposal.status == .pending
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
    let pTitle: String?
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
        case pTitle = "p_title"
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
        pTitle = expense.title
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
        if let pTitle {
            try container.encode(pTitle, forKey: .pTitle)
        } else {
            try container.encodeNil(forKey: .pTitle)
        }
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

private struct RespondToShareParams: Encodable, Sendable {
    let expenseId: UUID
    let action: String

    enum CodingKeys: String, CodingKey {
        case expenseId = "p_expense_id"
        case action = "p_action"
    }
}

private struct RespondToProposalParams: Encodable, Sendable {
    let proposalId: UUID
    let accept: Bool

    enum CodingKeys: String, CodingKey {
        case proposalId = "p_proposal_id"
        case accept = "p_accept"
    }
}

private struct CreateEditProposalParams: Encodable, Sendable {
    let expenseId: UUID
    let amountMinor: Int
    let category: ExpenseCategory
    let title: String?
    let note: String?
    let spentAt: String
    let paidBy: UUID
    let shares: [ShareParam]
    let message: String?

    enum CodingKeys: String, CodingKey {
        case expenseId = "p_expense_id"
        case amountMinor = "p_amount_minor"
        case category = "p_category"
        case title = "p_title"
        case note = "p_note"
        case spentAt = "p_spent_at"
        case paidBy = "p_paid_by"
        case shares = "p_shares"
        case message = "p_message"
    }

    init(proposal: ExpenseEditProposal, expenseId: UUID) {
        self.expenseId = expenseId
        amountMinor = proposal.amountMinor
        category = proposal.category
        title = proposal.title
        note = proposal.note
        spentAt = CalendarDateCodec.string(from: proposal.spentAt)
        paidBy = proposal.paidBy
        shares = proposal.shares.map { ShareParam(userId: $0.userId, amountMinor: $0.amountMinor) }
        message = proposal.message
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expenseId, forKey: .expenseId)
        try container.encode(amountMinor, forKey: .amountMinor)
        try container.encode(category, forKey: .category)
        if let title {
            try container.encode(title, forKey: .title)
        } else {
            try container.encodeNil(forKey: .title)
        }
        if let note {
            try container.encode(note, forKey: .note)
        } else {
            try container.encodeNil(forKey: .note)
        }
        try container.encode(spentAt, forKey: .spentAt)
        try container.encode(paidBy, forKey: .paidBy)
        try container.encode(shares, forKey: .shares)
        if let message {
            try container.encode(message, forKey: .message)
        } else {
            try container.encodeNil(forKey: .message)
        }
    }
}
