import Foundation
import Network

/// Whether the device can reach the internet. Loam keeps changes on the device while it can't.
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        #if DEBUG
        // Launch with -simulateOffline to try offline mode while the Mac stays online.
        if ProcessInfo.processInfo.arguments.contains("-simulateOffline") {
            isOnline = false
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != isOnline else { return }
                self.isOnline = isOnline
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.loam.connectivity"))
    }

    #if DEBUG
    /// Tests decide when the device is offline.
    func setOnlineForTesting(_ isOnline: Bool) {
        self.isOnline = isOnline
    }
    #endif

    /// True when a request failed because the device couldn't reach the server, so trying
    /// again later can succeed. Server answers (validation, conflicts) are never offline errors.
    nonisolated static func isOfflineError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return offlineCodes.contains(urlError.code)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return offlineCodes.contains(URLError.Code(rawValue: nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isOfflineError(underlying)
        }
        return false
    }

    private nonisolated static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .timedOut,
        .dataNotAllowed,
        .internationalRoamingOff,
        .callIsActive
    ]
}

/// Actions that only make sense with a connection, such as answering a suggested edit.
enum OfflineError: LocalizedError {
    case requiresConnection

    var errorDescription: String? {
        "You're offline. Try again when you're back online."
    }
}
