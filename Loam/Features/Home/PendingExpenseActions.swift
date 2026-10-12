import SwiftUI

struct PendingExpenseActions: View {
    let creatorName: String
    /// When true, menu content is declared in reverse so the visual top-to-bottom
    /// order matches downward menus (iOS flips upward menus relative to the anchor).
    var menuOpensUpward: Bool = false
    let onAccept: () -> Void
    let onAcceptWithTrust: () -> Void
    let onReject: () -> Void
    let onProposeEdit: () -> Void

    private let actionVerticalPadding: CGFloat = 4

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { LoamFeedback.tap(); onAccept() }) {
                acceptLabel
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, actionVerticalPadding)
            }
            .buttonStyle(.borderedProminent)
            .tint(HomeTheme.accentFill)
            .controlSize(.small)

            Menu {
                if menuOpensUpward {
                    declineButton
                    Divider()
                    proposeEditButton
                    acceptWithTrustButton
                } else {
                    acceptWithTrustButton
                    proposeEditButton
                    Divider()
                    declineButton
                }
            } label: {
                ZStack {
                    // Match Accept height without stretching the ellipsis icon.
                    acceptLabel
                        .padding(.vertical, actionVerticalPadding)
                        .hidden()
                        .accessibilityHidden(true)
                    Image(systemName: "ellipsis")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .symbolRenderingMode(.monochrome)
                }
                .padding(.horizontal, 10)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("More options")
        }
        // List swallows taps on nested bordered buttons unless the row opts out.
        .buttonStyle(.borderless)
    }

    private var acceptLabel: some View {
        Text("Accept")
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
    }

    private var acceptWithTrustButton: some View {
        Button("Accept & always trust \(creatorName)", systemImage: "hand.thumbsup", action: { LoamFeedback.tap(); onAcceptWithTrust() })
    }

    private var proposeEditButton: some View {
        Button("Suggest changes", systemImage: "square.and.pencil", action: { LoamFeedback.tap(); onProposeEdit() })
    }

    private var declineButton: some View {
        Button(role: .destructive, action: { LoamFeedback.tap(); onReject() }) {
            DestructiveMenuLabel(title: "Decline", systemImage: "xmark")
        }
    }
}
