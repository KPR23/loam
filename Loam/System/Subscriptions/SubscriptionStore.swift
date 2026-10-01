import Foundation
import RevenueCat
import Supabase

/// Loam Pro through RevenueCat. Apple processes the payment; RevenueCat validates
/// receipts and reports whether the `loam_pro` entitlement is active. RevenueCat
/// customers are keyed by the lowercase Supabase user ID so the backend can check
/// the same entitlement before it lets an account invite another connection.
@MainActor
final class SubscriptionStore: ObservableObject {
    static let entitlementId = "loam_pro"

    /// Free accounts may hold this many connections before inviting needs Pro.
    /// Joining someone else's code is always free, so this never limits invitees.
    static let freeConnectionLimit = 1

    @Published private(set) var isPro = false
    @Published private(set) var customerInfo: CustomerInfo?
    /// False when no RevenueCat key is set for this build; everyone stays on the free plan.
    let isAvailable = Purchases.isConfigured

    /// `.none` until an identity is requested, and again after it fails so it is retried.
    private var requestedUserId: UUID?? = .none
    /// While another account loads, RevenueCat can still report the previous one.
    private var isSwitchingAccount = false

    /// Call once at launch, before the store is created.
    static func configure() {
        guard !Purchases.isConfigured, let apiKey = Self.apiKey else { return }
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        Purchases.configure(with: .builder(withAPIKey: apiKey).build())
    }

    init() {
        guard isAvailable else { return }
        Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                guard let self else { return }
                if !self.isSwitchingAccount { self.apply(info) }
            }
        }
    }

    /// Pass `nil` when signed out or in local demo mode, whose IDs are not real accounts.
    func identify(userId: UUID?) async {
        guard isAvailable, requestedUserId != .some(userId) else { return }
        requestedUserId = .some(userId)
        // Until this account's entitlement loads, it has none; a failed switch
        // must never leave it with the previous account's Pro.
        isPro = false
        customerInfo = nil
        isSwitchingAccount = true
        do {
            if let userId {
                let (info, _) = try await Purchases.shared.logIn(userId.uuidString.lowercased())
                guard requestedUserId == .some(userId) else { return }
                isSwitchingAccount = false
                apply(info)
                // Purchases made before sign-in move to this account; let the backend see them.
                if isPro { await syncBackendEntitlement() }
            } else {
                let info = Purchases.shared.isAnonymous
                    ? try await Purchases.shared.customerInfo()
                    : try await Purchases.shared.logOut()
                guard requestedUserId == .some(nil) else { return }
                isSwitchingAccount = false
                apply(info)
            }
        } catch {
            // RevenueCat still reports the previous account, so its updates stay ignored
            // and this one stays on Free until a retry succeeds (the app retries on foreground).
            if requestedUserId == .some(userId) { requestedUserId = .none }
            LoamErrorCapture.capture("subscriptions.identify_failed")
        }
    }

    /// Called by the paywall after a purchase or restore.
    func didUpdate(_ info: CustomerInfo) async {
        apply(info)
        await syncBackendEntitlement()
    }

    /// Asks the backend to re-read this account's entitlement from RevenueCat, so an
    /// invite works right after a purchase instead of waiting for the webhook.
    func syncBackendEntitlement() async {
        guard case .some(.some) = requestedUserId, let client = SupabaseClientProvider.shared else { return }
        do {
            try await client.functions.invoke("sync-pro-entitlement")
        } catch {
            LoamErrorCapture.capture("subscriptions.backend_sync_failed")
        }
    }

    private func apply(_ info: CustomerInfo) {
        customerInfo = info
        isPro = info.entitlements.active[Self.entitlementId] != nil
    }

    private static var apiKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}
