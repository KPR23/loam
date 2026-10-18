import Foundation

/// The last data each screen loaded, saved per account so Loam still opens with it offline.
/// Changes made offline are stored here too, under `pendingChangesKey`, until they sync.
enum OfflineCache {
    static let pendingChangesKey = "pending-changes"

    /// Tests point this at a temporary folder.
    static var directory: URL = URL.applicationSupportDirectory.appending(path: "OfflineCache", directoryHint: .isDirectory)

    static func save<Value: Encodable>(_ value: Value, key: String, userId: UUID) {
        let folder = folder(for: userId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            excludeFromBackup(directory)
            let data = try JSONEncoder().encode(value)
            try data.write(to: file(key: key, userId: userId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A missing copy only means less to show offline.
        }
    }

    static func load<Value: Decodable>(_ type: Value.Type, key: String, userId: UUID) -> Value? {
        guard let data = try? Data(contentsOf: file(key: key, userId: userId)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func remove(key: String, userId: UUID) {
        try? FileManager.default.removeItem(at: file(key: key, userId: userId))
    }

    /// Signing out drops the saved screens but keeps changes that haven't synced yet,
    /// so they still reach the server when this account signs in again.
    static func removeSnapshots(for userId: UUID) {
        let folder = folder(for: userId)
        let keep = file(key: pendingChangesKey, userId: userId).lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent != keep {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Everything saved for an account, including unsynced changes, e.g. after it is deleted.
    static func removeAll(for userId: UUID) {
        try? FileManager.default.removeItem(at: folder(for: userId))
    }

    private static func folder(for userId: UUID) -> URL {
        directory.appending(path: userId.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private static func file(key: String, userId: UUID) -> URL {
        let safeKey = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return folder(for: userId).appending(path: String(safeKey) + ".json")
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

extension DatePeriod {
    /// Names this month's saved expenses in `OfflineCache`.
    var offlineCacheKey: String {
        switch self {
        case let .month(year, month): "expenses-\(year)-\(month)"
        }
    }

    func contains(_ day: Date) -> Bool {
        let (start, endExclusive) = dateRange
        return day >= start && day < endExclusive
    }
}
