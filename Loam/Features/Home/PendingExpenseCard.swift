import SwiftUI

struct PendingExpenseRow: View {
    let expense: ExpenseRecord
    let myUserId: UUID
    let creatorName: String
    let onAccept: () -> Void
    let onAcceptWithTrust: () -> Void
    let onReject: () -> Void
    let onProposeEdit: () -> Void

    @State private var isProcessing = false

    private var myShare: Money {
        expense.share(for: myUserId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(MoneyFormatter.string(from: myShare))
                        .monospacedDigit()
                    Text("of \(MoneyFormatter.string(from: expense.money))")
                        .font(.caption2)
                        .foregroundStyle(HomeTheme.secondary)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    categoryLabel
                    if let note = expense.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(HomeTheme.secondary)
                    }
                    Text("Added by \(creatorName)")
                        .font(.caption2)
                        .foregroundStyle(HomeTheme.tertiary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    guard !isProcessing else { return }
                    isProcessing = true
                    onAccept()
                } label: {
                    actionButtonLabel(title: "Accept", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(isProcessing)

                Button {
                    guard !isProcessing else { return }
                    isProcessing = true
                    onReject()
                } label: {
                    actionButtonLabel(title: "Decline", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isProcessing)

                Menu {
                    Button {
                        guard !isProcessing else { return }
                        isProcessing = true
                        onAcceptWithTrust()
                    } label: {
                        Label("Accept & always trust \(creatorName)", systemImage: "hand.thumbsup")
                    }

                    Button {
                        onProposeEdit()
                    } label: {
                        Label("Suggest changes", systemImage: "square.and.pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(HomeTheme.secondary)
                .disabled(isProcessing)
                .accessibilityLabel("More options")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var categoryLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: expense.category.systemImage)
                .font(.callout)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(expense.category.color)
                .frame(width: 22, alignment: .center)
            Text(expense.category.displayName)
        }
    }

    private func actionButtonLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.monochrome)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 6)
    }
}
