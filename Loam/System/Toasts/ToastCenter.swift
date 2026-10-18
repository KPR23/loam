import SwiftUI
import UIKit

/// One message at the top of the screen: an error, a missing state or a finished action.
struct Toast: Identifiable {
    enum Style {
        case success, error, warning, info
    }

    /// A button on the trailing edge, such as Undo or Retry.
    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    let id = UUID()
    var style: Style
    var message: String
    var action: Action?
    var duration: TimeInterval
    /// Runs once when the toast leaves without its action being tapped: it timed out,
    /// was swiped away, or another toast replaced it. Undoable changes commit here.
    var onExpire: (@MainActor () -> Void)?

    static let undoDuration: TimeInterval = 5

    static func success(_ message: String) -> Toast {
        Toast(style: .success, message: message, duration: 2.5)
    }

    static func error(_ message: String, action: Action? = nil) -> Toast {
        Toast(style: .error, message: message, action: action, duration: 4)
    }

    static func warning(_ message: String) -> Toast {
        Toast(style: .warning, message: message, duration: 4)
    }

    static func info(_ message: String) -> Toast {
        Toast(style: .info, message: message, duration: 3)
    }

    /// A finished change the person can take back for `undoDuration` seconds.
    static func undoable(
        _ message: String,
        undo: @escaping @MainActor () -> Void,
        commit: @escaping @MainActor () -> Void
    ) -> Toast {
        Toast(
            style: .success,
            message: message,
            action: Action(title: "Undo", perform: undo),
            duration: undoDuration,
            onExpire: commit
        )
    }
}

/// Shows the app's toasts, one at a time. A new toast replaces the one on screen.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: Toast?
    /// When the current toast started, for the Undo countdown.
    @Published private(set) var shownAt = Date()
    /// How long the current toast stays, for the Undo countdown.
    @Published private(set) var currentDuration: TimeInterval = 0

    private var expiry: Task<Void, Never>?

    func show(_ toast: Toast) {
        // The same words again, such as repeated offline refreshes, keep the toast already up.
        if let current, current.message == toast.message, current.style == toast.style,
           current.action == nil, toast.action == nil, toast.onExpire == nil {
            scheduleExpiry(for: current.id, after: duration(for: current))
            return
        }
        expireCurrent()
        current = toast
        shownAt = Date()
        currentDuration = duration(for: toast)
        if toast.style == .error { LoamFeedback.error() }
        UIAccessibility.post(notification: .announcement, argument: announcement(for: toast))
        scheduleExpiry(for: toast.id, after: currentDuration)
    }

    /// Shows what went wrong, or nothing when the error needs no message, such as a cancellation.
    func show(error: Error, action: Toast.Action? = nil) {
        guard let message = UserFacingError.message(for: error) else { return }
        show(.error(message, action: action))
    }

    func showError(_ message: String, action: Toast.Action? = nil) {
        show(.error(message, action: action))
    }

    func showSuccess(_ message: String) {
        show(.success(message))
    }

    /// The action was tapped: it runs instead of the expiry.
    func performAction(of id: Toast.ID) {
        guard let toast = current, toast.id == id else { return }
        expiry?.cancel()
        current = nil
        toast.action?.perform()
    }

    /// Swiped or tapped away, or timed out.
    func dismiss(_ id: Toast.ID) {
        guard current?.id == id else { return }
        expireCurrent()
    }

    /// Ends the toast on screen now, committing anything it could still undo.
    /// Called before the app leaves the foreground, where a timer may never fire.
    func expireCurrent() {
        expiry?.cancel()
        expiry = nil
        guard let toast = current else { return }
        current = nil
        toast.onExpire?()
    }

    private func scheduleExpiry(for id: Toast.ID, after duration: TimeInterval) {
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    /// VoiceOver reads the toast before acting on it, so it stays longer.
    private func duration(for toast: Toast) -> TimeInterval {
        let base = max(toast.duration, toast.action == nil ? 0 : 4)
        return UIAccessibility.isVoiceOverRunning ? base * 2 : base
    }

    private func announcement(for toast: Toast) -> String {
        guard let action = toast.action else { return toast.message }
        return "\(toast.message) \(action.title) is available."
    }
}

extension View {
    /// Shows `message` as an error toast, then clears it so the same message can show again.
    func errorToast(_ message: Binding<String?>) -> some View {
        onChange(of: message.wrappedValue) { _, newValue in
            guard let newValue else { return }
            ToastCenter.shared.showError(newValue)
            message.wrappedValue = nil
        }
    }
}
