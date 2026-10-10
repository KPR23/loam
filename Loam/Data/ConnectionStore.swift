import Foundation
import SwiftUI

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [SplitPartnerOption] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedConnections = false
    @Published var lastError: String?
    private var accountId: UUID?
    private var requestID = UUID()

    func refresh(userId: UUID?) async {
        if accountId != userId {
            connections = []
            ConnectionDirectory.shared.replace([])
            hasLoadedConnections = false
            lastError = nil
        }
        accountId = userId
        guard let userId, let client = SupabaseClientProvider.shared else {
            connections = []
            ConnectionDirectory.shared.replace([])
            hasLoadedConnections = false
            return
        }
        let token = UUID(); requestID = token; isLoading = true
        defer { if requestID == token { isLoading = false } }
        do {
            let fetched = try await SupabaseConnectionRepository(client: client).listConnections()
            guard requestID == token, accountId == userId else { return }
            connections = fetched; ConnectionDirectory.shared.replace(fetched); hasLoadedConnections = true; lastError = nil
        } catch { guard requestID == token else { return }; lastError = error.localizedDescription }
    }
    func createInvitation() async throws -> ConnectionInvitation { guard let client = SupabaseClientProvider.shared else { throw ConnectionError.unavailable }; return try await LoamErrorCapture.withCapture("connections.invitation_create_failed") { try await SupabaseConnectionRepository(client: client).createInvitation() } }
    func activeInvitation() async throws -> ConnectionInvitation? { guard let client = SupabaseClientProvider.shared else { throw ConnectionError.unavailable }; return try await SupabaseConnectionRepository(client: client).activeInvitation() }
    func revokeInvitation() async throws { guard let client = SupabaseClientProvider.shared else { throw ConnectionError.unavailable }; try await LoamErrorCapture.withCapture("connections.invitation_revoke_failed") { try await SupabaseConnectionRepository(client: client).revokeInvitation() } }
    func preview(code: String) async throws -> String { guard let client = SupabaseClientProvider.shared else { throw ConnectionError.unavailable }; return try await SupabaseConnectionRepository(client: client).preview(code: code) }
    func createPlaceholder(name: String) async throws -> SplitPartnerOption {
        guard let client = SupabaseClientProvider.shared else { throw ConnectionError.unavailable }
        let friend = try await LoamErrorCapture.withCapture("connections.placeholder_create_failed") { try await SupabaseConnectionRepository(client: client).createPlaceholderFriend(name: name) }
        await refresh(userId: accountId)
        return friend
    }
    func remove(_ friend: SplitPartnerOption) async throws {
        guard let client = SupabaseClientProvider.shared else { throw ConnectionError.unavailable }
        try await LoamErrorCapture.withCapture("connections.remove_failed") { try await SupabaseConnectionRepository(client: client).removeConnection(userId: friend.userId) }
        await refresh(userId: accountId)
    }
    func redeem(code: String) async throws -> SplitPartnerOption { guard let client = SupabaseClientProvider.shared else { throw ConnectionError.unavailable }; let friend = try await SupabaseConnectionRepository(client: client).redeem(code: code); Telemetry.capture(.friendConnected); await refresh(userId: accountId); return friend }
}

final class ConnectionDirectory: @unchecked Sendable {
    static let shared = ConnectionDirectory()
    private var names: [UUID: String] = [:]
    private let lock = NSLock()
    func replace(_ people: [SplitPartnerOption]) { lock.lock(); defer { lock.unlock() }; names = Dictionary(uniqueKeysWithValues: people.map { ($0.userId, $0.displayName) }) }
    func name(for id: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return names[id] }
}
