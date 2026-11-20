import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Picks the category for a Wallet payment that came without one. Each step only runs when the
/// one before it had no answer:
/// 1. the category the member last chose for this merchant,
/// 2. the bundled list of chains (`MerchantBrand`), then generic merchant words,
/// 3. Apple's on-device model, where the iPhone has Apple Intelligence,
/// 4. Other.
/// Every answer is one of the categories the member's picker offers, so a hidden or deleted
/// category is never used.
@MainActor
struct WalletCategoryChain {
    /// The picker's categories for this account.
    var options: (UUID) -> [SpendCategory]
    /// `SpendCategory.id` of the category last chosen for this merchant.
    var remembered: (String, UUID) -> String?
    /// Nil when the model isn't available, takes too long or has no answer.
    var model: (String, Money, [SpendCategory]) async -> SpendCategory?

    /// Tests replace it so they never depend on the machine's model.
    static var current = WalletCategoryChain.live

    static let live = WalletCategoryChain(
        options: { userId in
            CustomCategoryStore.shared.loadSavedCopyIfNeeded(userId: userId)
            return CustomCategoryStore.shared.pickerOptions(isPro: CategoryCustomizer.shared.isActive)
        },
        remembered: { merchant, userId in MerchantCategoryMemory.standard.categoryId(for: merchant, userId: userId) },
        model: { merchant, money, options in
            guard !LaunchEnvironment.isAutomatedTest else { return nil }
            return await OnDeviceCategoryModel.category(for: merchant, money: money, options: options)
        }
    )

    func pick(merchant: String, money: Money, userId: UUID) async -> SpendCategory {
        let options = options(userId)
        func offered(_ id: String) -> SpendCategory? { options.first { $0.id == id } }

        if let id = remembered(merchant, userId), let category = offered(id) {
            return category
        }
        let guess = MerchantCategory.guess(for: merchant)
        if guess != .other, let category = offered(guess.rawValue) {
            return category
        }
        if let answer = await model(merchant, money, options), let category = offered(answer.id) {
            return category
        }
        return .builtIn(.other)
    }
}

/// The category the member last chose for each merchant (an expense's title), kept on this
/// device per account. It learns from expenses the member saves or edits, never from guesses,
/// so changing a Wallet expense's category teaches it for the next payment there.
struct MerchantCategoryMemory {
    static let standard = MerchantCategoryMemory(defaults: .standard)
    /// Enough for anyone's regular places; the least recently chosen go first.
    static let limit = 500

    let defaults: UserDefaults

    private struct Entry: Codable {
        var categoryId: String
        var chosenAt: Date
    }

    func remember(_ category: SpendCategory, for merchant: String?, userId: UUID, at date: Date = Date()) {
        guard let key = merchant.flatMap(Self.key(for:)) else { return }
        var entries = load(userId: userId)
        entries[key] = Entry(categoryId: category.id, chosenAt: date)
        if entries.count > Self.limit {
            let kept = entries.sorted { $0.value.chosenAt > $1.value.chosenAt }.prefix(Self.limit)
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey(userId))
    }

    func categoryId(for merchant: String, userId: UUID) -> String? {
        guard let key = Self.key(for: merchant) else { return nil }
        return load(userId: userId)[key]?.categoryId
    }

    /// The merchant's words without store numbers, so "ORLEN STACJA 123" and "Orlen Stacja 456"
    /// are one place. A name made only of numbers keeps them.
    static func key(for merchant: String) -> String? {
        let words = MerchantCategory.words(merchant)
        let named = words.filter { !$0.contains(where: \.isNumber) }
        let key = (named.isEmpty ? words : named).joined(separator: " ")
        return key.isEmpty ? nil : key
    }

    private static func defaultsKey(_ userId: UUID) -> String {
        "loam.merchantCategories.\(userId.uuidString.lowercased())"
    }

    private func load(userId: UUID) -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey(userId)),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }
}

/// Asks Apple's on-device language model to file a payment. Only iOS 26 iPhones with Apple
/// Intelligence turned on have it; everywhere else, and on any error, this answers nil.
enum OnDeviceCategoryModel {
    /// Wallet automations have only a few seconds, so a slow answer is dropped.
    static let timeout: Duration = .seconds(2)

    @MainActor
    static func category(for merchant: String, money: Money, options: [SpendCategory]) async -> SpendCategory? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            // Each choice is a name the model can answer with; the first of two equal names wins.
            var byLabel: [String: SpendCategory] = [:]
            var labels: [String] = []
            for option in options {
                let label = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, byLabel[label] == nil else { continue }
                byLabel[label] = option
                labels.append(label)
            }
            guard labels.count > 1 else { return nil }
            let amount = MoneyFormatter.string(from: money)
            let label = await firstAnswer(within: timeout) {
                await FoundationModelCategorizer.label(merchant: merchant, amount: amount, labels: labels)
            }
            return label.flatMap { byLabel[$0] }
        }
        #endif
        return nil
    }

    /// The work's answer, or nil when it doesn't finish in time. The work is cancelled then,
    /// but nothing waits for it to stop.
    static func firstAnswer<Value: Sendable>(
        within timeout: Duration,
        _ work: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        let gate = AnswerGate<Value>()
        return await withCheckedContinuation { continuation in
            gate.start(continuation)
            let worker = Task {
                let value = await work()
                gate.finish(value)
            }
            Task {
                try? await Task.sleep(for: timeout)
                worker.cancel()
                gate.finish(nil)
            }
        }
    }

    /// Resumes the continuation once, with whichever answer arrives first.
    private final class AnswerGate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?

        func start(_ continuation: CheckedContinuation<Value?, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func finish(_ value: Value?) {
            let pending = lock.withLock { () -> CheckedContinuation<Value?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum FoundationModelCategorizer {
    static let instructions = """
        You file card payments into a personal budget. Given the merchant name from a card \
        payment and its amount, answer with the one category the payment most likely belongs to. \
        Merchant names are often shortened or include a store number or city. If no category \
        clearly fits, answer Other.
        """

    /// One of `labels`, or nil when the model can't run here or fails.
    static func label(merchant: String, amount: String, labels: [String]) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        do {
            let choice = DynamicGenerationSchema(name: "Category", anyOf: labels)
            let schema = try GenerationSchema(root: choice, dependencies: [])
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: "Merchant: \(merchant)\nAmount: \(amount)",
                schema: schema,
                options: GenerationOptions(sampling: .greedy)
            )
            let label = try response.content.value(String.self)
            return labels.contains(label) ? label : nil
        } catch {
            return nil
        }
    }
}
#endif
