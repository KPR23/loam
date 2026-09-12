import SwiftUI

struct PendingExpenseActions: View {
    let creatorName: String
    let onAccept: () -> Void
    let onAcceptWithTrust: () -> Void
    let onReject: () -> Void
    let onProposeEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            acceptButton

            Menu {
                Button("Accept & always trust \(creatorName)", systemImage: "hand.thumbsup", action: onAcceptWithTrust)
                Button("Suggest changes", systemImage: "square.and.pencil", action: onProposeEdit)
                Divider()
                Button("Decline", systemImage: "xmark", role: .destructive, action: onReject)
            } label: {
                ZStack {
                    // Match Accept height without stretching the ellipsis icon row.
                    acceptLabel
                        .padding(.vertical, 2)
                        .hidden()
                        .accessibilityHidden(true)
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.medium))
                        .symbolRenderingMode(.monochrome)
                }
            }
            .modifier(PendingActionsChrome(tint: HomeTheme.secondary, prominent: false))
            .accessibilityLabel("More options")
        }
        // List swallows taps on nested bordered buttons unless the row opts out.
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var acceptButton: some View {
        Button(action: onAccept) {
            acceptLabel
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
        .modifier(PendingActionsChrome(tint: .green, prominent: true))
    }

    /// Title on the filled/glass-prominent Accept control.
    private var acceptLabel: some View {
        Text("Accept")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
    }
}

/// Liquid Glass on iOS 26+; tint is the colored fill (don't use `.background` — it blocks glass).
private struct PendingActionsChrome: ViewModifier {
    let tint: Color
    var prominent: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            Group {
                if prominent {
                    content.buttonStyle(.glassProminent)
                } else {
                    content.buttonStyle(.glass)
                }
            }
            .tint(tint)
            .controlSize(.small)
        } else {
            Group {
                if prominent {
                    content.buttonStyle(.borderedProminent)
                } else {
                    content.buttonStyle(.bordered)
                }
            }
            .tint(tint)
            .controlSize(.small)
        }
    }
}
