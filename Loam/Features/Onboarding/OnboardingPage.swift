import Foundation

/// One idea per screen; the copy stays short enough to read at a glance.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, month, split, permissions

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: String(localized: "Know where your money goes")
        case .month: String(localized: "Your month at a glance")
        case .split: String(localized: "Split bills, skip the math")
        case .permissions: String(localized: "Stay in the loop")
        }
    }

    var message: String {
        switch self {
        case .welcome: String(localized: "Track what you spend and share bills with friends, all in one place.")
        case .month: String(localized: "Every expense lights up the arc in its category's color.")
        case .split: String(localized: "Add a shared expense once. Your friend accepts it and Loam keeps the balance.")
        case .permissions: String(localized: "It's optional. You can change it anytime in Settings.")
        }
    }

    var actionTitle: String {
        self == .welcome ? String(localized: "Get started") : String(localized: "Continue")
    }

    var next: OnboardingPage? {
        OnboardingPage(rawValue: rawValue + 1)
    }
}
