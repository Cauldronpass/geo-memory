import SwiftUI

// MARK: - CheckInView

struct CheckInView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let preselectedPlace: Place?

    @State private var selectedPlace: Place? = nil
    @State private var rating: Int? = nil
    @State private var notes: String = ""
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

    init(preselectedPlace: Place? = nil) {
        self.preselectedPlace = preselectedPlace
        _selectedPlace = State(initialValue: preselectedPlace)
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
             $0.city.localizedCaseInsensitiveContains(searchText) ||
             $0.category.localizedCaseInsensitiveContains(searchText))
            && (!showPinnedOnly || $0.flagged)
            && (selectedCategory == nil || $0.category == selectedCategory)
            && (selectedTag == nil || $0.tags.contains(selectedTag!))
        }
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
        }
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
                    if preselectedPlace != nil { dismiss() } else { selectedPlace = nil }
                }
            }
        }
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
    }

    // MARK: - Action

    private func performCheckIn(place: Place) async {
        isLoading = true
        do {
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
            withAnimation {
                showSuccess = true
            }
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
