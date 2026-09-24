import XCTest
@testable import Loam

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

    func testSettledBalancesNeedNoTransfers() {
        XCTAssertTrue(BalanceSimplifier.simplify([]).isEmpty)
        XCTAssertTrue(BalanceSimplifier.simplify([.init(userId: alice, amountMinor: 0)]).isEmpty)
    }

    func testOneCreditorIsPaidByEveryDebtor() {
        let transfers = BalanceSimplifier.simplify([
            .init(userId: alice, amountMinor: 900),
            .init(userId: bob, amountMinor: -600),
            .init(userId: carol, amountMinor: -300),
        ])
        XCTAssertEqual(Set(transfers), [
            .init(fromUserId: bob, toUserId: alice, amountMinor: 600),
            .init(fromUserId: carol, toUserId: alice, amountMinor: 300),
        ])
    }

    func testEveryNetBalanceIsSettledExactly() {
        let nets: [BalanceSimplifier.NetBalance] = [
            .init(userId: alice, amountMinor: 500),
            .init(userId: bob, amountMinor: 250),
            .init(userId: carol, amountMinor: -750),
        ]
        let transfers = BalanceSimplifier.simplify(nets)
        for net in nets {
            let received = transfers.filter { $0.toUserId == net.userId }.reduce(0) { $0 + $1.amountMinor }
            let paid = transfers.filter { $0.fromUserId == net.userId }.reduce(0) { $0 + $1.amountMinor }
            XCTAssertEqual(received - paid, net.amountMinor)
        }
    }
}
