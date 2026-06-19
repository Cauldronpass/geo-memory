import SwiftUI
import MapKit
import CoreLocation
import PhotosUI

// MARK: - Sheet routing

private enum DiscoverSheet: Identifiable {
    case tracePlace(Place)
    case poiItem(MKMapItem)

    var id: String {
        switch self {
        case .tracePlace(let p): return "place-\(p.id)"
        case .poiItem(let m): return "poi-\(ObjectIdentifier(m).hashValue)"
        }
    }
}

// MARK: - DiscoverView

struct DiscoverView: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var selectedMapItem: MKMapItem? = nil
    @State private var selectedMapFeature: MapFeature? = nil
    @State private var activeSheet: DiscoverSheet? = nil
    @State private var resultsExpanded = true
    @State private var mapPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @FocusState private var searchFocused: Bool

    private var tracePlaces: [Place] {
        notion.places.filter { $0.status != "Archived" }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // MARK: Map
            Map(position: $mapPosition, selection: $selectedMapFeature) {
                // Existing Trace places
                ForEach(tracePlaces) { place in
                    Annotation(place.name, coordinate: place.coordinate) {
                        Button { activeSheet = .tracePlace(place) } label: {
                            PlacePin(place: place)
                        }
                    }
                }

                // Search result pins (blue = new, yellow star = already in Trace)
                ForEach(searchResults, id: \.self) { item in
                    if let coord = item.placemark.location?.coordinate {
                        let inDB = isInDatabase(item)
                        Annotation(item.name ?? "", coordinate: coord) {
                            Button {
                                selectedMapItem = item
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
                }

                UserAnnotation()
            }
            .mapStyle(.standard)
            .ignoresSafeArea(edges: .bottom)
            .onChange(of: selectedMapItem) { _, new in
                if let new, let coord = new.placemark.location?.coordinate {
                    withAnimation {
                        mapPosition = .region(MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
                        ))
                    }
                }
            }
            .onChange(of: selectedMapFeature) { _, feature in
                guard let feature else { return }
                Task {
                    // MapFeature (SwiftUI) has no direct bridge to MKMapItemRequest.
                    // Do a tight point-of-interest search at the tapped coordinate.
                    let req = MKLocalSearch.Request()
                    req.naturalLanguageQuery = feature.title ?? "point of interest"
                    req.region = MKCoordinateRegion(
                        center: feature.coordinate,
                        latitudinalMeters: 50,
                        longitudinalMeters: 50
                    )
                    req.resultTypes = .pointOfInterest
                    let item: MKMapItem
                    if let first = try? await MKLocalSearch(request: req).start().mapItems.first {
                        item = first
                    } else {
                        // Fallback: synthetic item with coordinate + name only
                        let synthetic = MKMapItem(placemark: MKPlacemark(coordinate: feature.coordinate))
                        synthetic.name = feature.title
                        item = synthetic
                    }
                    await MainActor.run {
                        activeSheet = .poiItem(item)
                        selectedMapFeature = nil
                    }
                }
            }

            // MARK: Search bar
            VStack(spacing: 8) {
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
                                selectedMapItem = nil
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
            }
            .padding(.top, 12)

            // MARK: Results bottom sheet (after search)
            if hasSearched {
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
                                    Text(searchResults.isEmpty
                                         ? "No results"
                                         : "\(searchResults.count) place\(searchResults.count == 1 ? "" : "s") nearby")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Image(systemName: resultsExpanded ? "chevron.down" : "chevron.up")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                            }
                        }
                        .buttonStyle(.plain)

                        if resultsExpanded {
                            Divider()
                            if searchResults.isEmpty {
                                Text("No matching places")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                            } else {
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        LazyVStack(spacing: 0) {
                                            ForEach(searchResults, id: \.self) { item in
                                                DiscoverResultRow(
                                                    item: item,
                                                    notion: notion,
                                                    locationManager: locationManager,
                                                    selectedItem: selectedMapItem,
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
                                                .id(item)
                                                Divider().padding(.leading, 16)
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 300)
                                    .onChange(of: selectedMapItem) { _, new in
                                        if let new {
                                            withAnimation { proxy.scrollTo(new, anchor: .top) }
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
                POISaveSheet(item: item, notion: notion, locationManager: locationManager)
            }
        }
    }

    private func isInDatabase(_ item: MKMapItem) -> Bool {
        guard let name = item.name else { return false }
        return notion.places.contains { $0.name.lowercased() == name.lowercased() }
    }

    private func performSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        hasSearched = true
        searchResults = []
        selectedMapItem = nil

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        if let coord = locationManager.location?.coordinate {
            request.region = MKCoordinateRegion(
                center: coord,
                latitudinalMeters: 8000,
                longitudinalMeters: 8000
            )
        }
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            if let userLoc = locationManager.location {
                searchResults = response.mapItems.sorted {
                    let d1 = $0.placemark.location?.distance(from: userLoc) ?? .infinity
                    let d2 = $1.placemark.location?.distance(from: userLoc) ?? .infinity
                    return d1 < d2
                }
            } else {
                searchResults = response.mapItems
            }
            zoomToFit(searchResults)
            resultsExpanded = true
        } catch {
            searchResults = []
        }
        isSearching = false
    }

    private func zoomToFit(_ items: [MKMapItem]) {
        let coords = items.compactMap { $0.placemark.location?.coordinate }
        guard !coords.isEmpty else { return }
        if coords.count == 1 {
            withAnimation {
                mapPosition = .region(MKCoordinateRegion(
                    center: coords[0],
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
            return
        }
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
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

// MARK: - POI Save Sheet (tapped directly from map)

private struct POISaveSheet: View {
    let item: MKMapItem
    let notion: NotionService
    let locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DiscoverResultRow(
                    item: item,
                    notion: notion,
                    locationManager: locationManager,
                    startExpanded: true
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle(item.name ?? "Place")
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
    let item: MKMapItem
    let notion: NotionService
    let locationManager: LocationManager
    var selectedItem: MKMapItem? = nil
    var startExpanded: Bool = false
    var onSaved: (() -> Void)? = nil
    var onExpand: ((CLLocationCoordinate2D) -> Void)? = nil

    @State private var expanded = false
    @State private var showingExistingPlace = false
    @State private var matchedPlaceID: String? = nil   // resolved once on appear; stable across renames
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

    // Match by ID (set once on appear) so renames don't break the reference.
    var isInDatabase: Bool { matchedPlaceID != nil }

    var savedPlace: Place? {
        guard let id = matchedPlaceID else { return nil }
        return notion.places.first { $0.id == id }
    }

    var address: String {
        [item.placemark.subThoroughfare, item.placemark.thoroughfare]
            .compactMap { $0 }.joined(separator: " ")
    }

    var city: String { item.placemark.locality ?? "" }

    var displayAddress: String {
        [address, city].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var distanceString: String? {
        guard let userLoc = locationManager.location,
              let placeLoc = item.placemark.location else { return nil }
        let meters = userLoc.distance(from: placeLoc)
        let miles = meters / 1609.34
        return miles < 0.1
            ? "\(Int(meters * 3.281))ft"
            : String(format: "%.1f mi", miles)
    }

    var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row header
            Button {
                if isInDatabase {
                    showingExistingPlace = true
                } else if !saved {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    if !expanded, let coord = item.placemark.location?.coordinate {
                        onExpand?(coord)
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(customName.isEmpty ? (item.name ?? "Unknown") : customName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            if isInDatabase || saved {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                            }
                            if (isInDatabase && savedPlace?.flagged == true) || (saved && pinPlace) {
                                Image(systemName: "pin.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                        }
                        HStack(spacing: 4) {
                            if !displayAddress.isEmpty {
                                Text(displayAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let dist = distanceString {
                                Text("· \(dist)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if saved {
                        Text(checkedIn ? "Checked in!" : "Saved!")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if isInDatabase {
                        HStack(spacing: 4) {
                            Text("In Trace")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Image(systemName: expanded ? "chevron.up.circle" : "plus.circle")
                            .foregroundStyle(.blue)
                            .font(.title3)
                    }
                }
            }
            .buttonStyle(.plain)

            // Expanded save form
            if expanded && !isInDatabase && !saved {
                VStack(spacing: 12) {
                    TextField("Name", text: $customName)
                        .font(.subheadline)
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text("Category")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                        Label("Pin this place", systemImage: "pin")
                            .font(.subheadline)
                    }
                    .tint(.orange)

                    TextField("Notes (optional)", text: $placeNotes, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.subheadline)
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                    if status == "Visited" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Rate it (optional)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    if let img = discoverPhoto {
                        HStack(spacing: 10) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Photo added")
                                    .font(.subheadline)
                                Text(status == "Visited" ? "Will be attached to your visit" : "Will be saved to this place")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Change") { showingPhotoOptions = true }
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    } else {
                        HStack {
                            Button {
                                showingPhotoOptions = true
                            } label: {
                                Label("Add Photo", systemImage: "camera")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            Spacer()
                            Text(status == "Visited" ? "Goes to your visit" : "Goes to this place")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
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
            if customName.isEmpty { customName = item.name ?? "" }
            // Resolve place ID by name once; all subsequent checks use ID so renames don't break the row.
            if matchedPlaceID == nil, let name = item.name {
                matchedPlaceID = notion.places.first { $0.name.lowercased() == name.lowercased() }?.id
            }
            if startExpanded && !isInDatabase && !saved {
                expanded = true
            }
        }
        .sheet(isPresented: $showingExistingPlace) {
            if let place = savedPlace {
                PlaceDetailView(place: place)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            }
        }
        .onChange(of: selectedItem) { _, new in
            if let new, new === item, !saved {
                withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
            }
        }
        .confirmationDialog("Add Photo", isPresented: $showingPhotoOptions) {
            if cameraAvailable {
                Button("Take Photo") { showingCamera = true }
            }
            Button("Choose from Library") { showingPhotoPicker = true }
            if discoverPhoto != nil {
                Button("Remove Photo", role: .destructive) { discoverPhoto = nil }
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraView(image: $discoverPhoto, isPresented: $showingCamera)
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showingPhotoPicker,
                      selection: $selectedPhotoItem,
                      matching: .images)
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
        let name = customName.isEmpty ? (item.name ?? "Unknown") : customName
        isSaving = true
        saveError = nil
        do {
            let placeID = try await notion.addPlace(
                name: name,
                address: address,
                city: city,
                category: category,
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude,
                googlePlaceID: nil,
                phone: item.phoneNumber,
                website: item.url?.absoluteString,
                status: status,
                notes: placeNotes.isEmpty ? nil : placeNotes,
                flagged: pinPlace
            )
            await notion.fetchPlaces()

            if status == "Visited",
               let place = notion.places.first(where: { $0.name.lowercased() == name.lowercased() }) {
                let visitID = try await notion.checkIn(place: place, rating: checkInRating, notes: nil, date: visitDate)
                await notion.fetchVisits()
                if let photo = discoverPhoto { await uploadPhoto(photo, toPageID: visitID) }
                withAnimation { checkedIn = true; saved = true; expanded = false }
                if let cb = onSaved {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    cb()
                }
            } else {
                if let photo = discoverPhoto { await uploadPhoto(photo, toPageID: placeID) }
                withAnimation { saved = true; expanded = false }
                if let cb = onSaved {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    cb()
                }
            }
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
