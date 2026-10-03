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

    func createRecurringExpense(_ expense: ExpenseRecord, rule: RecurringRuleRecord) async throws -> ExpenseRecord {
        try validate(expense)
        let id: UUID = try await client.rpc("create_recurring_expense", params: CreateRecurringExpenseParams(
            pRule: RecurringRuleInsertDTO(from: rule), pExpense: ExpenseInsertDTO(from: expense)
        )).execute().value
        return try await fetchExpense(id: id)
    }

    func updateRecurringRule(_ rule: RecurringRuleRecord) async throws -> RecurringRuleRecord {
        let id: UUID = try await client.rpc("save_recurring_rule", params: SaveRecurringParams(
            pRule: RecurringRuleInsertDTO(from: rule), pExpectedVersion: rule.version ?? 1
        )).execute().value
        guard let saved = try await fetchRecurringRule(id: id) else { throw ExpenseRepositoryError.notFound }
        return saved
    }

    func fetchActiveRecurringRules(for userId: UUID) async throws -> [RecurringRuleRecord] {
        let rows: [RecurringRuleDTO] = try await client
            .from("recurring_rule")
            .select()
            .eq("owner_user_id", value: userId)
            .eq("is_active", value: true)
            .execute()
            .value
        return rows.compactMap { $0.toRecord() }
    }

    func fetchRecurringRule(id: UUID) async throws -> RecurringRuleRecord? {
        let rows: [RecurringRuleDTO] = try await client
            .from("recurring_rule")
            .select()
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.compactMap { $0.toRecord() }.first
    }

    func hasExpense(recurringId: UUID, spentAt: Date) async throws -> Bool {
        struct IdRow: Decodable {
            let id: UUID
        }

        let day = CalendarDateCodec.string(from: spentAt)
        let rows: [IdRow] = try await client
            .from("expense")
            .select("id")
            .eq("recurring_id", value: recurringId)
            .eq("spent_at", value: day)
            .limit(1)
            .execute()
            .value
        return !rows.isEmpty
    }

    func materializeRecurringRules(through date: Date) async throws -> Bool {
        // The server builds occurrences from the rule and advances it atomically.
        let _: Int = try await client.rpc("materialize_recurring_rules", params: MaterializeRecurringParams(
            pThrough: CalendarDateCodec.string(from: date)
        )).execute().value
        return true
    }

    func createRecurringOccurrence(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        do {
            return try await create(expense)
        } catch {
            // The unique index makes the insert the arbiter. If another device
            // inserted this occurrence first, use its row and keep refreshes
            // idempotent; propagate all unrelated failures.
            guard expense.recurringId != nil,
                  error.localizedDescription.localizedCaseInsensitiveContains("duplicate")
                    || error.localizedDescription.localizedCaseInsensitiveContains("unique")
            else { throw error }
            if let existing = try await fetchExpense(recurringId: expense.recurringId!, spentAt: expense.spentAt) {
                return existing
            }
            throw error
        }
    }

    func create(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        try validate(expense)
        let id: UUID = try await client.rpc("save_expense", params: SaveExpenseParams(
            pExpense: ExpenseInsertDTO(from: expense), pExpectedVersion: nil
        )).execute().value
        return try await fetchExpense(id: id)
    }

    func update(_ expense: ExpenseRecord) async throws -> ExpenseRecord {
        try validate(expense)
        let id: UUID = try await client.rpc("save_expense", params: SaveExpenseParams(
            pExpense: ExpenseInsertDTO(from: expense), pExpectedVersion: expense.version ?? 1
        )).execute().value
        return try await fetchExpense(id: id)
    }

    func delete(id: UUID) async throws {
        try await client
            .from("expense")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    #if DEBUG
    func deleteAllCreatedBy(_ userId: UUID) async throws {
        // Matches expense_delete_creator / recurring_owner_all (creator/owner only).
        try await client
            .from("expense")
            .delete()
            .eq("created_by", value: userId)
            .execute()
        try await client
            .from("recurring_rule")
            .delete()
            .eq("owner_user_id", value: userId)
            .execute()
    }
    #endif

    func deleteFutureRecurringExpenses(recurringId: UUID, after date: Date) async throws {
        let day = CalendarDateCodec.string(from: date)
        try await client
            .from("expense")
            .delete()
            .eq("recurring_id", value: recurringId)
            .gt("spent_at", value: day)
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
        let params = CreateEditProposalParams(pExpenseId: expenseId, pExpectedVersion: proposal.baseVersion ?? 1, pProposal: ProposalPayload(proposal))
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

    func fetchTrustedUserIds(for userId: UUID) async throws -> Set<UUID> {
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
            .execute()
            .value

        return Set(rows.map(\.trustedUserId))
    }

    func addTrust(for userId: UUID, trustedUserId: UUID) async throws {
        struct TrustInsert: Encodable {
            let userId: UUID
            let trustedUserId: UUID

            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case trustedUserId = "trusted_user_id"
            }
        }

        _ = try await client
            .from("expense_share_trust")
            .insert(TrustInsert(userId: userId, trustedUserId: trustedUserId))
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

    private func fetchExpense(recurringId: UUID, spentAt: Date) async throws -> ExpenseRecord? {
        let rows: [ExpenseDTO] = try await client
            .from("expense")
            .select("*, expense_share(*)")
            .eq("recurring_id", value: recurringId)
            .eq("spent_at", value: CalendarDateCodec.string(from: spentAt))
            .limit(1)
            .execute()
            .value
        return rows.compactMap { $0.toRecord() }.first
    }

    private func validate(_ expense: ExpenseRecord) throws {
        let sum = expense.shares.reduce(0) { $0 + $1.amountMinor }
        guard sum == expense.amountMinor else {
            throw ExpenseRepositoryError.invalidShares
        }
    }
}

private struct SaveExpenseParams: Encodable {
    let pExpense: ExpenseInsertDTO
    let pExpectedVersion: Int?
    enum CodingKeys: String, CodingKey { case pExpense = "p_expense", pExpectedVersion = "p_expected_version" }
}
private struct SaveRecurringParams: Encodable {
    let pRule: RecurringRuleInsertDTO
    let pExpectedVersion: Int?
    enum CodingKeys: String, CodingKey { case pRule = "p_rule", pExpectedVersion = "p_expected_version" }
}
private struct CreateRecurringExpenseParams: Encodable {
    let pRule: RecurringRuleInsertDTO
    let pExpense: ExpenseInsertDTO
    enum CodingKeys: String, CodingKey { case pRule = "p_rule", pExpense = "p_expense" }
}
private struct MaterializeRecurringParams: Encodable {
    let pThrough: String
    enum CodingKeys: String, CodingKey { case pThrough = "p_through" }
}
private struct RespondToShareParams: Encodable {
    let expenseId: UUID; let action: String
    enum CodingKeys: String, CodingKey { case expenseId = "p_expense_id", action = "p_action" }
}
private struct RespondToProposalParams: Encodable {
    let proposalId: UUID; let accept: Bool
    enum CodingKeys: String, CodingKey { case proposalId = "p_proposal_id", accept = "p_accept" }
}
private struct CreateEditProposalParams: Encodable {
    let pExpenseId: UUID; let pExpectedVersion: Int; let pProposal: ProposalPayload
    enum CodingKeys: String, CodingKey { case pExpenseId = "p_expense_id", pExpectedVersion = "p_expected_version", pProposal = "p_proposal" }
}
private struct ProposalPayload: Encodable {
    let amountMinor: Int; let category: ExpenseCategory; let title: String?; let note: String?
    let location: ExpenseLocation?; let spentAt: String; let paidBy: UUID; let shares: [ProposalShareDTO]; let message: String?
    enum CodingKeys: String, CodingKey { case amountMinor = "amount_minor", spentAt = "spent_at", paidBy = "paid_by", category, title, note, location, shares, message }
    init(_ p: ExpenseEditProposal) {
        amountMinor = p.amountMinor; category = p.category; title = p.title; note = p.note; location = p.location
        spentAt = CalendarDateCodec.string(from: p.spentAt); paidBy = p.paidBy; message = p.message
        shares = p.shares.map { ProposalShareDTO(userId: $0.userId, amountMinor: $0.amountMinor) }
    }
}
