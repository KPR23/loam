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
        var options = TestAccount.configured.compactMap { account -> SplitPartnerOption? in
            guard let userId = account.userId, userId != currentUserId else { return nil }
            return SplitPartnerOption(userId: userId, displayName: account.displayName)
        }

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

    /// Most recently used split partners, for quick-select in the people picker.
    /// Prefers persisted recent IDs; seeds from shared expense history when needed.
    static func recent(
        available: [SplitPartnerOption],
        myUserId: UUID,
        seedingFrom expenses: [ExpenseRecord] = [],
        limit: Int = 5
    ) -> [SplitPartnerOption] {
        let selectable = available.filter { $0.userId != myUserId }
        let byId = Dictionary(uniqueKeysWithValues: selectable.map { ($0.userId, $0) })

        var orderedIds = RecentSplitPartners.loadIDs(for: myUserId).filter { byId[$0] != nil }
        if orderedIds.count < limit {
            for id in partnerUserIdsByRecency(in: expenses, myUserId: myUserId) where byId[id] != nil {
                if !orderedIds.contains(id) {
                    orderedIds.append(id)
                }
                if orderedIds.count >= limit { break }
            }
        }

        return Array(orderedIds.prefix(limit).compactMap { byId[$0] })
    }

    /// Partner user IDs from shared expenses, most recent first (deduped).
    static func partnerUserIdsByRecency(
        in expenses: [ExpenseRecord],
        myUserId: UUID
    ) -> [UUID] {
        let shared = expenses
            .filter(\.isShared)
            .sorted {
                $0.spentAt > $1.spentAt
                    || ($0.spentAt == $1.spentAt && $0.createdAt > $1.createdAt)
            }

        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for expense in shared {
            for userId in expense.shares.map(\.userId) where userId != myUserId {
                if seen.insert(userId).inserted {
                    ordered.append(userId)
                }
            }
        }
        return ordered
    }

    static func displayName(for userId: UUID, fallback: String = "Partner") -> String {
        #if DEBUG
        if let account = TestAccount.configured.first(where: { $0.userId == userId }) {
            return account.displayName
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

}

/// Lightweight persistence for recent split-partner quick picks (most-recent first).
/// Keys are scoped per signed-in / active user so DEBUG account switches do not bleed.
enum RecentSplitPartners {
    private static let maxCount = 8

    private static func defaultsKey(for userId: UUID) -> String {
        "loam.recentSplitPartnerUserIds.\(userId.uuidString)"
    }

    static func record(_ userIds: [UUID], for userId: UUID) {
        guard !userIds.isEmpty else { return }
        var ordered = loadIDs(for: userId)
        for id in userIds.reversed() {
            ordered.removeAll { $0 == id }
            ordered.insert(id, at: 0)
        }
        if ordered.count > maxCount {
            ordered = Array(ordered.prefix(maxCount))
        }
        UserDefaults.standard.set(ordered.map(\.uuidString), forKey: defaultsKey(for: userId))
    }

    static func loadIDs(for userId: UUID) -> [UUID] {
        guard let raw = UserDefaults.standard.array(forKey: defaultsKey(for: userId)) as? [String] else {
            return []
        }
        return raw.compactMap(UUID.init(uuidString:))
    }

    #if DEBUG
    static func resetForTesting(userId: UUID? = nil) {
        if let userId {
            UserDefaults.standard.removeObject(forKey: defaultsKey(for: userId))
            return
        }
        // Clear any keys written by tests (legacy global + per-user).
        UserDefaults.standard.removeObject(forKey: "loam.recentSplitPartnerUserIds")
        for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("loam.recentSplitPartnerUserIds.")
        {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    #endif
}
