import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var authSession: AuthSession
    @AppStorage(OnboardingView.completedKey) private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            switch authSession.state {
            case .loading:
                ProgressView("Loading…")
            case .signedOut:
                // UI tests drive sign-in directly.
                if hasCompletedOnboarding || LaunchEnvironment.isUITesting {
                    AuthView()
                        .transition(.opacity)
                } else {
                    OnboardingView { hasCompletedOnboarding = true }
                        .transition(.opacity)
                }
            case .signedIn:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: authSession.state)
        .animation(.easeInOut(duration: 0.35), value: hasCompletedOnboarding)
        .onChange(of: authSession.state, initial: true) { _, state in
            // People who signed in before onboarding existed shouldn't meet it after signing out.
            if state == .signedIn { hasCompletedOnboarding = true }
        }
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
    private let keyboardGap: CGFloat = 16
    private var hideButtonBottomConstraint: NSLayoutConstraint?

    private lazy var dismissalTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    private lazy var hideKeyboardButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "keyboard.chevron.compact.down")
        configuration.baseForegroundColor = .systemBlue
        configuration.background.backgroundColor = .systemBackground
        configuration.background.cornerRadius = 24
        configuration.contentInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Hide keyboard"
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.12
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.addTarget(self, action: #selector(hideKeyboard), for: .touchUpInside)
        return button
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        removeRecognizer()
        guard let window else { return }
        window.addGestureRecognizer(dismissalTap)
        installHideKeyboardButton(in: window)
        observeKeyboard()
    }

    func removeRecognizer() {
        dismissalTap.view?.removeGestureRecognizer(dismissalTap)
        NotificationCenter.default.removeObserver(self)
        hideKeyboardButton.removeFromSuperview()
        hideButtonBottomConstraint = nil
    }

    @objc private func dismissKeyboard() {
        window?.endEditing(true)
    }

    @objc private func hideKeyboard() {
        window?.endEditing(true)
    }

    private func installHideKeyboardButton(in window: UIWindow) {
        window.addSubview(hideKeyboardButton)
        hideButtonBottomConstraint = hideKeyboardButton.bottomAnchor.constraint(
            equalTo: window.bottomAnchor,
            constant: -keyboardGap
        )
        NSLayoutConstraint.activate([
            hideKeyboardButton.trailingAnchor.constraint(equalTo: window.trailingAnchor, constant: -16),
            hideButtonBottomConstraint!,
            hideKeyboardButton.widthAnchor.constraint(equalToConstant: 48),
            hideKeyboardButton.heightAnchor.constraint(equalToConstant: 48)
        ])
        hideKeyboardButton.isHidden = true
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let window,
              let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let hideButtonBottomConstraint else { return }

        let keyboardFrame = window.convert(frameValue.cgRectValue, from: nil)
        let keyboardHeight = max(0, window.bounds.maxY - keyboardFrame.minY)
        let isKeyboardVisible = keyboardHeight > 0
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let curveValue = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curveValue << 16)

        if isKeyboardVisible {
            hideKeyboardButton.isHidden = false
        } else {
            // Avoid leaving the control visible after the keyboard has already gone away.
            hideKeyboardButton.isHidden = true
        }

        hideButtonBottomConstraint.constant = -(keyboardHeight + keyboardGap)
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) {
            window.layoutIfNeeded()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Controls perform their own actions. In particular, this prevents the keyboard
        // toolbar's Hide button from triggering a second, competing keyboard dismissal.
        var view = touch.view
        while let current = view {
            if current is UIControl || current is UITextField || current is UITextView {
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
