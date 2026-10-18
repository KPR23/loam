import SwiftUI

/// Pro: add your own categories, remove built-in ones from the picker, and rename,
/// recolor or re-icon the built-in ones.
struct CategorySettingsView: View {
    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    private var store: CustomCategoryStore { .shared }
    @State private var pendingDeletion: CustomCategory?
    @State private var error: String?

    private var visibleBuiltIns: [ExpenseCategory] {
        ExpenseCategory.allCases.filter { !store.hidden.contains($0) }
    }

    private var hiddenBuiltIns: [ExpenseCategory] {
        ExpenseCategory.allCases.filter { store.hidden.contains($0) }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    CategoryOrderView()
                } label: {
                    Label("Reorder", systemImage: "arrow.up.arrow.down")
                }
            } footer: {
                Text("The order you pick categories in, on every screen.")
            }

            Section {
                ForEach(store.categories) { category in
                    NavigationLink {
                        CustomCategoryEditorView(category: category)
                    } label: {
                        CategoryRow(name: category.name, symbol: category.symbol, color: category.color)
                    }
                    .swipeActions(edge: .trailing) {
                        // Avoid `role: .destructive` — it removes the row before the confirmation.
                        Button("Delete", systemImage: "trash") { pendingDeletion = category }
                            .tint(.red)
                    }
                }
                if store.categories.count < CustomCategoryStore.maxCount {
                    NavigationLink {
                        CustomCategoryEditorView(category: nil)
                    } label: {
                        Label("Add category", systemImage: "plus")
                    }
                }
            } header: {
                Text("Your categories")
            } footer: {
                Text("Friends see your categories on expenses you share with them.")
            }

            Section {
                ForEach(visibleBuiltIns) { category in
                    NavigationLink {
                        CategoryEditorView(category: category)
                    } label: {
                        CategoryRow(
                            name: category.displayName,
                            symbol: category.systemImage,
                            color: category.color,
                            detail: CategoryCustomizer.shared.savedStyle(for: category) != nil ? "Customized" : nil
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        if category != .other {
                            Button("Remove", systemImage: "minus.circle") { setHidden(category, true) }
                                .tint(.red)
                        }
                    }
                }
            } header: {
                Text("Built-in")
            } footer: {
                Text("Swipe to remove a category from the list you pick from. Expenses already in it keep it. Names, icons and colors you change here show up on this device.")
            }

            if !hiddenBuiltIns.isEmpty {
                Section("Removed") {
                    ForEach(hiddenBuiltIns) { category in
                        HStack {
                            CategoryRow(name: category.displayName, symbol: category.systemImage, color: category.color)
                            Button("Restore") { setHidden(category, false) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete \u{201C}\(pendingDeletion?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { category in
            Button("Delete category", role: .destructive) {
                Task {
                    do {
                        try await store.delete(category)
                        ToastCenter.shared.showSuccess("Category deleted")
                        // Loaded expenses still hold the deleted category; reload them under Other.
                        await expenseStore.refresh(userId: authSession.userId)
                    } catch { self.error = UserFacingError.message(for: error) }
                }
            }
        } message: { _ in
            Text("Its expenses move to Other, for you and for friends you shared them with.")
        }
        .errorToast($error)
    }

    private func setHidden(_ category: ExpenseCategory, _ isHidden: Bool) {
        Task {
            do { try await store.setHidden(category, isHidden) } catch { self.error = UserFacingError.message(for: error) }
        }
    }
}

/// Drag categories into the order the picker lists them.
private struct CategoryOrderView: View {
    @State private var options = CustomCategoryStore.shared.pickerOptions(isPro: true)
    @State private var error: String?

    var body: some View {
        List {
            ForEach(options) { option in
                CategoryRow(name: option.displayName, symbol: option.systemImage, color: option.color)
            }
            .onMove { source, destination in
                options.move(fromOffsets: source, toOffset: destination)
                LoamFeedback.selection()
                let moved = options
                Task {
                    do { try await CustomCategoryStore.shared.setOrder(moved) } catch { self.error = UserFacingError.message(for: error) }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Reorder")
        .navigationBarTitleDisplayMode(.inline)
        .errorToast($error)
    }
}

private struct CategoryRow: View {
    let name: String
    let symbol: String
    let color: Color
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text(name)
                .foregroundStyle(HomeTheme.text)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Creates or edits one of the member's own categories.
private struct CustomCategoryEditorView: View {
    let category: CustomCategory?

    @EnvironmentObject private var authSession: AuthSession
    @EnvironmentObject private var expenseStore: ExpenseStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var colorHex: String
    @State private var isSaving = false
    @State private var error: String?

    init(category: CustomCategory?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _symbol = State(initialValue: category?.symbol ?? "star.fill")
        _colorHex = State(initialValue: category?.colorHex ?? CategoryStyleOptions.colors[0].hex)
    }

    private var trimmedName: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CategoryCustomizer.maxNameLength))
    }

    var body: some View {
        Form {
            Section {
                CategoryPreview(name: trimmedName.isEmpty ? "New category" : trimmedName, symbol: symbol, color: Color(hex: colorHex) ?? .gray)
            }
            Section("Name") {
                TextField("Pets, Gym, Kids…", text: $name)
                    .textInputAutocapitalization(.words)
                    .onChange(of: name) { _, newValue in
                        if newValue.count > CategoryCustomizer.maxNameLength {
                            name = String(newValue.prefix(CategoryCustomizer.maxNameLength))
                        }
                    }
            }
            CategoryColorSection(colorHex: $colorHex, defaultColor: nil)
            CategoryIconSection(symbol: $symbol, options: CategoryStyleOptions.symbols, color: Color(hex: colorHex) ?? .gray)
        }
        .navigationTitle(category == nil ? "New category" : "Edit category")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    SavingActionLabel(title: "Save", isSaving: isSaving)
                }
                .fontWeight(.semibold)
                .disabled(trimmedName.isEmpty || isSaving)
            }
        }
        .errorToast($error)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let saved = CustomCategory(
            id: category?.id ?? UUID(),
            ownerId: category?.ownerId ?? UUID(),
            name: trimmedName,
            symbol: symbol,
            colorHex: colorHex
        )
        do {
            try await CustomCategoryStore.shared.save(saved)
            // Loaded expenses hold a copy of the category; reload them to show the new name, icon and color.
            if category != nil { await expenseStore.refresh(userId: authSession.userId) }
            ToastCenter.shared.showSuccess(category == nil ? "Category added" : "Category saved")
            LoamFeedback.success()
            dismiss()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
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
                CategoryPreview(name: trimmedName.isEmpty ? category.defaultDisplayName : trimmedName, symbol: symbol, color: previewColor)
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

            CategoryColorSection(colorHex: $colorHex, defaultColor: category.defaultColor)
            CategoryIconSection(symbol: $symbol, options: iconOptions, color: previewColor)

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
}

private struct CategoryPreview: View {
    let name: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(name)
                .font(.system(.title3, design: .rounded).weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// With a `defaultColor`, an empty hex means the built-in color.
private struct CategoryColorSection: View {
    @Binding var colorHex: String
    let defaultColor: Color?

    var body: some View {
        Section("Color") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                if let defaultColor {
                    swatch(hex: "", color: defaultColor, label: "Default")
                }
                ForEach(CategoryStyleOptions.colors, id: \.hex) { option in
                    swatch(hex: option.hex, color: Color(hex: option.hex) ?? .gray, label: option.name)
                }
            }
            .padding(.vertical, 4)
        }
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

private struct CategoryIconSection: View {
    @Binding var symbol: String
    let options: [String]
    let color: Color

    var body: some View {
        Section("Icon") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                ForEach(options, id: \.self) { option in
                    Button {
                        LoamFeedback.selection()
                        symbol = option
                    } label: {
                        Image(systemName: option)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(symbol == option ? color : Color.secondary)
                            .frame(width: 40, height: 40)
                            .background(
                                symbol == option ? color.opacity(0.16) : Color.clear,
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
    }
}
