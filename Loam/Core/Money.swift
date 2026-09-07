import Foundation

/// Money stored as integer minor units (grosze / cents). Never use Double for amounts.
struct Money: Hashable, Codable, Sendable, Comparable {
    let amountMinor: Int
    let currencyCode: String

    init(amountMinor: Int, currencyCode: String = "PLN") {
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode.uppercased()
    }

    /// Parses major-unit input like "12.34" into minor units. Trailing fraction digits beyond 2 are rejected.
    init?(majorString: String, currencyCode: String = "PLN") {
        let trimmed = majorString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }

        let majorPart = String(parts[0])
        guard let major = Int(majorPart) else { return nil }

        let fraction: Int
        if parts.count == 2 {
            let fracRaw = String(parts[1])
            guard fracRaw.count <= 2, let fracDigits = Int(fracRaw) else { return nil }
            fraction = fracRaw.count == 1 ? fracDigits * 10 : fracDigits
        } else {
            fraction = 0
        }

        let sign = major < 0 || trimmed.hasPrefix("-") ? -1 : 1
        let absMajor = abs(major)
        self.amountMinor = sign * (absMajor * 100 + fraction)
        self.currencyCode = currencyCode.uppercased()
    }

    static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(lhs.currencyCode == rhs.currencyCode, "Cannot compare different currencies")
        return lhs.amountMinor < rhs.amountMinor
    }

    static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currencyCode == rhs.currencyCode, "Cannot add different currencies")
        return Money(amountMinor: lhs.amountMinor + rhs.amountMinor, currencyCode: lhs.currencyCode)
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currencyCode == rhs.currencyCode, "Cannot subtract different currencies")
        return Money(amountMinor: lhs.amountMinor - rhs.amountMinor, currencyCode: lhs.currencyCode)
    }

    static let zeroPLN = Money(amountMinor: 0, currencyCode: "PLN")
}
