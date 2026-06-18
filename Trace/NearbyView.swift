import SwiftUI
import CoreLocation

struct NearbyView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @State private var searchText = ""
    @State private var selectedPlace: Place? = nil
    @State private var showPinnedOnly = false
    @State private var selectedCategory: String? = nil
    @State private var selectedTag: String? = nil

    private var availableCategories: [String] {
        Array(Set(notionService.places
            .filter { !$0.category.isEmpty }
            .map { $0.category }
        )).sorted()
    }

    private var availableTags: [String] {
        Array(Set(notionService.places.flatMap { $0.tags })).sorted()
    }

    private var hasActiveFilters: Bool {
        showPinnedOnly || selectedCategory != nil || selectedTag != nil
    }

    var filteredPlaces: [Place] {
        notionService.places
            .filter {
                (searchText.isEmpty ||
                 $0.name.localizedCaseInsensitiveContains(searchText) ||
                 $0.category.localizedCaseInsensitiveContains(searchText))
                && (!showPinnedOnly || $0.flagged)
                && (selectedCategory == nil || $0.category == selectedCategory)
                && (selectedTag == nil || $0.tags.contains(selectedTag!))
            }
            .sorted { a, b in
                let distA = locationManager.distance(to: a) ?? .infinity
                let distB = locationManager.distance(to: b) ?? .infinity
                return distA < distB
            }
    }

    var recentPlaces: [Place] {
        guard searchText.isEmpty else { return [] }
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
            VStack(spacing: 0) {
                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        MapFilterChip(title: "Pinned", systemImage: "pin.fill", isActive: showPinnedOnly) {
                            showPinnedOnly.toggle()
                        }
                        Menu {
                            Button("All Categories") { selectedCategory = nil }
                            Divider()
                            ForEach(availableCategories, id: \.self) { cat in
                                Button(cat) { selectedCategory = cat }
                            }
                        } label: {
                            MapFilterChip(title: selectedCategory ?? "Category",
                                          systemImage: "square.grid.2x2",
                                          isActive: selectedCategory != nil,
                                          showChevron: true) {}
                        }
                        if !availableTags.isEmpty {
                            Menu {
                                Button("All Tags") { selectedTag = nil }
                                Divider()
                                ForEach(availableTags, id: \.self) { tag in
                                    Button(tag) { selectedTag = tag }
                                }
                            } label: {
                                MapFilterChip(title: selectedTag ?? "Tag",
                                              systemImage: "tag",
                                              isActive: selectedTag != nil,
                                              showChevron: true) {}
                            }
                        }
                        if hasActiveFilters {
                            Button {
                                showPinnedOnly = false
                                selectedCategory = nil
                                selectedTag = nil
                            } label: {
                                Text("Clear")
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Color(.systemBackground).opacity(0.9))
                                    .foregroundStyle(.secondary)
                                    .clipShape(Capsule())
                                    .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color(UIColor.systemGroupedBackground))

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
                            if !recentPlaces.isEmpty {
                                Section(header: HStack(alignment: .firstTextBaseline, spacing: 4) {
    Text("Recent")
    Text("(unaffected by filters)").font(.caption2).foregroundStyle(.secondary)
}) {
                                    ForEach(recentPlaces) { place in
                                        Button { selectedPlace = place } label: {
                                            NearbyPlaceRow(place: place)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            Section(searchText.isEmpty && !hasActiveFilters ? "" : "Results") {
                                ForEach(filteredPlaces) { place in
                                    Button { selectedPlace = place } label: {
                                        NearbyPlaceRow(place: place)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .searchable(text: $searchText, prompt: "Search places")
                        .refreshable {
                            await notionService.fetchPlaces()
                            await notionService.fetchVisits()
                        }
                    }
                }
            }
            .navigationTitle("Nearby")
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
