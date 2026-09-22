import SwiftUI
import UIKit

/// Category control that keeps per-category colors (native Menu alone would tint with the app accent).
struct ExpenseCategoryPicker: View {
    enum Style {
        /// Form row with “Category” label — used on details / edit sheets.
        case formRow
        /// Compact chip for the amount step bottom bar.
        case chip
    }

    @Binding var category: ExpenseCategory
    var style: Style = .formRow

    var body: some View {
        switch style {
        case .formRow:
            formRow
        case .chip:
            chip
        }
    }

    private var formRow: some View {
        LabeledContent("Category") {
            menuLabel {
                HStack(spacing: 10) {
                    categoryIcon
                        .frame(width: 22, alignment: .center)

                    Text(category.displayName)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.primary)

                    chevron
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityLabel("Category")
        .accessibilityValue(category.displayName)
    }

    private var chip: some View {
        menuLabel {
            HStack(spacing: 8) {
                categoryIcon

                Text(category.displayName)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                chevron
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("Category")
        .accessibilityValue(category.displayName)
    }

    private var categoryIcon: some View {
        Image(systemName: category.systemImage)
            .font(.body)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(category.color)
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func menuLabel<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach(ExpenseCategory.allCases) { item in
                Button {
                    category = item
                } label: {
                    // UIMenu only keeps color when the image is `.alwaysOriginal`.
                    SwiftUI.Label {
                        Text(item.displayName)
                    } icon: {
                        Image(uiImage: item.menuIcon)
                    }
                }
            }
        } label: {
            label()
        }
        // Keep closed-state icon colors; Menu would otherwise recolor via accent/tint.
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: category)
    }
}

private extension ExpenseCategory {
    var menuIcon: UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let base = UIImage(systemName: systemImage, withConfiguration: config)
            ?? UIImage(systemName: "circle.fill", withConfiguration: config)
            ?? UIImage()
        return base
            .withTintColor(UIColor(color), renderingMode: .alwaysOriginal)
    }
}
