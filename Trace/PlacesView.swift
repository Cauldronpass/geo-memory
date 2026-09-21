import SwiftUI
import CoreLocation

// MARK: - Sort options

enum PlacesSort: String, CaseIterable {
    case lastVisited = "Last Visited"
    case name        = "Name"
    case nearMe      = "Near Me"
}

// MARK: - Places View

struct PlacesView: View {
    /// Shown inside the merged app's Records tab rather than as a tab of its
    /// own (D472). The only thing it changes is the big navigation title:
    /// under the Records masthead a second large "Places" is one heading too
    /// many, so the bar goes thin and keeps only the four buttons on its right.
    ///
    /// **The one edit this file takes, and why it is worth it.** D469's rule
    /// is that the screens coming across stay byte for byte as the old app has
    /// them while both apps are installed. `PeopleView` needed nothing.
    /// This screen does, because it pushes `PlaceDetailView` with a
    /// `NavigationLink` and hangs Add a place, Visits, Sort and Refresh off a
    /// navigation bar. With no `NavigationStack` around it, tapping a place
    /// does nothing and all four buttons are simply absent — a screen with
    /// four missing controls and a dead row, which is worse than a parameter.
    /// So Records wraps it in a `NavigationStack` and passes this.
    ///
    /// Default `false`, so Trace itself is unchanged.
    var embedded: Bool = false

    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager

    @State private var searchText        = ""
    @State private var sort: PlacesSort  = .lastVisited
    @State private var selectedCategory: String? = nil
    @State private var frequentOnly      = false
    @State private var pinnedOnly        = false
    @State private var wantToVisitOnly   = false
    @State private var checkInPlace: Place? = nil
    @State private var showingAddPlace   = false
    @State private var showingVisits     = false
    @FocusState private var isSearchFocused: Bool

    private var availableCategories: [String] {
        Array(Set(notion.places.compactMap { $0.category.isEmpty ? nil : $0.category })).sorted()
    }

    private var filtered: [Place] {
        var result = notion.places

        if wantToVisitOnly {
            result = result.filter { $0.status == "Want to Visit" }
        } else {
            result = result.filter { $0.status != "Archived" }
        }

        if frequentOnly { result = result.filter { $0.frequent } }
        if pinnedOnly   { result = result.filter { $0.flagged } }
        if let cat = selectedCategory { result = result.filter { $0.category == cat } }

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.city.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sort {
        case .lastVisited:
            result = result.sorted {
                switch ($0.lastVisited, $1.lastVisited) {
                case (let a?, let b?): return a > b
                case (_?, nil):        return true
                case (nil, _?):        return false
                case (nil, nil):       return $0.name < $1.name
                }
            }
        case .name:
            result = result.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .nearMe:
            if let loc = locationManager.location {
                result = result.sorted {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: loc)
                    < CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: loc)
                }
            }
        }

        return result
    }

    private var hasActiveFilters: Bool {
        selectedCategory != nil || frequentOnly || pinnedOnly || wantToVisitOnly
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.dayflowMuted)
                TextField("Search places", text: $searchText)
                    .autocorrectionDisabled()
                    .focused($isSearchFocused)
                    .onSubmit { isSearchFocused = false }
                if !searchText.isEmpty {
                    Button { searchText = ""; isSearchFocused = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.dayflowMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.dayflowPanel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(Color.dayflowPaper)

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Button("All Categories") { selectedCategory = nil }
                        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                        ForEach(availableCategories, id: \.self) { cat in
                            Button(cat) { selectedCategory = cat }
                        }
                    } label: {
                        MapFilterChip(title: selectedCategory ?? "Category",
                                      systemImage: "square.grid.2x2",
                                      isActive: selectedCategory != nil,
                                      showChevron: true) {}
                    }

                    MapFilterChip(title: "Frequent",
                                  systemImage: "star.fill",
                                  isActive: frequentOnly,
                                  showChevron: false) {
                        frequentOnly.toggle()
                        if frequentOnly { wantToVisitOnly = false; pinnedOnly = false }
                    }

                    MapFilterChip(title: "Pinned",
                                  systemImage: "pin.fill",
                                  isActive: pinnedOnly,
                                  showChevron: false) {
                        pinnedOnly.toggle()
                        if pinnedOnly { frequentOnly = false; wantToVisitOnly = false }
                    }

                    MapFilterChip(title: "Want to Visit",
                                  systemImage: "bookmark.fill",
                                  isActive: wantToVisitOnly,
                                  showChevron: false) {
                        wantToVisitOnly.toggle()
                        if wantToVisitOnly { frequentOnly = false }
                    }

                    if hasActiveFilters {
                        Button {
                            selectedCategory = nil
                            frequentOnly = false
                            pinnedOnly = false
                            wantToVisitOnly = false
                        } label: {
                            Text("Clear")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.dayflowPaper.opacity(0.9))
                                .foregroundStyle(Color.dayflowMuted)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color.dayflowPaper)

            if notion.isLoading {
                ProgressView("Loading places…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    "No Places",
                    systemImage: "mappin.slash",
                    description: Text(hasActiveFilters || !searchText.isEmpty
                        ? "Try adjusting your filters."
                        : "Check in somewhere to get started.")
                )
            } else {
                List {
                    ForEach(filtered) { (place: Place) in
                        NavigationLink {
                            PlaceDetailView(place: place)
                                .environment(NotionService.shared)
                                .environment(LocationManager.shared)
                        } label: {
                            PlacesListRow(place: place,
                                          userLocation: locationManager.location,
                                          sort: sort)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if place.status != "Want to Visit" {
                                Button { checkInPlace = place } label: {
                                    Label("Check In", systemImage: "checkmark.circle.fill")
                                }
                                .tint(Color.dayflowAccent)
                            }
                        }
                    }
                }
                // D474 — keep the List and its separators; the system
                // grouped background underneath it goes, so the rows sit on
                // the same paper as everything else.
                .scrollContentBackground(.hidden)
                .background(Color.dayflowPaper)
                .refreshable { await notion.fetchPlaces() }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .navigationTitle(embedded ? "" : "Places")
        .navigationBarTitleDisplayMode(embedded ? .inline : .large)
        .drawerToolbar()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isSearchFocused = false }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingVisits = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingAddPlace = true } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(PlacesSort.allCases, id: \.self) { option in
                        Button {
                            sort = option
                        } label: {
                            if sort == option {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await notion.fetchPlaces() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showingVisits) {
            VisitsView()
                .environment(NotionService.shared)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tracePlacesShowVisits)) { _ in
            showingVisits = true
        }
        .sheet(item: $checkInPlace) { place in
            CheckInView(preselectedPlace: place)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingAddPlace) {
            Task { await notion.fetchPlaces() }
        } content: {
            AddPlaceView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
    }
}

// MARK: - Row

struct PlacesListRow: View {
    let place: Place
    let userLocation: CLLocation?
    let sort: PlacesSort

    private var distanceLabel: String? {
        guard sort == .nearMe, let loc = userLocation else { return nil }
        let metres = CLLocation(latitude: place.latitude, longitude: place.longitude).distance(from: loc)
        return metres < 1000
            ? String(format: "%.0f m", metres)
            : String(format: "%.1f km", metres / 1000)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: placeIcon(for: place.category))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.dayflowPaper)
                .frame(width: 36, height: 36)
                .background(placeColor(for: place.category))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(place.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if place.flagged {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.dayflowAccent)
                    }
                    if place.frequent {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.dayflowAccent)
                    }
                }
                Text([place.city, place.category].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.dayflowMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let dist = distanceLabel {
                    Text(dist).font(.caption).foregroundStyle(Color.dayflowMuted)
                } else if let last = place.lastVisited {
                    Text(last, style: .date).font(.caption).foregroundStyle(Color.dayflowMuted)
                } else if place.status == "Want to Visit" {
                    Text("Want to visit").font(.caption).foregroundStyle(Color.dayflowAccent)
                }
                if place.visitCount > 0 {
                    Text("\(place.visitCount) visit\(place.visitCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(Color.dayflowFaint)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
