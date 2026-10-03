import Foundation
import MapKit

/// Debounced Apple Maps place search for the location picker sheet.
@MainActor
final class PlaceSearchController: NSObject, ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            handleQueryChange()
        }
    }

    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var mapItems: [MKMapItem] = []
    @Published private(set) var isSearching = false
    @Published var selectedLocation: ExpenseLocation?
    /// Region the map should focus on; `nil` means keep / use automatic framing.
    @Published private(set) var focusedRegion: MKCoordinateRegion?
    /// Bumps whenever `focusedRegion` should be applied to the map camera.
    @Published private(set) var focusGeneration = 0

    private let completer = MKLocalSearchCompleter()
    private var debounceTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var regionSearchTask: Task<Void, Never>?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func clearSelection() {
        selectedLocation = nil
        query = ""
        suggestions = []
        mapItems = []
        isSearching = false
        completer.queryFragment = ""
        focusedRegion = nil
        focusGeneration += 1
    }

    func apply(_ location: ExpenseLocation?) {
        selectedLocation = location
        query = location?.name ?? ""
        suggestions = []
        mapItems = []
        if let location {
            focusedRegion = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 600,
                longitudinalMeters: 600
            )
        } else {
            focusedRegion = nil
        }
        focusGeneration += 1
    }

    func selectSuggestion(_ completion: MKLocalSearchCompletion) {
        suggestions = []
        isSearching = true
        query = completion.title
        resolveTask?.cancel()
        resolveTask = Task {
            defer { isSearching = false }
            do {
                let items = try await Self.search(completion: completion)
                guard !Task.isCancelled else { return }
                mapItems = items
                if let first = items.first {
                    selectMapItem(first, fallbackTitle: completion.title, fallbackSubtitle: completion.subtitle)
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func selectMapItem(
        _ item: MKMapItem,
        fallbackTitle: String? = nil,
        fallbackSubtitle: String? = nil
    ) {
        let location = ExpenseLocation(
            mapItem: item,
            fallbackTitle: fallbackTitle,
            fallbackSubtitle: fallbackSubtitle
        )
        selectedLocation = location
        query = location.name
        suggestions = []
        focusedRegion = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 500,
            longitudinalMeters: 500
        )
        focusGeneration += 1
    }

    /// Runs a full text search and drops pins for matching places (better for “Lidl”, restaurant names).
    func searchPlaces() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        suggestions = []
        isSearching = true
        regionSearchTask?.cancel()
        regionSearchTask = Task {
            defer { isSearching = false }
            do {
                let items = try await Self.search(query: trimmed)
                guard !Task.isCancelled else { return }
                mapItems = items
                if let first = items.first {
                    selectMapItem(first)
                } else if selectedLocation == nil {
                    // Keep camera as-is when nothing matched.
                }
            } catch {
                guard !Task.isCancelled else { return }
                mapItems = []
            }
        }
    }

    private func handleQueryChange() {
        debounceTask?.cancel()
        resolveTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            suggestions = []
            mapItems = []
            isSearching = false
            completer.queryFragment = ""
            if selectedLocation != nil {
                selectedLocation = nil
            }
            return
        }

        if let selected = selectedLocation, selected.name == trimmed {
            suggestions = []
            isSearching = false
            return
        }

        if selectedLocation != nil {
            selectedLocation = nil
        }

        isSearching = true
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            completer.queryFragment = trimmed
        }
    }

    nonisolated static func search(completion: MKLocalSearchCompletion) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
    }

    nonisolated static func search(query: String) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return Array(response.mapItems.prefix(12))
    }
}

extension ExpenseLocation {
    init(mapItem: MKMapItem, fallbackTitle: String? = nil, fallbackSubtitle: String? = nil) {
        let trimmedName = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (trimmedName?.isEmpty == false ? trimmedName! : nil)
            ?? fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Place"

        let placemarkBits = [
            mapItem.placemark.subThoroughfare,
            mapItem.placemark.thoroughfare,
            mapItem.placemark.locality
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        let placemarkAddress = placemarkBits.isEmpty ? nil : placemarkBits.joined(separator: ", ")
        let subtitle = fallbackSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedAddress = [placemarkAddress, subtitle]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty, value != resolvedName else { return nil }
                return value
            }
            .first

        name = resolvedName
        address = resolvedAddress
        latitude = mapItem.placemark.coordinate.latitude
        longitude = mapItem.placemark.coordinate.longitude
        if #available(iOS 18.0, *) {
            mapItemIdentifier = mapItem.identifier?.rawValue
        } else {
            mapItemIdentifier = nil
        }
    }
}

extension PlaceSearchController: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            suggestions = Array(completer.results.prefix(8))
            isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            suggestions = []
            isSearching = false
        }
    }
}
