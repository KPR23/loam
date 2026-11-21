import BackgroundTasks
import UIKit
import UserNotifications

/// Asks iOS for time to finish work that started on screen, such as a save, when Loam leaves it.
@MainActor
enum BackgroundTime {
    static func run<Value>(_ name: String, operation: () async throws -> Value) async rethrows -> Value {
        let task = Holder()
        task.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: the request stops, and the change it carried stays on the device.
            MainActor.assumeIsolated { task.end() }
        }
        defer { task.end() }
        return try await operation()
    }

    @MainActor
    private final class Holder {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}

/// Keeps the person posted about changes that are still on the device after they leave Loam:
/// a reminder when they haven't synced a while later, and a note when one couldn't sync at all.
@MainActor
final class SyncNotifier {
    static let shared = SyncNotifier()

    enum Category {
        static let waiting = "loam.sync.waiting"
        static let failed = "loam.sync.failed"
    }

    /// How long changes may wait after Loam leaves the screen before the reminder shows.
    static let reminderDelay: TimeInterval = 15 * 60
    /// The background refresh that sends waiting changes, e.g. once the connection is back.
    nonisolated static var refreshTaskId: String { (Bundle.main.bundleIdentifier ?? "app.loam") + ".sync" }

    private static let waitingId = "loam.sync.waiting"

    private var center: UNUserNotificationCenter { .current() }
    /// Tests must never touch the system notification center or task scheduler.
    private var isEnabled: Bool { !LaunchEnvironment.isAutomatedTest }

    private var backgroundEntry: Task<Void, Never>?

    private init() {}

    nonisolated static var categories: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(identifier: Category.waiting, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.failed, actions: [], intentIdentifiers: []),
        ]
    }

    // MARK: - Leaving and opening Loam

    /// Loam left the screen: finish what's saving and send what's waiting. Anything that might
    /// still be on the device gets a background retry and a reminder first, since iOS can suspend
    /// Loam before a slow sync ends; both are dropped once everything is sent.
    func appDidEnterBackground(userId: UUID, hasUnsavedChanges: Bool, settle: @escaping () async -> Void) {
        guard isEnabled else { return }
        let waiting = OfflineSync.shared.waitingCount(for: userId)
        // Only the latest trip to the background decides about the reminder and the refresh.
        backgroundEntry?.cancel()
        backgroundEntry = Task {
            await BackgroundTime.run("Sync before suspending") {
                if waiting > 0 || hasUnsavedChanges {
                    scheduleRefresh()
                    await scheduleWaitingReminder(count: waiting, userId: userId)
                }
                await settle()
                await OfflineSync.shared.flush(userId: userId)
                guard !Task.isCancelled else { return }
                let left = OfflineSync.shared.waitingCount(for: userId)
                if left == 0 {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskId)
                    clearWaitingReminder()
                } else {
                    scheduleRefresh()
                    await scheduleWaitingReminder(count: left, userId: userId)
                }
            }
        }
    }

    /// Loam is on screen again, where the toasts and row badges take over from the reminder.
    func appDidBecomeActive() {
        guard isEnabled else { return }
        clearWaitingReminder()
    }

    func clearWaitingReminder() {
        guard isEnabled else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.waitingId])
        center.removeDeliveredNotifications(withIdentifiers: [Self.waitingId])
    }

    // MARK: - Notifications

    func postFailure(_ message: String, userId: UUID) async {
        // A change from an account that has since signed out isn't this person's to hear about.
        guard AppServices.shared.authSession.userId == userId, await canNotify() else { return }
        let content = makeContent(category: Category.failed, title: "A change couldn't sync", body: message, userId: userId)
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// `count` 0 means changes are still being saved, so the number isn't known yet.
    private func scheduleWaitingReminder(count: Int, userId: UUID) async {
        guard await canNotify() else { return }
        // Loam came back on screen meanwhile; it shows what's waiting itself.
        guard UIApplication.shared.applicationState == .background else { return }
        let body = count <= 1
            ? "Your change is saved on this iPhone and will sync on its own. Open Loam to sync it now."
            : "\(count) changes are saved on this iPhone and will sync on their own. Open Loam to sync them now."
        let content = makeContent(category: Category.waiting, title: "Not synced yet", body: body, userId: userId)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.reminderDelay, repeats: false)
        // The same id replaces an earlier reminder, so there is only ever one.
        try? await center.add(UNNotificationRequest(identifier: Self.waitingId, content: content, trigger: trigger))
    }

    private func makeContent(category: String, title: String, body: String, userId: UUID) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = ["user_id": userId.uuidString]
        content.interruptionLevel = .active
        return content
    }

    private func canNotify() async -> Bool {
        guard isEnabled else { return false }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    // MARK: - Background refresh

    /// Called at launch, before iOS can start the task.
    nonisolated static func registerRefreshTask() {
        // On the main queue, so the expiration handler is set before the handler returns.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: .main) { task in
            MainActor.assumeIsolated { SyncNotifier.shared.handleRefresh(task) }
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleRefresh(_ task: BGTask) {
        let run = RefreshRun(task)
        let work = Task {
            Connectivity.shared.start()
            guard let userId = try? await AppServices.shared.signedInUserId() else { return run.finish(true) }
            await OfflineSync.shared.flush(userId: userId)
            let waiting = OfflineSync.shared.waitingCount(for: userId)
            // Still offline: try again later. The reminder scheduled on leaving Loam stays.
            if waiting > 0 { scheduleRefresh() }
            run.finish(waiting == 0)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in run.finish(false) }
        }
    }

    /// iOS ends the app if a task is completed twice or never, so the first ending wins.
    @MainActor
    private final class RefreshRun {
        private let task: BGTask
        private var isFinished = false

        init(_ task: BGTask) { self.task = task }

        func finish(_ success: Bool) {
            guard !isFinished else { return }
            isFinished = true
            task.setTaskCompleted(success: success)
        }
    }
}
