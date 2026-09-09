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
