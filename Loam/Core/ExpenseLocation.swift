import Foundation
import CoreLocation

/// A place attached to an expense, typically resolved from Apple Maps search.
struct ExpenseLocation: Codable, Hashable, Sendable {
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    /// Stable Apple Maps place id when available (`MKMapItem.Identifier.rawValue`).
    var mapItemIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case name
        case address
        case latitude
        case longitude
        case mapItemIdentifier = "map_item_identifier"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displaySubtitle: String? {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
