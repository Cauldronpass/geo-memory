import SwiftUI
import MapKit
import CoreLocation

struct AddCaptureView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var notes = ""
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var selectedPlace: Place? = nil
    @State private var selectedMapItem: MKMapItem? = nil
    @State private var isSaving = false
    @State private var showingPlacePicker = false

    var nearbyPlaces: [Place] {
        notion.places.sorted {
            let a = locationManager.distance(to: $0) ?? .infinity
            let b = locationManager.distance(to: $1) ?? .infinity
            return a < b
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Place section
                Section("Place") {
                    if let place = selectedPlace {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).font(.body)
                                Text(place.city).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Change") {
                                showingPlacePicker = true
                            }
                            .font(.caption)
                        }
                    } else {
                        Button {
                            showingPlacePicker = true
                        } label: {
                            HStack {
                                Text("Select a place")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption)
                            }
                        }
                    }

                    Button("Save without a place") {
                        selectedPlace = nil
                        selectedMapItem = nil
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Notes section
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("Add Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .disabled(notes.isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showingPlacePicker) {
                PlacePickerView(selectedPlace: $selectedPlace)
                    .environment(notion)
                    .environment(locationManager)
            }
        }
    }

    func save() {
        isSaving = true
        let coord = locationManager.location?.coordinate
        Task {
            try? await notion.saveCapture(
                notes: notes,
                placeID: selectedPlace?.id,
                placeName: selectedPlace?.name,
                lat: coord?.latitude,
                lon: coord?.longitude
            )
            isSaving = false
            dismiss()
        }
    }
}

// MARK: - Place Picker

struct PlacePickerView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedPlace: Place?

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false

    var nearbyPlaces: [Place] {
        notion.places.sorted {
            let a = locationManager.distance(to: $0) ?? .infinity
            let b = locationManager.distance(to: $1) ?? .infinity
            return a < b
        }
    }

    var filteredNearby: [Place] {
        if searchText.isEmpty { return Array(nearbyPlaces.prefix(10)) }
        return nearbyPlaces.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !filteredNearby.isEmpty {
                    Section("Your Places") {
                        ForEach(filteredNearby) { place in
                            Button {
                                selectedPlace = place
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name).foregroundStyle(.primary)
                                        HStack(spacing: 4) {
                                            Text(place.category).foregroundStyle(.secondary)
                                            Text("·").foregroundStyle(.secondary)
                                            Text(place.city).foregroundStyle(.secondary)
                                        }
                                        .font(.caption)
                                    }
                                    Spacer()
                                    if let dist = locationManager.formattedDistance(to: place) {
                                        Text(dist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                } else if !searchResults.isEmpty {
                    Section("Search Results") {
                        ForEach(searchResults, id: \.self) { item in
                            Button {
                                // Create a temporary Place from the map item
                                let coord = item.placemark.coordinate
                                let tempPlace = Place(
                                    id: UUID().uuidString,
                                    name: item.name ?? "Unknown",
                                    city: item.placemark.locality ?? "",
                                    address: [item.placemark.subThoroughfare,
                                              item.placemark.thoroughfare]
                                        .compactMap { $0 }.joined(separator: " "),
                                    category: "Restaurant",
                                    latitude: coord.latitude,
                                    longitude: coord.longitude,
                                    flagged: false,
                                    googlePlaceID: nil,
                                    googleMapsURL: nil,
                                    phone: nil,
                                    website: nil,
                                    hours: nil,
                                    status: "Visited",
                                    ratingExternal: nil,
                                    ratingPersonal: nil,
                                    visitCount: 0,
                                    lastVisited: nil,
                                    tags: [],
                                    aiSummary: nil
                                )
                                selectedPlace = tempPlace
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Unknown").foregroundStyle(.primary)
                                    Text(item.placemark.locality ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $searchText, prompt: "Search your places or nearby")
            .onChange(of: searchText) { _, newValue in
                if newValue.count > 2 {
                    performSearch(newValue)
                } else {
                    searchResults = []
                }
            }
        }
    }

    func performSearch(_ query: String) {
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coord = locationManager.location?.coordinate {
            request.region = MKCoordinateRegion(
                center: coord,
                latitudinalMeters: 10000,
                longitudinalMeters: 10000
            )
        }
        Task {
            let search = MKLocalSearch(request: request)
            let response = try? await search.start()
            searchResults = response?.mapItems ?? []
            isSearching = false
        }
    }
}
