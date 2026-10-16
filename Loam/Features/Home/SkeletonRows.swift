import SwiftUI

/// Placeholder rows for a list's first load, shaped like the rows they stand in for so the
/// content lands without the layout jumping.
struct SkeletonRows: View {
    enum Leading {
        /// A category glyph, as on expense and history rows.
        case icon
        /// A person's avatar of the given diameter.
        case avatar(CGFloat)
    }

    var count = 5
    var leading: Leading = .icon
    /// Whether rows carry a trailing amount.
    var showsAmount = true

    /// Varied so the placeholder reads as text rather than a grid of identical bars.
    private static let titleWidths: [CGFloat] = [132, 96, 160, 112, 144, 104]
    private static let captionWidths: [CGFloat] = [72, 104, 60, 88, 76, 96]

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            row(index)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
                .accessibilityHidden(index > 0)
        }
    }

    private func row(_ index: Int) -> some View {
        HStack(spacing: 12) {
            switch leading {
            case .icon:
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .frame(width: 26, height: 26)
            case .avatar(let size):
                Circle()
                    .frame(width: size, height: size)
            }

            VStack(alignment: .leading, spacing: 7) {
                bar(width: Self.titleWidths[index % Self.titleWidths.count], height: 13)
                bar(width: Self.captionWidths[index % Self.captionWidths.count], height: 9)
            }

            Spacer(minLength: 8)

            if showsAmount {
                bar(width: 58, height: 13)
            }
        }
        .foregroundStyle(HomeTheme.tileEmpty)
        .padding(.vertical, 4)
        .skeletonPulse()
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .frame(width: width, height: height)
    }
}

private struct SkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.phaseAnimator([1, 0.45]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        }
    }
}

private extension View {
    func skeletonPulse() -> some View {
        modifier(SkeletonPulse())
    }
}

#Preview {
    List {
        Section { SkeletonRows() }
        Section { SkeletonRows(count: 3, leading: .avatar(40)) }
    }
}
