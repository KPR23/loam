import XCTest
@testable import Loam

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

    func testPersonalExpenseIsOneFullShare() {
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

    func testMultiPersonPercentageSplitGivesMineAndSplitsRemainder() {
        let shares = SplitCalculator.split(
            totalMinor: 1000,
            mode: .percentage,
            myUserId: alice,
            partnerUserIds: [bob, carol],
            paidByUserId: bob,
            myPercentage: 40
        )

        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1000))
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 400)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 300)
        XCTAssertEqual(shares.first { $0.userId == carol }?.amountMinor, 300)
    }

    func testMultiPersonExactSplitGivesMineAndSplitsRemainder() {
        let shares = SplitCalculator.split(
            totalMinor: 1001,
            mode: .exactAmount,
            myUserId: alice,
            partnerUserIds: [bob, carol],
            paidByUserId: bob,
            myExactAmountMinor: 401
        )

        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1001))
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 401)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 300)
        XCTAssertEqual(shares.first { $0.userId == carol }?.amountMinor, 300)
    }

    func testMultiPersonPercentageSplitUsesEveryParticipantInput() {
        let shares = SplitCalculator.split(
            totalMinor: 1000,
            mode: .percentage,
            myUserId: alice,
            partnerUserIds: [bob, carol],
            paidByUserId: alice,
            participantPercentages: [alice: 20, bob: 30, carol: 50]
        )

        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 200)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 300)
        XCTAssertEqual(shares.first { $0.userId == carol }?.amountMinor, 500)
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1000))
    }

    func testTwoPersonPercentageSplitUsesEditableParticipantInputs() {
        let shares = SplitCalculator.split(
            totalMinor: 1000,
            mode: .percentage,
            myUserId: alice,
            partnerUserIds: [bob],
            paidByUserId: alice,
            myPercentage: 50,
            participantPercentages: [alice: 25, bob: 75]
        )

        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 250)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 750)
    }

    func testMultiPersonExactSplitUsesEveryParticipantInput() {
        let shares = SplitCalculator.split(
            totalMinor: 1001,
            mode: .exactAmount,
            myUserId: alice,
            partnerUserIds: [bob, carol],
            paidByUserId: bob,
            participantExactAmountMinors: [alice: 101, bob: 400, carol: 500]
        )

        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 101)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 400)
        XCTAssertEqual(shares.first { $0.userId == carol }?.amountMinor, 500)
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1001))
    }

    func testPayingEverythingForSomeoneElseIsValid() {
        let error = SplitExpenseSection.validationError(
            totalMinor: 1000,
            selectedPartnerCount: 1,
            splitMode: .percentage,
            participantUserIds: [alice, bob],
            participantPercentages: [alice: 0, bob: 100],
            participantAmountTexts: [:]
        )
        XCTAssertNil(error)

        let shares = SplitCalculator.split(
            totalMinor: 1000,
            mode: .percentage,
            myUserId: alice,
            partnerUserIds: [bob],
            paidByUserId: alice,
            participantPercentages: [alice: 0, bob: 100]
        )
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 0)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 1000)
    }

    func testZeroPercentPayerNeverReceivesRemainder() {
        let shares = SplitCalculator.percentage(
            totalMinor: 1001,
            userPercentages: [(alice, 0), (bob, 50), (carol, 50)],
            paidByUserId: alice
        )
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 1001))
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 0)
    }

    func testZeroShareReopensAsPercentage() {
        let stored = [
            SplitCalculator.Share(userId: alice, amountMinor: 0),
            SplitCalculator.Share(userId: bob, amountMinor: 1000),
        ]
        let percentages = SplitCalculator.matchingPercentages(
            totalMinor: 1000,
            paidByUserId: alice,
            storedShares: stored
        )
        XCTAssertEqual(percentages?[alice], 0)
        XCTAssertEqual(percentages?[bob], 100)
    }

    func testTwoPersonEqualSplit() {
        let shares = SplitCalculator.twoPersonSplit(
            totalMinor: 1001,
            mode: .equal,
            myUserId: alice,
            partnerUserId: bob,
            paidByUserId: bob
        )
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 500)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 501)
    }

    func testRemainderGoesToFirstParticipantWhenPayerIsNotSplitting() {
        let shares = SplitCalculator.equal(totalMinor: 101, participants: [alice, bob], paidByUserId: carol)
        XCTAssertTrue(SplitCalculator.sharesSumEqualsTotal(shares, totalMinor: 101))
        XCTAssertEqual(shares.map(\.amountMinor).sorted(), [50, 51])
    }

    func testEqualSplitCountsDuplicateParticipantsOnce() {
        let shares = SplitCalculator.equal(totalMinor: 1000, participants: [alice, bob, bob], paidByUserId: alice)
        XCTAssertEqual(shares.count, 2)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 500)
    }

    func testZeroTotalSplitsIntoZeroShares() {
        let shares = SplitCalculator.equal(totalMinor: 0, participants: [alice, bob], paidByUserId: alice)
        XCTAssertEqual(shares.map(\.amountMinor), [0, 0])
    }

    func testMultiPersonEqualSplitRemainderGoesToPayer() {
        let shares = SplitCalculator.split(
            totalMinor: 1000,
            mode: .equal,
            myUserId: alice,
            partnerUserIds: [bob, carol],
            paidByUserId: carol
        )
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 333)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 333)
        XCTAssertEqual(shares.first { $0.userId == carol }?.amountMinor, 334)
    }

    func testIncompletePercentageInputsFallBackToMyPercentage() {
        let shares = SplitCalculator.split(
            totalMinor: 1000,
            mode: .percentage,
            myUserId: alice,
            partnerUserIds: [bob],
            paidByUserId: alice,
            myPercentage: 40,
            participantPercentages: [alice: 30]
        )
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 400)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 600)
    }

    func testExactInputsThatMissTheTotalFallBackToMyExactAmount() {
        let shares = SplitCalculator.split(
            totalMinor: 1000,
            mode: .exactAmount,
            myUserId: alice,
            partnerUserIds: [bob],
            paidByUserId: alice,
            myExactAmountMinor: 300,
            participantExactAmountMinors: [alice: 100, bob: 100]
        )
        XCTAssertEqual(shares.first { $0.userId == alice }?.amountMinor, 300)
        XCTAssertEqual(shares.first { $0.userId == bob }?.amountMinor, 700)
    }

    func testMatchingPercentagesRejectsInvalidStoredShares() {
        let halves = [
            SplitCalculator.Share(userId: alice, amountMinor: 500),
            SplitCalculator.Share(userId: bob, amountMinor: 500),
        ]
        XCTAssertNil(SplitCalculator.matchingPercentages(totalMinor: 0, paidByUserId: alice, storedShares: halves))
        XCTAssertNil(SplitCalculator.matchingPercentages(totalMinor: 1200, paidByUserId: alice, storedShares: halves))
        XCTAssertNil(SplitCalculator.matchingPercentages(
            totalMinor: 1000,
            paidByUserId: alice,
            storedShares: [SplitCalculator.Share(userId: alice, amountMinor: 500), SplitCalculator.Share(userId: alice, amountMinor: 500)]
        ))
        XCTAssertNil(SplitCalculator.matchingTwoPersonPercentage(
            totalMinor: 1000, myUserId: alice, partnerUserId: carol, paidByUserId: alice, storedShares: halves
        ))
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

    func testMatchingPercentagesAcceptsMultiPersonPercentageSplit() {
        let stored = SplitCalculator.percentage(
            totalMinor: 1001,
            userPercentages: [(alice, 20), (bob, 30), (carol, 50)],
            paidByUserId: bob
        )

        XCTAssertEqual(
            SplitCalculator.matchingPercentages(
                totalMinor: 1001,
                paidByUserId: bob,
                storedShares: stored
            ),
            [alice: 20, bob: 30, carol: 50]
        )
    }

    func testMatchingPercentagesRejectsCustomExactAmounts() {
        let stored = [
            SplitCalculator.Share(userId: alice, amountMinor: 101),
            SplitCalculator.Share(userId: bob, amountMinor: 400),
            SplitCalculator.Share(userId: carol, amountMinor: 500),
        ]

        XCTAssertNil(
            SplitCalculator.matchingPercentages(
                totalMinor: 1001,
                paidByUserId: bob,
                storedShares: stored
            )
        )
    }
}
