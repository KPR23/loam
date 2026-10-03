import XCTest
@testable import Loam

enum TestUser {
    static let alice = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let bob = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let carol = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
}

/// Calendar day in the calendar the app stores dates in.
func day(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar = AppPreferences.calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Tests share `UserDefaults.standard` with the simulator's installed app, so
/// every `loam.*` key is set aside before a test and put back afterwards.
class LocalStorageTestCase: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private var savedUsesLocalStorage = false

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedDefaults = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("loam.") }
        savedDefaults.keys.forEach(defaults.removeObject(forKey:))
        savedUsesLocalStorage = ExpenseRepositoryFactory.usesLocalStorage
        ExpenseRepositoryFactory.setUsesLocalStorage(true)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("loam.") }
            .forEach(defaults.removeObject(forKey:))
        savedDefaults.forEach { defaults.set($0.value, forKey: $0.key) }
        ExpenseRepositoryFactory.setUsesLocalStorage(savedUsesLocalStorage)
        super.tearDown()
    }

    func setTimeZonePreference(_ identifier: String) {
        UserDefaults.standard.set(identifier, forKey: AppPreferences.timeZoneKey)
    }
}

func personalExpense(
    _ amountMinor: Int,
    by user: UUID = TestUser.alice,
    category: ExpenseCategory = .groceries,
    currency: String = "PLN",
    spentAt: Date = Date()
) -> ExpenseRecord {
    ExpenseRecord(
        amountMinor: amountMinor,
        currency: currency,
        category: category,
        spentAt: spentAt,
        paidBy: user,
        createdBy: user,
        shares: [ExpenseShareRecord(userId: user, amountMinor: amountMinor)]
    )
}

/// Expense created and paid by `createdBy`, split across `shares`.
func sharedExpense(
    _ amountMinor: Int,
    createdBy: UUID = TestUser.alice,
    paidBy: UUID? = nil,
    shares: [ExpenseShareRecord],
    spentAt: Date = Date()
) -> ExpenseRecord {
    ExpenseRecord(
        amountMinor: amountMinor,
        category: .dining,
        spentAt: spentAt,
        paidBy: paidBy ?? createdBy,
        createdBy: createdBy,
        shares: shares
    )
}
