import CryptoKit
import Foundation

/// Reads a Splitwise CSV export (Account → Export as spreadsheet) and turns it into Loam
/// expenses and repayments. Pure logic: no storage, no network.
///
/// Each export row holds the net balance of every person (paid − owed). Loam keeps a single
/// payer per expense, so a row is importable when exactly one person paid.
enum SplitwiseImport {
    struct Row: Equatable, Sendable {
        var index: Int
        var date: Date
        var description: String
        var category: String
        var costMinor: Int
        var currency: String
        /// Net balance in minor units per column, parallel to `Export.people`.
        var nets: [Int]
        var isPayment: Bool
    }

    struct Export: Equatable, Sendable {
        var people: [String]
        var rows: [Row]
    }

    enum ParseError: LocalizedError, Equatable {
        case notSplitwise
        case noRows

        var errorDescription: String? {
            switch self {
            case .notSplitwise: return "This doesn’t look like a Splitwise export. Export your group as a spreadsheet (CSV) and try again."
            case .noRows: return "No expenses found in this file."
            }
        }
    }

    enum SkipReason: Equatable, Sendable {
        case notInvolvingYou
        case multiplePayers
        case invalid
    }

    struct PlannedExpense: Equatable, Sendable {
        var expense: ExpenseRecord
    }

    struct PlannedPayment: Equatable, Sendable {
        var operationId: UUID
        var personId: UUID
        /// True when the other person paid you.
        var isReceived: Bool
        var amountMinor: Int
        var currency: String
        var note: String?
        var date: Date
    }

    struct Plan: Equatable, Sendable {
        var expenses: [PlannedExpense] = []
        var payments: [PlannedPayment] = []
        var skipped: [(row: Int, reason: SkipReason)] = []

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.expenses == rhs.expenses && lhs.payments == rhs.payments
                && lhs.skipped.map(\.row) == rhs.skipped.map(\.row)
        }
    }

    // MARK: - Parsing

    static func parse(_ text: String) throws -> Export {
        let records = csvRecords(text)
        guard let headerIndex = records.firstIndex(where: { isHeader($0) }) else { throw ParseError.notSplitwise }
        let header = records[headerIndex].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let people = Array(header.dropFirst(5)).filter { !$0.isEmpty }
        guard !people.isEmpty else { throw ParseError.notSplitwise }

        var rows: [Row] = []
        for (offset, record) in records.dropFirst(headerIndex + 1).enumerated() {
            guard record.count >= 5 + people.count else { continue }
            let description = record[1].trimmingCharacters(in: .whitespacesAndNewlines)
            // The footer line, and blank separator lines, carry no date.
            guard let date = parseDate(record[0]), description.lowercased() != "total balance" else { continue }
            guard let cost = parseMinor(record[3]) else { continue }
            var nets: [Int] = []
            for column in 0..<people.count { nets.append(parseMinor(record[5 + column]) ?? 0) }
            let category = record[2].trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(Row(
                index: offset,
                date: date,
                description: description,
                category: category,
                costMinor: abs(cost),
                currency: record[4].trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                nets: nets,
                isPayment: isPayment(category: category, description: description)
            ))
        }
        guard !rows.isEmpty else { throw ParseError.noRows }
        return Export(people: people, rows: rows)
    }

    /// Repayments: "X paid Y" in the Payment category, and the settle-up lines Splitwise writes
    /// in the account's language.
    private static func isPayment(category: String, description: String) -> Bool {
        if category.caseInsensitiveCompare("Payment") == .orderedSame { return true }
        let settle = ["settle all balances", "rozlicz wszystkie salda"]
        return settle.contains(description.lowercased())
    }

    private static func isHeader(_ record: [String]) -> Bool {
        guard record.count > 5 else { return false }
        let names = record.prefix(5).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return names == ["date", "description", "category", "cost", "currency"]
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = AppPreferences.calendar
        formatter.timeZone = AppPreferences.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return formatter.date(from: String(trimmed.prefix(10)))
    }

    /// "12.34", "12,34", "1,234.56", "-5" → minor units. Nil when it isn't a number.
    static func parseMinor(_ raw: String) -> Int? {
        var text = raw.filter { !$0.isWhitespace && $0 != "\u{00A0}" }
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("-") { negative = true; text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { return nil }
        let lastSeparator = text.lastIndex(where: { $0 == "." || $0 == "," })
        var whole = text
        var fraction = ""
        if let lastSeparator {
            let tail = text[text.index(after: lastSeparator)...]
            let hasBoth = text.contains(".") && text.contains(",")
            let sameSeparatorCount = text.filter { $0 == text[lastSeparator] }.count
            if hasBoth || tail.count <= 2 || sameSeparatorCount == 1 && tail.count != 3 {
                whole = String(text[..<lastSeparator])
                fraction = String(tail)
            }
        }
        whole = whole.filter(\.isNumber)
        guard fraction.count <= 2, fraction.allSatisfy(\.isNumber) else { return nil }
        guard let major = Int(whole.isEmpty ? "0" : whole) else { return nil }
        let fractionMinor = fraction.isEmpty ? 0 : (fraction.count == 1 ? Int(fraction)! * 10 : Int(fraction)!)
        let (scaled, overflow) = major.multipliedReportingOverflow(by: 100)
        guard !overflow else { return nil }
        let value = scaled + fractionMinor
        return negative ? -value : value
    }

    /// RFC 4180 records: quoted fields, doubled quotes, newlines inside quotes, BOM.
    static func csvRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var characters = Array(text.unicodeScalars.map(Character.init))
        if characters.first == "\u{FEFF}" { characters.removeFirst() }
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < characters.count, characters[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                record.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                record.append(field); field = ""
                if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
                record = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    // MARK: - Planning

    /// People who appear with a non-zero balance in a row that involves `meIndex`.
    /// Only these need a Loam person.
    static func involvedPeople(in export: Export, meIndex: Int) -> [Int] {
        var involved = Set<Int>()
        for row in export.rows where row.nets[meIndex] != 0 {
            for (column, net) in row.nets.enumerated() where column != meIndex && net != 0 { involved.insert(column) }
        }
        return involved.sorted()
    }

    /// - Parameters:
    ///   - meIndex: the column that is the signed-in person.
    ///   - mapping: Loam user id per other column (placeholders).
    static func plan(_ export: Export, meIndex: Int, me: UUID, mapping: [Int: UUID], now: Date = Date()) -> Plan {
        var plan = Plan()
        for row in export.rows {
            guard row.nets[meIndex] != 0 else { plan.skipped.append((row.index, .notInvolvingYou)); continue }
            let payers = row.nets.indices.filter { row.nets[$0] > 0 }
            guard payers.count == 1, let payerColumn = payers.first else { plan.skipped.append((row.index, .multiplePayers)); continue }
            func user(_ column: Int) -> UUID? { column == meIndex ? me : mapping[column] }
            guard let payerId = user(payerColumn) else { plan.skipped.append((row.index, .invalid)); continue }

            if row.isPayment {
                let recipients = row.nets.indices.filter { row.nets[$0] < 0 }
                guard recipients.count == 1, let recipientColumn = recipients.first,
                      payerColumn == meIndex || recipientColumn == meIndex,
                      let recipientId = user(recipientColumn), row.costMinor > 0
                else { plan.skipped.append((row.index, .invalid)); continue }
                let other = payerColumn == meIndex ? recipientId : payerId
                plan.payments.append(PlannedPayment(
                    operationId: stableId("payment", me, row),
                    personId: other,
                    isReceived: recipientColumn == meIndex,
                    amountMinor: row.costMinor,
                    currency: row.currency,
                    note: "Imported from Splitwise",
                    date: row.date
                ))
                continue
            }

            var owed: [(UUID, Int)] = []
            var othersOwed = 0
            var valid = row.costMinor > 0
            for (column, net) in row.nets.enumerated() where column != payerColumn && net < 0 {
                guard let id = user(column) else { valid = false; break }
                owed.append((id, -net)); othersOwed += -net
            }
            let payerOwed = row.costMinor - othersOwed
            guard valid, payerOwed >= 0 else { plan.skipped.append((row.index, .invalid)); continue }
            let shares = ([(payerId, payerOwed)] + owed).map { id, amount in
                ExpenseShareRecord(userId: id, amountMinor: amount, status: .accepted, respondedAt: now)
            }
            plan.expenses.append(PlannedExpense(expense: ExpenseRecord(
                id: stableId("expense", me, row),
                amountMinor: row.costMinor,
                currency: row.currency.isEmpty ? AppPreferences.defaultCurrencyCode : row.currency,
                category: mapCategory(row.category),
                title: row.description.isEmpty ? nil : row.description,
                note: "Imported from Splitwise",
                spentAt: row.date,
                paidBy: payerId,
                createdBy: me,
                shares: shares,
                createdAt: now,
                updatedAt: now
            )))
        }
        return plan
    }

    static func mapCategory(_ splitwise: String) -> ExpenseCategory {
        let name = splitwise.lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("grocer", "supermarket") { return .groceries }
        if has("dining", "restaurant", "coffee", "food", "liquor", "bar") { return .dining }
        if has("heat", "electric", "water", "trash", "internet", "phone", "utilit", "cleaning") { return .utilities }
        if has("taxi", "bus", "train", "car", "gas/fuel", "parking", "bicycle", "transport") { return .transport }
        if has("hotel", "plane", "vacation", "trip") { return .travel }
        if has("rent", "mortgage", "household", "furniture", "home", "maintenance", "lawn", "pet") { return .housing }
        if has("medical", "health", "pharmac") { return .health }
        if has("movie", "music", "game", "sport", "entertain", "party") { return .entertainment }
        if has("cloth", "electronic", "gift", "shopping") { return .shopping }
        return .other
    }

    /// The same file produces the same ids, so importing it twice doesn't duplicate anything.
    static func stableId(_ kind: String, _ me: UUID, _ row: Row) -> UUID {
        let key = "splitwise|\(kind)|\(me.uuidString)|\(row.index)|\(row.date.timeIntervalSince1970)|\(row.description)|\(row.costMinor)|\(row.currency)|\(row.nets)"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
