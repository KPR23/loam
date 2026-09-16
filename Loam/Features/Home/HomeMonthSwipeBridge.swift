import SwiftUI
import UIKit

/// Installs a horizontal pan on the Home `List`'s scroll view so month changes work again,
/// while yielding to UIKit row `swipeActions` pans (Delete / Split).
struct HomeMonthSwipeBridge: UIViewRepresentable {
    var threshold: CGFloat = 80
    var onSwipeToNext: () -> Void
    var onSwipeToPrevious: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(threshold: threshold, onSwipeToNext: onSwipeToNext, onSwipeToPrevious: onSwipeToPrevious)
    }

    func makeUIView(context: Context) -> UIView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onAttached = { [weak coordinator = context.coordinator] in
            coordinator?.attachIfNeeded()
        }
        context.coordinator.anchorView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.threshold = threshold
        context.coordinator.onSwipeToNext = onSwipeToNext
        context.coordinator.onSwipeToPrevious = onSwipeToPrevious
        context.coordinator.attachIfNeeded()
    }

    private final class AttachmentView: UIView {
        var onAttached: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAttached?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onAttached?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var threshold: CGFloat
        var onSwipeToNext: () -> Void
        var onSwipeToPrevious: () -> Void
        weak var anchorView: UIView?
        private weak var hostScrollView: UIScrollView?
        private var panRecognizer: UIPanGestureRecognizer?

        init(threshold: CGFloat, onSwipeToNext: @escaping () -> Void, onSwipeToPrevious: @escaping () -> Void) {
            self.threshold = threshold
            self.onSwipeToNext = onSwipeToNext
            self.onSwipeToPrevious = onSwipeToPrevious
        }

        func attachIfNeeded() {
            DispatchQueue.main.async { [weak self] in
                self?.findAndAttach()
            }
        }

        private func findAndAttach() {
            guard let anchorView else { return }
            if let hostScrollView, panRecognizer != nil, hostScrollView.window != nil {
                return
            }

            guard let scrollView = Self.findHomeListScrollView(from: anchorView) else { return }
            if hostScrollView === scrollView, panRecognizer != nil { return }

            if let panRecognizer, let previous = hostScrollView {
                previous.removeGestureRecognizer(panRecognizer)
            }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            pan.maximumNumberOfTouches = 1
            scrollView.addGestureRecognizer(pan)

            hostScrollView = scrollView
            panRecognizer = pan
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended, let view = pan.view else { return }

            let translation = pan.translation(in: view)
            let horizontal = translation.x
            let vertical = translation.y
            guard abs(horizontal) >= threshold,
                  abs(horizontal) > abs(vertical) * 1.5 else { return }

            // Negative x = finger moved left → next month.
            if horizontal < 0 {
                onSwipeToNext()
            } else {
                onSwipeToPrevious()
            }
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let translation = pan.translation(in: view)
            // Only claim clearly horizontal pans; vertical scroll keeps the List pan.
            return abs(translation.x) > abs(translation.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Row swipeActions win: delay month pan until the system swipe-action gesture fails.
            Self.isSwipeActionGesture(otherGestureRecognizer)
        }

        private static func isSwipeActionGesture(_ gesture: UIGestureRecognizer) -> Bool {
            let name = String(describing: type(of: gesture))
            return name.contains("SwipeAction")
        }

        /// SwiftUI `.background` is often a sibling of the List scroll view, not a descendant.
        private static func findHomeListScrollView(from view: UIView) -> UIScrollView? {
            var current: UIView? = view
            while let node = current {
                if let scrollView = preferredScrollView(in: node) {
                    return scrollView
                }
                if let superview = node.superview {
                    for sibling in superview.subviews {
                        if let scrollView = preferredScrollView(in: sibling) {
                            return scrollView
                        }
                    }
                }
                current = node.superview
            }
            return nil
        }

        private static func preferredScrollView(in root: UIView) -> UIScrollView? {
            if let tableView = root as? UITableView { return tableView }
            if let collectionView = root as? UICollectionView { return collectionView }

            var fallback: UIScrollView?
            var stack = root.subviews
            while let next = stack.popLast() {
                if let tableView = next as? UITableView { return tableView }
                if let collectionView = next as? UICollectionView { return collectionView }
                if fallback == nil, let scrollView = next as? UIScrollView {
                    fallback = scrollView
                }
                stack.append(contentsOf: next.subviews)
            }
            return fallback
        }
    }
}
