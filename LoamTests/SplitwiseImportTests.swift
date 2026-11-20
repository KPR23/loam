import XCTest
@testable import Loam

final class SplitwiseImportTests: XCTestCase {
    private let sample = """
    Note: does not include group expenses

    Date,Description,Category,Cost,Currency,Kacper Zabłudowski,Julia Dębiec

    2024-08-07,Paliwko,Gas/fuel,215.00,PLN,107.50,-107.50
    2024-08-12,Julia D. paid Kacper Z.,Payment,151.60,PLN,-151.60,151.60
    2024-08-22,"Ikea, duża ",Furniture,17.99,PLN,-17.99,17.99
    2024-09-18,Settle all balances,General,35.45,PLN,35.45,-35.45
    2025-02-07,Kino,Movies,27.00,PLN,0.00,0.00

    2026-11-17,Total balance, , ,PLN,16.26,-16.26
    """
    private let me = UUID()
    private let julia = UUID()

    func testParsesHeaderPeopleAndSkipsFooter() throws {
        let export = try SplitwiseImport.parse(sample)
        XCTAssertEqual(export.people, ["Kacper Zabłudowski", "Julia Dębiec"])
        XCTAssertEqual(export.rows.count, 5)
        XCTAssertEqual(export.rows[2].description, "Ikea, duża")
        XCTAssertEqual(export.rows[1].isPayment, true)
        XCTAssertEqual(export.rows[3].isPayment, true)
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try SplitwiseImport.parse("a,b,c\n1,2,3"))
    }

    func testPlanBuildsExpensesAndPayments() throws {
        let export = try SplitwiseImport.parse(sample)
        let plan = SplitwiseImport.plan(export, meIndex: 0, me: me, mapping: [1: julia])
        XCTAssertEqual(plan.expenses.count, 2)
        let fuel = plan.expenses[0].expense
        XCTAssertEqual(fuel.paidBy, me)
        XCTAssertEqual(fuel.amountMinor, 21500)
        XCTAssertEqual(fuel.shareRecord(for: julia)?.amountMinor, 10750)
        XCTAssertEqual(fuel.shareRecord(for: me)?.amountMinor, 10750)
        XCTAssertEqual(fuel.category, .transport)
        let ikea = plan.expenses[1].expense
        XCTAssertEqual(ikea.paidBy, julia)
        XCTAssertEqual(ikea.shares.map(\.amountMinor).reduce(0, +), 1799)
        XCTAssertEqual(plan.payments.count, 2)
        XCTAssertTrue(plan.payments[0].isReceived)
        XCTAssertFalse(plan.payments[1].isReceived)
        XCTAssertEqual(plan.skipped.count, 1)
    }

    func testPlanIsStableAcrossRuns() throws {
        let export = try SplitwiseImport.parse(sample)
        let a = SplitwiseImport.plan(export, meIndex: 0, me: me, mapping: [1: julia])
        let b = SplitwiseImport.plan(export, meIndex: 0, me: me, mapping: [1: julia])
        XCTAssertEqual(a.expenses.map(\.expense.id), b.expenses.map(\.expense.id))
    }

    func testParseMinor() {
        XCTAssertEqual(SplitwiseImport.parseMinor("12.34"), 1234)
        XCTAssertEqual(SplitwiseImport.parseMinor("12,34"), 1234)
        XCTAssertEqual(SplitwiseImport.parseMinor("-1,234.50"), -123450)
        XCTAssertEqual(SplitwiseImport.parseMinor("3008.5"), 300850)
        XCTAssertEqual(SplitwiseImport.parseMinor("7"), 700)
        XCTAssertNil(SplitwiseImport.parseMinor("abc"))
    }

    func testSuggestsFriendsByName() {
        let julia = UUID(), jan = UUID(), janina = UUID()
        let candidates = [
            SplitwiseImport.Candidate(id: julia, name: "Julia Dębiec"),
            SplitwiseImport.Candidate(id: jan, name: "Jan Kowalski"),
            SplitwiseImport.Candidate(id: janina, name: "Janina Nowak")
        ]
        XCTAssertEqual(SplitwiseImport.suggestMatch(for: "julia debiec", in: candidates), julia)
        XCTAssertEqual(SplitwiseImport.suggestMatch(for: "Julia D.", in: candidates), julia)
        XCTAssertEqual(SplitwiseImport.suggestMatch(for: "Julia", in: candidates), julia)
        XCTAssertEqual(SplitwiseImport.suggestMatch(for: "Jan K.", in: candidates), jan)
        XCTAssertNil(SplitwiseImport.suggestMatch(for: "Marek", in: candidates))
        XCTAssertNil(SplitwiseImport.suggestMatch(for: "Jan", in: candidates + [.init(id: UUID(), name: "Jan Zieliński")]))
    }

    func testFriendsWithAnAccountGetPendingShares() throws {
        let export = try SplitwiseImport.parse(sample)
        let plan = SplitwiseImport.plan(export, meIndex: 0, me: me, mapping: [1: julia], pendingUsers: [julia])
        let fuel = plan.expenses[0].expense
        XCTAssertEqual(fuel.shareRecord(for: julia)?.status, .pending)
        XCTAssertEqual(fuel.shareRecord(for: me)?.status, .accepted)
    }
}
