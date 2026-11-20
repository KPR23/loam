import SwiftUI

/// A chain Loam recognizes from a card payment's merchant name, from a list bundled with the app,
/// so it works offline and from a locked iPhone. A match gives the payment a clean name, a tile
/// to show beside it and a default category the member can still change.
///
/// Tiles are a monogram on the chain's color, not its logo: logos are trademarks Loam has no
/// license to ship.
struct MerchantBrand: Equatable, Sendable, Identifiable {
    /// Display name, also the expense title when a payment matches.
    let name: String
    /// Lowercased, accent-free phrases matched against whole words of the merchant name, in order.
    let patterns: [String]
    let category: ExpenseCategory
    /// Tile background, hex.
    let colorHex: String
    /// Monogram color on the tile, hex.
    let textHex: String
    /// One or two characters shown on the tile.
    let monogram: String

    var id: String { name }

    init(_ name: String, _ category: ExpenseCategory, _ patterns: [String], color: String, text: String = "FFFFFF", monogram: String? = nil) {
        self.name = name
        self.category = category
        self.patterns = patterns
        self.colorHex = color
        self.textHex = text
        self.monogram = monogram ?? String(name.prefix(1)).uppercased()
    }

    var color: Color { Color(hex: colorHex) ?? .gray }
    var textColor: Color { Color(hex: textHex) ?? .white }

    /// The chain whose pattern matches the most words of `merchant`; the list order breaks a tie.
    /// Case, diacritics, store numbers and legal suffixes ("Sp. z o.o.", "S.A.") don't matter.
    static func match(_ merchant: String?) -> MerchantBrand? {
        guard let merchant else { return nil }
        let name = normalizedWords(merchant)
        var best: (brand: Int, length: Int)?
        for (start, word) in name.enumerated() {
            for candidate in index[word] ?? [] {
                let end = start + candidate.words.count
                guard end <= name.count, Array(name[start..<end]) == candidate.words else { continue }
                if let current = best,
                   current.length > candidate.words.count
                    || (current.length == candidate.words.count && current.brand < candidate.brand) {
                    continue
                }
                best = (candidate.brand, candidate.words.count)
            }
        }
        return best.map { all[$0.brand] }
    }

    /// The merchant's lowercased, accent-free words without numbers or legal-form suffixes.
    static func normalizedWords(_ merchant: String) -> [String] {
        var words = MerchantCategory.words(merchant).filter { !$0.allSatisfy(\.isNumber) }
        for suffix in legalSuffixes {
            var start = 0
            while start + suffix.count <= words.count {
                if Array(words[start..<(start + suffix.count)]) == suffix {
                    words.removeSubrange(start..<(start + suffix.count))
                } else {
                    start += 1
                }
            }
        }
        return words
    }

    /// Longest first, so "sp z o o" goes before a shorter form could leave pieces behind.
    private static let legalSuffixes: [[String]] = [
        "spolka z ograniczona odpowiedzialnoscia", "spolka akcyjna", "spolka komandytowa", "spolka jawna",
        "sp z o o", "s k a", "sp k", "sp j", "sp zoo", "spzoo", "s a", "sa", "ltd", "gmbh", "inc", "llc", "plc", "bv",
    ]
    .map { $0.split(separator: " ").map(String.init) }
    .sorted { $0.count > $1.count }

    /// Each pattern under its first word, so matching is one lookup per word of the name.
    private static let index: [String: [(brand: Int, words: [String])]] = {
        var index: [String: [(brand: Int, words: [String])]] = [:]
        for (position, brand) in all.enumerated() {
            for pattern in brand.patterns {
                let words = MerchantCategory.words(pattern)
                guard let first = words.first else { continue }
                index[first, default: []].append((position, words))
            }
        }
        return index
    }()
}

extension MerchantBrand {
    /// The most common chains in Poland. A pattern should be a name nobody else uses; a short or
    /// common word needs a second word ("costa coffee", "lot polish") to be safe.
    static let all: [MerchantBrand] = [
        // Groceries
        MerchantBrand("Biedronka", .groceries, ["biedronka", "jeronimo martins"], color: "E30613", text: "FFE200"),
        MerchantBrand("Lidl", .groceries, ["lidl"], color: "0050AA", text: "FFF000"),
        MerchantBrand("Żabka", .groceries, ["zabka", "zabka nano"], color: "00843D", monogram: "Ż"),
        MerchantBrand("Kaufland", .groceries, ["kaufland"], color: "E10915"),
        MerchantBrand("Auchan", .groceries, ["auchan"], color: "E2001A"),
        MerchantBrand("Carrefour", .groceries, ["carrefour"], color: "1E4FA0"),
        MerchantBrand("Netto", .groceries, ["netto"], color: "FFE500", text: "1A1A1A"),
        MerchantBrand("Dino", .groceries, ["dino", "dino polska"], color: "D2161E"),
        MerchantBrand("Aldi", .groceries, ["aldi"], color: "00549F", text: "FFFFFF"),
        MerchantBrand("Stokrotka", .groceries, ["stokrotka"], color: "009A44"),
        MerchantBrand("Lewiatan", .groceries, ["lewiatan"], color: "E30613"),
        MerchantBrand("Polomarket", .groceries, ["polomarket", "polo market"], color: "E2231A"),
        MerchantBrand("Intermarché", .groceries, ["intermarche"], color: "D7001E"),
        MerchantBrand("Spar", .groceries, ["spar", "eurospar"], color: "00843D"),
        MerchantBrand("Delikatesy Centrum", .groceries, ["delikatesy centrum"], color: "E30613", monogram: "DC"),
        MerchantBrand("Freshmarket", .groceries, ["freshmarket", "fresh market"], color: "6DB33F"),
        MerchantBrand("Topaz", .groceries, ["topaz"], color: "E30613"),
        MerchantBrand("Groszek", .groceries, ["groszek"], color: "4CAF50"),
        MerchantBrand("Mila", .groceries, ["supermarket mila", "mila sklep"], color: "E4032E"),
        MerchantBrand("Frisco", .groceries, ["frisco"], color: "7AB800"),
        MerchantBrand("E.Leclerc", .groceries, ["leclerc"], color: "0067B1", monogram: "E"),
        MerchantBrand("Selgros", .groceries, ["selgros"], color: "D52B1E"),
        MerchantBrand("Makro", .groceries, ["makro"], color: "003B7E", text: "FFE500"),
        MerchantBrand("Rossmann", .health, ["rossmann"], color: "C3002F"),
        MerchantBrand("Hebe", .health, ["hebe"], color: "E5007E"),
        MerchantBrand("Super-Pharm", .health, ["super pharm", "superpharm"], color: "00205B", monogram: "SP"),

        // Dining and delivery. "Uber Eats" outranks "Uber" because it matches more words.
        MerchantBrand("Uber Eats", .dining, ["uber eats", "ubereats"], color: "06C167", text: "000000", monogram: "UE"),
        MerchantBrand("Wolt", .dining, ["wolt"], color: "009DE0"),
        MerchantBrand("Glovo", .dining, ["glovo"], color: "FFC244", text: "1A1A1A"),
        MerchantBrand("Pyszne.pl", .dining, ["pyszne", "pyszne pl"], color: "FF8000"),
        MerchantBrand("Bolt Food", .dining, ["bolt food"], color: "34D186", text: "000000", monogram: "BF"),
        MerchantBrand("McDonald's", .dining, ["mcdonald", "mcdonalds", "mcdonald s"], color: "DA291C", text: "FFC72C", monogram: "M"),
        MerchantBrand("KFC", .dining, ["kfc"], color: "E4002B"),
        MerchantBrand("Burger King", .dining, ["burger king"], color: "D62300", text: "F5EBDC", monogram: "BK"),
        MerchantBrand("Starbucks", .dining, ["starbucks"], color: "00704A"),
        MerchantBrand("Costa Coffee", .dining, ["costa coffee"], color: "6D1F37"),
        MerchantBrand("Pizza Hut", .dining, ["pizza hut"], color: "EE3124", monogram: "PH"),
        MerchantBrand("Domino's", .dining, ["dominos", "domino s", "dominos pizza"], color: "006491"),
        MerchantBrand("Telepizza", .dining, ["telepizza"], color: "E2001A"),
        MerchantBrand("Subway", .dining, ["subway"], color: "008C15", text: "FFC600"),
        MerchantBrand("North Fish", .dining, ["north fish"], color: "00539F", monogram: "NF"),
        MerchantBrand("Sphinx", .dining, ["sphinx"], color: "7A1F2B"),
        MerchantBrand("Max Premium Burgers", .dining, ["max premium burgers", "max burgers"], color: "E30613", monogram: "MX"),
        MerchantBrand("Green Caffè Nero", .dining, ["caffe nero", "green caffe nero"], color: "1F3D2B", monogram: "N"),

        // Transport and fuel
        MerchantBrand("Orlen", .transport, ["orlen", "pkn orlen"], color: "E30613"),
        MerchantBrand("BP", .transport, ["bp", "bp polska"], color: "007F00", text: "FFE600"),
        MerchantBrand("Shell", .transport, ["shell"], color: "FFD500", text: "DD1D21"),
        MerchantBrand("Circle K", .transport, ["circle k", "circlek"], color: "EE2E24", monogram: "K"),
        MerchantBrand("Lotos", .transport, ["lotos"], color: "003E7E"),
        MerchantBrand("Moya", .transport, ["moya"], color: "E30613"),
        MerchantBrand("Amic", .transport, ["amic", "amic energy"], color: "00A3E0"),
        MerchantBrand("Uber", .transport, ["uber"], color: "000000"),
        MerchantBrand("Bolt", .transport, ["bolt", "bolt eu"], color: "34D186", text: "000000"),
        MerchantBrand("FreeNow", .transport, ["freenow", "free now"], color: "C7003B", monogram: "FN"),
        MerchantBrand("PKP Intercity", .transport, ["pkp intercity", "intercity"], color: "143C78", monogram: "IC"),
        MerchantBrand("Koleje Mazowieckie", .transport, ["koleje mazowieckie"], color: "009640", monogram: "KM"),
        MerchantBrand("Jakdojade", .transport, ["jakdojade"], color: "FF6A00"),
        MerchantBrand("SkyCash", .transport, ["skycash"], color: "0D2B52", monogram: "S"),
        MerchantBrand("Traficar", .transport, ["traficar"], color: "F7A600", text: "1A1A1A"),
        MerchantBrand("Panek", .transport, ["panek carsharing", "panek cs"], color: "8DC63F"),
        MerchantBrand("Lime", .transport, ["lime ride", "limebike"], color: "00DD00", text: "0B3D0B"),
        MerchantBrand("FlixBus", .transport, ["flixbus"], color: "73D700", text: "FFFFFF"),

        // Health
        MerchantBrand("Dr.Max", .health, ["dr max", "drmax"], color: "005CA9", monogram: "DM"),
        MerchantBrand("Apteka Gemini", .health, ["apteka gemini", "gemini apteka"], color: "00A0DF", monogram: "G"),
        MerchantBrand("Ziko Apteka", .health, ["ziko"], color: "E30613", monogram: "Z"),
        MerchantBrand("DOZ", .health, ["doz", "doz pl"], color: "00A651"),
        MerchantBrand("Lux Med", .health, ["lux med", "luxmed"], color: "00498C", monogram: "LM"),
        MerchantBrand("Medicover", .health, ["medicover"], color: "00A9A5"),
        MerchantBrand("Enel-Med", .health, ["enel med", "enelmed"], color: "E4032E", monogram: "E"),

        // Entertainment and subscriptions
        MerchantBrand("Netflix", .entertainment, ["netflix"], color: "000000", text: "E50914"),
        MerchantBrand("Spotify", .entertainment, ["spotify"], color: "1DB954", text: "000000"),
        MerchantBrand("Disney+", .entertainment, ["disney plus", "disneyplus"], color: "0E2B63"),
        MerchantBrand("Max", .entertainment, ["hbo max", "hbomax"], color: "002BE7", monogram: "M"),
        MerchantBrand("Multikino", .entertainment, ["multikino"], color: "E30613"),
        MerchantBrand("Cinema City", .entertainment, ["cinema city"], color: "E2001A", monogram: "CC"),
        MerchantBrand("Helios", .entertainment, ["helios"], color: "D7262B"),
        MerchantBrand("Steam", .entertainment, ["steam", "steampowered", "steamgames"], color: "171A21"),
        MerchantBrand("PlayStation", .entertainment, ["playstation", "playstation network"], color: "003791", monogram: "PS"),
        MerchantBrand("Xbox", .entertainment, ["xbox"], color: "107C10"),
        MerchantBrand("Eventim", .entertainment, ["eventim"], color: "002B5C"),

        // Travel
        MerchantBrand("Ryanair", .travel, ["ryanair"], color: "073590", text: "F1C933"),
        MerchantBrand("Wizz Air", .travel, ["wizz air", "wizzair", "wizz"], color: "C6007E", monogram: "W"),
        MerchantBrand("LOT", .travel, ["pll lot", "lot polish", "polskie linie lotnicze"], color: "11397E", monogram: "L"),
        MerchantBrand("Booking.com", .travel, ["booking com", "booking"], color: "003580", monogram: "B"),
        MerchantBrand("Airbnb", .travel, ["airbnb"], color: "FF5A5F"),

        // Bills
        MerchantBrand("Orange", .utilities, ["orange", "orange polska"], color: "FF7900", text: "000000"),
        MerchantBrand("T-Mobile", .utilities, ["t mobile", "tmobile"], color: "E20074", monogram: "T"),
        MerchantBrand("Play", .utilities, ["play pl", "p4", "play24"], color: "5B2C83", monogram: "P"),
        MerchantBrand("Plus", .utilities, ["plus pl", "polkomtel"], color: "2E9A47", monogram: "+"),
        MerchantBrand("PGE", .utilities, ["pge"], color: "003B7A"),
        MerchantBrand("Tauron", .utilities, ["tauron"], color: "E2007A"),
        MerchantBrand("Enea", .utilities, ["enea"], color: "0060A9"),
        MerchantBrand("Energa", .utilities, ["energa"], color: "0F2F6A"),
        MerchantBrand("PGNiG", .utilities, ["pgnig"], color: "0055A5", monogram: "PG"),
        MerchantBrand("E.ON", .utilities, ["e on", "eon"], color: "EA1C0A", monogram: "E"),
        MerchantBrand("Veolia", .utilities, ["veolia"], color: "E2001A"),
        MerchantBrand("Vectra", .utilities, ["vectra"], color: "E30613"),
        MerchantBrand("Netia", .utilities, ["netia"], color: "E4032E"),

        // Shopping
        MerchantBrand("Allegro", .shopping, ["allegro", "allegro pl"], color: "FF5A00"),
        MerchantBrand("Amazon", .shopping, ["amazon", "amzn"], color: "232F3E", text: "FF9900"),
        MerchantBrand("AliExpress", .shopping, ["aliexpress"], color: "E62E04", monogram: "AE"),
        MerchantBrand("Temu", .shopping, ["temu"], color: "FB7701"),
        MerchantBrand("Shein", .shopping, ["shein"], color: "000000"),
        MerchantBrand("Zalando", .shopping, ["zalando"], color: "FF6900"),
        MerchantBrand("Vinted", .shopping, ["vinted"], color: "007782"),
        MerchantBrand("OLX", .shopping, ["olx"], color: "002F34", text: "23E5DB"),
        MerchantBrand("Zara", .shopping, ["zara"], color: "000000"),
        MerchantBrand("Reserved", .shopping, ["reserved"], color: "000000"),
        MerchantBrand("Sinsay", .shopping, ["sinsay"], color: "E6007E"),
        MerchantBrand("H&M", .shopping, ["h m", "hm", "hennes mauritz"], color: "E50010", monogram: "H"),
        MerchantBrand("Pepco", .shopping, ["pepco"], color: "0072BC"),
        MerchantBrand("Action", .shopping, ["action"], color: "0055A5"),
        MerchantBrand("TK Maxx", .shopping, ["tk maxx", "tkmaxx"], color: "E2001A", monogram: "TK"),
        MerchantBrand("CCC", .shopping, ["ccc"], color: "E30613", monogram: "C"),
        MerchantBrand("Deichmann", .shopping, ["deichmann"], color: "009EE0"),
        MerchantBrand("4F", .shopping, ["4f"], color: "000000", monogram: "4F"),
        MerchantBrand("Decathlon", .shopping, ["decathlon"], color: "0082C3"),
        MerchantBrand("Smyk", .shopping, ["smyk"], color: "E30613"),
        MerchantBrand("Empik", .shopping, ["empik"], color: "E4032E"),
        MerchantBrand("Media Expert", .shopping, ["media expert", "mediaexpert"], color: "FFDD00", text: "1A1A1A", monogram: "ME"),
        MerchantBrand("MediaMarkt", .shopping, ["media markt", "mediamarkt"], color: "DF0000", monogram: "MM"),
        MerchantBrand("RTV Euro AGD", .shopping, ["rtv euro", "euro rtv", "euro net", "euro agd"], color: "00377B", text: "FFE500", monogram: "E"),
        MerchantBrand("x-kom", .shopping, ["x kom", "xkom"], color: "000000", text: "FFFFFF", monogram: "x"),
        MerchantBrand("Apple", .shopping, ["apple store", "apple com"], color: "1D1D1F", monogram: "A"),
        MerchantBrand("IKEA", .shopping, ["ikea"], color: "0058A3", text: "FFDA1A", monogram: "I"),
        MerchantBrand("Castorama", .shopping, ["castorama"], color: "0078D7"),
        MerchantBrand("Leroy Merlin", .shopping, ["leroy merlin"], color: "78BE20", monogram: "LM"),
        MerchantBrand("OBI", .shopping, ["obi"], color: "FF7E21", monogram: "O"),
        MerchantBrand("Jysk", .shopping, ["jysk"], color: "143C8C"),
        MerchantBrand("Douglas", .shopping, ["douglas"], color: "000000"),
        MerchantBrand("Sephora", .shopping, ["sephora"], color: "000000"),
        MerchantBrand("InPost", .shopping, ["inpost"], color: "FFCD00", text: "1A1A1A"),
    ]
}

extension ExpenseRecord {
    /// The chain this expense was paid at, from its title or else its place.
    var merchantBrand: MerchantBrand? {
        MerchantBrand.match(title) ?? MerchantBrand.match(location?.name)
    }
}

/// A chain's monogram on its color, in a circle.
struct MerchantBrandTile: View {
    let brand: MerchantBrand
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(brand.color)
            .overlay {
                Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
            .overlay {
                Text(brand.monogram)
                    .font(.system(size: size * (brand.monogram.count > 1 ? 0.36 : 0.46), weight: .bold, design: .rounded))
                    .foregroundStyle(brand.textColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(size * 0.1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
