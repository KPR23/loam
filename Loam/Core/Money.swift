import Foundation

/// Money stored as integer minor units (grosze / cents). Never use Double for amounts.
struct Money: Hashable, Codable, Sendable, Comparable {
    let amountMinor: Int
    let currencyCode: String

    init(amountMinor: Int, currencyCode: String = "PLN") {
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode.uppercased()
    }

    /// Parses major-unit input like "12,34" / "12.34" into minor units.
    /// Only digits and a single decimal separator are accepted; trailing fraction digits beyond 2 are rejected.
    init?(majorString: String, currencyCode: String = "PLN") {
        let trimmed = majorString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard Self.isValidMajorString(trimmed) else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }

        let majorPart = String(parts[0])
        guard !majorPart.isEmpty, let major = Int(majorPart), major >= 0 else { return nil }

        let fraction: Int
        if parts.count == 2 {
            let fracRaw = String(parts[1])
            if fracRaw.isEmpty {
                fraction = 0
            } else {
                guard fracRaw.count <= 2, fracRaw.allSatisfy(\.isNumber), let fracDigits = Int(fracRaw) else {
                    return nil
                }
                fraction = fracRaw.count == 1 ? fracDigits * 10 : fracDigits
            }
        } else {
            fraction = 0
        }

        // The amount field accepts any number of digits; reject what cannot be stored instead of trapping.
        let (majorMinor, multiplyOverflow) = major.multipliedReportingOverflow(by: 100)
        let (amountMinor, addOverflow) = majorMinor.addingReportingOverflow(fraction)
        guard !multiplyOverflow, !addOverflow else { return nil }

        self.amountMinor = amountMinor
        self.currencyCode = currencyCode.uppercased()
    }

    /// True when the string contains only digits and at most one `,` or `.`.
    static func isValidMajorString(_ string: String) -> Bool {
        var separatorCount = 0
        for character in string {
            if character.isNumber { continue }
            if character == "," || character == "." {
                separatorCount += 1
                if separatorCount > 1 { return false }
                continue
            }
            return false
        }
        return true
    }

    /// Keeps digits and a single comma while typing. Periods become commas; max 2 fraction digits.
    static func sanitizeTypingInput(_ raw: String) -> String {
        var result = ""
        var sawSeparator = false
        var fractionCount = 0

        for character in raw {
            if character.isNumber {
                if sawSeparator {
                    guard fractionCount < 2 else { continue }
                    fractionCount += 1
                }
                result.append(character)
                continue
            }

            guard character == "," || character == "." else { continue }
            guard !sawSeparator else { continue }

            if result.isEmpty {
                result = "0"
            }
            result.append(",")
            sawSeparator = true
        }

        return result
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
