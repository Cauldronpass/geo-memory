import SwiftUI
import CoreLocation

struct NearbyView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @State private var searchText = ""
    @State private var selectedPlace: Place? = nil

    var filteredPlaces: [Place] {
        let places = notionService.places
        let filtered = searchText.isEmpty ? places : places.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted { a, b in
            let distA = locationManager.distance(to: a) ?? .infinity
            let distB = locationManager.distance(to: b) ?? .infinity
            return distA < distB
        }
    }

    var recentPlaces: [Place] {
        let recentNames = Array(
            notionService.visits
                .sorted { $0.date > $1.date }
                .map { $0.placeName }
                .reduce(into: [String]()) { result, name in
                    if !result.contains(name) { result.append(name) }
                }
                .prefix(5)
        )
        return recentNames.compactMap { name in
            notionService.places.first { $0.name == name }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if locationManager.authorizationStatus == .notDetermined {
                    VStack(spacing: 16) {
                        Image(systemName: "location.circle")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text("Location access lets Trace show places near you.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Allow Location Access") {
                            locationManager.requestPermission()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    List {
                        if searchText.isEmpty && !recentPlaces.isEmpty {
                            Section("Recent") {
                                ForEach(recentPlaces) { place in
                                    Button {
                                        selectedPlace = place
                                    } label: {
                                        NearbyPlaceRow(place: place)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Section(searchText.isEmpty ? "" : "Results") {
                            ForEach(filteredPlaces) { place in
                                Button {
                                    selectedPlace = place
                                } label: {
                                    NearbyPlaceRow(place: place)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nearby")
            .searchable(text: $searchText, prompt: "Search places")
            .refreshable {
                await notionService.fetchPlaces()
                await notionService.fetchVisits()
            }
        }
        .sheet(item: $selectedPlace) { place in
            PlaceDetailView(place: place)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
    }
}

struct NearbyPlaceRow: View {
    let place: Place
    @Environment(LocationManager.self) private var locationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(place.name)
                    .font(.headline)
                if place.flagged {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
                .font(.headline)
            HStack {
                Text(place.category.isEmpty ? place.city : "\(place.category) · \(place.city)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(locationManager.formattedDistance(to: place) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
