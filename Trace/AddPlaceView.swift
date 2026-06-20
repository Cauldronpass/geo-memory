import SwiftUI
import MapKit
import CoreLocation
import UserNotifications

// MARK: - Supporting Types

enum AddPlaceMode {
    case none, search, personal, temp
}

enum TempDuration: String, CaseIterable {
    case twoHours, fourHours, eightHours, eod, tomorrow

    var label: String {
        switch self {
        case .twoHours: return "2 hr"
        case .fourHours: return "4 hr"
        case .eightHours: return "8 hr"
        case .eod: return "EOD"
        case .tomorrow: return "Tomorrow"
        }
    }

    var expiry: Date {
        let now = Date()
        switch self {
        case .twoHours:   return Calendar.current.date(byAdding: .hour, value: 2, to: now)!
        case .fourHours:  return Calendar.current.date(byAdding: .hour, value: 4, to: now)!
        case .eightHours: return Calendar.current.date(byAdding: .hour, value: 8, to: now)!
        case .eod:
            var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
            c.hour = 23; c.minute = 59
            return Calendar.current.date(from: c)!
        case .tomorrow:   return Calendar.current.date(byAdding: .day, value: 1, to: now)!
        }
    }
}

private let placeCategories = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                "Attraction", "Venue", "House", "Fitness",
                                "Office", "Airport", "Medical", "Park", "Grocery"]

// MARK: - Mode Card

private struct ModeCard: View {
    let title: String
    let description: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}


// MARK: - Location Map View

private struct LocationMapView: View {
    @Binding var position: MapCameraPosition
    let isGeocoding: Bool
    let onCameraChange: (CLLocationCoordinate2D) -> Void

    var body: some View {
        ZStack {
            Map(position: $position)
                .onMapCameraChange(frequency: .onEnd) { context in
                    onCameraChange(context.camera.centerCoordinate)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Fixed crosshair pin — user pans the map under it
            VStack(spacing: 0) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                    .shadow(radius: 2)
                Rectangle()
                    .frame(width: 2, height: 6)
                    .foregroundStyle(.red)
            }
            .allowsHitTesting(false)

            if isGeocoding {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - AddPlaceView

struct AddPlaceView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var mode: AddPlaceMode = .none

    // Search
    @State private var searchText = ""
    @State private var searchResults: [GooglePlace] = []
    @State private var isSearching = false

    // Personal
    @State private var personalName = ""
    @State private var personalCategory = "House"
    @State private var personalStatus = "Visited"
    @State private var geocodedAddress = ""
    @State private var geocodedCity = ""
    @State private var geocodedLat: Double = 0
    @State private var geocodedLon: Double = 0
    @State private var isGeocoding = false

    // Temp
    @State private var tempLabel = ""
    @State private var tempDuration: TempDuration = .twoHours

    // Shared location map
    @State private var showLocationMap = false
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var isReverseGeocoding = false

    // Shared
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if mode == .none {
                        modeSelector
                    } else {
                        Button {
                            mode = .none
                            searchResults = []
                            searchText = ""
                            showLocationMap = false
                        } label: {
                            Label("Change type", systemImage: "chevron.left")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        switch mode {
                        case .search:   searchForm
                        case .personal: personalForm
                        case .temp:     tempForm
                        case .none:     EmptyView()
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Add Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Mode Selector

    var modeSelector: some View {
        VStack(spacing: 12) {
            ModeCard(
                title: "Search",
                description: "Find a business, restaurant, or point of interest near you",
                icon: "magnifyingglass",
                color: .blue
            ) { mode = .search }

            ModeCard(
                title: "Personal",
                description: "Home, friend's house, or private landmark — pinned at your current location",
                icon: "house",
                color: .green
            ) {
                mode = .personal
                reverseGeocode()
            }

            ModeCard(
                title: "Temp",
                description: "Parking spot, trailhead, or anything that auto-deletes after a set time",
                icon: "clock",
                color: .orange
            ) {
                mode = .temp
                initTempLocation()
            }
        }
    }

    // MARK: Search Form

    var searchForm: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search places...", text: $searchText)
                    .submitLabel(.search)
                    .onSubmit { performSearch() }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            if isSearching {
                ProgressView().padding()
            }

            ForEach(searchResults) { item in
                DiscoverResultRow(
                    place: item,
                    notion: notion,
                    locationManager: locationManager,
                    onSaved: { dismiss() }
                )
                Divider()
            }

            if !searchResults.isEmpty {
                Text("Sorted by distance from your location")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: Personal Form

    var personalForm: some View {
        VStack(spacing: 14) {
            // Location section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 6) {
                        if isGeocoding || isReverseGeocoding {
                            ProgressView().scaleEffect(0.8)
                            Text("Getting location…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "location.fill").foregroundStyle(.green)
                            Text("Location")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showLocationMap.toggle()
                        }
                    } label: {
                        Label(showLocationMap ? "Hide Map" : "Adjust on Map",
                              systemImage: showLocationMap ? "map.fill" : "map")
                            .font(.caption)
                    }
                }

                if showLocationMap {
                    LocationMapView(
                        position: $mapPosition,
                        isGeocoding: isReverseGeocoding,
                        onCameraChange: { coord in
                            reverseGeocodeCoordinate(coord)
                        }
                    )
                    Text("Pan the map to move the pin")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                TextField("Address", text: $geocodedAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("City", text: $geocodedCity)
                    .textFieldStyle(.roundedBorder)
            }

            TextField("Name (e.g. Mom's House)", text: $personalName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Category").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Picker("Category", selection: $personalCategory) {
                    ForEach(placeCategories, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }

            Picker("Status", selection: $personalStatus) {
                Text("Visited").tag("Visited")
                Text("Want to Visit").tag("Want to Visit")
            }
            .pickerStyle(.segmented)

            Button {
                savePersonal()
            } label: {
                Group {
                    if isSaving { ProgressView() }
                    else { Text("Save Place").frame(maxWidth: .infinity) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(personalName.isEmpty || isSaving || isGeocoding)
        }
    }

    // MARK: Temp Form

    var tempForm: some View {
        VStack(spacing: 14) {
            // Location section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 6) {
                        if isReverseGeocoding {
                            ProgressView().scaleEffect(0.8)
                            Text("Getting location…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "location.fill").foregroundStyle(.orange)
                            Text(!geocodedAddress.isEmpty || !geocodedCity.isEmpty
                                 ? [geocodedAddress, geocodedCity].filter { !$0.isEmpty }.joined(separator: ", ")
                                 : "Current location")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showLocationMap.toggle()
                        }
                    } label: {
                        Label(showLocationMap ? "Hide Map" : "Adjust on Map",
                              systemImage: showLocationMap ? "map.fill" : "map")
                            .font(.caption)
                    }
                }

                if showLocationMap {
                    LocationMapView(
                        position: $mapPosition,
                        isGeocoding: isReverseGeocoding,
                        onCameraChange: { coord in
                            reverseGeocodeCoordinate(coord)
                        }
                    )
                    Text("Pan the map to move the pin")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            TextField("Label (e.g. Car on Level 3)", text: $tempLabel)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Auto-deletes after")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(TempDuration.allCases, id: \.self) { d in
                        Button {
                            tempDuration = d
                        } label: {
                            Text(d.label)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(tempDuration == d ? Color.orange : Color.gray.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(tempDuration == d ? .white : .primary)
                        }
                    }
                }
            }

            Text("Deletes at \(tempDuration.expiry.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                saveTemp()
            } label: {
                Group {
                    if isSaving { ProgressView() }
                    else { Text("Drop Temp Pin").frame(maxWidth: .infinity) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(tempLabel.isEmpty || isSaving)
        }
    }

    // MARK: - Actions

    func performSearch() {
        guard !searchText.isEmpty else { return }
        isSearching = true
        searchResults = []
        Task {
            let results = (try? await GooglePlacesService.shared.textSearch(
                query: searchText,
                coordinate: locationManager.location?.coordinate
            )) ?? []
            if let userLoc = locationManager.location {
                searchResults = results.sorted {
                    let a = CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    let b = CLLocation(latitude: $1.latitude, longitude: $1.longitude)
                    return a.distance(from: userLoc) < b.distance(from: userLoc)
                }
            } else {
                searchResults = results
            }
            isSearching = false
        }
    }

    func reverseGeocode() {
        guard let coord = locationManager.location?.coordinate else { return }
        isGeocoding = true
        geocodedLat = coord.latitude
        geocodedLon = coord.longitude
        mapPosition = .camera(MapCamera(centerCoordinate: coord, distance: 500))
        Task {
            let geocoder = CLGeocoder()
            let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let marks = try? await geocoder.reverseGeocodeLocation(loc)
            let pm = marks?.first
            geocodedAddress = [pm?.subThoroughfare, pm?.thoroughfare]
                .compactMap { $0 }.joined(separator: " ")
            geocodedCity = pm?.locality ?? ""
            isGeocoding = false
        }
    }

    func initTempLocation() {
        guard let coord = locationManager.location?.coordinate else { return }
        geocodedLat = coord.latitude
        geocodedLon = coord.longitude
        mapPosition = .camera(MapCamera(centerCoordinate: coord, distance: 500))
        reverseGeocodeCoordinate(coord)
    }

    func reverseGeocodeCoordinate(_ coord: CLLocationCoordinate2D) {
        isReverseGeocoding = true
        geocodedLat = coord.latitude
        geocodedLon = coord.longitude
        Task {
            let geocoder = CLGeocoder()
            let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let marks = try? await geocoder.reverseGeocodeLocation(loc)
            let pm = marks?.first
            geocodedAddress = [pm?.subThoroughfare, pm?.thoroughfare]
                .compactMap { $0 }.joined(separator: " ")
            geocodedCity = pm?.locality ?? ""
            isReverseGeocoding = false
        }
    }

    func savePersonal() {
        guard !isSaving, !personalName.isEmpty else { return }
        isSaving = true
        Task {
            try? await notion.addPlace(
                name: personalName, address: geocodedAddress, city: geocodedCity,
                category: personalCategory, latitude: geocodedLat, longitude: geocodedLon,
                googlePlaceID: nil, phone: nil, website: nil, status: personalStatus
            )
            await notion.fetchPlaces()
            isSaving = false
            dismiss()
        }
    }

    func saveTemp() {
        guard !isSaving, !tempLabel.isEmpty else { return }
        isSaving = true
        Task {
            try? await notion.addPlace(
                name: tempLabel, address: geocodedAddress, city: geocodedCity, category: "Temp",
                latitude: geocodedLat, longitude: geocodedLon,
                googlePlaceID: nil, phone: nil, website: nil, status: "Visited", expires: tempDuration.expiry
            )
            scheduleExpiry(name: tempLabel, at: tempDuration.expiry)
            await notion.fetchPlaces()
            isSaving = false
            dismiss()
        }
    }

    func formattedDistance(to coord: CLLocationCoordinate2D) -> String? {
        guard let userCoord = locationManager.location?.coordinate else { return nil }
        let from = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
        let to = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let meters = from.distance(from: to)
        if meters < 1000 {
            return "\(Int(meters)) m"
        } else {
            let miles = meters / 1609.34
            return String(format: "%.1f mi", miles)
        }
    }

    func scheduleExpiry(name: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Temp Pin Expired"
        content.body = "\(name) — open Trace to archive it."
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: "temp-\(UUID().uuidString)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
}
