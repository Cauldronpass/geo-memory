import SwiftUI
import MapKit
import CoreLocation
import PhotosUI

// MARK: - Sheet routing

private enum DiscoverSheet: Identifiable {
    case tracePlace(Place)
    case poiItem(GooglePlace)

    var id: String {
        switch self {
        case .tracePlace(let p): return "place-\(p.id)"
        case .poiItem(let g):    return "poi-\(g.id)"
        }
    }
}

// MARK: - DiscoverView

struct DiscoverView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager

    @State private var searchText = ""
    @State private var searchResults: [GooglePlace] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var selectedResult: GooglePlace? = nil
    @State private var selectedMapFeature: MapFeature? = nil
    @State private var activeSheet: DiscoverSheet? = nil
    @State private var resultsExpanded = true
    @State private var mapPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @FocusState private var searchFocused: Bool
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    // Filters
    @State private var showPinnedOnly = false
    @State private var myPlacesOnly = false
    @State private var selectedCategory: String? = nil
    @State private var selectedTag: String? = nil

    private var hasActiveFilters: Bool {
        showPinnedOnly || myPlacesOnly || selectedCategory != nil || selectedTag != nil
    }

    private var availableCategories: [String] {
        Array(Set(notion.places.filter { !$0.category.isEmpty }.map { $0.category })).sorted()
    }

    private var availableTags: [String] {
        Array(Set(notion.places.flatMap { $0.tags })).sorted()
    }

    private var tracePlaces: [Place] {
        notion.places
            .filter { $0.status != "Archived" }
            .filter { !showPinnedOnly || $0.flagged }
            .filter { selectedCategory == nil || $0.category == selectedCategory }
            .filter { selectedTag == nil || $0.tags.contains(selectedTag!) }
            .filter {
                guard myPlacesOnly, !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
                let q = searchText.lowercased()
                return $0.name.lowercased().contains(q) || $0.category.lowercased().contains(q)
            }
    }

    // Local database places matching the current search text — updated on every keystroke.
    private var matchingLocalPlaces: [Place] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let filtered = notion.places
            .filter { $0.status != "Archived" }
            .filter { !showPinnedOnly || $0.flagged }
            .filter { selectedCategory == nil || $0.category == selectedCategory }
            .filter { selectedTag == nil || $0.tags.contains(selectedTag!) }
            .filter { place in
                place.name.lowercased().contains(q) ||
                place.city.lowercased().contains(q) ||
                place.address.lowercased().contains(q) ||
                place.tags.contains { $0.lowercased().contains(q) } ||
                (place.notes?.lowercased().contains(q) ?? false)
            }
        // Sort by distance when location is available; fall back to alphabetical
        if let userLoc = locationManager.location {
            return filtered.sorted {
                let d0 = userLoc.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                let d1 = userLoc.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
                return d0 < d1
            }
        }
        return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Google results — hidden when Saved filter is active, and deduplicated against local matches.
    private var filteredSearchResults: [GooglePlace] {
        guard !myPlacesOnly else { return [] }
        return searchResults.filter { !isInDatabase($0) }
    }

    private var totalResultCount: Int { matchingLocalPlaces.count + filteredSearchResults.count }

    /// Returns the Google result from the current search that matches a local Place, if any.
    private func matchingGoogleResult(for place: Place) -> GooglePlace? {
        // Prefer Google Place ID match
        if let gpid = place.googlePlaceID,
           let match = searchResults.first(where: { $0.id == gpid }) {
            return match
        }
        // Fallback: same name + overlapping address city
        return searchResults.first {
            $0.name.lowercased() == place.name.lowercased() &&
            $0.formattedAddress.lowercased().contains(place.city.lowercased())
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // MARK: Map
            Map(position: $mapPosition, selection: $selectedMapFeature) {
                ForEach(tracePlaces) { place in
                    Annotation(place.name, coordinate: place.coordinate) {
                        Button { activeSheet = .tracePlace(place) } label: {
                            PlacePin(place: place)
                        }
                    }
                }

                ForEach(filteredSearchResults) { item in
                    let inDB = isInDatabase(item)
                    Annotation(item.name, coordinate: item.coordinate) {
                        Button {
                            selectedResult = item
                            withAnimation(.spring(response: 0.3)) { resultsExpanded = true }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(inDB ? Color.yellow : Color.blue)
                                    .frame(width: 28, height: 28)
                                Image(systemName: inDB ? "star.fill" : "mappin")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white)
                            }
                            .shadow(radius: 3)
                        }
                    }
                }

                UserAnnotation()
            }
            .mapStyle(.standard)
            .ignoresSafeArea(edges: .bottom)
            .onChange(of: selectedResult) { _, new in
                if let new {
                    withAnimation {
                        mapPosition = .region(MKCoordinateRegion(
                            center: new.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
                        ))
                    }
                }
            }
            .onChange(of: selectedMapFeature) { _, feature in
                guard let feature else { return }
                Task {
                    let results = try? await GooglePlacesService.shared.nearbySearch(
                        coordinate: feature.coordinate,
                        query: feature.title ?? "point of interest"
                    )
                    let place = results?.first ?? GooglePlace(
                        id: UUID().uuidString,
                        name: feature.title ?? "Unknown",
                        formattedAddress: "",
                        latitude: feature.coordinate.latitude,
                        longitude: feature.coordinate.longitude,
                        phone: nil, website: nil, rating: nil,
                        ratingCount: nil, primaryType: nil, openNow: nil,
                        weekdayDescriptions: []
                    )
                    await MainActor.run {
                        activeSheet = .poiItem(place)
                        selectedMapFeature = nil
                    }
                }
            }

            // MARK: Search bar + filters
            VStack(spacing: 8) {
                DrawerButtons()

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        if isSearching {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        }
                        TextField("Restaurants, bars, museums...", text: $searchText)
                            .focused($searchFocused)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit {
                                Task { await performSearch() }
                                searchFocused = false
                            }
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                searchResults = []
                                hasSearched = false
                                selectedResult = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                    if !searchText.isEmpty && !isSearching {
                        Button("Search") {
                            Task { await performSearch() }
                            searchFocused = false
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 16)
                .onChange(of: searchText) { _, newValue in
                    // Cancel any pending debounce
                    searchDebounceTask?.cancel()
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !myPlacesOnly else {
                        if trimmed.isEmpty {
                            searchResults = []
                            hasSearched = false
                        }
                        return
                    }
                    // 0.6 s debounce — fires Google search as you type
                    searchDebounceTask = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled else { return }
                        await performSearch()
                    }
                }

                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        MapFilterChip(title: "Saved", systemImage: "star.fill", isActive: myPlacesOnly) {
                            myPlacesOnly.toggle()
                        }
                        MapFilterChip(title: "Pinned", systemImage: "pin.fill", isActive: showPinnedOnly) {
                            showPinnedOnly.toggle()
                        }
                        if !availableTags.isEmpty {
                            Menu {
                                Button("All Tags") { selectedTag = nil }
                                Divider()
                                ForEach(availableTags, id: \.self) { tag in Button(tag) { selectedTag = tag } }
                            } label: {
                                MapFilterChip(title: selectedTag ?? "Tag", systemImage: "tag",
                                              isActive: selectedTag != nil, showChevron: true) {}
                            }
                        }
                        Menu {
                            Button("All Types") { selectedCategory = nil }
                            Divider()
                            ForEach(availableCategories, id: \.self) { cat in Button(cat) { selectedCategory = cat } }
                        } label: {
                            MapFilterChip(title: selectedCategory ?? "Type", systemImage: "square.grid.2x2",
                                          isActive: selectedCategory != nil, showChevron: true) {}
                        }
                        if hasActiveFilters {
                            Button {
                                showPinnedOnly = false; myPlacesOnly = false
                                selectedCategory = nil; selectedTag = nil
                            } label: {
                                Text("Clear")
                                    .font(.subheadline)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(.regularMaterial)
                                    .foregroundStyle(.secondary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 12)

            // MARK: Results bottom sheet
            if hasSearched || !matchingLocalPlaces.isEmpty {
                VStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.spring(response: 0.3)) { resultsExpanded.toggle() }
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.4))
                                    .frame(width: 36, height: 4)
                                    .padding(.top, 8)
                                HStack {
                                    Text(totalResultCount == 0
                                         ? "No results"
                                         : "\(totalResultCount) place\(totalResultCount == 1 ? "" : "s") found")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Image(systemName: resultsExpanded ? "chevron.down" : "chevron.up")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16).padding(.bottom, 8)
                            }
                        }
                        .buttonStyle(.plain)

                        if resultsExpanded {
                            Divider()
                            if totalResultCount == 0 {
                                Text("No matching places")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                            } else {
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        LazyVStack(spacing: 0) {
                                            // Saved (local database) results — always first
                                            if !matchingLocalPlaces.isEmpty {
                                                if !filteredSearchResults.isEmpty {
                                                    HStack {
                                                        Text("Saved")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundStyle(.secondary)
                                                        Spacer()
                                                    }
                                                    .padding(.horizontal, 16)
                                                    .padding(.top, 8)
                                                    .padding(.bottom, 2)
                                                }
                                                ForEach(matchingLocalPlaces) { place in
                                                    let gMatch = matchingGoogleResult(for: place)
                                                    Button {
                                                        activeSheet = .tracePlace(place)
                                                        withAnimation {
                                                            mapPosition = .region(MKCoordinateRegion(
                                                                center: place.coordinate,
                                                                span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
                                                            ))
                                                        }
                                                    } label: {
                                                        HStack(spacing: 12) {
                                                            Image(systemName: placeIcon(for: place.category))
                                                                .foregroundStyle(placeColor(for: place.category))
                                                                .frame(width: 20)
                                                            VStack(alignment: .leading, spacing: 2) {
                                                                HStack(spacing: 4) {
                                                                    Text(place.name)
                                                                        .font(.body)
                                                                        .foregroundStyle(.primary)
                                                                    Image(systemName: "star.fill")
                                                                        .foregroundStyle(.yellow)
                                                                        .font(.caption2)
                                                                }
                                                                // Base subtitle: category · city
                                                                let subtitle = [place.category, place.city]
                                                                    .filter { !$0.isEmpty }
                                                                    .joined(separator: " · ")
                                                                // Distance always from local coordinates
                                                                let distText: String? = {
                                                                    guard let userLoc = locationManager.location else { return nil }
                                                                    let meters = userLoc.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
                                                                    return String(format: "%.1f mi", meters / 1609.344)
                                                                }()
                                                                HStack(spacing: 6) {
                                                                    Text(subtitle)
                                                                        .font(.caption)
                                                                        .foregroundStyle(.secondary)
                                                                    if let d = distText {
                                                                        Text("· \(d)")
                                                                            .font(.caption)
                                                                            .foregroundStyle(.secondary)
                                                                    }
                                                                }
                                                                // Rating + open status from Google match when available
                                                                if let g = gMatch, g.rating != nil || g.openNow != nil {
                                                                    HStack(spacing: 6) {
                                                                        if let rating = g.rating {
                                                                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                                                                .font(.caption)
                                                                                .foregroundStyle(.orange)
                                                                        }
                                                                        if let open = g.openNow {
                                                                            Text(open ? "Open" : "Closed")
                                                                                .font(.caption)
                                                                                .foregroundStyle(open ? .green : .red)
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                            Spacer()
                                                            Image(systemName: "chevron.right")
                                                                .font(.caption2)
                                                                .foregroundStyle(.tertiary)
                                                        }
                                                        .padding(.vertical, 10)
                                                    }
                                                    .buttonStyle(.plain)
                                                    .padding(.horizontal, 16)
                                                    Divider().padding(.leading, 16)
                                                }
                                            }

                                            // Google Places results
                                            if !filteredSearchResults.isEmpty {
                                                if !matchingLocalPlaces.isEmpty {
                                                    HStack {
                                                        Text("Nearby")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundStyle(.secondary)
                                                        Spacer()
                                                    }
                                                    .padding(.horizontal, 16)
                                                    .padding(.top, 8)
                                                    .padding(.bottom, 2)
                                                }
                                                ForEach(filteredSearchResults) { item in
                                                    DiscoverResultRow(
                                                        place: item,
                                                        notion: notion,
                                                        locationManager: locationManager,
                                                        selectedItem: selectedResult,
                                                        onExpand: { coord in
                                                            withAnimation {
                                                                mapPosition = .region(MKCoordinateRegion(
                                                                    center: coord,
                                                                    span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
                                                                ))
                                                            }
                                                        }
                                                    )
                                                    .padding(.horizontal, 16)
                                                    .id(item.id)
                                                    Divider().padding(.leading, 16)
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 300)
                                    .onChange(of: selectedResult) { _, new in
                                        if let new {
                                            withAnimation { proxy.scrollTo(new.id, anchor: .top) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: -2)
                    .padding(.bottom, 83)
                }
            }

            // MARK: Location button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        withAnimation { mapPosition = .userLocation(fallback: .automatic) }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 18))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, hasSearched ? (resultsExpanded ? 420 : 140) : 100)
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tracePlace(let place):
                PlaceDetailView(place: place)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            case .poiItem(let item):
                POISaveSheet(place: item, notion: notion, locationManager: locationManager)
            }
        }
    }

    private func isInDatabase(_ place: GooglePlace) -> Bool {
        // Prefer Google Place ID match — exact and unambiguous.
        if notion.places.contains(where: { $0.googlePlaceID == place.id }) {
            return true
        }
        // Name-only fallback: only match if no Google Place ID is stored on the local record
        // (i.e. a manually created place that was never enriched). Requires name + city to agree.
        return notion.places.contains {
            $0.googlePlaceID == nil &&
            $0.name.lowercased() == place.name.lowercased() &&
            !place.formattedAddress.isEmpty &&
            place.formattedAddress.lowercased().contains($0.city.lowercased())
        }
    }

    private func performSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        hasSearched = true
        searchResults = []
        selectedResult = nil

        do {
            let results = try await GooglePlacesService.shared.textSearch(
                query: searchText,
                coordinate: locationManager.location?.coordinate
            )
            if let userLoc = locationManager.location {
                searchResults = results.sorted {
                    let d1 = CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: userLoc)
                    let d2 = CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: userLoc)
                    return d1 < d2
                }
            } else {
                searchResults = results
            }
            zoomToFit(searchResults)
            resultsExpanded = true
        } catch {
            searchResults = []
        }
        isSearching = false
    }

    private func zoomToFit(_ places: [GooglePlace]) {
        guard !places.isEmpty else { return }
        if places.count == 1 {
            withAnimation {
                mapPosition = .region(MKCoordinateRegion(
                    center: places[0].coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
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
                    latitudeDelta: (lats.max()! - lats.min()!) * 1.5 + 0.01,
                    longitudeDelta: (lons.max()! - lons.min()!) * 1.5 + 0.01
                )
            ))
        }
    }
}

// MARK: - POI Save Sheet

private struct POISaveSheet: View {
    let place: GooglePlace
    let notion: NotionService
    let locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DiscoverResultRow(
                    place: place,
                    notion: notion,
                    locationManager: locationManager,
                    startExpanded: true
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - DiscoverResultRow

private let discoverCategories = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                   "Attraction", "Venue", "House", "Fitness",
                                   "Office", "Airport", "Medical", "Park", "Grocery"]

struct DiscoverResultRow: View {
    let place: GooglePlace
    let notion: NotionService
    let locationManager: LocationManager
    var selectedItem: GooglePlace? = nil
    var startExpanded: Bool = false
    var onSaved: (() -> Void)? = nil
    var onExpand: ((CLLocationCoordinate2D) -> Void)? = nil

    @State private var expanded = false
    @State private var showingExistingPlace = false
    @State private var matchedPlaceID: String? = nil
    @State private var customName: String = ""
    @State private var category = "Restaurant"
    @State private var status = "Visited"
    @State private var visitDate = Date()
    @State private var pinPlace = false
    @State private var placeNotes = ""
    @State private var checkInRating: Int? = nil
    @State private var isSaving = false
    @State private var saved = false
    @State private var checkedIn = false
    @State private var saveError: String? = nil

    // Photo
    @State private var discoverPhoto: UIImage? = nil
    @State private var showingPhotoOptions = false
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    var isInDatabase: Bool { matchedPlaceID != nil }

    var savedPlace: Place? {
        guard let id = matchedPlaceID else { return nil }
        return notion.places.first { $0.id == id }
    }

    var distanceString: String? {
        guard let userLoc = locationManager.location else { return nil }
        let placeLoc = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let meters = userLoc.distance(from: placeLoc)
        let miles = meters / 1609.34
        return miles < 0.1
            ? "\(Int(meters * 3.281))ft"
            : String(format: "%.1f mi", miles)
    }

    var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row header
            Button {
                if isInDatabase {
                    if let coord = place.coordinate as CLLocationCoordinate2D? { onExpand?(coord) }
                    showingExistingPlace = true
                } else if !saved {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    if !expanded { onExpand?(place.coordinate) }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(customName.isEmpty ? place.name : customName)
                                .font(.body).foregroundStyle(.primary)
                            if isInDatabase || saved {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                            }
                            if (isInDatabase && savedPlace?.flagged == true) || (saved && pinPlace) {
                                Image(systemName: "pin.fill").foregroundStyle(.orange).font(.caption)
                            }
                        }
                        HStack(spacing: 6) {
                            if !place.streetAddress.isEmpty || !place.city.isEmpty {
                                let addr = [place.streetAddress, place.city]
                                    .filter { !$0.isEmpty }.joined(separator: ", ")
                                Text(addr).font(.caption).foregroundStyle(.secondary)
                            }
                            if let dist = distanceString {
                                Text("· \(dist)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 6) {
                            if let rating = place.rating {
                                Text("★ \(String(format: "%.1f", rating))")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if let openNow = place.openNow {
                                Text(openNow ? "Open" : "Closed")
                                    .font(.caption)
                                    .foregroundStyle(openNow ? .green : .red)
                            }
                        }
                    }
                    Spacer()
                    if saved {
                        Text(checkedIn ? "Checked in!" : "Saved!")
                            .font(.caption).foregroundStyle(.green)
                    } else if isInDatabase {
                        HStack(spacing: 4) {
                            Text("In Trace").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    } else {
                        Image(systemName: expanded ? "chevron.up.circle" : "plus.circle")
                            .foregroundStyle(.blue).font(.title3)
                    }
                }
            }
            .buttonStyle(.plain)

            // Quick-action bar + hours (always shown when expanded, even without saving)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Action buttons
                    HStack(spacing: 10) {
                        // Directions
                        Button {
                            let url = URL(string: "maps.apple.com/?daddr=\(place.latitude),\(place.longitude)&dirflg=d")!
                            UIApplication.shared.open(url)
                        } label: {
                            Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)

                        // Call
                        if let phone = place.phone,
                           let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label("Call", systemImage: "phone.fill")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                        }

                        // Website
                        if let websiteString = place.website, let url = URL(string: websiteString) {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label("Website", systemImage: "globe")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(.purple)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Phone number (tappable)
                    if let phone = place.phone {
                        HStack(spacing: 6) {
                            Image(systemName: "phone").font(.caption).foregroundStyle(.secondary)
                            Text(phone).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // Today's hours
                    if let hours = place.todayHours {
                        HStack(spacing: 6) {
                            Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                            Text("Today: \(hours)").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // Full week hours (collapsed)
                    if !place.weekdayDescriptions.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(place.weekdayDescriptions, id: \.self) { line in
                                    Text(line).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("Hours").font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 4)
            }

            // Expanded save form
            if expanded && !isInDatabase && !saved {
                VStack(spacing: 12) {
                    TextField("Name", text: $customName)
                        .font(.subheadline).padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text("Category").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Category", selection: $category) {
                            ForEach(discoverCategories, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }

                    Picker("Status", selection: $status) {
                        Text("Visited").tag("Visited")
                        Text("Want to Visit").tag("Want to Visit")
                    }
                    .pickerStyle(.segmented)

                    if status == "Visited" {
                        DatePicker("Date visited", selection: $visitDate, in: ...Date(), displayedComponents: .date)
                            .font(.subheadline)
                    }

                    Toggle(isOn: $pinPlace) {
                        Label("Pin this place", systemImage: "pin").font(.subheadline)
                    }
                    .tint(.orange)

                    TextField("Notes (optional)", text: $placeNotes, axis: .vertical)
                        .lineLimit(2...4).font(.subheadline).padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                    if status == "Visited" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Rate it (optional)").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                ForEach(1...7, id: \.self) { star in
                                    Button {
                                        checkInRating = checkInRating == star ? nil : star
                                    } label: {
                                        Image(systemName: star <= (checkInRating ?? 0) ? "star.fill" : "star")
                                            .font(.title3)
                                            .foregroundStyle(star <= (checkInRating ?? 0) ? .yellow : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer()
                                if checkInRating != nil {
                                    Button("Clear") { checkInRating = nil }
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    if let img = discoverPhoto {
                        HStack(spacing: 10) {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Photo added").font(.subheadline)
                                Text(status == "Visited" ? "Will be attached to your visit" : "Will be saved to this place")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Change") { showingPhotoOptions = true }
                                .font(.caption).foregroundStyle(.blue)
                        }
                    } else {
                        HStack {
                            Button { showingPhotoOptions = true } label: {
                                Label("Add Photo", systemImage: "camera").font(.subheadline)
                            }
                            .buttonStyle(.plain).foregroundStyle(.blue)
                            Spacer()
                            Text(status == "Visited" ? "Goes to your visit" : "Goes to this place")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }

                    if let err = saveError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    Button {
                        Task { await savePlace() }
                    } label: {
                        if isSaving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Save to Trace").frame(maxWidth: .infinity).bold()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            if customName.isEmpty { customName = place.name }
            if matchedPlaceID == nil {
                // Pass 1: Google Place ID match — exact, unambiguous
                matchedPlaceID = notion.places.first { $0.googlePlaceID == place.id }?.id
                // Pass 2: name + city fallback — only for local records with no Google Place ID
                if matchedPlaceID == nil {
                    let lower = place.name.lowercased()
                    let addrLower = place.formattedAddress.lowercased()
                    matchedPlaceID = notion.places.first {
                        $0.googlePlaceID == nil &&
                        $0.name.lowercased() == lower &&
                        !addrLower.isEmpty &&
                        addrLower.contains($0.city.lowercased())
                    }?.id
                }
            }
            if startExpanded && !isInDatabase && !saved { expanded = true }
        }
        .sheet(isPresented: $showingExistingPlace) {
            if let place = savedPlace {
                PlaceDetailView(place: place)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            }
        }
        .onChange(of: selectedItem) { _, new in
            if let new, new.id == place.id, !saved {
                withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
            }
        }
        .confirmationDialog("Add Photo", isPresented: $showingPhotoOptions) {
            if cameraAvailable { Button("Take Photo") { showingCamera = true } }
            Button("Choose from Library") { showingPhotoPicker = true }
            if discoverPhoto != nil {
                Button("Remove Photo", role: .destructive) { discoverPhoto = nil }
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraView(image: $discoverPhoto, isPresented: $showingCamera).ignoresSafeArea()
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    discoverPhoto = image
                }
                selectedPhotoItem = nil
            }
        }
    }

    private func savePlace() async {
        let name = customName.isEmpty ? place.name : customName
        isSaving = true
        saveError = nil
        do {
            let placeID = try await notion.addPlace(
                name: name,
                address: place.streetAddress,
                city: place.city,
                category: category,
                latitude: place.latitude,
                longitude: place.longitude,
                googlePlaceID: place.id,
                phone: place.phone,
                website: place.website,
                status: status,
                notes: placeNotes.isEmpty ? nil : placeNotes,
                flagged: pinPlace
            )
            await notion.fetchPlaces()

            if status == "Visited",
               let savedPlace = notion.places.first(where: { $0.id == placeID }) {
                let visitID = try await notion.checkIn(place: savedPlace, rating: checkInRating, notes: nil, date: visitDate)
                await notion.fetchVisits()
                if let photo = discoverPhoto { await uploadPhoto(photo, toPageID: visitID) }
                withAnimation { checkedIn = true; saved = true; expanded = false }
            } else {
                if let photo = discoverPhoto { await uploadPhoto(photo, toPageID: placeID) }
                withAnimation { saved = true; expanded = false }
            }
            onSaved?()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    private func uploadPhoto(_ image: UIImage, toPageID pageID: String) async {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        guard !B2Service.shared.keyID.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "place-\(formatter.string(from: Date())).jpg"
        do {
            let url = try await B2Service.shared.upload(image, filename: filename)
            try await notion.addPhotoToPage(pageID, photoURL: url)
        } catch { }
    }
}
