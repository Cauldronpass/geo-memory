import SwiftUI
import MapKit

struct MapView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @State private var selectedPlace: Place? = nil
    @State private var showPinnedOnly = false
    @State private var selectedCategory: String? = nil
    @State private var selectedTag: String? = nil
    @State private var searchText = ""
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var currentRegion: MKCoordinateRegion? = nil
    @State private var resultsExpanded = true
    @FocusState private var searchFocused: Bool

    private var availableCategories: [String] {
        Array(Set(notionService.places.compactMap {
            $0.category.isEmpty ? nil : $0.category
        })).sorted()
    }

    private var availableTags: [String] {
        Array(Set(notionService.places.flatMap { $0.tags })).sorted()
    }

    private var filteredPlaces: [Place] {
        notionService.places
            .filter { $0.status != "Archived" }
            .filter { !showPinnedOnly || $0.flagged }
            .filter { selectedCategory == nil || $0.category == selectedCategory }
            .filter { selectedTag == nil || $0.tags.contains(selectedTag!) }
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.city.localizedCaseInsensitiveContains(searchText)
            }
    }

    private var isFiltering: Bool {
        !searchText.isEmpty || showPinnedOnly || selectedCategory != nil || selectedTag != nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $mapPosition) {
                ForEach(filteredPlaces) { place in
                    Annotation(place.name, coordinate: place.coordinate) {
                        Button { selectedPlace = place } label: {
                            PlacePin(place: place)
                        }
                    }
                }
                UserAnnotation()
            }
            .mapStyle(.standard)
            .ignoresSafeArea(edges: .bottom)
            .onMapCameraChange { context in
                currentRegion = context.region
            }
            .onChange(of: searchText) {
                if !searchText.isEmpty {
                    zoomToFit(filteredPlaces)
                    resultsExpanded = true
                }
            }
            .onChange(of: showPinnedOnly) {
                zoomToFit(filteredPlaces)
                resultsExpanded = true
            }
            .onChange(of: selectedCategory) {
                zoomToFit(filteredPlaces)
                resultsExpanded = true
            }
            .onChange(of: selectedTag) {
                zoomToFit(filteredPlaces)
                resultsExpanded = true
            }

            // Top overlay
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search places...", text: $searchText)
                        .focused($searchFocused)
                    if searchFocused {
                        Button("Done") { searchFocused = false }
                            .font(.subheadline)
                    } else if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)

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
                            MapFilterChip(title: selectedCategory ?? "Category", systemImage: "square.grid.2x2", isActive: selectedCategory != nil, showChevron: true) {}
                        }

                        if !availableTags.isEmpty {
                            Menu {
                                Button("All Tags") { selectedTag = nil }
                                Divider()
                                ForEach(availableTags, id: \.self) { tag in
                                    Button(tag) { selectedTag = tag }
                                }
                            } label: {
                                MapFilterChip(title: selectedTag ?? "Tag", systemImage: "tag", isActive: selectedTag != nil, showChevron: true) {}
                            }
                        }

                        if showPinnedOnly || selectedCategory != nil || selectedTag != nil {
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
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.top, 12)

            // Bottom results sheet
            if isFiltering {
                VStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                resultsExpanded.toggle()
                            }
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.4))
                                    .frame(width: 36, height: 4)
                                    .padding(.top, 8)
                                HStack {
                                    Text(filteredPlaces.isEmpty ? "No results" : "\(filteredPlaces.count) place\(filteredPlaces.count == 1 ? "" : "s")")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: resultsExpanded ? "chevron.down" : "chevron.up")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                            }
                        }

                        if resultsExpanded {
                            Divider()
                            if filteredPlaces.isEmpty {
                                Text("No matching places")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                            } else {
                                ScrollView {
                                    LazyVStack(spacing: 0) {
                                        ForEach(filteredPlaces) { place in
                                            Button {
                                                withAnimation {
                                                    mapPosition = .region(MKCoordinateRegion(
                                                        center: place.coordinate,
                                                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                                                    ))
                                                    resultsExpanded = false
                                                }
                                            } label: {
                                                HStack(spacing: 12) {
                                                    ZStack {
                                                        Circle()
                                                            .fill(place.flagged ? Color.yellow : placeColor(for: place.category))
                                                            .frame(width: 28, height: 28)
                                                        Image(systemName: placeIcon(for: place.category))
                                                            .font(.system(size: 12))
                                                            .foregroundStyle(.white)
                                                    }
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(place.name)
                                                            .font(.body)
                                                            .foregroundStyle(.primary)
                                                        Text(place.category.isEmpty ? place.city : "\(place.category) · \(place.city)")
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    Spacer()
                                                    Image(systemName: "mappin")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                            }
                                            .buttonStyle(.plain)
                                            Divider().padding(.leading, 56)
                                        }
                                    }
                                }
                                .frame(maxHeight: 260)
                            }
                        }
                    }
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: -2)
                    .padding(.bottom, 83)
                }
            }

            // Location button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        withAnimation {
                            mapPosition = .userLocation(fallback: .automatic)
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 18))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, isFiltering ? (resultsExpanded ? 360 : 120) : 100)
                }
            }
        }
        .sheet(item: $selectedPlace) { place in
            PlaceDetailView(place: place)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
    }

    private func zoomToFit(_ places: [Place]) {
        guard !places.isEmpty else { return }
        if places.count == 1 {
            mapPosition = .region(MKCoordinateRegion(
                center: places[0].coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
            return
        }
        let lats = places.map { $0.latitude }
        let lons = places.map { $0.longitude }
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        withAnimation {
            mapPosition = .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(
                    latitudeDelta: (lats.max()! - lats.min()!) * 1.4 + 0.01,
                    longitudeDelta: (lons.max()! - lons.min()!) * 1.4 + 0.01
                )
            ))
        }
    }
}

// MARK: - Filter chip

struct MapFilterChip: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    var showChevron: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
                if showChevron {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isActive ? Color.accentColor : Color(.systemBackground).opacity(0.95))
            .foregroundStyle(isActive ? .white : .primary)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
        }
    }
}
