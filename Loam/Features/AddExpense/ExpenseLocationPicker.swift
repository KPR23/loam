import SwiftUI
import MapKit

/// Form row that opens a map sheet for picking a store / restaurant via Apple Maps.
struct ExpenseLocationPicker: View {
    @Binding var location: ExpenseLocation?
    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(location?.name ?? "Location")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(location == nil ? .secondary : .primary)
                            .lineLimit(1)
                        if let subtitle = location?.displaySubtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if location == nil {
                            Text("Search on map")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(location == nil ? "Add location" : "Edit location")

            if location != nil {
                Button {
                    location = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear location")
            }
        }
        .sheet(isPresented: $isPresented) {
            PlacePickerSheet(location: $location)
        }
    }
}

private struct PlacePickerSheet: View {
    @Binding var location: ExpenseLocation?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearchController()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                mapLayer

                VStack(spacing: 0) {
                    searchChrome
                    if !search.suggestions.isEmpty {
                        suggestionsList
                    }
                    Spacer(minLength: 0)
                }
            }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        location = search.selectedLocation
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let selected = search.selectedLocation {
                    selectedBanner(selected)
                }
            }
        }
        .onAppear {
            search.apply(location)
            applyFocusedRegion()
            searchFocused = location == nil
        }
        .onChange(of: search.focusGeneration) { _, _ in
            applyFocusedRegion()
        }
    }

    private func applyFocusedRegion() {
        if let region = search.focusedRegion {
            cameraPosition = .region(region)
        } else {
            cameraPosition = .automatic
        }
    }

    private var mapLayer: some View {
        Map(position: $cameraPosition) {
            ForEach(Array(search.mapItems.enumerated()), id: \.offset) { _, item in
                let coordinate = item.placemark.coordinate
                let isSelected = search.selectedLocation.map {
                    abs($0.latitude - coordinate.latitude) < 0.00001
                        && abs($0.longitude - coordinate.longitude) < 0.00001
                } ?? false

                Annotation(item.name ?? "Place", coordinate: coordinate) {
                    Button {
                        search.selectMapItem(item)
                        searchFocused = false
                    } label: {
                        Image(systemName: isSelected ? "mappin.circle.fill" : "mappin.circle")
                            .font(.title)
                            .foregroundStyle(isSelected ? Color.accentColor : .red)
                            .shadow(radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }

            if search.mapItems.isEmpty, let selected = search.selectedLocation {
                Annotation(selected.name, coordinate: selected.coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                        .shadow(radius: 2, y: 1)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .all))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var searchChrome: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search places", text: $search.query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit {
                    search.searchPlaces()
                    searchFocused = false
                }

            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !search.query.isEmpty {
                Button {
                    search.clearSelection()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(search.suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    search.selectSuggestion(suggestion)
                    searchFocused = false
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        if !suggestion.subtitle.isEmpty {
                            Text(suggestion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if index < search.suggestions.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func selectedBanner(_ selected: ExpenseLocation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(selected.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                if let subtitle = selected.displaySubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.regularMaterial)
    }
}
