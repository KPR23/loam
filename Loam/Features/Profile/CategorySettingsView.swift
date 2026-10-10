import SwiftUI

/// Pro: rename the built-in categories and change their icon and color.
struct CategorySettingsView: View {
    var body: some View {
        List {
            Section {
                ForEach(ExpenseCategory.allCases) { category in
                    NavigationLink {
                        CategoryEditorView(category: category)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.systemImage)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(category.color)
                                .frame(width: 26, height: 26)
                                .accessibilityHidden(true)
                            Text(category.displayName)
                                .foregroundStyle(HomeTheme.text)
                            Spacer(minLength: 0)
                            if CategoryCustomizer.shared.savedStyle(for: category) != nil {
                                Text("Customized")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Your names, icons and colors show up on this device wherever a category appears.")
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CategoryEditorView: View {
    let category: ExpenseCategory

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var colorHex: String

    init(category: ExpenseCategory) {
        self.category = category
        let saved = CategoryCustomizer.shared.savedStyle(for: category)
        _name = State(initialValue: saved?.name ?? "")
        _symbol = State(initialValue: saved?.symbol ?? category.defaultSystemImage)
        _colorHex = State(initialValue: saved?.colorHex ?? "")
    }

    private var previewColor: Color {
        Color(hex: colorHex) ?? category.defaultColor
    }

    private var trimmedName: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CategoryCustomizer.maxNameLength))
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(previewColor)
                        .frame(width: 44, height: 44)
                        .background(previewColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    Text(trimmedName.isEmpty ? category.defaultDisplayName : trimmedName)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Name") {
                TextField(category.defaultDisplayName, text: $name)
                    .textInputAutocapitalization(.words)
                    .onChange(of: name) { _, newValue in
                        if newValue.count > CategoryCustomizer.maxNameLength {
                            name = String(newValue.prefix(CategoryCustomizer.maxNameLength))
                        }
                    }
            }

            Section("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                    swatch(hex: "", color: category.defaultColor, label: "Default")
                    ForEach(CategoryStyleOptions.colors, id: \.hex) { option in
                        swatch(hex: option.hex, color: Color(hex: option.hex) ?? .gray, label: option.name)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                    ForEach(iconOptions, id: \.self) { option in
                        Button {
                            LoamFeedback.selection()
                            symbol = option
                        } label: {
                            Image(systemName: option)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(symbol == option ? previewColor : Color.secondary)
                                .frame(width: 40, height: 40)
                                .background(
                                    symbol == option ? previewColor.opacity(0.16) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option)
                        .accessibilityAddTraits(symbol == option ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }

            if CategoryCustomizer.shared.savedStyle(for: category) != nil {
                Section {
                    Button("Reset to default", role: .destructive) {
                        CategoryCustomizer.shared.reset(category)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(category.defaultDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    CategoryCustomizer.shared.save(style, for: category)
                    LoamFeedback.success()
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }

    /// The built-in icon stays an option even though it isn't in the shared list.
    private var iconOptions: [String] {
        let options = CategoryStyleOptions.symbols
        return options.contains(category.defaultSystemImage) ? options : [category.defaultSystemImage] + options
    }

    /// Only what differs from the built-in category is saved.
    private var style: CategoryStyleOverride {
        CategoryStyleOverride(
            name: trimmedName.isEmpty || trimmedName == category.defaultDisplayName ? nil : trimmedName,
            symbol: symbol == category.defaultSystemImage ? nil : symbol,
            colorHex: Color(hex: colorHex) == nil ? nil : colorHex
        )
    }

    private func swatch(hex: String, color: Color, label: String) -> some View {
        Button {
            LoamFeedback.selection()
            colorHex = hex
        } label: {
            Circle()
                .fill(color)
                .frame(width: 32, height: 32)
                .overlay {
                    if colorHex == hex {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
    }
}
