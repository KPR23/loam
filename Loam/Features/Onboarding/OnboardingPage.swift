import Foundation

/// One idea per screen; the copy stays short enough to read at a glance.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, month, split, permissions

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: "Know where your money goes"
        case .month: "Your month at a glance"
        case .split: "Split bills, skip the math"
        case .permissions: "Stay in the loop"
        }
    }

    var message: String {
        switch self {
        case .welcome: "Track what you spend and share bills with friends, all in one place."
        case .month: "Every expense lights up the arc in its category's color."
        case .split: "Add a shared expense once. Your friend accepts it and Loam keeps the balance."
        case .permissions: "Both are optional. You can change them anytime in Settings."
        }
    }

    var actionTitle: String {
        self == .welcome ? "Get started" : "Continue"
    }

    var next: OnboardingPage? {
        OnboardingPage(rawValue: rawValue + 1)
    }
}
