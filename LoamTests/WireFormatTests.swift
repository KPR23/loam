import XCTest
@testable import Loam

/// Pins the JSON shapes exchanged with PostgREST and the SQL functions.
final class WireFormatTests: LocalStorageTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    func testNilNoteIsEncodedAsExplicitNullForPostgRESTFunctionResolution() throws {
        let params = CreateRepaymentParams(
            toUserId: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            amountMinor: 100,
            currency: "EUR",
            note: nil,
            paidAt: "2026-09-17",
            operationId: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )

        let data = try JSONEncoder().encode(params)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(payload.keys.contains("p_note"))
        XCTAssertTrue(payload["p_note"] is NSNull)
        XCTAssertEqual(payload["p_amount_minor"] as? Int, 100)
        XCTAssertEqual(payload["p_currency"] as? String, "EUR")
    }

    func testExpenseRowDecodesWithNestedShares() throws {
        let row = try decode(ExpenseDTO.self, """
        {"id":"\(UUID())","amount_minor":1000,"currency":"PLN","category":"dining","title":"Dinner","note":null,
         "spent_at":"2026-09-07","paid_by":"\(TestUser.alice)","created_by":"\(TestUser.alice)","version":3,
         "recurring_id":null,"expense_share":[
           {"user_id":"\(TestUser.alice)","amount_minor":600,"status":"accepted"},
           {"user_id":"\(TestUser.bob)","amount_minor":400,"status":"pending","accepted_via_trust":false}]}
        """)

        let record = try XCTUnwrap(row.toRecord())
        XCTAssertEqual(record.spentAt, day(2026, 9, 7))
        XCTAssertEqual(record.version, 3)
        XCTAssertEqual(record.shareStatus(for: TestUser.bob), .pending)
        XCTAssertEqual(record.acceptedShareMinor(for: TestUser.alice), 600)
    }

    func testLegacyRowsDefaultShareStatusToAccepted() throws {
        let share = try decode(ExpenseShareDTO.self, #"{"user_id":"\#(TestUser.bob)","amount_minor":400}"#)
        XCTAssertEqual(share.toRecord().status, .accepted)
    }

    func testRowWithUnreadableDateIsSkipped() throws {
        var row = try decode(ExpenseDTO.self, """
        {"amount_minor":1,"currency":"PLN","category":"other","spent_at":"2026-09-07",
         "paid_by":"\(TestUser.alice)","created_by":"\(TestUser.alice)"}
        """)
        row.spentAt = "yesterday"
        XCTAssertNil(row.toRecord())
    }

    func testSavedExpenseUsesServerKeysAndCalendarDates() throws {
        var expense = personalExpense(1250, spentAt: day(2026, 9, 7))
        expense.recurringId = UUID()
        let payload = try json(ExpenseInsertDTO(from: expense))

        XCTAssertTrue(Set(["id", "amount_minor", "currency", "category", "spent_at", "paid_by", "recurring_id", "shares"]).isSubset(of: payload.keys))
        XCTAssertEqual(payload["spent_at"] as? String, "2026-09-07")
        XCTAssertEqual(payload["amount_minor"] as? Int, 1250)
        XCTAssertEqual(payload["category"] as? String, "groceries")
        let shares = try XCTUnwrap(payload["shares"] as? [[String: Any]])
        XCTAssertEqual(shares.first?["amount_minor"] as? Int, 1250)
        XCTAssertEqual(shares.first?["user_id"] as? String, TestUser.alice.uuidString)
        XCTAssertNil(payload["created_by"], "The server assigns the creator")
        XCTAssertNil(payload["status"], "The server assigns consent")
    }

    func testRecurringRuleRoundTripsThroughTheServerShape() throws {
        let rule = RecurringRuleRecord(
            ownerUserId: TestUser.alice,
            amountMinor: 5000,
            category: .housing,
            title: "Rent",
            intervalUnit: .month,
            intervalCount: 1,
            startDate: day(2026, 1, 31),
            endDate: day(2026, 12, 31),
            nextOccurrence: day(2026, 2, 28),
            skippedDates: [day(2026, 3, 31)]
        )
        let payload = try json(RecurringRuleInsertDTO(from: rule))
        XCTAssertEqual(payload["interval_unit"] as? String, "month")
        XCTAssertEqual(payload["start_date"] as? String, "2026-01-31")
        XCTAssertEqual(payload["next_occurrence"] as? String, "2026-02-28")
        XCTAssertEqual(payload["skipped_dates"] as? [String], ["2026-03-31"])

        let decoded = try JSONDecoder().decode(RecurringRuleDTO.self, from: JSONEncoder().encode(RecurringRuleInsertDTO(from: rule)))
        let record = try XCTUnwrap(decoded.toRecord())
        XCTAssertEqual(record.startDate, rule.startDate)
        XCTAssertEqual(record.endDate, rule.endDate)
        XCTAssertEqual(record.nextOccurrence, rule.nextOccurrence)
        XCTAssertEqual(record.skippedDates, rule.skippedDates)
        XCTAssertEqual(record.shares.map(\.amountMinor), [5000])
    }

    func testRecurringRuleFromAnOlderServerStartsAtItsNextOccurrence() throws {
        let row = try decode(RecurringRuleDTO.self, """
        {"id":"\(UUID())","owner_user_id":"\(TestUser.alice)","paid_by":"\(TestUser.alice)","shares":[],
         "amount_minor":100,"currency":"PLN","category":"other","interval_unit":"week","interval_count":2,
         "next_occurrence":"2026-09-10","is_active":true,"failure":"Partner left"}
        """)
        let record = try XCTUnwrap(row.toRecord())
        XCTAssertEqual(record.startDate, day(2026, 9, 10))
        XCTAssertEqual(record.generationFailure, "Partner left")

        var unknownUnit = row
        unknownUnit.intervalUnit = "fortnight"
        XCTAssertNil(unknownUnit.toRecord())
    }

    func testEditProposalRowDecodes() throws {
        let row = try decode(ExpenseEditProposalDTO.self, """
        {"expense_id":"\(UUID())","base_version":4,"proposed_by":"\(TestUser.bob)","status":"pending",
         "amount_minor":900,"category":"dining","spent_at":"2026-09-07","paid_by":"\(TestUser.alice)",
         "shares":[{"user_id":"\(TestUser.alice)","amount_minor":450},{"user_id":"\(TestUser.bob)","amount_minor":450}],
         "message":"Tip was smaller"}
        """)
        let proposal = try XCTUnwrap(row.toRecord())
        XCTAssertEqual(proposal.baseVersion, 4)
        XCTAssertEqual(proposal.shares.map(\.amountMinor), [450, 450])
        XCTAssertEqual(proposal.spentAt, day(2026, 9, 7))
    }

    func testBalanceHistoryDecodesServerKeys() throws {
        let entries = try JSONDecoder().decode([BalanceHistoryEntry].self, from: Data("""
        [{"id":"\(UUID())","kind":"repayment","title":"Cash","amount_minor":-500,"occurred_at":0,"status":null}]
        """.utf8))
        XCTAssertEqual(entries.first?.kind, .repayment)
        XCTAssertEqual(entries.first?.amountMinor, -500)
        XCTAssertNil(entries.first?.currencyCode)

        let purchase = try JSONDecoder().decode([BalanceHistoryEntry].self, from: Data("""
        [{"id":"\(UUID())","kind":"purchase","title":"groceries","amount_minor":900,"occurred_at":0,"status":"accepted","currency":"EUR","category":"groceries"}]
        """.utf8))
        XCTAssertEqual(purchase.first?.currencyCode, "EUR")
        XCTAssertEqual(purchase.first?.category, .groceries)
        XCTAssertEqual(purchase.first?.displayTitle, "Groceries")
    }

    func testLocallySavedRecordsFromOlderVersionsStillLoad() throws {
        let repayment = try decode(RepaymentRecord.self, """
        {"id":"\(UUID())","fromUserId":"\(TestUser.alice)","toUserId":"\(TestUser.bob)","amountMinor":100,"paidAt":0,"createdAt":0}
        """)
        XCTAssertEqual(repayment.currencyCode, "PLN")
        XCTAssertFalse(repayment.isReversed)

        let share = try decode(ExpenseShareRecord.self, #"{"id":"\#(UUID())","userId":"\#(TestUser.bob)","amountMinor":100}"#)
        XCTAssertEqual(share.status, .accepted)
        XCTAssertFalse(share.acceptedViaTrust)
    }
}
