import XCTest
@testable import Loam

final class NotificationPreferencesTests: XCTestCase {
    func testEveryActivityKindHasACategory() {
        let expected: [ActivityEventKind: NotificationCategory] = [
            .shared: .requests, .proposalCreated: .requests,
            .accepted: .replies, .rejected: .replies, .proposalAccepted: .replies, .proposalRejected: .replies, .autoAccepted: .replies,
            .edited: .changes, .participantRemoved: .changes, .deleted: .changes, .proposalSuperseded: .changes,
            .repaymentRecorded: .repayments, .repaymentReversed: .repayments,
        ]
        XCTAssertEqual(expected.count, 13)
        for (kind, category) in expected { XCTAssertEqual(NotificationCategory(kind: kind), category, "\(kind)") }
    }

    func testSubscriptSetsOneCategory() {
        var preferences = NotificationPreferences()
        preferences[.changes] = false
        XCTAssertEqual(preferences, NotificationPreferences(requests: true, replies: true, changes: false, repayments: true))
    }

    func testRouteReadsThePushPayload() {
        let user = UUID(), event = UUID(), expense = UUID()
        let route = NotificationRoute(userInfo: ["event_id": event.uuidString, "user_id": user.uuidString, "expense_id": expense.uuidString, "aps": [:]])
        XCTAssertEqual(route, NotificationRoute(userId: user, eventId: event, expenseId: expense))
        XCTAssertNil(NotificationRoute(userInfo: ["other": "payload"]))
        XCTAssertNil(NotificationRoute(userInfo: ["event_id": event.uuidString, "expense_id": "nope"])?.expenseId)
    }
}

@MainActor
final class PushNotificationStoreTests: XCTestCase {
    private final class FakeCenter: NotificationCenterClient {
        var current: NotificationPermission = .notDetermined
        var grantsOnRequest = true
        var registerCalls = 0
        var badges: [Int] = []
        var removed: Set<UUID> = []
        var removedAll = 0
        func permission() async -> NotificationPermission { current }
        func requestPermission() async -> Bool {
            if grantsOnRequest { current = .allowed } else { current = .denied }
            return grantsOnRequest
        }
        func registerForRemoteNotifications() { registerCalls += 1 }
        func setBadge(_ count: Int) async { badges.append(count) }
        func removeDelivered(eventIds: Set<UUID>) async { removed.formUnion(eventIds) }
        func removeAllDelivered() { removedAll += 1 }
    }

    private final class FakeRepository: NotificationRepository, @unchecked Sendable {
        var registered: [(String, PushEnvironment)] = []
        var unregistered: [String] = []
        var stored = NotificationPreferences()
        var saved: [NotificationPreferences] = []
        var failsSave = false
        var saveDelay: Duration = .zero
        var failsRegister = false
        func registerDevice(token: String, environment: PushEnvironment) async throws {
            if failsRegister { throw URLError(.notConnectedToInternet) }
            registered.append((token, environment))
        }
        func unregisterDevice(token: String) async throws { unregistered.append(token) }
        func fetchPreferences() async throws -> NotificationPreferences { stored }
        func savePreferences(_ preferences: NotificationPreferences) async throws {
            try await Task.sleep(for: saveDelay)
            if failsSave { throw URLError(.notConnectedToInternet) }
            saved.append(preferences)
        }
    }

    private let center = FakeCenter()
    private let repository = FakeRepository()
    private let token = Data([0xAB, 0x01, 0xFF])

    private func makeStore() -> PushNotificationStore {
        let repository = repository
        return PushNotificationStore(center: center, environment: .sandbox, repository: { repository })
    }

    func testTokenIsHexEncoded() {
        XCTAssertEqual(PushNotificationStore.hex(token), "ab01ff")
    }

    func testDeviceRegistersOnceAllowedAndSignedIn() async {
        let store = makeStore()
        await store.didRegister(deviceToken: token)
        await store.activate(userId: TestUser.alice)
        XCTAssertTrue(repository.registered.isEmpty, "Registered before the user allowed notifications")
        XCTAssertEqual(store.permission, .notDetermined)

        let allowed = await store.requestPermission()
        XCTAssertTrue(allowed)
        XCTAssertEqual(repository.registered.map(\.0), ["ab01ff"])
        XCTAssertEqual(repository.registered.first?.1, .sandbox)
        XCTAssertEqual(center.registerCalls, 1)

        await store.refreshPermission()
        XCTAssertEqual(repository.registered.count, 1, "Re-registered an unchanged token")
    }

    func testDeniedPermissionNeverRegisters() async {
        center.grantsOnRequest = false
        let store = makeStore()
        await store.didRegister(deviceToken: token)
        await store.activate(userId: TestUser.alice)
        let allowed = await store.requestPermission()
        XCTAssertFalse(allowed)
        XCTAssertEqual(store.permission, .denied)
        XCTAssertTrue(repository.registered.isEmpty)
    }

    func testFailedRegistrationRetriesOnNextRefresh() async {
        center.current = .allowed
        repository.failsRegister = true
        let store = makeStore()
        await store.didRegister(deviceToken: token)
        await store.activate(userId: TestUser.alice)
        XCTAssertTrue(repository.registered.isEmpty)
        repository.failsRegister = false
        await store.refreshPermission()
        XCTAssertEqual(repository.registered.count, 1)
    }

    func testSwitchingAccountsRegistersTheTokenAgain() async {
        center.current = .allowed
        let store = makeStore()
        await store.didRegister(deviceToken: token)
        await store.activate(userId: TestUser.alice)
        await store.activate(userId: TestUser.bob)
        XCTAssertEqual(repository.registered.count, 2)
    }

    func testSigningOutClearsBadgeAndBanners() async {
        center.current = .allowed
        let store = makeStore()
        await store.activate(userId: TestUser.alice)
        await store.activate(userId: nil)
        XCTAssertEqual(center.badges.last, 0)
        XCTAssertEqual(center.removedAll, 1)
    }

    func testDeviceUnregistersBeforeSignOut() async {
        center.current = .allowed
        let store = makeStore()
        await store.didRegister(deviceToken: token)
        await store.activate(userId: TestUser.alice)
        await store.deviceWillSignOut()
        XCTAssertEqual(repository.unregistered, ["ab01ff"])
    }

    func testPreferencesLoadAndSave() async {
        repository.stored = NotificationPreferences(requests: true, replies: false, changes: true, repayments: true)
        let store = makeStore()
        await store.activate(userId: TestUser.alice)
        XCTAssertEqual(store.preferencesState, .loaded)
        XCTAssertFalse(store.preferences.replies)

        await store.setPreference(.repayments, enabled: false)
        XCTAssertEqual(repository.saved.last, NotificationPreferences(requests: true, replies: false, changes: true, repayments: false))
    }

    func testFailedSaveRevertsTheSwitch() async {
        let store = makeStore()
        await store.activate(userId: TestUser.alice)
        repository.failsSave = true
        await store.setPreference(.changes, enabled: false)
        XCTAssertTrue(store.preferences.changes)
        XCTAssertNotNil(store.lastError)
    }

    func testBadgeOnlyFollowsWhenAllowed() async {
        let store = makeStore()
        await store.activate(userId: TestUser.alice)
        await store.updateBadge(unreadCount: 3)
        XCTAssertTrue(center.badges.isEmpty)
        center.current = .allowed
        await store.refreshPermission()
        await store.updateBadge(unreadCount: 3)
        XCTAssertEqual(center.badges, [3])
    }

    func testReadEventsClearTheirBanners() async {
        let id = UUID()
        await makeStore().clearDelivered(eventIds: [id])
        XCTAssertEqual(center.removed, [id])
    }

    func testQuickSuccessiveSwitchesSaveInOrder() async {
        let store = makeStore()
        await store.activate(userId: TestUser.alice)
        repository.saveDelay = .milliseconds(50)
        async let first: Void = store.setPreference(.changes, enabled: false)
        try? await Task.sleep(for: .milliseconds(10))
        await store.setPreference(.replies, enabled: false)
        await first
        let final = NotificationPreferences(requests: true, replies: false, changes: false, repayments: true)
        XCTAssertEqual(store.preferences, final)
        XCTAssertEqual(repository.saved.last, final, "An older save landed last")
    }

    func testTappedPushRoutesOnlyToItsOwnAccount() {
        let store = makeStore()
        let expense = UUID()
        store.open(userInfo: ["event_id": UUID().uuidString, "user_id": TestUser.alice.uuidString, "expense_id": expense.uuidString])
        XCTAssertEqual(store.consumeRoute(for: TestUser.alice)?.expenseId, expense)
        XCTAssertNil(store.pendingRoute)

        store.open(userInfo: ["event_id": UUID().uuidString, "user_id": TestUser.alice.uuidString])
        XCTAssertNil(store.consumeRoute(for: TestUser.bob), "Another account opened someone else's push")
        XCTAssertNil(store.pendingRoute)
    }
}
