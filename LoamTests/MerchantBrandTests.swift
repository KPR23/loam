import SwiftUI
import XCTest
@testable import Loam

/// The bundled list of chains and how card merchant names are matched to it.
final class MerchantBrandTests: XCTestCase {
    private func brand(_ merchant: String?) -> String? {
        MerchantBrand.match(merchant)?.name
    }

    func testCaseAndDiacriticsDontMatter() {
        XCTAssertEqual(brand("ŻABKA"), "Żabka")
        XCTAssertEqual(brand("zabka"), "Żabka")
        XCTAssertEqual(brand("Żabka"), "Żabka")
        XCTAssertEqual(brand("INTERMARCHÉ"), "Intermarché")
        XCTAssertEqual(brand("intermarche"), "Intermarché")
    }

    func testStoreNumbersAndCitiesDontMatter() {
        XCTAssertEqual(brand("ZABKA Z1234 K.1"), "Żabka")
        XCTAssertEqual(brand("BIEDRONKA 4521 KRAKOW"), "Biedronka")
        XCTAssertEqual(brand("Orlen Stacja nr 123"), "Orlen")
        XCTAssertEqual(brand("McDonald's 0412"), "McDonald's")
    }

    func testLegalSuffixesDontMatter() {
        XCTAssertEqual(brand("LIDL SP. Z O.O. WARSZAWA 123"), "Lidl")
        XCTAssertEqual(brand("Lidl sp. z o.o. sp. k."), "Lidl")
        XCTAssertEqual(brand("JERONIMO MARTINS POLSKA S.A."), "Biedronka")
        XCTAssertEqual(brand("Allegro.pl Sp. z o.o."), "Allegro")
        XCTAssertEqual(MerchantBrand.normalizedWords("LIDL SP. Z O.O. WARSZAWA 123"), ["lidl", "warszawa"])
        XCTAssertEqual(MerchantBrand.normalizedWords("Orlen S.A."), ["orlen"])
        XCTAssertEqual(MerchantBrand.normalizedWords("Shell Polska Spółka z ograniczoną odpowiedzialnością"), ["shell", "polska"])
    }

    func testOnlineNamesMatch() {
        XCTAssertEqual(brand("WWW.ALLEGRO.PL"), "Allegro")
        XCTAssertEqual(brand("Bolt.eu"), "Bolt")
        XCTAssertEqual(brand("NETFLIX.COM"), "Netflix")
        XCTAssertEqual(brand("AMZN Mktp PL"), "Amazon")
    }

    func testTheLongerNameWins() {
        XCTAssertEqual(brand("UBER *EATS"), "Uber Eats")
        XCTAssertEqual(brand("Uber *Trip"), "Uber")
        XCTAssertEqual(brand("Bolt Food"), "Bolt Food")
        XCTAssertEqual(brand("Bolt"), "Bolt")
    }

    func testWholeWordsOnly() {
        XCTAssertNil(brand("Sparkasse"))
        XCTAssertNil(brand("Benetton"))
        XCTAssertNil(brand("Google Play"))
        XCTAssertNil(brand("Gemini Advanced"))
        XCTAssertNil(brand("Costa Brava Bistro"))
        XCTAssertNil(brand("Lot nad Tatrami"))
        XCTAssertNil(brand("Some Unknown Shop Ltd"))
        XCTAssertNil(brand(""))
        XCTAssertNil(brand(nil))
    }

    func testEachChainHasADefaultCategory() {
        XCTAssertEqual(MerchantBrand.match("Lidl")?.category, .groceries)
        XCTAssertEqual(MerchantBrand.match("Wolt")?.category, .dining)
        XCTAssertEqual(MerchantBrand.match("Orlen")?.category, .transport)
        XCTAssertEqual(MerchantBrand.match("Rossmann")?.category, .health)
        XCTAssertEqual(MerchantBrand.match("Allegro")?.category, .shopping)
        XCTAssertEqual(MerchantBrand.match("Ryanair")?.category, .travel)
        XCTAssertEqual(MerchantBrand.match("Orange Polska")?.category, .utilities)
    }

    func testTheListIsWellFormed() {
        let names = MerchantBrand.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "Duplicate chain names")
        XCTAssertGreaterThanOrEqual(names.count, 100)
        for brand in MerchantBrand.all {
            XCTAssertFalse(brand.patterns.isEmpty, brand.name)
            XCTAssertFalse(brand.monogram.isEmpty, brand.name)
            XCTAssertNotNil(Color(hex: brand.colorHex), brand.name)
            XCTAssertNotNil(Color(hex: brand.textHex), brand.name)
            // Every pattern finds its own chain, so no earlier chain shadows it.
            for pattern in brand.patterns {
                XCTAssertEqual(MerchantBrand.match(pattern)?.name, brand.name, "\(brand.name): \(pattern)")
            }
        }
    }

    // MARK: Where the list sits in the guess

    func testChainsComeBeforeGenericWords() {
        // A chain's category wins over a generic word in the same name ("kawiarnia" is dining).
        XCTAssertEqual(MerchantCategory.guess(for: "Pizzeria Roma"), .dining)
        XCTAssertEqual(MerchantCategory.guess(for: "Hotel Mercure"), .travel)
        XCTAssertEqual(MerchantCategory.guess(for: "Shell parking"), .transport)
        XCTAssertEqual(MerchantCategory.guess(for: "Rossmann"), .health)
        XCTAssertEqual(MerchantCategory.guess(for: "Kawiarnia Empik"), .shopping)
    }

    func testAWalletPaymentGetsTheChainsName() throws {
        let payment = try WalletPayment.make(amount: 5, currencyCode: "PLN", merchant: "LIDL SP. Z O.O. WARSZAWA 123", category: nil, paidAt: Date())
        XCTAssertEqual(payment.merchant, "Lidl")
        XCTAssertEqual(payment.category, .groceries)

        let unknown = try WalletPayment.make(amount: 5, currencyCode: "PLN", merchant: "Kwiaciarnia Róża", category: nil, paidAt: Date())
        XCTAssertEqual(unknown.merchant, "Kwiaciarnia Róża")
    }
}
