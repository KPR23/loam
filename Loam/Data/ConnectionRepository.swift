import Foundation

struct ConnectionInvitation: Equatable, Sendable {
    let code: String
    let expiresAt: Date
}

protocol ConnectionRepository: Sendable {
    func listConnections() async throws -> [SplitPartnerOption]
    func createInvitation() async throws -> ConnectionInvitation
    func activeInvitation() async throws -> ConnectionInvitation?
    func revokeInvitation() async throws
    func preview(code: String) async throws -> String
    func redeem(code: String) async throws -> SplitPartnerOption
}
