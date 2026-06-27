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
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(Color(UIColor.systemGroupedBackground))

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
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
                                .tint(.teal)
                            }
                        }
                    }
                }
                .refreshable { await notion.fetchPlaces() }
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.large)
        .drawerToolbar()
        .toolbar {
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
                .foregroundStyle(.white)
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
                            .foregroundStyle(.yellow)
                    }
                    if place.frequent {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text([place.city, place.category].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let dist = distanceLabel {
                    Text(dist).font(.caption).foregroundStyle(.secondary)
                } else if let last = place.lastVisited {
                    Text(last, style: .date).font(.caption).foregroundStyle(.secondary)
                } else if place.status == "Want to Visit" {
                    Text("Want to visit").font(.caption).foregroundStyle(.blue)
                }
                if place.visitCount > 0 {
                    Text("\(place.visitCount) visit\(place.visitCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
