import Foundation
import Observation
import Supabase
import SwiftUI

/// A category a Pro member made. Expenses in it are filed under `.other`, so
/// anything that only knows built-in categories still works; everyone on the
/// expense sees the custom name, icon and color.
struct CustomCategory: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var ownerId: UUID
    var name: String
    var symbol: String
    var colorHex: String

    var color: Color { Color(hex: colorHex) ?? ExpenseCategory.other.defaultColor }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case name
        case symbol
        case colorHex = "color_hex"
    }
}

/// What an expense is filed under: a built-in category or a custom one.
enum SpendCategory: Hashable, Identifiable, Sendable {
    case builtIn(ExpenseCategory)
    case custom(CustomCategory)

    var id: String {
        switch self {
        case let .builtIn(category): category.rawValue
        case let .custom(category): category.id.uuidString
        }
    }

    /// The category stored in the expense's `category` column.
    var builtInCategory: ExpenseCategory {
        switch self {
        case let .builtIn(category): category
        case .custom: .other
        }
    }

    var customCategory: CustomCategory? {
        if case let .custom(category) = self { return category }
        return nil
    }

    var displayName: String {
        switch self {
        case let .builtIn(category): category.displayName
        case let .custom(category): category.name
        }
    }

    var systemImage: String {
        switch self {
        case let .builtIn(category): category.systemImage
        case let .custom(category): category.symbol
        }
    }

    var color: Color {
        switch self {
        case let .builtIn(category): category.color
        case let .custom(category): category.color
        }
    }
}

/// The signed-in member's own categories and the built-in ones they removed.
/// Only applied while the account has Loam Pro: without it, the picker shows
/// every built-in category and no custom ones, though existing expenses keep theirs.
@MainActor
@Observable
final class CustomCategoryStore {
    static let shared = CustomCategoryStore()
    static let maxCount = 50

    private(set) var categories: [CustomCategory] = []
    private(set) var hidden: Set<ExpenseCategory> = []
    /// Keys of the member's chosen order (`SpendCategory.id`); categories not listed follow the listed ones.
    private(set) var order: [String] = []
    private var userId: UUID?
    @ObservationIgnored private var hiddenWrite: Task<Void, Error>?
    @ObservationIgnored private var orderWrite: Task<Void, Error>?

    private init() {}

    /// The picker's choices: built-in categories that aren't hidden, then custom ones, in the member's order.
    func pickerOptions(isPro: Bool) -> [SpendCategory] {
        let builtIns = ExpenseCategory.allCases.filter { !isPro || $0 == .other || !hidden.contains($0) }
        let options = builtIns.map(SpendCategory.builtIn) + (isPro ? categories.map(SpendCategory.custom) : [])
        return isPro ? Self.sorted(options, by: order) : options
    }

    /// Listed categories first, in list order; the rest keep their relative order after them.
    nonisolated static func sorted(_ options: [SpendCategory], by order: [String]) -> [SpendCategory] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return options.enumerated()
            .sorted { lhs, rhs in
                let l = position[lhs.element.id] ?? Int.max, r = position[rhs.element.id] ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func load(userId: UUID?) async {
        if userId != self.userId { categories = []; hidden = []; order = [] }
        self.userId = userId
        guard let userId else { return }
        let keepsCopy = !ExpenseRepositoryFactory.usesLocalStorage
        let loaded: CustomCategoryData
        if let fetched = try? await repository.load(userId: userId) {
            loaded = fetched
            if keepsCopy { OfflineCache.save(SavedCategories(categories: fetched.categories, hidden: fetched.hidden, order: fetched.order), key: "categories", userId: userId) }
        } else if keepsCopy, let saved = OfflineCache.load(SavedCategories.self, key: "categories", userId: userId) {
            // Offline, the categories as last loaded, so new expenses can still use them.
            loaded = CustomCategoryData(categories: saved.categories, hidden: saved.hidden, order: saved.order ?? [])
        } else {
            return
        }
        guard self.userId == userId else { return }
        categories = loaded.categories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        hidden = loaded.hidden
        order = loaded.order
    }

    private struct SavedCategories: Codable {
        var categories: [CustomCategory]
        var hidden: Set<ExpenseCategory>
        var order: [String]?
    }

    /// Creates or updates one of the member's categories; the owner is always the signed-in member.
    func save(_ category: CustomCategory) async throws {
        guard let userId else { return }
        var category = category
        category.ownerId = userId
        try await repository.save(category, userId: userId)
        await load(userId: userId)
    }

    func delete(_ category: CustomCategory) async throws {
        guard let userId else { return }
        try await repository.delete(category, userId: userId)
        await load(userId: userId)
    }

    /// Each call replaces the whole list on the server, so calls run one at a time and each
    /// starts from the list the previous one saved; otherwise two quick removals would undo one another.
    func setHidden(_ category: ExpenseCategory, _ isHidden: Bool) async throws {
        guard let userId, category != .other else { return }
        while let running = hiddenWrite { _ = await running.result }
        guard self.userId == userId else { return }
        let write = Task { [self] in
            var updated = hidden
            if isHidden { updated.insert(category) } else { updated.remove(category) }
            try await repository.setHidden(updated, userId: userId)
            guard self.userId == userId else { return }
            hidden = updated
        }
        hiddenWrite = write
        defer { if hiddenWrite == write { hiddenWrite = nil } }
        try await write.value
    }

    /// Saves the picker order; `options` is the whole visible list in its new order.
    func setOrder(_ options: [SpendCategory]) async throws {
        guard let userId else { return }
        while let running = orderWrite { _ = await running.result }
        guard self.userId == userId else { return }
        let keys = options.map(\.id)
        let write = Task { [self] in
            try await repository.setOrder(keys, userId: userId)
            guard self.userId == userId else { return }
            order = keys
        }
        orderWrite = write
        defer { if orderWrite == write { orderWrite = nil } }
        try await write.value
    }

    private var repository: any CustomCategoryRepository {
        ExpenseRepositoryFactory.usesLocalStorage
            ? LocalCustomCategoryRepository()
            : SupabaseCustomCategoryRepository(client: SupabaseClientProvider.shared!)
    }
}

struct CustomCategoryData: Sendable {
    var categories: [CustomCategory]
    var hidden: Set<ExpenseCategory>
    var order: [String] = []
}

protocol CustomCategoryRepository: Sendable {
    func load(userId: UUID) async throws -> CustomCategoryData
    func save(_ category: CustomCategory, userId: UUID) async throws
    func delete(_ category: CustomCategory, userId: UUID) async throws
    func setHidden(_ hidden: Set<ExpenseCategory>, userId: UUID) async throws
    func setOrder(_ keys: [String], userId: UUID) async throws
}

actor SupabaseCustomCategoryRepository: CustomCategoryRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient) { self.client = client }

    func load(userId: UUID) async throws -> CustomCategoryData {
        struct HiddenRow: Decodable { let category: String }
        struct OrderRow: Decodable { let keys: [String] }
        async let categories: [CustomCategory] = client.from("custom_category")
            .select("id, owner_id, name, symbol, color_hex")
            .eq("owner_id", value: userId)
            .execute().value
        async let hiddenRows: [HiddenRow] = client.from("hidden_category")
            .select("category")
            .execute().value
        async let orderRows: [OrderRow] = client.from("category_order")
            .select("keys")
            .execute().value
        return try await CustomCategoryData(
            categories: categories,
            hidden: Set(hiddenRows.compactMap { ExpenseCategory(rawValue: $0.category) }),
            order: orderRows.first?.keys ?? []
        )
    }

    func save(_ category: CustomCategory, userId: UUID) async throws {
        _ = userId
        struct Params: Encodable {
            let pId: UUID; let pName: String; let pSymbol: String; let pColorHex: String
            enum CodingKeys: String, CodingKey { case pId = "p_id", pName = "p_name", pSymbol = "p_symbol", pColorHex = "p_color_hex" }
        }
        let _: UUID = try await client.rpc("save_custom_category", params: Params(
            pId: category.id, pName: category.name, pSymbol: category.symbol, pColorHex: category.colorHex
        )).execute().value
    }

    func delete(_ category: CustomCategory, userId: UUID) async throws {
        _ = userId
        struct Params: Encodable { let pId: UUID; enum CodingKeys: String, CodingKey { case pId = "p_id" } }
        try await client.rpc("delete_custom_category", params: Params(pId: category.id)).execute()
    }

    func setHidden(_ hidden: Set<ExpenseCategory>, userId: UUID) async throws {
        _ = userId
        struct Params: Encodable { let pCategories: [String]; enum CodingKeys: String, CodingKey { case pCategories = "p_categories" } }
        try await client.rpc("set_hidden_categories", params: Params(pCategories: hidden.map(\.rawValue).sorted())).execute()
    }

    func setOrder(_ keys: [String], userId: UUID) async throws {
        _ = userId
        struct Params: Encodable { let pKeys: [String]; enum CodingKeys: String, CodingKey { case pKeys = "p_keys" } }
        try await client.rpc("set_category_order", params: Params(pKeys: keys)).execute()
    }
}

/// Demo accounts keep their categories on the device. Deleting one files its
/// expenses under Other, like the server does.
struct LocalCustomCategoryRepository: CustomCategoryRepository {
    private static let categoriesKey = "loam.local.customCategories"
    private static let hiddenKey = "loam.local.hiddenCategories"
    private static let orderKey = "loam.local.categoryOrder"

    func load(userId: UUID) async throws -> CustomCategoryData {
        let hidden = (UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(ExpenseCategory.init(rawValue:))
        return CustomCategoryData(
            categories: Self.stored().filter { $0.ownerId == userId },
            hidden: Set(hidden),
            order: UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        )
    }

    func save(_ category: CustomCategory, userId: UUID) async throws {
        var all = Self.stored()
        if let index = all.firstIndex(where: { $0.id == category.id }) {
            all[index] = category
        } else {
            all.append(category)
        }
        Self.store(all)
        try await LocalExpenseRepository().replaceCustomCategory(id: category.id, with: category)
    }

    func delete(_ category: CustomCategory, userId: UUID) async throws {
        Self.store(Self.stored().filter { $0.id != category.id })
        try await LocalExpenseRepository().replaceCustomCategory(id: category.id, with: nil)
    }

    func setHidden(_ hidden: Set<ExpenseCategory>, userId: UUID) async throws {
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }

    func setOrder(_ keys: [String], userId: UUID) async throws {
        UserDefaults.standard.set(keys, forKey: Self.orderKey)
    }

    private static func stored() -> [CustomCategory] {
        guard let data = UserDefaults.standard.data(forKey: categoriesKey) else { return [] }
        return (try? JSONDecoder().decode([CustomCategory].self, from: data)) ?? []
    }

    private static func store(_ categories: [CustomCategory]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(categories), forKey: categoriesKey)
    }
}
