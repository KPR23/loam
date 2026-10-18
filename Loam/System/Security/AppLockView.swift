import SwiftUI
import UIKit

/// The screen that covers Loam while it's locked.
struct AppLockView: View {
    @EnvironmentObject private var appLock: AppLock
    /// On screen with the app active. The window stays in place while hidden, so this gates
    /// the prompt; the scene phase is passed in because this window sits outside the SwiftUI scene.
    let isPresented: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            LoamArcMark()
            Text("Loam is locked")
                .font(.headline)
                .foregroundStyle(HomeTheme.secondary)
            Spacer()
            Button {
                Task { await appLock.unlock() }
            } label: {
                Label("Unlock with \(appLock.method.title)", systemImage: appLock.method.symbolName)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(appLock.isAuthenticating)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomeTheme.background.ignoresSafeArea())
        .task(id: isPresented) {
            // Face ID makes the scene inactive, which ends this task; the prompt must outlive it.
            if isPresented { Task { await appLock.unlockAutomaticallyIfNeeded() } }
        }
    }
}

/// Shows the lock screen in a window above the app, so open sheets and alerts are covered too.
struct AppLockWindowInstaller<Content: View>: UIViewRepresentable {
    let isLocked: Bool
    /// Covers the app the moment it backgrounds, before SwiftUI catches up, so the
    /// app switcher snapshot never shows what's behind the lock.
    let coversOnBackground: Bool
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> AppLockAnchorView<Content> {
        AppLockAnchorView(content: content())
    }

    func updateUIView(_ uiView: AppLockAnchorView<Content>, context: Context) {
        uiView.update(isLocked: isLocked, coversOnBackground: coversOnBackground, content: content())
    }

    static func dismantleUIView(_ uiView: AppLockAnchorView<Content>, coordinator: ()) {
        uiView.tearDown()
    }
}

final class AppLockAnchorView<Content: View>: UIView {
    private var lockWindow: UIWindow?
    private let host: UIHostingController<Content>
    private var isLocked = false
    private var coversOnBackground = false
    private var backgroundObserver: NSObjectProtocol?

    init(content: Content) {
        host = UIHostingController(rootView: content)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // VoiceOver must not reach the app underneath.
        host.view.accessibilityViewIsModal = true
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installIfNeeded()
        apply()
    }

    func update(isLocked: Bool, coversOnBackground: Bool, content: Content) {
        self.isLocked = isLocked
        self.coversOnBackground = coversOnBackground
        host.rootView = content
        installIfNeeded()
        apply()
    }

    func tearDown() {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        lockWindow?.isHidden = true
        lockWindow = nil
    }

    private func installIfNeeded() {
        guard lockWindow == nil, let scene = window?.windowScene else { return }
        let lockWindow = UIWindow(windowScene: scene)
        lockWindow.windowLevel = .alert + 1
        lockWindow.rootViewController = host
        lockWindow.isHidden = true
        self.lockWindow = lockWindow
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didEnterBackgroundNotification,
            object: scene,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.coversOnBackground else { return }
                self.show()
            }
        }
    }

    private func apply() {
        guard let lockWindow, lockWindow.isHidden == isLocked else { return }
        if isLocked {
            show()
        } else {
            lockWindow.isHidden = true
            window?.makeKey()
        }
    }

    private func show() {
        guard let lockWindow, lockWindow.isHidden else { return }
        // A keyboard left open would sit above the lock screen.
        window?.endEditing(true)
        // Key, so hardware keyboard input and shortcuts can't reach the app underneath.
        lockWindow.makeKeyAndVisible()
    }
}
