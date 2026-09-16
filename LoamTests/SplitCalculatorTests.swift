import XCTest
@testable import Loam

final class MoneyTests: XCTestCase {
    func testParsesMajorString() {
        let money = Money(majorString: "12.34", currencyCode: "PLN")
        XCTAssertEqual(money?.amountMinor, 1234)
    }

    func testParsesCommaDecimal() {
        let money = Money(majorString: "12,5", currencyCode: "PLN")
        XCTAssertEqual(money?.amountMinor, 1250)
    }

    func testRejectsTooManyFractionDigits() {
        XCTAssertNil(Money(majorString: "1.234"))
    }

    func testRejectsLettersAndSymbols() {
        XCTAssertNil(Money(majorString: "12a"))
        XCTAssertNil(Money(majorString: "12 zł"))
        XCTAssertNil(Money(majorString: "-12"))
        XCTAssertNil(Money(majorString: "12;34"))
    }

    func testParsesTrailingCommaAsWholeUnits() {
        XCTAssertEqual(Money(majorString: "12,")?.amountMinor, 1200)
    }

    func testSanitizeTypingInput() {
        XCTAssertEqual(Money.sanitizeTypingInput("12a.3b4c5"), "12,34")
        XCTAssertEqual(Money.sanitizeTypingInput("..,,5"), "0,5")
        XCTAssertEqual(Money.sanitizeTypingInput("1,2,3"), "1,23")
    }

    func testAddition() {
        let a = Money(amountMinor: 100, currencyCode: "PLN")
        let b = Money(amountMinor: 50, currencyCode: "PLN")
        XCTAssertEqual((a + b).amountMinor, 150)
    }
}

final class SplitCalculatorTests: XCTestCase {
    let alice = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let bob = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let carol = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testEqualSplitEven() {
        let shares = SplitCalculator.equal(totalMinor: 1000, participants: [alice, bob], paidByUserId: alice)
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1000))
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 500)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 500)
    }

    func testEqualSplitRemainderGoesToPayer() {
        let shares = SplitCalculator.equal(totalMinor: 1001, participants: [alice, bob], paidByUserId: alice)
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1001))
        let aliceShare = shares.first { $0.userId == alice }!.amountMinor
        let bobShare = shares.first { $0.userId == bob }!.amountMinor
        XCTAssertEqual(aliceShare + bobShare, 1001)
        XCTAssertEqual(abs(aliceShare - bobShare), 1)
        XCTAssertEqual(aliceShare, 501) // remainder to payer
    }

    func testThreeWayRemainderToPayer() {
        let shares = SplitCalculator.equal(
            totalMinor: 100,
            participants: [alice, bob, carol],
            paidByUserId: bob
        )
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 100))
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 34) // 33+33+34
    }

    func testPersonalIsFullAmount() {
        let shares = SplitCalculator.personal(totalMinor: 2500, userId: alice)
        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(shares[0].amountMinor, 2500)
    }

    func testPercentageSplit() {
        let shares = SplitCalculator.percentage(
            totalMinor: 1000,
            userPercentages: [(alice, 70), (bob, 30)],
            paidByUserId: alice
        )
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1000))
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 700)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 300)
    }

    func testTwoPersonExactSplit() {
        let shares = SplitCalculator.twoPersonSplit(
            totalMinor: 999,
            mode: .exactAmount,
            myUserId: alice,
            partnerUserId: bob,
            paidByUserId: alice,
            myExactAmountMinor: 400
        )
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 999))
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 400)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 599)
    }

    func testTwoPersonEqualSplit() {
        let shares = SplitCalculator.twoPersonSplit(
            totalMinor: 1001,
            mode: .equal,
            myUserId: alice,
            partnerUserId: bob,
            paidByUserId: bob
        )
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1001))
    }

    func testMatchingPercentageRejectsExactSplitDisguisedAsHalf() {
        let stored = [
            SplitCalculator.Share(userId: alice, amountMinor: 500),
            SplitCalculator.Share(userId: bob, amountMinor: 501),
        ]

        XCTAssertNil(
            SplitCalculator.matchingTwoPersonPercentage(
                totalMinor: 1001,
                myUserId: alice,
                partnerUserId: bob,
                paidByUserId: alice,
                storedShares: stored
            )
        )
    }

    func testMatchingPercentageAcceptsTruePercentageSplit() {
        let stored = SplitCalculator.twoPersonSplit(
            totalMinor: 1000,
            mode: .percentage,
            myUserId: alice,
            partnerUserId: bob,
            paidByUserId: alice,
            myPercentage: 70
        )

        XCTAssertEqual(
            SplitCalculator.matchingTwoPersonPercentage(
                totalMinor: 1000,
                myUserId: alice,
                partnerUserId: bob,
                paidByUserId: alice,
                storedShares: stored
            ),
            70
        )
    }
}

final class BalanceSimplifierTests: XCTestCase {
    let alice = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let bob = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let carol = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testSimplePair() {
        let transfers = BalanceSimplifier.simplify([
            .init(userId: alice, amountMinor: 500),
            .init(userId: bob, amountMinor: -500),
        ])
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(transfers[0].fromUserId, bob)
        XCTAssertEqual(transfers[0].toUserId, alice)
        XCTAssertEqual(transfers[0].amountMinor, 500)
    }
}

final class RecentSplitPartnersTests: XCTestCase {
    let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let julia = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let philip = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

    override func setUp() {
        super.setUp()
        RecentSplitPartners.resetForTesting()
    }

    override func tearDown() {
        RecentSplitPartners.resetForTesting()
        super.tearDown()
    }

    func testRecordOrdersMostRecentFirstAndDedupes() {
        RecentSplitPartners.record([julia])
        RecentSplitPartners.record([philip, julia])
        XCTAssertEqual(RecentSplitPartners.loadIDs(), [philip, julia])
    }

    func testRecentExcludesCurrentUserAndMapsAvailable() {
        RecentSplitPartners.record([me, julia, philip])
        let available = [
            SplitPartnerOption(userId: julia, displayName: "Julia"),
            SplitPartnerOption(userId: philip, displayName: "Philip"),
            SplitPartnerOption(userId: me, displayName: "Me"),
        ]
        let recent = SplitPartnerOption.recent(available: available, myUserId: me, limit: 5)
        XCTAssertEqual(recent.map(\.userId), [julia, philip])
        XCTAssertFalse(recent.contains(where: { $0.userId == me }))
    }

    func testRecentSeedsFromSharedExpenseHistory() {
        let older = ExpenseRecord(
            amountMinor: 1000,
            category: .groceries,
            spentAt: Date(timeIntervalSince1970: 1_000),
            paidBy: me,
            createdBy: me,
            householdId: UUID(),
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
            householdId: UUID(),
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
}

