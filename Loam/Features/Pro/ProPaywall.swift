import SwiftUI
import CoreMotion
import RevenueCat

extension View {
    /// Presents the Loam Pro paywall. Its packages (yearly, monthly) and prices
    /// come from the current RevenueCat offering; the layout and copy live here.
    func proPaywall(isPresented: Binding<Bool>) -> some View {
        modifier(ProPaywallModifier(isPresented: isPresented))
    }
}

private struct ProPaywallModifier: ViewModifier {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            Group {
                if subscriptions.isAvailable {
                    ProPaywallView()
                } else {
                    PurchasesUnavailableView()
                }
            }
            .environmentObject(subscriptions)
        }
    }
}

private struct ProPaywallView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var packages: [Package] = []
    @State private var selectedId: String?
    /// Packages whose free trial this Apple Account hasn't used yet.
    @State private var trialEligibleIds: Set<String> = []
    @State private var isLoading = true
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var alert: PaywallAlert?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: Package? {
        packages.first { $0.identifier == selectedId }
    }

    private var isBusy: Bool { isPurchasing || isRestoring }

    private var selectedTrial: StoreProductDiscount? {
        guard let selected, trialEligibleIds.contains(selected.identifier) else { return nil }
        return selected.storeProduct.introductoryDiscount
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header

                    if packages.count > 1 {
                        VStack(spacing: 12) {
                            planPicker
                            if let yearlyHint {
                                yearlyHintPill(yearlyHint)
                            }
                        }
                    }

                    ProComparisonCard()
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { purchaseBar }
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .disabled(isBusy)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .task { await loadPackages() }
        .alert(
            alert?.title ?? "",
            isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
            presenting: alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 10) {
            ProEmblem()
                .padding(.bottom, 14)

            Text("Get Loam Pro")
                .font(.system(size: 36, weight: .bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("Share every bill, with everyone")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var annualPackage: Package? {
        packages.first { $0.packageType == .annual }
    }

    private var isAnnualSelected: Bool {
        annualPackage != nil && selectedId == annualPackage?.identifier
    }

    /// Yearly's discount over Monthly. The free trial stays out of it: App Review rejects
    /// paywalls that show a trial more prominently than the price billed after it.
    private var yearlyHint: String? {
        guard let annualSavings else { return nil }
        return isAnnualSelected ? "You save \(annualSavings)% with Yearly" : "Save \(annualSavings)% with Yearly"
    }

    /// The segmented control can't color part of a label, so Yearly's discount sits below it.
    /// On Monthly it doubles as a shortcut to Yearly.
    private func yearlyHintPill(_ text: String) -> some View {
        Button {
            guard let annualPackage, !isAnnualSelected else { return }
            withAnimation(reduceMotion ? nil : .snappy) { selectedId = annualPackage.identifier }
        } label: {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HomeTheme.accent)
                .contentTransition(.opacity)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(HomeTheme.accent.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(LoamPressStyle())
        .allowsHitTesting(!isAnnualSelected && !isBusy)
        .accessibilityAddTraits(isAnnualSelected ? .isStaticText : [])
    }

    private var planPicker: some View {
        Picker("Plan", selection: $selectedId.animation(reduceMotion ? nil : .snappy)) {
            ForEach(packages, id: \.identifier) { package in
                Text(package.paywallTitle).tag(Optional(package.identifier))
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .disabled(isBusy)
        .onChange(of: selectedId) { oldValue, _ in
            if oldValue != nil { LoamFeedback.selection() }
        }
    }

    private var purchaseBar: some View {
        VStack(spacing: 12) {
            priceSummary

            Button {
                Task {
                    if let selected { await purchase(selected) } else { await loadPackages() }
                }
            } label: {
                ZStack {
                    Text(ctaTitle)
                        .contentTransition(.numericText())
                        .opacity(isPurchasing || isLoading ? 0 : 1)
                    if isPurchasing || isLoading {
                        ProgressView()
                            .tint(Color(.systemBackground))
                            .accessibilityHidden(true)
                    }
                }
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Color(.systemBackground))
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(Color.primary, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(LoamPressStyle())
            .disabled(isLoading || isBusy)
            .accessibilityLabel(isPurchasing ? "Purchasing" : ctaTitle)

            HStack(spacing: 20) {
                Button {
                    Task { await restore() }
                } label: {
                    if isRestoring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .disabled(isBusy)

                // Short labels keep all three on one line on the smallest iPhones.
                Link("Terms", destination: LegalPages.termsOfUse)
                Link("Privacy", destination: LegalPages.privacyPolicy)
            }
            .padding(.top, 6)
            .font(.footnote.weight(.medium))
            .tint(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background {
            // Content scrolls under the purchase bar and fades out rather than being cut off.
            Color(.systemBackground)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 32)
                    .offset(y: -32)
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The billed price leads, larger than anything about the trial, with the trial's length
    /// and what renews after it right below. App Review requires that order of prominence.
    @ViewBuilder
    private var priceSummary: some View {
        if let selected {
            VStack(spacing: 4) {
                Text(billedPrice(selected))
                    .font(.title2.weight(.bold))
                    .contentTransition(.numericText())
                Text(billingTerms(selected))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
        } else {
            Text(isLoading ? " " : "Couldn’t load plans. Check your connection and try again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Copy

    private var ctaTitle: String {
        guard selected != nil else { return isLoading ? "" : "Try Again" }
        return selectedTrial == nil ? "Subscribe" : "Start Free Trial"
    }

    /// "99,99 zł/year": what each renewal charges.
    private func billedPrice(_ package: Package) -> String {
        let price = package.storeProduct.localizedPriceString
        guard let period = package.billingPeriod else { return price }
        return "\(price)/\(period)"
    }

    private func billingTerms(_ package: Package) -> String {
        let product = package.storeProduct
        if let trial = selectedTrial {
            let then = package.billingPeriod.map { "\(product.localizedPriceString)/\($0)" } ?? product.localizedPriceString
            return "Free for \(trial.durationText.lowercased()), then \(then). Renews until cancelled."
        }
        switch package.packageType {
        case .monthly:
            return "Renews monthly until cancelled."
        case .annual:
            if let perMonth = product.localizedPricePerMonth {
                return "Billed yearly, about \(perMonth)/month. Renews until cancelled."
            }
            return "Renews yearly until cancelled."
        default:
            if let period = package.billingPeriod { return "Renews every \(period) until cancelled." }
            return product.productType == .autoRenewableSubscription
                ? "Renews until cancelled."
                : "One-time purchase."
        }
    }

    /// Whole-percent discount of the yearly plan over twelve monthly payments.
    private var annualSavings: Int? {
        guard let monthly = packages.first(where: { $0.packageType == .monthly })?.storeProduct.price,
              let annual = packages.first(where: { $0.packageType == .annual })?.storeProduct.price,
              monthly > 0
        else { return nil }
        let ratio = NSDecimalNumber(decimal: annual / (monthly * 12)).doubleValue
        let percent = Int(((1 - ratio) * 100).rounded(.down))
        return percent >= 5 ? percent : nil
    }

    // MARK: Purchasing

    private func loadPackages() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let offerings = try await Purchases.shared.offerings()
            // Lifetime stays in the offering but isn't sold for now.
            packages = (offerings.current?.availablePackages ?? [])
                .filter { $0.packageType != .lifetime }
                .sorted { $0.packageType.paywallOrder < $1.packageType.paywallOrder }
            // Yearly is the best value, so it leads when the offering has one.
            selectedId = (packages.first { $0.packageType == .annual } ?? packages.first)?.identifier
            await loadTrialEligibility()
        } catch {
            LoamErrorCapture.capture("subscriptions.offerings_failed")
        }
    }

    private func loadTrialEligibility() async {
        var eligible: Set<String> = []
        for package in packages where package.storeProduct.introductoryDiscount?.paymentMode == .freeTrial {
            let status = await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: package.storeProduct)
            if status == .eligible { eligible.insert(package.identifier) }
        }
        trialEligibleIds = eligible
    }

    private func purchase(_ package: Package) async {
        LoamFeedback.tap()
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            guard !result.userCancelled else { return }
            LoamFeedback.success()
            dismiss()
            await subscriptions.didUpdate(result.customerInfo)
        } catch {
            if (error as? ErrorCode) == .purchaseCancelledError { return }
            LoamErrorCapture.capture("subscriptions.purchase_failed")
            LoamFeedback.error()
            alert = PaywallAlert(title: "Purchase Failed", message: error.localizedDescription)
        }
    }

    private func restore() async {
        LoamFeedback.tap()
        isRestoring = true
        defer { isRestoring = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            if info.entitlements.active[SubscriptionStore.entitlementId] != nil {
                LoamFeedback.success()
                dismiss()
                await subscriptions.didUpdate(info)
            } else {
                await subscriptions.didUpdate(info)
                alert = PaywallAlert(
                    title: "Nothing to Restore",
                    message: "This Apple Account has no Loam Pro purchase."
                )
            }
        } catch {
            LoamErrorCapture.capture("subscriptions.restore_failed")
            LoamFeedback.error()
            alert = PaywallAlert(title: "Restore Failed", message: error.localizedDescription)
        }
    }
}

private struct PaywallAlert {
    let title: String
    let message: String
}

/// The paywall's hero: the PRO mark, floating gently and tilting with the phone.
/// Holds still with Reduce Motion.
private struct ProEmblem: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let lift = sin(t * 1.1) * 2.5

            TiltingProMark(height: ProMark.baseSize.height)
                .shadow(color: .black.opacity(0.12), radius: 12 - lift, y: 10 - lift)
                .offset(y: -lift)
        }
        .frame(width: ProMark.baseSize.width + 24, height: ProMark.baseSize.height + 24)
        .accessibilityHidden(true)
    }
}

/// The app's PRO mark as a soft clay tile: a pale accent pill with puffy accent lettering.
/// `height` scales the whole mark; the paywall hero uses the full 40 pt.
struct ProMark: View {
    static let baseSize = CGSize(width: 90, height: 40)

    var height: CGFloat = baseSize.height

    var body: some View {
        let accent = HomeTheme.solidAccent
        let clay = Self.pastel(of: accent)
        let scale = height / Self.baseSize.height

        ZStack {
            // Thickness: a slightly darker copy just below the face.
            Capsule()
                .fill(Self.pastel(of: accent, whiteness: 0.72))
                .offset(y: 3 * scale)

            // Face: lit from the top left, shaded toward the bottom right, like soft plastic.
            Capsule()
                .fill(
                    clay
                        .shadow(.inner(color: .white.opacity(0.9), radius: 4 * scale, x: 2 * scale, y: 3 * scale))
                        .shadow(.inner(color: accent.opacity(0.28), radius: 6 * scale, x: -3 * scale, y: -4 * scale))
                )

            Text("PRO")
                .font(.system(size: 22 * scale, weight: .heavy, design: .rounded))
                .tracking(1.5 * scale)
                .foregroundStyle(
                    accent
                        .shadow(.inner(color: .white.opacity(0.55), radius: 1.5 * scale, x: scale, y: 1.5 * scale))
                        .shadow(.drop(color: accent.opacity(0.35), radius: 2 * scale, y: 2 * scale))
                )
        }
        .frame(width: Self.baseSize.width * scale, height: height)
    }

    /// The accent mixed toward white, for the clay body.
    static func pastel(of color: Color, whiteness: CGFloat = 0.84) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let mix = { (channel: CGFloat) in channel + (1 - channel) * whiteness }
        return Color(red: mix(red), green: mix(green), blue: mix(blue))
    }

    /// The accent mixed toward black, for surfaces that sit on dark backgrounds.
    static func shaded(of color: Color, blackness: CGFloat) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let mix = { (channel: CGFloat) in channel * (1 - blackness) }
        return Color(red: mix(red), green: mix(green), blue: mix(blue))
    }
}

/// The PRO mark, turning in 3D as the phone tilts, like a physical badge.
/// Holds still when Reduce Motion is on.
struct TiltingProMark: View {
    var height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var tilt = DeviceTilt()

    var body: some View {
        ProMark(height: height)
            .rotation3DEffect(.degrees(tilt.pitch * 16), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tilt.roll * 22), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .onAppear { if !reduceMotion { tilt.start() } }
            .onDisappear { tilt.stop() }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { tilt.stop() } else { tilt.start() }
            }
    }
}

/// How far the phone has tilted since it started being watched, from -1 to 1 on each axis.
/// The first reading is the rest position, so the badge starts flat however the phone is held.
@MainActor
final class DeviceTilt: ObservableObject {
    @Published private(set) var roll: Double = 0
    @Published private(set) var pitch: Double = 0

    private let manager = CMMotionManager()
    private var reference: CMAttitude?
    /// Radians of tilt that count as a full -1...1 swing.
    private static let range = 0.6

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        reference = nil
        manager.deviceMotionUpdateInterval = 1 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            MainActor.assumeIsolated { self.update(with: attitude) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
        roll = 0
        pitch = 0
    }

    private func update(with attitude: CMAttitude) {
        guard let reference else {
            reference = attitude.copy() as? CMAttitude
            return
        }
        attitude.multiply(byInverseOf: reference)
        let clamp = { (value: Double) in min(max(value / Self.range, -1), 1) }
        // Eases toward the reading, so sensor jitter doesn't shake the badge.
        roll += (clamp(attitude.roll) - roll) * 0.2
        pitch += (clamp(attitude.pitch) - pitch) * 0.2
    }
}

/// Free vs. Pro, one row per gated feature.
private struct ProComparisonCard: View {
    private static let columnWidth: CGFloat = 52

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 26) {
            GridRow {
                Text("Features")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Free")
                    .frame(width: Self.columnWidth)
                Text("Pro")
                    .foregroundStyle(HomeTheme.accent)
                    .frame(width: Self.columnWidth)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            ForEach(ProFeature.all) { feature in
                GridRow {
                    Text(feature.title)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    mark(feature.free, tint: .secondary)
                        .frame(width: Self.columnWidth)
                    mark(feature.pro, tint: HomeTheme.accent)
                        .frame(width: Self.columnWidth)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(feature.accessibilityLabel)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func mark(_ availability: ProFeature.Availability, tint: Color) -> some View {
        switch availability {
        case .included:
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
        case .missing:
            Image(systemName: "minus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
        case .limit(let value):
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct ProFeature: Identifiable {
    enum Availability {
        case included, missing
        case limit(String)
    }

    let title: String
    let free: Availability
    let pro: Availability
    let accessibilityLabel: String

    var id: String { title }

    static let all = [
        ProFeature(
            title: "Personal & shared expenses",
            free: .included,
            pro: .included,
            accessibilityLabel: "Personal and shared expenses: included on Free and Pro"
        ),
        ProFeature(
            title: "Connections",
            free: .limit("\(SubscriptionStore.freeConnectionLimit)"),
            pro: .limit("∞"),
            accessibilityLabel: "Connections: \(SubscriptionStore.freeConnectionLimit) on Free, unlimited on Pro"
        ),
        ProFeature(
            title: "Recurring expenses",
            free: .missing,
            pro: .included,
            accessibilityLabel: "Recurring expenses: Pro only"
        ),
        ProFeature(
            title: "Notes on expenses",
            free: .missing,
            pro: .included,
            accessibilityLabel: "Notes on expenses: Pro only"
        ),
        ProFeature(
            title: "Custom categories",
            free: .missing,
            pro: .included,
            accessibilityLabel: "Custom categories: Pro only"
        ),
    ]
}

private extension Package {
    var paywallTitle: String {
        switch packageType {
        case .monthly: "Monthly"
        case .annual: "Yearly"
        default: storeProduct.localizedTitle
        }
    }

    /// The length each renewal is billed for, as in "99,99 zł/year" or "29,99 zł/3 months".
    /// Read from the product, since the offering can gain packages without an app update.
    var billingPeriod: String? {
        guard let period = storeProduct.subscriptionPeriod else { return nil }
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: return nil
        }
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }
}

private extension StoreProductDiscount {
    /// "2 Weeks", "1 Month": the trial's whole length, in title case for the button.
    var durationText: String {
        var count = subscriptionPeriod.value * numberOfPeriods
        var unit = subscriptionPeriod.unit
        if unit == .day, count % 7 == 0 {
            count /= 7
            unit = .week
        }
        let name = switch unit {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        @unknown default: "Day"
        }
        return "\(count) \(name)\(count == 1 ? "" : "s")"
    }
}

private extension PackageType {
    /// Cheapest commitment first, like the plan order on the App Store.
    var paywallOrder: Int {
        switch self {
        case .monthly: 0
        case .annual: 1
        default: 2
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
