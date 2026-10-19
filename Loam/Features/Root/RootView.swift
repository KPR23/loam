import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var authSession: AuthSession
    @AppStorage(OnboardingView.completedKey) private var hasCompletedOnboarding = false

    /// Whether onboarding was ever finished or reset here, as opposed to never recorded.
    private var hasRecordedOnboarding: Bool {
        UserDefaults.standard.object(forKey: OnboardingView.completedKey) != nil
    }

    var body: some View {
        Group {
            switch authSession.state {
            case .loading:
                ProgressView("Loading…")
            case .signedOut:
                // A pending deletion's status lives on the sign-in screen. UI tests drive sign-in directly.
                if hasCompletedOnboarding || authSession.deletionPending || LaunchEnvironment.isUITesting {
                    AuthView()
                        .transition(.opacity)
                } else {
                    OnboardingView { hasCompletedOnboarding = true }
                        .transition(.opacity)
                }
            case .signedIn:
                // Someone who signs up again right after deleting an account skipped
                // onboarding on the sign-in screen, where the deletion status showed instead.
                if hasCompletedOnboarding || !hasRecordedOnboarding || LaunchEnvironment.isUITesting {
                    MainTabView()
                } else {
                    OnboardingView { hasCompletedOnboarding = true }
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: authSession.state)
        .animation(.easeInOut(duration: 0.35), value: hasCompletedOnboarding)
        .onChange(of: authSession.state, initial: true) { _, state in
            switch state {
            case .loading:
                // Decided before any signed-out screen shows, so returning people never glimpse onboarding.
                // Only versions that kept no flag at all; a deleted account leaves it explicitly false.
                if !hasRecordedOnboarding, OnboardingHistory.hasUsedLoam() {
                    hasCompletedOnboarding = true
                }
            case .signedIn:
                if !hasRecordedOnboarding { hasCompletedOnboarding = true }
            case .signedOut:
                break
            }
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
    private var hideKeyboardWindow: HideKeyboardWindow?

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
        configuration.background.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2A2C33) : .systemBackground }
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
        // Not in deinit on purpose: didMoveToWindow re-observes after every move.
        NotificationCenter.default.removeObserver(self) // swiftlint:disable:this notification_center_detachment
        hideKeyboardButton.removeFromSuperview()
        hideKeyboardWindow?.isHidden = true
        hideKeyboardWindow = nil
        hideButtonBottomConstraint = nil
    }

    @objc private func dismissKeyboard() {
        window?.endEditing(true)
    }

    @objc private func hideKeyboard() {
        window?.endEditing(true)
    }

    /// The button lives in its own window above the app so sheets and their dimming never cover it.
    private func installHideKeyboardButton(in window: UIWindow) {
        guard let scene = window.windowScene else { return }
        let buttonWindow = HideKeyboardWindow(windowScene: scene)
        buttonWindow.windowLevel = .normal + 1
        buttonWindow.backgroundColor = .clear
        buttonWindow.rootViewController = UIViewController()
        buttonWindow.rootViewController?.view.backgroundColor = .clear
        buttonWindow.button = hideKeyboardButton
        buttonWindow.isHidden = false
        hideKeyboardWindow = buttonWindow
        let container = buttonWindow
        container.addSubview(hideKeyboardButton)
        hideButtonBottomConstraint = hideKeyboardButton.bottomAnchor.constraint(
            equalTo: container.bottomAnchor,
            constant: -keyboardGap
        )
        NSLayoutConstraint.activate([
            hideKeyboardButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
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
        let layoutWindow: UIWindow = hideKeyboardWindow ?? window
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
            layoutWindow.layoutIfNeeded()
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

/// Takes touches only on the hide-keyboard button; never key, so typing stays in the app.
private final class HideKeyboardWindow: UIWindow {
    weak var button: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let button, !button.isHidden, button.frame.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }

    override var canBecomeKey: Bool { false }
}
