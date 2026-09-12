import SwiftUI

struct PendingExpenseActions: View {
    let creatorName: String
    let onAccept: () -> Void
    let onAcceptWithTrust: () -> Void
    let onReject: () -> Void
    let onProposeEdit: () -> Void

    private let actionVerticalPadding: CGFloat = 4

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAccept) {
                acceptLabel
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, actionVerticalPadding)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.small)

            Menu {
                Button("Accept & always trust \(creatorName)", systemImage: "hand.thumbsup", action: onAcceptWithTrust)
                Button("Suggest changes", systemImage: "square.and.pencil", action: onProposeEdit)
                Divider()
                Button(role: .destructive, action: onReject) {
                    DestructiveMenuLabel(title: "Decline", systemImage: "xmark")
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
}
