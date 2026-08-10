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

// MARK: - Research notes panel (E32) — paths

// Lives outside Notes/ entirely — Notes/Inbox/ specifically fires a live
// "Inbox changed" notification on every write and gets listed as real inbox
// items, which would make an in-progress scratchpad look processed before
// it actually is. Drafts/ isn't watched or browsed by anything.
private let discoverDraftPath = "Drafts/discover-research.md"
private let discoverLinkedPath = "Drafts/discover-linked.txt"

private enum ResearchDestination: String, CaseIterable, Identifiable {
    case inbox = "Inbox"
    case today = "Today"
    case project = "Project"
    var id: String { rawValue }
}

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

    /// Drives the Add sheet. **Presentation and content are one piece of
    /// state**, deliberately — see the note on the `.sheet` below.
    @State private var pendingResult: GooglePlace?

    @State private var fullRecordPlace: Place?

    // Phase 2 — composable filters. Three independent axes (source/category/
    // location) that AND together, not exclusive tabs — see
    // Discover-Mac-Workplan.md § Vision.
    @State private var showSavedPlaces = true
    @State private var showSearchPlaces = true
    @State private var categoryFilter: Set<String> = []   // empty = all categories
    @State private var cityFilter = ""

    // Phase 2 — directions-from-origin. nil = current location.
    @State private var directionsOriginPlace: Place?

    // Phase 2 — Place Details (reviews), loaded per-selection.
    @State private var selectedPlaceReviews: [GooglePlaceReview] = []
    @State private var selectedPlaceMapsURI: String?
    @State private var selectedPlaceRating: Double?
    @State private var selectedPlaceRatingCount: Int?
    @State private var isLoadingReviews = false

    // E32 — research notes panel.
    @State private var researchPanelCollapsed = true
    @State private var draftText = ""
    @State private var draftSaveTask: Task<Void, Never>?
    // Set once the draft is loaded from an existing note ("Load Note…") —
    // switches the panel from "Process" (pick a destination) to "Save to X"
    // (overwrite that same note directly), so continuing old research
    // doesn't re-append everything that was already there.
    @State private var linkedNotePath: String?
    @State private var linkedNoteLabel = ""
    @State private var hasUnprocessedDraft = false
    @State private var showProcessSheet = false
    @State private var showLoadNoteSheet = false

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

    // MARK: - Filter matching (composable — all active axes must match)

    private func matchesCategory(_ category: String) -> Bool {
        categoryFilter.isEmpty || categoryFilter.contains(category)
    }

    private func matchesCity(_ city: String) -> Bool {
        let trimmed = cityFilter.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || city.localizedCaseInsensitiveContains(trimmed)
    }

    // The search bar's text does double duty: it's the query for the live
    // Google search AND a name/category/tag filter over your own saved
    // places — otherwise typing with Search toggled off does nothing to the
    // Saved list, which is confusing (flagged by David 2026-07-06).
    private func matchesSearchText(_ place: Place) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return place.name.localizedCaseInsensitiveContains(trimmed)
            || place.category.localizedCaseInsensitiveContains(trimmed)
            || place.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    // Saved places and search results, filtered but NOT yet gated by the
    // showSaved/showSearchPlaces source toggles — used by centerOnSavedPlaces
    // and anywhere the source toggle shouldn't apply.
    private var categoryAndCityFilteredPlaces: [Place] {
        sortedPlaces.filter { matchesCategory($0.category) && matchesCity($0.city) && matchesSearchText($0) }
    }

    private var categoryAndCityFilteredSearchResults: [GooglePlace] {
        searchResults.filter { matchesCategory(guessCategory($0.primaryType)) && matchesCity($0.city) }
    }

    // What actually renders on the map + in the list — source toggle applied
    // on top of category/city.
    private var filteredPlaces: [Place] {
        showSavedPlaces ? categoryAndCityFilteredPlaces : []
    }

    private var filteredSearchResults: [GooglePlace] {
        showSearchPlaces ? categoryAndCityFilteredSearchResults : []
    }

    // Both sections visible at once → label them so it's clear which is which.
    private var showBothListSections: Bool {
        !filteredSearchResults.isEmpty && !filteredPlaces.isEmpty
    }

    private var emptyListMessage: String {
        if !showSavedPlaces && !showSearchPlaces {
            return "Both sources are hidden — toggle Saved or Search above."
        }
        if showingSearchResults && showSearchPlaces && isSearching { return "Keep typing…" }
        if showingSearchResults && showSearchPlaces, let err = searchError { return err }
        if !categoryFilter.isEmpty || !cityFilter.trimmingCharacters(in: .whitespaces).isEmpty || showingSearchResults {
            return "No matches for the current filters."
        }
        return showingSearchResults ? "Keep typing…" : "No saved places yet."
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
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                    filterBar
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    Spacer()
                    if let pin = selectedPin {
                        infoCard(for: pin)
                            .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !researchPanelCollapsed {
                CollapseHandle(isCollapsed: $researchPanelCollapsed, collapsesRight: true, showLine: true, panelColor: .clear)
                researchPanel
            }
        }
        .task {
            if notion.places.isEmpty { await notion.fetchPlaces() }
            centerOnSavedPlaces()
        }
        .task(id: selectedPin) {
            await loadReviewsIfNeeded()
        }
        .task {
            draftText = (try? noteStore.readFile(discoverDraftPath)) ?? ""
            let linked = (try? noteStore.readFile(discoverLinkedPath)) ?? ""
            if !linked.isEmpty {
                linkedNotePath = linked
                linkedNoteLabel = (linked as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
            }
            hasUnprocessedDraft = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Catch up the live search if Search is toggled back on after being
        // skipped — otherwise turning it on with existing search text just
        // shows nothing until the next keystroke.
        .onChange(of: showSearchPlaces) { _, isOn in
            if isOn && searchResults.isEmpty {
                scheduleSearch(searchText)
            }
        }
        // THE APP FREEZE, 2026-08-04. David, adding Lakemore Resort as a
        // destination: clicked the place's pin, and the app stopped responding
        // with a blank white rounded rectangle drawn over the map.
        //
        // **It was not a hang.** The paused main thread sat in
        // `mach_msg2_trap` — idle, waiting for events — and the console showed
        // `CAMetalLayer ignoring invalid setDrawableSize width=0 height=0`.
        // A window with no content, modal, eating every event.
        //
        // Two causes, both here, and either alone is enough:
        //
        // **1. A sheet whose content could be empty.** This was
        // `.sheet(isPresented: $showAddSheet) { if let result = pendingResult {…} }`
        // with no `else`. If `showAddSheet` ever became true while
        // `pendingResult` was nil — a stale flag, a re-render between the two
        // assignments, a dismissal that cleared one and not the other — SwiftUI
        // presented a sheet containing **nothing**: a zero-size modal window,
        // exactly the white rectangle on screen.
        //
        // Fixed by deleting `showAddSheet` entirely and driving the sheet from
        // `.sheet(item: $pendingResult)`. Presentation and content become one
        // piece of state, so "presented but empty" is no longer expressible.
        // **Two booleans that must agree is a bug waiting for a race; one
        // optional cannot disagree with itself.**
        //
        // **2. Two `.sheet` modifiers on the same view.** This file had two
        // pairs of them. That is D36: the later one wins and the earlier
        // silently never presents, and when both are triggered the result is
        // undefined. `fullRecordPlace`'s sheet moves onto the map below.
        .sheet(item: $pendingResult) { result in
            AddDiscoveredPlaceSheet(result: result) {
                await notion.fetchPlaces()
            }
            .environment(notion)
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
            ForEach(filteredPlaces) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    PlacePin(place: place)
                        .onTapGesture {
                            selectedPin = .saved(place)
                            focusOn(place.coordinate)
                        }
                }
            }
            ForEach(filteredSearchResults) { result in
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
        // Hosted here, not beside the Add sheet on the container — two `.sheet`
        // modifiers on one view is D36, and this file had two pairs of them.
        //
        // Presented as a dismissable sheet rather than navigating to the Places
        // section: Discover's map, search and selection state stay exactly as
        // they were underneath, so closing it returns you where you were.
        .sheet(item: $fullRecordPlace) { place in
            PlaceDetailSheet(place: place)
                .environment(notion)
                .environment(noteStore)
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

    // MARK: - Filter bar (Phase 2)

    private var filterBar: some View {
        HStack(spacing: 8) {
            sourceChip(label: "Saved", isOn: $showSavedPlaces)
            sourceChip(label: "Search", isOn: $showSearchPlaces)
            categoryMenu
            cityFilterField
            researchPanelToggleButton
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 3)
    }

    private func sourceChip(label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isOn.wrappedValue ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var categoryMenu: some View {
        Menu {
            Button("All Categories") { categoryFilter = [] }
            Divider()
            ForEach(discoverCategories, id: \.self) { cat in
                Button {
                    if categoryFilter.contains(cat) {
                        categoryFilter.remove(cat)
                    } else {
                        categoryFilter.insert(cat)
                    }
                } label: {
                    HStack {
                        Text(cat)
                        if categoryFilter.contains(cat) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(categoryFilter.isEmpty ? "Category" : "\(categoryFilter.count) selected")
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                categoryFilter.isEmpty ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.18),
                in: Capsule()
            )
            .foregroundStyle(categoryFilter.isEmpty ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var cityFilterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "mappin.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("City", text: $cityFilter)
                .textFieldStyle(.plain)
                .font(.caption)
            if !cityFilter.isEmpty {
                Button {
                    cityFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .frame(width: 120)
    }

    private var researchPanelToggleButton: some View {
        Button {
            researchPanelCollapsed.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "note.text")
                    .font(.caption)
                    .padding(6)
                    .background(
                        !researchPanelCollapsed ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: Circle()
                    )
                    .foregroundStyle(!researchPanelCollapsed ? Color.accentColor : Color.secondary)
                if hasUnprocessedDraft {
                    Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Research Notes")
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchError = nil
            return
        }
        // Search source toggled off — the typed text still filters Saved
        // places (see matchesSearchText), but there's no reason to spend a
        // live Google API call on results nobody can see.
        guard showSearchPlaces else { return }
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

    // Sources compose (Phase 2) — Saved and Search can both be on at once,
    // so the list shows both sections rather than one replacing the other.
    // Section headers only appear when both are actually populated
    // simultaneously; otherwise this looks exactly like the old either/or list.
    @ViewBuilder
    private var listContent: some View {
        if filteredSearchResults.isEmpty && filteredPlaces.isEmpty {
            emptyListState(emptyListMessage)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !filteredSearchResults.isEmpty {
                        if showBothListSections {
                            sectionHeader("Search Results (\(filteredSearchResults.count))")
                        }
                        ForEach(filteredSearchResults) { result in
                            searchResultRowButton(result)
                        }
                    }
                    if !filteredPlaces.isEmpty {
                        if showBothListSections {
                            sectionHeader("Saved Places (\(filteredPlaces.count))")
                        }
                        ForEach(filteredPlaces) { place in
                            savedPlaceRowButton(place)
                        }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func searchResultRowButton(_ result: GooglePlace) -> some View {
        let pin = DiscoverPin.search(result)
        return VStack(spacing: 0) {
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

    private func savedPlaceRowButton(_ place: Place) -> some View {
        let pin = DiscoverPin.saved(place)
        return VStack(spacing: 0) {
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

    private func emptyListState(_ message: String) -> some View {
        MacEmptyState.list("binoculars", message)
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
                reviews: selectedPlaceReviews,
                isLoadingReviews: isLoadingReviews,
                overallRating: selectedPlaceRating,
                totalReviewCount: selectedPlaceRatingCount,
                mapsURI: selectedPlaceMapsURI,
                directionsOrigin: $directionsOriginPlace,
                originChoices: sortedPlaces,
                onDismiss: { selectedPin = nil },
                onOpenFullRecord: { fullRecordPlace = place },
                onAddToResearch: { addSelectedToResearch() }
            )
        case .search(let result):
            SearchResultInfoCard(
                result: result,
                isSaved: isAlreadySaved(result),
                reviews: selectedPlaceReviews,
                isLoadingReviews: isLoadingReviews,
                overallRating: selectedPlaceRating,
                totalReviewCount: selectedPlaceRatingCount,
                mapsURI: selectedPlaceMapsURI,
                directionsOrigin: $directionsOriginPlace,
                originChoices: sortedPlaces,
                onAdd: {
                    // Setting this presents the sheet — see the note on it.
                    pendingResult = result
                },
                onDismiss: { selectedPin = nil },
                onAddToResearch: { addSelectedToResearch() }
            )
        }
    }

    // MARK: - Reviews (Phase 2 — Place Details call)

    // Fetched per-selection rather than cached on the model — reviews are
    // supplementary detail, not core data, so a miss/failure here should
    // never block the rest of the info card from rendering.
    private func loadReviewsIfNeeded() async {
        selectedPlaceReviews = []
        selectedPlaceMapsURI = nil
        selectedPlaceRating = nil
        selectedPlaceRatingCount = nil
        guard let pin = selectedPin else { return }
        let placeID: String?
        switch pin {
        case .saved(let place):  placeID = place.googlePlaceID
        case .search(let result): placeID = result.id
        }
        guard let placeID else { return }
        isLoadingReviews = true
        defer { isLoadingReviews = false }
        do {
            let details = try await GooglePlacesService.shared.placeDetails(placeID: placeID)
            // Selection may have moved on while this was in flight — only
            // apply results if they're still for the current pin.
            guard selectedPin == pin else { return }
            selectedPlaceReviews = details.reviews
            selectedPlaceMapsURI = details.googleMapsURI
            selectedPlaceRating = details.overallRating
            selectedPlaceRatingCount = details.totalReviewCount
        } catch {
            // Silent — no API key, network hiccup, or a saved place with no
            // googlePlaceID are all expected, non-error states here.
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

    // MARK: - Research notes panel (E32)

    private var researchPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(linkedNotePath != nil ? "Research — \(linkedNoteLabel)" : "Research Notes")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    researchPanelCollapsed = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)

            Divider()

            // Plain text box, deliberately not the rich TraceMacNoteEditor —
            // that component's content is private state, shared across
            // Journal/People/Places, with no way for an outside "insert this
            // place" button to write into it. This scratchpad only ever
            // needs to hold real markdown; it just doesn't render it until
            // it's processed into a real note and opened there.
            TextEditor(text: $draftText)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .onChange(of: draftText) { _, newValue in
                    scheduleDraftSave(newValue)
                }

            Divider()

            HStack(spacing: 10) {
                Button("New Draft") { startNewDraft() }
                    .buttonStyle(.plain)
                    .font(.caption)

                Button("Load Note…") { showLoadNoteSheet = true }
                    .sheet(isPresented: $showLoadNoteSheet) {
                        ResearchLoadNoteSheet { path, label in
                            loadNote(path: path, label: label)
                        }
                        .environment(noteStore)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)

                Spacer()

                if let linkedNotePath {
                    Button("Save to \(linkedNoteLabel)") {
                        saveLinkedNote(path: linkedNotePath)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Process") { showProcessSheet = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
        }
        .frame(width: 300)
        .background(.regularMaterial)
        // The second stacked pair — see the note on the Add sheet. `Load Note…`
        // moves onto the toolbar row that triggers it, so the two live on
        // different views.
        .sheet(isPresented: $showProcessSheet) {
            ResearchProcessSheet { destination, projectName in
                process(destination: destination, projectName: projectName)
            }
            .environment(noteStore)
        }
    }

    private func scheduleDraftSave(_ text: String) {
        draftSaveTask?.cancel()
        hasUnprocessedDraft = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? noteStore.writeFile(discoverDraftPath, content: text)
        }
    }

    private func persistLinkedPath(_ path: String?) {
        try? noteStore.writeFile(discoverLinkedPath, content: path ?? "")
    }

    private func startNewDraft() {
        draftSaveTask?.cancel()
        draftText = ""
        linkedNotePath = nil
        linkedNoteLabel = ""
        hasUnprocessedDraft = false
        try? noteStore.writeFile(discoverDraftPath, content: "")
        persistLinkedPath(nil)
    }

    private func loadNote(path: String, label: String) {
        draftSaveTask?.cancel()
        let content = (try? noteStore.readFile(path)) ?? ""
        draftText = content
        linkedNotePath = path
        linkedNoteLabel = label
        hasUnprocessedDraft = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        try? noteStore.writeFile(discoverDraftPath, content: content)
        persistLinkedPath(path)
    }

    // Overwrites the linked note directly — the draft already contains
    // everything that was in it plus whatever's been added this session, so
    // appending again would duplicate the original content.
    private func saveLinkedNote(path: String) {
        try? noteStore.writeFile(path, content: draftText)
    }

    private func process(destination: ResearchDestination, projectName: String?) {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            switch destination {
            case .inbox:
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                try noteStore.writeFile(
                    "Notes/Inbox/\(timestamp)-Discover-Research.md",
                    content: "# Discover Research\n\n\(text)"
                )
            case .today:
                try noteStore.appendToDailyNote(text)
            case .project:
                guard let projectName, !projectName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let path = "Notes/Projects/\(projectName).md"
                let existing = (try? noteStore.readFile(path)) ?? ""
                let updated = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "# \(projectName)\n\n\(text)"
                    : existing + "\n\n" + text
                try noteStore.writeFile(path, content: updated)
            }
            startNewDraft()
        } catch {
            // Best-effort, matching other NoteStore writes in this file —
            // a failed process leaves the draft intact so nothing is lost.
        }
    }

    // Appends the currently-selected pin to the research draft. Auto-opens
    // the panel if it's closed, since clicking this is a clear enough signal
    // of intent that requiring a separate "open the panel first" step would
    // just be friction.
    private func addSelectedToResearch() {
        guard let pin = selectedPin else { return }
        let line: String
        switch pin {
        case .saved(let place):
            var context = [place.category, place.city].filter { !$0.isEmpty }.joined(separator: ", ")
            if let rating = selectedPlaceRating {
                let countPart = selectedPlaceRatingCount.map { " (\($0) review\($0 == 1 ? "" : "s"))" } ?? ""
                if !context.isEmpty { context += ". " }
                context += String(format: "%.1f★%@", rating, countPart)
            }
            line = "- [[\(place.name)]]" + (context.isEmpty ? "" : " — \(context)")
        case .search(let result):
            var context = [guessCategory(result.primaryType), result.city].filter { !$0.isEmpty }.joined(separator: ", ")
            if let rating = result.rating {
                if !context.isEmpty { context += ". " }
                context += String(format: "%.1f★", rating)
            }
            // A coordinate-only URL just drops a generic pin. Google's
            // documented "Place Search" link (query + query_place_id) opens
            // the actual place page — name, photos, reviews — same as what
            // you'd see tapping through in Discover itself.
            let encodedName = result.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? result.name
            let mapsLink = "[Google Maps](https://www.google.com/maps/search/?api=1&query=\(encodedName)&query_place_id=\(result.id))"
            line = "- **\(result.name)**" + (context.isEmpty ? "" : " — \(context)") + ". \(mapsLink)"
        }
        researchPanelCollapsed = false
        let combined = draftText.isEmpty ? line : draftText + "\n" + line
        draftText = combined
        scheduleDraftSave(combined)
    }
}

// MARK: - Directions-from-origin (Phase 2)

// `maps://` (not `maps.apple.com`) — the http(s) form silently failed on
// iOS's DiscoverView until Session 53 fixed it (see HANDOFF.md); same scheme
// works on Mac via NSWorkspace. Omitting `saddr` falls back to current
// location, matching the iOS behavior; passing it lets David route from any
// saved place (a hotel while traveling, etc.) instead of assuming "here."
private func openDirections(to destination: CLLocationCoordinate2D, from origin: Place?) {
    var urlString = "maps://?daddr=\(destination.latitude),\(destination.longitude)&dirflg=d"
    if let origin {
        urlString += "&saddr=\(origin.latitude),\(origin.longitude)"
    }
    if let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
    }
}

private struct DirectionsControl: View {
    let destination: CLLocationCoordinate2D
    @Binding var origin: Place?
    let originChoices: [Place]

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Current Location") { origin = nil }
                if !originChoices.isEmpty {
                    Divider()
                    ForEach(originChoices) { place in
                        Button(place.name) { origin = place }
                    }
                }
            } label: {
                Label(origin?.name ?? "Current Location", systemImage: "location.fill")
                    .font(.caption)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                openDirections(to: destination, from: origin)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Reviews section (Phase 2 — shared by both info cards)

// Shows the aggregate rating (the only real "distribution" signal Google's
// API gives us — no per-star breakdown is available) plus one positive and
// one critical example drawn from the up-to-5 individual reviews Place
// Details returns, rather than an arbitrary first-3 slice. David's call
// (2026-07-06): more honest than presenting a handful of comments as if
// they were a representative sample.
private struct ReviewsSection: View {
    let reviews: [GooglePlaceReview]
    let isLoadingReviews: Bool
    let overallRating: Double?
    let totalReviewCount: Int?
    let mapsURI: String?

    private var bestReview: GooglePlaceReview? {
        reviews.max { $0.rating < $1.rating }
    }

    private var worstReview: GooglePlaceReview? {
        reviews.min { $0.rating < $1.rating }
    }

    // A single review, or all-tied ratings, just shows one labeled "Review"
    // rather than manufacturing a fake positive/negative split.
    private var highlighted: [(label: String, review: GooglePlaceReview)] {
        guard let best = bestReview else { return [] }
        guard let worst = worstReview, worst.id != best.id else {
            return [("Review", best)]
        }
        return [("Positive", best), ("Critical", worst)]
    }

    var body: some View {
        if isLoadingReviews {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading reviews…").font(.caption).foregroundStyle(.secondary)
            }
        } else if overallRating != nil || !reviews.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let overallRating {
                    HStack(spacing: 5) {
                        ratingStars(Int(overallRating.rounded()))
                        Text(String(format: "%.1f", overallRating)).font(.caption.weight(.semibold))
                        if let totalReviewCount {
                            Text("· \(totalReviewCount) review\(totalReviewCount == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(highlighted, id: \.review.id) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(item.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(item.label == "Critical" ? .orange : .secondary)
                            Text(item.review.authorName).font(.caption.weight(.medium))
                            ratingStars(item.review.rating)
                            if !item.review.relativeTime.isEmpty {
                                Text(item.review.relativeTime).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if let text = item.review.text, !text.isEmpty {
                            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }

                // Google ToS attribution — required whenever review content
                // sourced via the Places API is displayed.
                Group {
                    if let mapsURI, let url = URL(string: mapsURI) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Text("Reviews by Google · View on Google Maps")
                        }
                        .buttonStyle(.link)
                    } else {
                        Text("Reviews by Google")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func ratingStars(_ rating: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < rating ? "star.fill" : "star")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
            }
        }
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
                .font(MacGlyph.control)
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
            MacIconBadge(icon: placeIcon(for: place.category),
                         tint: placeColor(for: place.category),
                         size: .compact)
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
                    .font(MacGlyph.control)
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
    let reviews: [GooglePlaceReview]
    let isLoadingReviews: Bool
    let overallRating: Double?
    let totalReviewCount: Int?
    let mapsURI: String?
    @Binding var directionsOrigin: Place?
    let originChoices: [Place]
    let onDismiss: () -> Void
    let onOpenFullRecord: () -> Void
    let onAddToResearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                MacIconBadge(icon: placeIcon(for: place.category),
                             tint: placeColor(for: place.category),
                             size: .header)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name).font(.headline)
                    Text([place.category, place.city].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if !place.address.isEmpty {
                        Text(place.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { onAddToResearch() } label: {
                    Image(systemName: "note.text.badge.plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add to Research Notes")
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

            DirectionsControl(destination: place.coordinate, origin: $directionsOrigin, originChoices: originChoices)

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

            ReviewsSection(reviews: reviews, isLoadingReviews: isLoadingReviews, overallRating: overallRating, totalReviewCount: totalReviewCount, mapsURI: mapsURI)

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
    let reviews: [GooglePlaceReview]
    let isLoadingReviews: Bool
    let overallRating: Double?
    let totalReviewCount: Int?
    let mapsURI: String?
    @Binding var directionsOrigin: Place?
    let originChoices: [Place]
    let onAdd: () -> Void
    let onDismiss: () -> Void
    let onAddToResearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(isSaved ? Color.yellow : Color.blue).frame(width: 36, height: 36)
                    Image(systemName: isSaved ? "star.fill" : "mappin")
                        .font(MacGlyph.control).foregroundStyle(.white)
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
                    Button { onAddToResearch() } label: {
                        Image(systemName: "note.text.badge.plus").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Add to Research Notes")
                    if isSaved {
                        Text("Saved").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Button("Add") { onAdd() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }

            DirectionsControl(destination: result.coordinate, origin: $directionsOrigin, originChoices: originChoices)

            ReviewsSection(reviews: reviews, isLoadingReviews: isLoadingReviews, overallRating: overallRating, totalReviewCount: totalReviewCount, mapsURI: mapsURI)
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
                // `addressWithRegion`, not `streetAddress` — the latter drops
                // the state and postcode and stores them nowhere. See the note
                // on it in `GooglePlacesService`.
                address: result.addressWithRegion,
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

// MARK: - Research notes — Process sheet (E32)

// Mirrors AddDocumentView's DocDestination picker (Inbox/Today/Project),
// minus "Place" — David's call: a research note usually covers several
// places at once, so "append into this one place's note" doesn't map
// cleanly the way it does for a single-file document import.
private struct ResearchProcessSheet: View {
    let onConfirm: (ResearchDestination, String?) -> Void

    @Environment(NoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss

    @State private var destination: ResearchDestination = .inbox
    @State private var projectSearch = ""
    @State private var existingProjects: [String] = []
    @State private var confirmedProject = ""

    private var filteredProjects: [String] {
        let q = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return existingProjects }
        return existingProjects.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var saveDisabled: Bool {
        destination == .project && confirmedProject.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Process Research Note").font(.headline)
                Spacer()
                Button("Save") {
                    onConfirm(destination, destination == .project ? confirmedProject : nil)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveDisabled)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            Divider()

            Form {
                Picker("Destination", selection: $destination) {
                    ForEach(ResearchDestination.allCases) { dest in
                        Text(dest.rawValue).tag(dest)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: destination) { _, _ in confirmedProject = "" }

                if destination == .project {
                    Section("Project") {
                        if !confirmedProject.isEmpty {
                            HStack {
                                Text(confirmedProject).bold()
                                Spacer()
                                Button("Change") { confirmedProject = "" }
                                    .buttonStyle(.borderless)
                            }
                        } else {
                            TextField("Search or create a project…", text: $projectSearch)
                            ForEach(filteredProjects, id: \.self) { name in
                                Button(name) { confirmedProject = name }
                                    .buttonStyle(.plain)
                            }
                            if filteredProjects.isEmpty, !projectSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                                Button("Create \"\(projectSearch)\"") { confirmedProject = projectSearch }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
        }
        .frame(width: 420, height: 380)
        .task { loadExistingProjects() }
    }

    private func loadExistingProjects() {
        existingProjects = (try? noteStore.listFiles(in: "Notes/Projects"))?.compactMap { filename -> String? in
            filename.hasSuffix(".md") ? String(filename.dropLast(3)) : nil
        }.sorted() ?? []
    }
}

// MARK: - Research notes — Load Note sheet (E32)

private struct ResearchLoadNoteSheet: View {
    let onSelect: (String, String) -> Void

    @Environment(NoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [String] = []
    @State private var inboxNotes: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Continue a Note").font(.headline)
                Spacer()
                Color.clear.frame(width: 50)
            }
            .padding()

            Divider()

            List {
                Section("Today") {
                    Button {
                        onSelect(todayDailyNotePath(), "Today")
                        dismiss()
                    } label: {
                        Label("Today's Daily Note", systemImage: "calendar")
                    }
                }
                if !projects.isEmpty {
                    Section("Projects") {
                        ForEach(projects, id: \.self) { name in
                            Button {
                                onSelect("Notes/Projects/\(name).md", name)
                                dismiss()
                            } label: {
                                Label(name, systemImage: "folder")
                            }
                        }
                    }
                }
                if !inboxNotes.isEmpty {
                    Section("Inbox") {
                        ForEach(inboxNotes, id: \.self) { file in
                            Button {
                                onSelect("Notes/Inbox/\(file)", String(file.dropLast(3)))
                                dismiss()
                            } label: {
                                Label(file.hasSuffix(".md") ? String(file.dropLast(3)) : file, systemImage: "tray")
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 440)
        .task { load() }
    }

    private func load() {
        projects = (try? noteStore.listFiles(in: "Notes/Projects"))?.compactMap { filename -> String? in
            filename.hasSuffix(".md") ? String(filename.dropLast(3)) : nil
        }.sorted() ?? []
        inboxNotes = (try? noteStore.listFiles(in: "Notes/Inbox"))?.sorted(by: >) ?? []
    }

    private func todayDailyNotePath() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return "Calendar/\(formatter.string(from: Date())).md"
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
