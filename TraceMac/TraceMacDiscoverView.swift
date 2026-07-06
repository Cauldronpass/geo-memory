// TraceMacDiscoverView.swift
// Map-based place research tool for Mac — Phase 1 (see Discover-Mac-Workplan.md).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Phase 1 scope: map with saved places + live Google search results, a
// browsable list synced to the map, and a basic "add to my places" flow.
// Filters, reviews, directions-from-origin, and lists are Phase 2/3 —
// see Discover-Mac-Workplan.md for the full plan.

import SwiftUI
import MapKit

// MARK: - Selection wrapper (saved place vs. live search result)

private enum DiscoverPin: Identifiable, Hashable {
    case saved(Place)
    case search(GooglePlace)

    var id: String {
        switch self {
        case .saved(let p):  return "saved-\(p.id)"
        case .search(let g): return "search-\(g.id)"
        }
    }

    static func == (lhs: DiscoverPin, rhs: DiscoverPin) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Category guess (Google primaryType → our fixed category set)
// Best-effort only — the add-flow's category picker lets David correct it
// before saving, so this doesn't need to be exhaustive.

private func guessCategory(_ primaryType: String?) -> String {
    guard let t = primaryType?.lowercased() else { return "Attraction" }
    if t.contains("restaurant") || t.contains("food")            { return "Restaurant" }
    if t.contains("bar") || t.contains("night_club") || t.contains("pub") { return "Bar" }
    if t.contains("cafe") || t.contains("coffee")                { return "Cafe" }
    if t.contains("lodging") || t.contains("hotel")               { return "Hotel" }
    if t.contains("store") || t.contains("shop") || t.contains("shopping") { return "Shop" }
    if t.contains("gym") || t.contains("fitness")                 { return "Fitness" }
    if t.contains("airport")                                      { return "Airport" }
    if t.contains("hospital") || t.contains("doctor") || t.contains("pharmacy") { return "Medical" }
    if t.contains("park")                                         { return "Park" }
    if t.contains("grocery") || t.contains("supermarket")         { return "Grocery" }
    if t.contains("museum") || t.contains("tourist") || t.contains("attraction") { return "Attraction" }
    return "Attraction"
}

private let discoverCategories = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                   "Attraction", "Venue", "House", "Fitness",
                                   "Office", "Airport", "Medical", "Park", "Grocery"]

// MARK: - Main view

struct TraceMacDiscoverView: View {
    @Environment(NotionService.self) private var notion
    @Environment(NoteStore.self)     private var noteStore

    @State private var searchText = ""
    @State private var searchResults: [GooglePlace] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var cameraCenter: CLLocationCoordinate2D?
    @State private var selectedPin: DiscoverPin?
    @State private var listCollapsed = false

    @State private var showAddSheet = false
    @State private var pendingResult: GooglePlace?

    @State private var fullRecordPlace: Place?

    private var savedGooglePlaceIDs: Set<String> {
        Set(notion.places.compactMap(\.googlePlaceID))
    }

    private func isAlreadySaved(_ result: GooglePlace) -> Bool {
        savedGooglePlaceIDs.contains(result.id)
    }

    // What the list shows: search results while actively searching, otherwise
    // all saved places (alphabetical) as a browsable baseline.
    private var showingSearchResults: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var sortedPlaces: [Place] {
        notion.places.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left column — browsable list only. Search lives on the map side
            // (below) so it's still reachable when this column is collapsed —
            // it used to live here and disappeared along with the column.
            if !listCollapsed {
                VStack(spacing: 0) {
                    listContent
                }
                .frame(width: 280)
            }

            CollapseHandle(isCollapsed: $listCollapsed, collapsesRight: false, showLine: true, panelColor: .clear)

            // Right — map, with search floating on top and the info card on
            // the bottom, both always visible regardless of the list column.
            ZStack {
                mapContent

                VStack {
                    searchBar
                        .padding(12)
                    Spacer()
                    if let pin = selectedPin {
                        infoCard(for: pin)
                            .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            if notion.places.isEmpty { await notion.fetchPlaces() }
            centerOnSavedPlaces()
        }
        .sheet(isPresented: $showAddSheet) {
            if let result = pendingResult {
                AddDiscoveredPlaceSheet(result: result) {
                    await notion.fetchPlaces()
                }
                .environment(notion)
            }
        }
        .sheet(item: $fullRecordPlace) { place in
            // Presented as a dismissable sheet rather than navigating to the
            // Places section — Discover's map/search/selection state stays
            // exactly as it was underneath, so closing this returns you right
            // back to where you were instead of losing your place.
            PlaceDetailSheet(place: place)
                .environment(notion)
                .environment(noteStore)
        }
    }

    // Native MapKit taps on our own annotations only — MapKit's own built-in
    // POI layer (restaurants/shops the base map renders itself) can't be
    // made tappable this way. .mapFeatureSelectionAccessory(_:), the
    // modifier that would enable that, is iOS/iPadOS/Mac Catalyst/visionOS
    // only per Apple's docs — there's no native-macOS (AppKit) variant, so
    // it isn't reachable from this app no matter how it's guarded. See
    // Discover-Google-Maps-Workplan.md for the actual path to clickable
    // arbitrary places (a WKWebView-embedded Google Maps JS view).
    private var mapContent: some View {
        Map(position: $cameraPosition) {
            ForEach(notion.places) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    PlacePin(place: place)
                        .onTapGesture {
                            selectedPin = .saved(place)
                            focusOn(place.coordinate)
                        }
                }
            }
            ForEach(searchResults) { result in
                Annotation(result.name, coordinate: result.coordinate) {
                    SearchResultPin(isSaved: isAlreadySaved(result))
                        .onTapGesture {
                            selectedPin = .search(result)
                            focusOn(result.coordinate)
                        }
                }
            }
        }
        .onMapCameraChange { context in
            cameraCenter = context.region.center
        }
        .mapControls {
            MapCompass()
            MapZoomStepper()
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                TextField("Restaurants, bars, museums…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) { _, newValue in
                        scheduleSearch(newValue)
                    }
                if isSearching {
                    ProgressView().scaleEffect(0.6)
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let err = searchError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchError = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ query: String) async {
        isSearching = true
        searchError = nil
        do {
            let results = try await GooglePlacesService.shared.textSearch(query: query, coordinate: cameraCenter)
            guard !Task.isCancelled else { return }
            searchResults = results
            if results.isEmpty {
                searchError = "No results. If this persists, check the Google Places key in Settings."
            }
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    // MARK: - List

    @ViewBuilder
    private var listContent: some View {
        if showingSearchResults {
            if searchResults.isEmpty && !isSearching {
                emptyListState(searchError == nil ? "Keep typing…" : searchError!)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(searchResults) { result in
                            let pin = DiscoverPin.search(result)
                            Button {
                                selectedPin = pin
                                focusOn(result.coordinate)
                            } label: {
                                SearchResultRow(result: result, isSaved: isAlreadySaved(result))
                                    .padding(.horizontal, 12)
                                    .background(selectedPin == pin ? Color.accentColor.opacity(0.12) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        } else if sortedPlaces.isEmpty {
            emptyListState("No saved places yet.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedPlaces) { place in
                        let pin = DiscoverPin.saved(place)
                        Button {
                            selectedPin = pin
                            focusOn(place.coordinate)
                        } label: {
                            SavedPlaceRow(place: place)
                                .padding(.horizontal, 12)
                                .background(selectedPin == pin ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func emptyListState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "binoculars")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Info card

    // People David has visited this place with — same underlying data
    // (Visit.peopleIDs) used on the home screen's visit cards and person
    // detail views, just filtered to one place.
    private func companions(for place: Place) -> [Person] {
        var seen: [String: Person] = [:]
        for visit in notion.visits where visit.placeID == place.id {
            for pid in visit.peopleIDs {
                if seen[pid] == nil, let person = notion.people.first(where: { $0.id == pid }) {
                    seen[pid] = person
                }
            }
        }
        return Array(seen.values).sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private func infoCard(for pin: DiscoverPin) -> some View {
        switch pin {
        case .saved(let place):
            SavedPlaceInfoCard(
                place: place,
                companions: companions(for: place),
                onDismiss: { selectedPin = nil },
                onOpenFullRecord: { fullRecordPlace = place }
            )
        case .search(let result):
            SearchResultInfoCard(
                result: result,
                isSaved: isAlreadySaved(result),
                onAdd: {
                    pendingResult = result
                    showAddSheet = true
                },
                onDismiss: { selectedPin = nil }
            )
        }
    }

    // MARK: - Map helpers

    private func focusOn(_ coordinate: CLLocationCoordinate2D) {
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            ))
        }
    }

    private func centerOnSavedPlaces() {
        guard cameraCenter == nil else { return }
        let coords = notion.places.map(\.coordinate)
        guard !coords.isEmpty else { return }
        let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let avgLon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
        ))
    }
}

// MARK: - Search result pin (map annotation)

private struct SearchResultPin: View {
    let isSaved: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSaved ? Color.yellow : Color.blue)
                .frame(width: 26, height: 26)
            Image(systemName: isSaved ? "star.fill" : "mappin")
                .font(.system(size: 11))
                .foregroundStyle(.white)
        }
        .shadow(radius: 2)
    }
}

// MARK: - List rows

private struct SavedPlaceRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(placeColor(for: place.category).opacity(0.18)).frame(width: 30, height: 30)
                Image(systemName: placeIcon(for: place.category))
                    .font(.system(size: 13))
                    .foregroundStyle(placeColor(for: place.category))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.callout).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    if !place.city.isEmpty {
                        Text(place.city).font(.caption).foregroundStyle(.secondary)
                    }
                    if place.visitCount > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(place.visitCount) visit\(place.visitCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

private struct SearchResultRow: View {
    let result: GooglePlace
    let isSaved: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill((isSaved ? Color.yellow : Color.blue).opacity(0.18)).frame(width: 30, height: 30)
                Image(systemName: isSaved ? "star.fill" : "mappin")
                    .font(.system(size: 13))
                    .foregroundStyle(isSaved ? .yellow : .blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).font(.callout).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    if !result.city.isEmpty {
                        Text(result.city).font(.caption).foregroundStyle(.secondary)
                    }
                    if let rating = result.rating {
                        Text("·").foregroundStyle(.tertiary)
                        Text("★ \(String(format: "%.1f", rating))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if isSaved {
                Text("Saved").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Info cards (map overlay)

private struct SavedPlaceInfoCard: View {
    let place: Place
    let companions: [Person]
    let onDismiss: () -> Void
    let onOpenFullRecord: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(placeColor(for: place.category)).frame(width: 36, height: 36)
                    Image(systemName: placeIcon(for: place.category))
                        .font(.system(size: 15)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name).font(.headline)
                    Text([place.category, place.city].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if !place.address.isEmpty {
                        Text(place.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Text(place.status).font(.caption).foregroundStyle(.secondary)
                if place.visitCount > 0 {
                    Label("\(place.visitCount) visit\(place.visitCount == 1 ? "" : "s")", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let rating = place.ratingPersonal, rating > 0 {
                    Label("\(rating)/7", systemImage: "star.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let phone = place.phone, !phone.isEmpty {
                    Button {
                        if let url = URL(string: "tel:\(phone.filter(\.isNumber))") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(phone, systemImage: "phone").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                if let website = place.website, let url = URL(string: website) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Website", systemImage: "link").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !place.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(place.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }

            if !companions.isEmpty {
                Text("Been here with: \(companions.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let notes = place.notes, !notes.isEmpty {
                Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }

            Button("Open Full Record") { onOpenFullRecord() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 6)
    }
}

private struct SearchResultInfoCard: View {
    let result: GooglePlace
    let isSaved: Bool
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(isSaved ? Color.yellow : Color.blue).frame(width: 36, height: 36)
                Image(systemName: isSaved ? "star.fill" : "mappin")
                    .font(.system(size: 15)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name).font(.headline)
                if !result.formattedAddress.isEmpty {
                    Text(result.formattedAddress).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let rating = result.rating {
                        Label("\(String(format: "%.1f", rating)) (\(result.ratingCount ?? 0))", systemImage: "star.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let hours = result.todayHours {
                        Text(hours).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    if let phone = result.phone {
                        Button {
                            if let url = URL(string: "tel:\(phone.filter(\.isNumber))") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label(phone, systemImage: "phone").font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    if let website = result.website, let url = URL(string: website) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label("Website", systemImage: "link").font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if isSaved {
                    Text("Saved").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Add") { onAdd() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 6)
    }
}

// MARK: - Add-from-search sheet

private struct AddDiscoveredPlaceSheet: View {
    let result: GooglePlace
    let onSaved: () async -> Void

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var category: String
    @State private var status: String = "Want to Visit"
    @State private var isSaving = false
    @State private var saveError: String?

    init(result: GooglePlace, onSaved: @escaping () async -> Void) {
        self.result = result
        self.onSaved = onSaved
        _category = State(initialValue: guessCategory(result.primaryType))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Add Place").font(.headline)
                Spacer()
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            Divider()

            Form {
                Section {
                    Text(result.name).font(.headline)
                    if !result.formattedAddress.isEmpty {
                        Text(result.formattedAddress).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Picker("Category", selection: $category) {
                    ForEach(discoverCategories, id: \.self) { Text($0).tag($0) }
                }

                Picker("Status", selection: $status) {
                    Text("Want to Visit").tag("Want to Visit")
                    Text("Visited").tag("Visited")
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .frame(width: 420, height: 320)
    }

    private func save() async {
        isSaving = true
        saveError = nil
        do {
            _ = try await notion.addPlace(
                name: result.name,
                address: result.streetAddress,
                city: result.city,
                category: category,
                latitude: result.latitude,
                longitude: result.longitude,
                googlePlaceID: result.id,
                phone: result.phone,
                website: result.website,
                status: status
            )
            await onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Full record sheet

// TraceMacPlaceDetail (defined in TraceMacContentView.swift) has no built-in
// Done/Cancel affordance because it normally lives as a sidebar-selected
// full-pane view, not a sheet — this wrapper adds the missing dismiss button
// so it can be presented modally from Discover without losing map/search state.
private struct PlaceDetailSheet: View {
    let place: Place
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            TraceMacPlaceDetail(place: place)
        }
        .frame(width: 760, height: 680)
    }
}
