import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var authSession: AuthSession

    var body: some View {
        Group {
            switch authSession.state {
            case .loading:
                ProgressView("Loading…")
            case .signedOut:
                AuthView()
            case .signedIn:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: authSession.state)
        .background(KeyboardDismissalInstaller())
    }
}

/// Install once per window so presented sheets receive the same behavior.
private struct KeyboardDismissalInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardDismissalView {
        KeyboardDismissalView()
    }

    func updateUIView(_ uiView: KeyboardDismissalView, context: Context) {}

    static func dismantleUIView(_ uiView: KeyboardDismissalView, coordinator: ()) {
        uiView.removeRecognizer()
    }
}

private final class KeyboardDismissalView: UIView, UIGestureRecognizerDelegate {
    private lazy var dismissalTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizer()
        window?.addGestureRecognizer(dismissalTap)
    }

    func removeRecognizer() {
        dismissalTap.view?.removeGestureRecognizer(dismissalTap)
    }

    @objc private func dismissKeyboard() {
        window?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Let input controls handle cursor placement and direct field-to-field focus.
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView {
                return false
            }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
