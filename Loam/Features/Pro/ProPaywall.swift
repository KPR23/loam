import SwiftUI
import RevenueCat
import RevenueCatUI

extension View {
    /// Presents the RevenueCat paywall for the current offering. Its layout, copy and
    /// packages (lifetime, yearly, monthly) are edited in the RevenueCat dashboard.
    func proPaywall(isPresented: Binding<Bool>) -> some View {
        modifier(ProPaywallModifier(isPresented: isPresented))
    }
}

private struct ProPaywallModifier: ViewModifier {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if subscriptions.isAvailable {
                PaywallView(displayCloseButton: true)
                    .onPurchaseCompleted { info in
                        isPresented = false
                        Task { await subscriptions.didUpdate(info) }
                    }
                    .onRestoreCompleted { info in
                        Task { await subscriptions.didUpdate(info) }
                        if info.entitlements.active[SubscriptionStore.entitlementId] != nil {
                            isPresented = false
                        }
                    }
                    .onPurchaseFailure { _ in
                        LoamErrorCapture.capture("subscriptions.purchase_failed")
                    }
            } else {
                PurchasesUnavailableView()
            }
        }
    }
}

private struct PurchasesUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Loam Pro isn’t available yet",
                systemImage: "sparkles",
                description: Text("Purchases aren’t set up in this build.")
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Marks a control that opens the paywall for accounts without Pro.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .accessibilityLabel("Requires Loam Pro")
    }
}
