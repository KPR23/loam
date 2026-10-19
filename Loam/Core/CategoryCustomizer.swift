import Observation
import SwiftUI

/// A Pro member's own name, icon and color for one built-in category. Any field left
/// empty keeps the built-in value.
struct CategoryStyleOverride: Codable, Equatable, Sendable {
    var name: String?
    var symbol: String?
    var colorHex: String?

    var isEmpty: Bool { name == nil && symbol == nil && colorHex == nil }

    /// Drops a color that matches the category's built-in one, so the category keeps following
    /// its default if that ever changes instead of pinning today's value.
    func normalized(for category: ExpenseCategory) -> CategoryStyleOverride {
        var style = self
        if let hex = style.colorHex, hex.caseInsensitiveCompare(category.defaultColorHex) == .orderedSame {
            style.colorHex = nil
        }
        return style
    }
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
            overrides = Self.normalized(saved)
            if overrides != saved { persistLocked() }
        } else {
            overrides = [:]
        }
    }

    /// Earlier versions saved the built-in color when it was picked from the swatches; drop those
    /// so they follow the default again.
    static func normalized(_ saved: [String: CategoryStyleOverride]) -> [String: CategoryStyleOverride] {
        saved.reduce(into: [:]) { result, entry in
            let style = ExpenseCategory(rawValue: entry.key).map(entry.value.normalized(for:)) ?? entry.value
            if !style.isEmpty { result[entry.key] = style }
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
        let style = style.normalized(for: category)
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
        ("Green", "33C571"), ("Orange", "FF7303"), ("Blue", "219FFB"), ("Indigo", "5D6BFF"),
        ("Yellow", "FFB300"), ("Red", "FF4D5E"), ("Purple", "9768FE"), ("Pink", "FF5CAD"),
        ("Teal", "14C4C4"), ("Graphite", "98A2B3"), ("Brown", "9C7A55")
    ]

    static let symbols: [String] = [
        "cart.fill", "fork.knife.circle.fill", "bus.fill", "house.fill", "bolt.fill", "heart.fill",
        "ticket.fill", "bag.fill", "airplane.circle.fill", "ellipsis.circle.fill", "car.fill", "fuelpump.fill",
        "cup.and.saucer.fill", "gift.fill", "graduationcap.fill", "pawprint.fill", "gamecontroller.fill", "book.fill",
        "tshirt.fill", "wrench.and.screwdriver.fill", "figure.run", "music.note", "film.fill", "stethoscope",
        "leaf.fill", "star.fill", "tram.fill", "bed.double.fill", "wifi", "creditcard.fill",
        "fork.knife", "takeoutbag.and.cup.and.straw.fill", "wineglass.fill", "birthday.cake.fill", "carrot.fill", "basket.fill",
        "bicycle", "scooter", "ferry.fill", "sailboat.fill", "parkingsign", "train.side.front.car",
        "dumbbell.fill", "figure.yoga", "figure.hiking", "soccerball", "tennis.racket", "figure.pool.swim",
        "pills.fill", "cross.case.fill", "syringe.fill", "eyeglasses", "comb.fill", "scissors",
        "iphone", "laptopcomputer", "headphones", "tv.fill", "camera.fill", "printer.fill",
        "lightbulb.fill", "drop.fill", "flame.fill", "washer.fill", "sofa.fill", "hammer.fill",
        "person.2.fill", "face.smiling.fill", "hare.fill", "tortoise.fill", "bird.fill", "ant.fill",
        "banknote.fill", "percent", "chart.line.uptrend.xyaxis", "building.columns.fill", "briefcase.fill", "shield.fill",
        "sun.max.fill", "beach.umbrella.fill", "tent.fill", "mountain.2.fill", "globe.europe.africa.fill", "suitcase.fill",
        "party.popper.fill", "balloon.fill", "theatermasks.fill", "paintpalette.fill", "guitars.fill", "popcorn.fill",
        "pencil.and.ruler.fill", "bell.fill", "heart.text.square.fill", "hands.sparkles.fill", "cross.fill", "tag.fill"
    ]
}

extension Color {
    /// Six hex digits, e.g. "1FA85A".
    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
