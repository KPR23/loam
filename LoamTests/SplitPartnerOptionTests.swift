import XCTest
@testable import Loam

final class RecentSplitPartnersTests: LocalStorageTestCase {
    let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let otherAccount = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let julia = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let philip = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

    func testRecordOrdersMostRecentFirstAndDedupes() {
        RecentSplitPartners.record([julia], for: me)
        RecentSplitPartners.record([philip, julia], for: me)
        XCTAssertEqual(RecentSplitPartners.loadIDs(for: me), [philip, julia])
    }

    func testRecentExcludesCurrentUserAndMapsAvailable() {
        RecentSplitPartners.record([me, julia, philip], for: me)
        let available = [
            SplitPartnerOption(userId: julia, displayName: "Julia"),
            SplitPartnerOption(userId: philip, displayName: "Philip"),
            SplitPartnerOption(userId: me, displayName: "Me"),
        ]
        let recent = SplitPartnerOption.recent(available: available, myUserId: me, limit: 5)
        XCTAssertEqual(recent.map(\.userId), [julia, philip])
        XCTAssertFalse(recent.contains(where: { $0.userId == me }))
    }

    func testRecentIsScopedPerAccount() {
        RecentSplitPartners.record([julia], for: me)
        RecentSplitPartners.record([philip], for: otherAccount)
        XCTAssertEqual(RecentSplitPartners.loadIDs(for: me), [julia])
        XCTAssertEqual(RecentSplitPartners.loadIDs(for: otherAccount), [philip])
    }

    func testRecentSeedsFromSharedExpenseHistory() {
        let older = ExpenseRecord(
            amountMinor: 1000,
            category: .groceries,
            spentAt: Date(timeIntervalSince1970: 1_000),
            paidBy: me,
            createdBy: me,
            shares: [
                ExpenseShareRecord(userId: me, amountMinor: 500),
                ExpenseShareRecord(userId: philip, amountMinor: 500),
            ],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = ExpenseRecord(
            amountMinor: 2000,
            category: .dining,
            spentAt: Date(timeIntervalSince1970: 2_000),
            paidBy: me,
            createdBy: me,
            shares: [
                ExpenseShareRecord(userId: me, amountMinor: 1000),
                ExpenseShareRecord(userId: julia, amountMinor: 1000),
            ],
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let available = [
            SplitPartnerOption(userId: julia, displayName: "Julia"),
            SplitPartnerOption(userId: philip, displayName: "Philip"),
        ]
        let recent = SplitPartnerOption.recent(
            available: available,
            myUserId: me,
            seedingFrom: [older, newer],
            limit: 5
        )
        XCTAssertEqual(recent.map(\.userId), [julia, philip])
    }

    func testRecordKeepsOnlyTheEightMostRecent() {
        let partners = (0..<10).map { _ in UUID() }
        partners.forEach { RecentSplitPartners.record([$0], for: me) }
        XCTAssertEqual(RecentSplitPartners.loadIDs(for: me), Array(partners.reversed().prefix(8)))
    }
}

final class SplitPartnerDisplayNameTests: XCTestCase {
    override func tearDown() {
        ConnectionDirectory.shared.replace([])
        super.tearDown()
    }

    func testNamesComeFromConnectionsWithAFallback() {
        ConnectionDirectory.shared.replace([
            SplitPartnerOption(userId: TestUser.alice, displayName: "Alice"),
            SplitPartnerOption(userId: TestUser.bob, displayName: "Bob"),
            SplitPartnerOption(userId: TestUser.carol, displayName: "Carol"),
        ])

        XCTAssertEqual(SplitPartnerOption.displayName(for: UUID(), fallback: "Someone"), "Someone")
        XCTAssertEqual(SplitPartnerOption.displayNames(for: [UUID]()), "Partner")
        XCTAssertEqual(SplitPartnerOption.displayNames(for: [TestUser.alice]), "Alice")
        XCTAssertEqual(SplitPartnerOption.displayNames(for: [TestUser.alice, TestUser.bob]), "Alice and Bob")
        XCTAssertEqual(SplitPartnerOption.displayNames(for: [TestUser.alice, TestUser.bob, TestUser.carol]), "Alice, Bob, and Carol")
    }

    func testPartnersExcludeMe() {
        let expense = sharedExpense(900, shares: [
            ExpenseShareRecord(userId: TestUser.alice, amountMinor: 300),
            ExpenseShareRecord(userId: TestUser.bob, amountMinor: 300),
            ExpenseShareRecord(userId: TestUser.carol, amountMinor: 300),
        ])
        XCTAssertEqual(SplitPartnerOption.partnerUserIds(in: expense, myUserId: TestUser.alice), [TestUser.bob, TestUser.carol])
    }
}
