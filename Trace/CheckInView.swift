import SwiftUI
import CoreLocation

// MARK: - CheckInView

struct CheckInView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let preselectedPlace: Place?

    @State private var selectedPlace: Place?
    @State private var rating: Int? = nil
    @State private var notes: String
    @State private var checkInDate: Date = Date()
    @State private var personIDs: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showSuccess = false
    @State private var searchText = ""
    @State private var showPinnedOnly = false
    @State private var selectedCategory: String? = nil
    @State private var selectedTag: String? = nil
    @State private var showingAddPlace = false
    @State private var showingBilliardsWizard = false

    // MARK: D521 - check in at a place not yet saved
    //
    // David, before a trip: *"When i know that i do not have a place in my
    // system i have to go to the directory find it then add it then check in.
    // its time consuming..."* This sheet listed only his own places, and its
    // `+` opened a blank form. Now it also lists what Google says is around
    // him that he has not saved; picking one adds it (as Visited, his call)
    // and checks in, in one press. Nothing is preselected (D398): he picks.

    private enum NearbyState: Equatable { case idle, loading, loaded, failed(String) }
    @State private var nearby: [GooglePlace] = []
    /// D525. What Google finds for the typed search, near him but not only
    /// near him. David typed "Bonobos" and nothing happened: the field only
    /// filtered his own places and the 250 m list, and a shop across town is in
    /// neither.
    @State private var typedResults: [GooglePlace] = []
    @State private var typedSearching = false
    @State private var nearbyState: NearbyState = .idle
    /// The Google result being checked into, while it is not yet a Place.
    @State private var pendingNew: GooglePlace? = nil
    /// Its category, guessed from Google's type and editable before saving.
    @State private var newCategory: String = "Attraction"

    /// AI-prefill, Session 28 — optional suggested Notes riding in on the
    /// `trace://checkin` URL's "notes" query param (see DayflowWikiSummaryView.swift's
    /// placeVisitsTab). No Type field to prefill here — CheckInView has none.
    /// Defaults to blank for every other existing way of opening this sheet (the
    /// FAB buttons, the Home Screen shortcut, geofence check-ins, and a bare
    /// `trace://checkin` hand-off) — all of those pass nil and are unaffected.
    init(preselectedPlace: Place? = nil, prefillNotes: String? = nil) {
        self.preselectedPlace = preselectedPlace
        self.selectedPlace = preselectedPlace
        self.notes = prefillNotes ?? ""
    }

    private var availableCategories: [String] {
        Array(Set(notionService.places
            .filter { $0.status != "Archived" && !$0.category.isEmpty }
            .map { $0.category }
        )).sorted()
    }

    private var availableTags: [String] {
        Array(Set(notionService.places
            .filter { $0.status != "Archived" }
            .flatMap { $0.tags }
        )).sorted()
    }

    private var hasActiveFilters: Bool {
        showPinnedOnly || selectedCategory != nil || selectedTag != nil
    }

    private var sortedPlaces: [Place] {
        notionService.places
            .filter { $0.status != "Archived" }
            .sorted {
                let d1 = locationManager.distance(to: $0) ?? .infinity
                let d2 = locationManager.distance(to: $1) ?? .infinity
                return d1 < d2
            }
    }

    private var filteredPlaces: [Place] {
        sortedPlaces.filter {
            (searchText.isEmpty ||
             $0.name.localizedCaseInsensitiveContains(searchText) ||
             $0.category.localizedCaseInsensitiveContains(searchText))
            && (!showPinnedOnly || $0.flagged)
            && (selectedCategory == nil || $0.category == selectedCategory)
            && (selectedTag == nil || $0.tags.contains(selectedTag!))
        }
    }

    /// Google results that are not already one of his places: same Google
    /// ID, or the same name within 100 m, counts as already saved.
    private var nearbyNew: [GooglePlace] {
        let mine = notionService.places + notionService.archivedPlaces
        let unsaved = nearby.filter { g in
            !mine.contains { p in
                if let gid = p.googlePlaceID, !gid.isEmpty, gid == g.id { return true }
                guard p.name.caseInsensitiveCompare(g.name) == .orderedSame else { return false }
                return CLLocation(latitude: p.latitude, longitude: p.longitude)
                    .distance(from: CLLocation(latitude: g.latitude, longitude: g.longitude)) < 100
            }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return unsaved }
        // Typed: Google's answer for the words, nearest first, then anything in
        // the 250 m list that also matches. De-duplicated by Google ID.
        let typedUnsaved = typedResults.filter { g in !unsavedIDsExcluded(g, mine: mine) }
        var seen = Set<String>()
        return (typedUnsaved + unsaved.filter { $0.name.localizedCaseInsensitiveContains(q) })
            .filter { seen.insert($0.id).inserted }
    }

    private func unsavedIDsExcluded(_ g: GooglePlace, mine: [Place]) -> Bool {
        mine.contains { p in
            if let gid = p.googlePlaceID, !gid.isEmpty, gid == g.id { return true }
            guard p.name.caseInsensitiveCompare(g.name) == .orderedSame else { return false }
            return CLLocation(latitude: p.latitude, longitude: p.longitude)
                .distance(from: CLLocation(latitude: g.latitude, longitude: g.longitude)) < 100
        }
    }

    /// Looks the typed words up on Google after a short pause (D525).
    @MainActor
    private func searchTyped(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { typedResults = []; return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        typedSearching = true
        defer { typedSearching = false }
        let here = locationManager.location?.coordinate
        let found = (try? await GooglePlacesService.shared.textSearch(query: q, coordinate: here)) ?? []
        guard !Task.isCancelled else { return }
        if let here {
            let loc = CLLocation(latitude: here.latitude, longitude: here.longitude)
            typedResults = found.sorted {
                loc.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                    < loc.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
            }
        } else {
            typedResults = found
        }
    }

    /// A stand-in `Place` so the ordinary check-in screen can show a Google
    /// result before it exists in Notion. Never saved as it stands.
    private func provisional(_ g: GooglePlace) -> Place {
        Place(id: "google:\(g.id)", name: g.name, city: g.city, address: g.addressWithRegion,
              category: newCategory, latitude: g.latitude, longitude: g.longitude,
              flagged: false, googlePlaceID: g.id, googleMapsURL: nil, phone: g.phone,
              website: g.website, hours: nil, status: "Visited", ratingExternal: g.rating,
              ratingPersonal: nil, visitCount: 0, lastVisited: nil, tags: [],
              aiSummary: nil, notes: nil)
    }

    @MainActor
    private func loadNearby() async {
        guard nearbyState != .loading, nearbyState != .loaded else { return }
        // Location can arrive a moment after the sheet opens; wait up to 3 s.
        for _ in 0..<6 where locationManager.location == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let here = locationManager.location?.coordinate else {
            nearbyState = .failed("Your location isn't available yet, so nearby places can't be listed.")
            return
        }
        nearbyState = .loading
        do {
            nearby = try await GooglePlacesService.shared.placesAround(here)
            nearbyState = .loaded
        } catch {
            nearbyState = .failed("Nearby places need a connection. Your own places are above.")
        }
    }

    private func distanceLabel(_ g: GooglePlace) -> String {
        guard let here = locationManager.location else { return "" }
        let m = here.distance(from: CLLocation(latitude: g.latitude, longitude: g.longitude))
        return m < 1000 ? "\(Int(m.rounded())) m" : String(format: "%.1f km", m / 1000)
    }

    var body: some View {
        NavigationStack {
            if let place = selectedPlace {
                ratingView(for: place)
            } else {
                placeListView
            }
        }
    }

    // MARK: - Place list

    private var placeListView: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search places", text: $searchText)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            ForEach(filteredPlaces) { place in
                Button {
                    selectedPlace = place
                    rating = nil
                    notes = ""
                    searchText = ""
                } label: {
                    CheckInPlaceRow(place: place, locationManager: locationManager)
                }
                .tint(.primary)
            }

            // D521
            Section {
                switch nearbyState {
                case .idle, .loading:
                    HStack { ProgressView(); Text("Looking around you…").foregroundStyle(.secondary) }
                case .failed(let why):
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                case .loaded:
                    if typedSearching {
                        HStack { ProgressView(); Text("Searching Google…").foregroundStyle(.secondary) }
                    } else if nearbyNew.isEmpty {
                        Text(searchText.isEmpty ? "Everything nearby is already in your places."
                                                : "Google found nothing new for that.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(nearbyNew) { g in
                        Button {
                            newCategory = PlaceCategory.suggest(from: g.primaryType) ?? "Attraction"
                            pendingNew = g
                            selectedPlace = provisional(g)
                            rating = nil
                            notes = ""
                            searchText = ""
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(g.name)
                                        Text("NEW")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.orange, lineWidth: 1))
                                    }
                                    Text([PlaceCategory.suggest(from: g.primaryType),
                                          g.rating.map { String(format: "%.1f ★", $0) }]
                                            .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(distanceLabel(g)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                }
            } header: {
                Text(searchText.isEmpty ? "Nearby, not in your places" : "Not in your places")
            }
        }
        .task { await loadNearby() }
        .task(id: searchText) { await searchTyped(searchText) }
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddPlace = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddPlace) {
            Task { await notionService.fetchPlaces() }
        } content: {
            AddPlaceView()
                .environment(notionService)
                .environment(locationManager)
        }
    }

    // MARK: - Rating + notes

    @ViewBuilder
    private func ratingView(for place: Place) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.headline)
                    if let dist = locationManager.formattedDistance(to: place) {
                        Text(dist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // D521: say out loud that this press also adds a place.
            if pendingNew != nil {
                Section {
                    Picker("Category", selection: $newCategory) {
                        ForEach(PlaceCategory.all, id: \.self) { Text($0).tag($0) }
                    }
                } header: {
                    Text("New place")
                } footer: {
                    Text("Checking in also adds this to your places, as Visited.")
                }
            }

            Section("Date") {
                DatePicker("Date", selection: $checkInDate, displayedComponents: .date)
            }

            Section("Rating (optional)") {
                StarRatingPicker(rating: $rating)
            }

            Section("Notes (optional)") {
                TextField("How was it?", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }

            PeoplePickerSection(selectedIDs: $personIDs)

            if place.category.lowercased() == "fitness" {
                Section {
                    Button {
                        if let url = URL(string: "shortcuts://run-shortcut?name=Open%20WellHub") {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "figure.run.circle.fill")
                                .foregroundStyle(.orange)
                            Text("Open WellHub for class check-in")
                                .foregroundStyle(.orange)
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Tap before entering — WellHub check-in is required to avoid being charged.")
                        .font(.caption)
                }
            }

            Section {
                Button {
                    Task { await performCheckIn(place: place) }
                } label: {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        Text("Check In")
                            .frame(maxWidth: .infinity)
                            .bold()
                    }
                }
                .disabled(isLoading)
            }
        }
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(preselectedPlace != nil ? "Cancel" : "Back") {
                    if preselectedPlace != nil { dismiss() } else { selectedPlace = nil; pendingNew = nil }
                }
            }
            // A SECOND WAY TO COMMIT, IN THE BAR.
            //
            // The Check In button is the last row of the Form, so the keyboard
            // covers it the moment you tap into Notes — David, 2026-08-01:
            // "when i add a note to a visit the keyboard covers up the save
            // button." The row is still there and still works; it is simply
            // underneath the thing you had to open to use it.
            //
            // The bar is the one place a keyboard cannot reach, which is why
            // every other sheet in this app puts its commit there. The big row
            // stays: it is the obvious target when the keyboard is down, and
            // two doors to one action is fine when they are plainly the same
            // action.
            ToolbarItem(placement: .confirmationAction) {
                Button("Check In") {
                    Task { await performCheckIn(place: place) }
                }
                .fontWeight(.semibold)
                .disabled(isLoading)
            }
        }
        // Swipe the list to put the keyboard away, so the big button is
        // reachable without hunting for a Done key that this form has no
        // reason to own.
        .scrollDismissesKeyboard(.interactively)
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if showSuccess {
                CheckInSuccessOverlay(placeName: place.name)
            }
        }
        .sheet(isPresented: $showingBilliardsWizard) {
            BilliardsWizardView()
                .environment(notionService)
        }
    }

    // MARK: - Action

    private func performCheckIn(place provisionalOrReal: Place) async {
        isLoading = true
        do {
            // D521: a Google result becomes a real place first, then the visit
            // is logged against it. `addPlace` returns an existing row instead
            // of a duplicate if one already matches, so a race cannot make two.
            var place = provisionalOrReal
            if let g = pendingNew {
                let newID = try await notionService.addPlace(
                    name: g.name, address: g.addressWithRegion, city: g.city,
                    category: newCategory, latitude: g.latitude, longitude: g.longitude,
                    googlePlaceID: g.id, phone: g.phone, website: g.website,
                    status: "Visited")
                await notionService.fetchPlaces()
                guard let saved = notionService.places.first(where: { $0.id == newID }) else {
                    throw NSError(domain: "CheckIn", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "\(g.name) was added, but it did not come back from Notion yet. Try checking in again in a moment."])
                }
                // Hours, Maps link and Google's rating: best effort, the
                // place and the visit do not wait on it.
                try? await notionService.enrichPlace(saved, from: g)
                place = saved
                pendingNew = nil
            }
            _ = try await notionService.checkIn(
                place: place,
                rating: rating,
                notes: notes.isEmpty ? nil : notes,
                date: checkInDate,
                people: personIDs.isEmpty ? nil : personIDs
            )
            // Cancel any pending dwell notification so it doesn't double-prompt
            GeofenceManager.shared.cancelDwellNotificationForManualCheckIn(placeID: place.id)
            await notionService.fetchPlaces()
            await notionService.fetchVisits()
            withAnimation { showSuccess = true }
            logToWeeklyNote(place: place)
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func logToWeeklyNote(place: Place) {
        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = TimeZone.current
        timeFmt.dateFormat = "h:mm a"
        let timeStr = timeFmt.string(from: checkInDate)

        var parts: [String] = ["\(timeStr) — [[\(place.name)]]"]

        let companions = personIDs.compactMap { id in
            notionService.people.first { $0.id == id }?.name
        }
        if !companions.isEmpty {
            parts.append("with \(companions.joined(separator: ", "))")
        }

        if let r = rating, r > 0 {
            parts.append(String(repeating: "★", count: r))
        }

        try? NoteStore.shared.appendToWeeklyCheckInLog(parts.joined(separator: " "), date: checkInDate)
    }
}

// MARK: - Star rating picker

struct StarRatingPicker: View {
    @Binding var rating: Int?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(1...7, id: \.self) { star in
                Button {
                    rating = rating == star ? nil : star
                } label: {
                    Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(star <= (rating ?? 0) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if rating != nil {
                Button("Clear") { rating = nil }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Place row

struct CheckInPlaceRow: View {
    let place: Place
    let locationManager: LocationManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if !place.category.isEmpty {
                        Text(place.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !place.city.isEmpty {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(place.city)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let dist = locationManager.formattedDistance(to: place) {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(dist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Success overlay

struct CheckInSuccessOverlay: View {
    let placeName: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Checked in!")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(placeName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .transition(.opacity)
    }
}
