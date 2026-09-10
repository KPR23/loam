import Foundation

struct SplitPartnerOption: Identifiable, Equatable, Hashable {
    let userId: UUID
    let displayName: String

    var id: UUID { userId }

    static func isSplitAvailable(usesRemoteBackend: Bool) -> Bool {
        #if DEBUG
        _ = usesRemoteBackend
        return true
        #else
        return !usesRemoteBackend
        #endif
    }

    static func available(
        for currentUserId: UUID,
        savedMainAccount: SplitPartnerOption? = nil
    ) -> [SplitPartnerOption] {
        #if DEBUG
        var options = TestAccount.allCases
            .filter { $0.userId != currentUserId }
            .map { SplitPartnerOption(userId: $0.userId, displayName: $0.displayName) }

        if let savedMainAccount, savedMainAccount.userId != currentUserId {
            options.append(savedMainAccount)
        }

        return options.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        #else
        _ = currentUserId
        _ = savedMainAccount
        return []
        #endif
    }

    static func partnerUserIds(in expense: ExpenseRecord, myUserId: UUID) -> Set<UUID> {
        Set(expense.shares.map(\.userId).filter { $0 != myUserId })
    }

    static func displayName(for userId: UUID, fallback: String = "Partner") -> String {
        #if DEBUG
        if let account = TestAccount.allCases.first(where: { $0.userId == userId }) {
            return account.displayName
        }
        if let savedName = savedMainDisplayName(for: userId) {
            return savedName
        }
        #endif
        return fallback
    }

    static func displayNames(for userIds: some Sequence<UUID>, fallback: String = "Partner") -> String {
        let names = userIds.map { displayName(for: $0, fallback: fallback) }
        switch names.count {
        case 0: return fallback
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head), and \(names.last!)"
        }
    }

    #if DEBUG
    static func shouldUseLocalSimulation(for partnerUserIds: [UUID]) -> Bool {
        !partnerUserIds.isEmpty && partnerUserIds.allSatisfy(isSimulatedAccount)
    }

    static func isSimulatedAccount(_ userId: UUID) -> Bool {
        TestAccount.contains(userId: userId) || savedMainDisplayName(for: userId) != nil
    }

    private static func savedMainDisplayName(for userId: UUID) -> String? {
        guard
            let idString = UserDefaults.standard.string(forKey: "loam.debug.savedMain.userId"),
            idString == userId.uuidString
        else {
            return nil
        }
        return UserDefaults.standard.string(forKey: "loam.debug.savedMain.displayName")
    }
    #endif
}
