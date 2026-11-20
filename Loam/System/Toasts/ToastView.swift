import SwiftUI
import UIKit

/// The toast card and its drop in from the top edge.
struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter
    /// Reports each card's frame in window coordinates, or nil once it's gone,
    /// so touches elsewhere pass through.
    let onFrameChange: (Toast.ID, CGRect?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack {
            // Stacked, so a replaced card leaves in place while the next one arrives over it.
            ZStack(alignment: .top) {
                if let toast = center.current {
                    ToastCard(
                        toast: toast,
                        shownAt: center.shownAt,
                        duration: center.currentDuration
                    ) {
                        center.performAction(of: toast.id)
                    }
                    .id(toast.id)
                    .offset(y: min(dragOffset, 0) + max(dragOffset, 0) * 0.15)
                    // Swipe up to dismiss. No tap-to-dismiss: on the card it took taps meant for Undo.
                    .simultaneousGesture(dismissGesture(for: toast.id))
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { onFrameChange(toast.id, proxy.frame(in: .global)) }
                                .onChange(of: proxy.frame(in: .global)) { _, frame in onFrameChange(toast.id, frame) }
                        }
                    )
                    // A replaced card can leave after the next one arrives, so each clears only its own frame.
                    .onDisappear { onFrameChange(toast.id, nil) }
                    .transition(reduceMotion ? Self.fade : Self.drop)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.22), value: center.current?.id)
        .onChange(of: center.current?.id) { _, _ in dragOffset = 0 }
    }

    /// Drops in from under the status bar with a little settle, and lifts away quicker than it came.
    private static let drop = AnyTransition.asymmetric(
        insertion: .move(edge: .top)
            .combined(with: .modifier(active: ToastMotion(isHidden: true), identity: ToastMotion(isHidden: false)))
            .animation(.spring(duration: 0.5, bounce: 0.22)),
        removal: .move(edge: .top)
            .combined(with: .modifier(active: ToastMotion(isHidden: true), identity: ToastMotion(isHidden: false)))
            .animation(.smooth(duration: 0.3))
    )

    /// Reduce Motion: no movement, only a short cross-fade.
    private static let fade = AnyTransition.opacity.animation(.easeInOut(duration: 0.2))

    private func dismissGesture(for id: Toast.ID) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { dragOffset = $0.translation.height }
            .onEnded { value in
                if value.translation.height < -24 || value.predictedEndTranslation.height < -60 {
                    center.dismiss(id)
                } else {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)) { dragOffset = 0 }
                }
            }
    }
}

/// Shrinks, blurs and fades the card at the edges of its transition.
private struct ToastMotion: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHidden ? 0.92 : 1, anchor: .top)
            .blur(radius: isHidden ? 6 : 0)
            .opacity(isHidden ? 0 : 1)
    }
}

struct ToastCard: View {
    let toast: Toast
    let shownAt: Date
    let duration: TimeInterval
    let onAction: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var tileSize: CGFloat = 32

    private var isDark: Bool { colorScheme == .dark }
    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Large text: the message gets the full width and the action sits under it.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        icon
                        message
                    }
                    actionButton
                }
            } else {
                HStack(spacing: 12) {
                    icon
                    message
                    actionButton
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, toast.action == nil ? 16 : 8)
        .padding(.vertical, toast.action == nil ? 12 : 6)
        .frame(minHeight: 56)
        // White in light mode; in dark mode the gray of a Home expense row.
        .background(card.fill(isDark ? HomeTheme.surface : Color.white))
        .overlay(card.strokeBorder(Color.primary.opacity(isDark ? 0.14 : 0.05), lineWidth: 1))
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.10), radius: 24, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityActions {
            if let action = toast.action {
                Button(action.title, action: onAction)
            }
        }
    }

    private var icon: some View {
        CategoryIconTile(
            systemImage: toast.style.symbolName,
            color: toast.style.tint,
            size: min(tileSize, 44)
        )
    }

    private var message: some View {
        Text(toast.message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(HomeTheme.text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action = toast.action {
            Button(action: onAction) {
                HStack(spacing: 6) {
                    if toast.onExpire != nil {
                        ToastCountdown(shownAt: shownAt, duration: duration)
                    }
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(HomeTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(HomeTheme.accent.opacity(isDark ? 0.22 : 0.12), in: Capsule(style: .continuous))
                // The tinted pill stays compact; the tap area still reaches 44 points.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(LoamPressStyle())
        }
    }
}

/// A ring that empties while the change can still be undone.
private struct ToastCountdown: View {
    let shownAt: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let elapsed = context.date.timeIntervalSince(shownAt)
            let remaining = max(0, 1 - elapsed / max(duration, 0.1))
            ZStack {
                Circle()
                    .stroke(HomeTheme.accent.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        }
        .accessibilityHidden(true)
    }
}

extension Toast.Style {
    var symbolName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: .green
        case .error: .red
        case .warning: .orange
        case .info: HomeTheme.accent
        }
    }
}

/// Shows toasts in a window above the app, so they appear over sheets and alerts too.
/// Below the lock screen, which covers everything.
struct ToastWindowInstaller<Content: View>: UIViewRepresentable {
    @ObservedObject var center: ToastCenter
    @ViewBuilder let content: (_ onFrameChange: @escaping (Toast.ID, CGRect?) -> Void) -> Content

    func makeUIView(context: Context) -> ToastAnchorView<Content> {
        ToastAnchorView(makeContent: content)
    }

    func updateUIView(_ uiView: ToastAnchorView<Content>, context: Context) {
        uiView.update(isShowing: center.current != nil, makeContent: content)
    }

    static func dismantleUIView(_ uiView: ToastAnchorView<Content>, coordinator: ()) {
        uiView.tearDown()
    }
}

final class ToastAnchorView<Content: View>: UIView {
    private var toastWindow: ToastWindow?
    private var host: UIHostingController<Content>?
    private var makeContent: (_ onFrameChange: @escaping (Toast.ID, CGRect?) -> Void) -> Content
    private var hideWork: DispatchWorkItem?

    init(makeContent: @escaping (_ onFrameChange: @escaping (Toast.ID, CGRect?) -> Void) -> Content) {
        self.makeContent = makeContent
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installIfNeeded()
    }

    func update(isShowing: Bool, makeContent: @escaping (_ onFrameChange: @escaping (Toast.ID, CGRect?) -> Void) -> Content) {
        self.makeContent = makeContent
        installIfNeeded()
        host?.rootView = content()
        guard let toastWindow else { return }
        hideWork?.cancel()
        if isShowing {
            toastWindow.isHidden = false
        } else {
            // Kept up until the slide-out animation finishes.
            let work = DispatchWorkItem { [weak toastWindow] in
                toastWindow?.isHidden = true
                toastWindow?.toastFrames = [:]
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    func tearDown() {
        hideWork?.cancel()
        toastWindow?.isHidden = true
        toastWindow = nil
        host = nil
    }

    private func content() -> Content {
        makeContent { [weak self] id, frame in self?.toastWindow?.toastFrames[id] = frame }
    }

    private func installIfNeeded() {
        guard toastWindow == nil, let scene = window?.windowScene else { return }
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        let toastWindow = ToastWindow(windowScene: scene)
        // Above sheets and alerts, below the lock screen at `.alert + 1`.
        toastWindow.windowLevel = .alert
        toastWindow.backgroundColor = .clear
        toastWindow.rootViewController = host
        toastWindow.isHidden = true
        self.host = host
        self.toastWindow = toastWindow
    }
}

/// Takes touches only on the toast itself; everything else reaches the app below.
/// Never key, so typing stays in the app's text fields.
final class ToastWindow: UIWindow {
    var toastFrames: [Toast.ID: CGRect] = [:]

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard toastFrames.values.contains(where: { $0.insetBy(dx: 0, dy: -8).contains(point) }) else { return nil }
        return super.hitTest(point, with: event)
    }

    override var canBecomeKey: Bool { false }
}
