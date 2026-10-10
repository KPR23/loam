import Observation
import SwiftUI

/// A Pro member's own name, icon and color for one built-in category. Any field left
/// empty keeps the built-in value.
struct CategoryStyleOverride: Codable, Equatable, Sendable {
    var name: String?
    var symbol: String?
    var colorHex: String?

    var isEmpty: Bool { name == nil && symbol == nil && colorHex == nil }
}

/// Holds category customizations, which are stored on this device and only applied while the
/// account has Loam Pro. `ExpenseCategory` reads from here, and `revision` is observed so
/// every view showing a category redraws after a change.
@Observable
final class CategoryCustomizer: @unchecked Sendable {
    static let shared = CategoryCustomizer()
    static let defaultsKey = "loam.categoryOverrides"
    static let maxNameLength = 24

    private(set) var revision = 0
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var overrides: [String: CategoryStyleOverride]
    @ObservationIgnored private var active = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: CategoryStyleOverride].self, from: data) {
            overrides = saved
        } else {
            overrides = [:]
        }
    }

    /// Follows the account's Pro status; customizations are kept but ignored without it.
    var isActive: Bool {
        get {
            _ = revision
            lock.lock(); defer { lock.unlock() }
            return active
        }
        set {
            lock.lock()
            let changed = active != newValue
            active = newValue
            lock.unlock()
            if changed { revision += 1 }
        }
    }

    /// The style to show, or nil for the built-in one.
    func appliedStyle(for category: ExpenseCategory) -> CategoryStyleOverride? {
        _ = revision
        lock.lock(); defer { lock.unlock() }
        return active ? overrides[category.rawValue] : nil
    }

    /// The saved style whether or not Pro is active, for the editor.
    func savedStyle(for category: ExpenseCategory) -> CategoryStyleOverride? {
        _ = revision
        lock.lock(); defer { lock.unlock() }
        return overrides[category.rawValue]
    }

    func save(_ style: CategoryStyleOverride, for category: ExpenseCategory) {
        lock.lock()
        if style.isEmpty {
            overrides.removeValue(forKey: category.rawValue)
        } else {
            overrides[category.rawValue] = style
        }
        persistLocked()
        lock.unlock()
        revision += 1
    }

    func reset(_ category: ExpenseCategory) {
        save(CategoryStyleOverride(), for: category)
    }

    private func persistLocked() {
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// The choices the category editor offers.
enum CategoryStyleOptions {
    static let colors: [(name: String, hex: String)] = [
        ("Green", "66C240"), ("Red", "F56652"), ("Blue", "2680FA"), ("Orange", "E07330"),
        ("Yellow", "F5AD2E"), ("Rose", "F5384F"), ("Purple", "AD3DF5"), ("Pink", "FA3D94"),
        ("Teal", "1FC7E0"), ("Indigo", "6B61FA"), ("Brown", "9C7A55"), ("Graphite", "6E7480")
    ]

    static let symbols: [String] = [
        "cart.fill", "fork.knife.circle.fill", "bus.fill", "house.fill", "bolt.fill", "heart.fill",
        "ticket.fill", "bag.fill", "airplane.circle.fill", "ellipsis.circle.fill", "car.fill", "fuelpump.fill",
        "cup.and.saucer.fill", "gift.fill", "graduationcap.fill", "pawprint.fill", "gamecontroller.fill", "book.fill",
        "tshirt.fill", "wrench.and.screwdriver.fill", "figure.run", "music.note", "film.fill", "stethoscope",
        "leaf.fill", "star.fill", "tram.fill", "bed.double.fill", "wifi", "creditcard.fill"
    ]
}

extension Color {
    /// Six hex digits, e.g. "66C240".
    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
