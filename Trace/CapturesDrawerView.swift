import SwiftUI
import CoreLocation

struct CapturesDrawerView: View {
    @Binding var isShowing: Bool
    @Environment(NotionService.self) private var notion
    @State private var selectedCapture: Capture?
    @State private var actionCapture: Capture?
    @State private var showingVisitPicker = false
    @State private var showingActions = false
    @State private var showingCreateVisit = false
    @State private var showingSaveAsPlace = false

    // Bulk select
    @State private var isSelecting = false
    @State private var selectedCaptureIDs: Set<String> = []
    @State private var showingBulkVisitPicker = false
    @State private var showingBulkDeleteConfirm = false

    var groupedCaptures: [(key: String, value: [Capture])] {
        let grouped = Dictionary(grouping: notion.captures) { capture in
            capture.placeID != nil ? (capture.placeName ?? "Unknown Place") : "No Place"
        }
        return grouped.sorted { a, b in
            if a.key == "No Place" { return false }
            if b.key == "No Place" { return true }
            let aLatest = a.value.map { $0.timestamp }.max() ?? .distantPast
            let bLatest = b.value.map { $0.timestamp }.max() ?? .distantPast
            return aLatest > bLatest
        }
    }

    private var selectedCaptures: [Capture] {
        notion.captures.filter { selectedCaptureIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if notion.captures.isEmpty {
                    VStack {
                        Spacer()
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No pending notes")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(groupedCaptures, id: \.key) { group in
                            Section(group.key) {
                                ForEach(group.value) { capture in
                                    CaptureRow(
                                        capture: capture,
                                        isSelecting: isSelecting,
                                        isSelected: selectedCaptureIDs.contains(capture.id)
                                    ) {
                                        if isSelecting {
                                            toggleSelection(capture.id)
                                        } else {
                                            actionCapture = capture
                                            showingActions = true
                                        }
                                    } onDismiss: {
                                        Task { try? await notion.dismissCapture(capture.id) }
                                    } onLongPress: {
                                        if !isSelecting {
                                            withAnimation { isSelecting = true }
                                            toggleSelection(capture.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .safeAreaInset(edge: .bottom) {
                        if isSelecting && !selectedCaptureIDs.isEmpty {
                            bulkActionBar
                        }
                    }
                }
            }
            .navigationTitle(isSelecting ? "\(selectedCaptureIDs.count) selected" : "Pending")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isSelecting {
                        Button("Cancel") {
                            withAnimation {
                                isSelecting = false
                                selectedCaptureIDs.removeAll()
                            }
                        }
                    } else {
                        Button("Done") {
                            withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
                        }
                        .bold()
                    }
                }
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selectedCaptureIDs.count == notion.captures.count ? "Deselect All" : "Select All") {
                            if selectedCaptureIDs.count == notion.captures.count {
                                selectedCaptureIDs.removeAll()
                            } else {
                                selectedCaptureIDs = Set(notion.captures.map { $0.id })
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("What would you like to do?", isPresented: $showingActions, titleVisibility: .visible) {
            if let capture = actionCapture {
                Button("Link to existing visit") {
                    selectedCapture = capture
                    showingVisitPicker = true
                }
                if capture.placeID != nil {
                    Button("Add to place notes") {
                        Task {
                            guard let placeID = capture.placeID else { return }
                            try? await notion.appendToPlaceNotes(placeID: placeID, text: capture.notes)
                            try? await notion.deleteCapture(capture.id)
                        }
                    }
                }
                // NoteStore actions (only shown when NoteStore folder is linked)
                let NoteStore = NoteStore.shared
                if NoteStore.hasAccess {
                    Button("Send to today's note") {
                        Task {
                            try? NoteStore.appendToDailyNote("- \(capture.notes)")
                            try? await notion.dismissCapture(capture.id)
                        }
                    }
                    if let placeName = capture.placeName {
                        Button("Send to \(placeName) note") {
                            Task {
                                try? NoteStore.appendToPlaceNote(for: placeName, text: "- \(capture.notes)")
                                try? await notion.dismissCapture(capture.id)
                            }
                        }
                    }
                }
                if let lat = capture.gpsLat, let lon = capture.gpsLon,
                   let url = URL(string: "maps://?daddr=\(lat),\(lon)") {
                    Button("Get Directions") {
                        UIApplication.shared.open(url)
                    }
                }
                if capture.gpsLat != nil {
                    Button("Save as Place…") {
                        selectedCapture = capture
                        showingSaveAsPlace = true
                    }
                }
                Button("Create new visit") {
                    selectedCapture = capture
                    showingCreateVisit = true
                }
                Button("Dismiss from queue", role: .destructive) {
                    Task { try? await notion.dismissCapture(capture.id) }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
        .confirmationDialog(
            "Delete \(selectedCaptureIDs.count) capture\(selectedCaptureIDs.count == 1 ? "" : "s")?",
            isPresented: $showingBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = Array(selectedCaptureIDs)
                Task {
                    for id in ids {
                        try? await notion.deleteCapture(id)
                    }
                    withAnimation { isSelecting = false; selectedCaptureIDs.removeAll() }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width > 50 {
                        withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
                    }
                }
        )
        .sheet(isPresented: $showingVisitPicker) {
            if let capture = selectedCapture {
                VisitPickerView(capture: capture, isShowing: $showingVisitPicker) {
                    showingCreateVisit = true
                }
                .environment(notion)
            }
        }
        .sheet(isPresented: $showingCreateVisit) {
            if let capture = selectedCapture {
                CreateVisitFromCaptureView(capture: capture, isShowing: $showingCreateVisit)
                    .environment(notion)
                    .environment(LocationManager.shared)
            }
        }
        .sheet(isPresented: $showingSaveAsPlace) {
            if let capture = selectedCapture {
                SaveCaptureAsPlaceSheet(capture: capture)
                    .environment(NotionService.shared)
            }
        }
        .sheet(isPresented: $showingBulkVisitPicker) {
            BulkVisitPickerView(captures: selectedCaptures, isShowing: $showingBulkVisitPicker) {
                withAnimation { isSelecting = false; selectedCaptureIDs.removeAll() }
            }
            .environment(notion)
        }
        .task {
            await notion.fetchCaptures()
        }
    }

    // MARK: - Bulk Action Bar

    private var bulkActionBar: some View {
        HStack(spacing: 12) {
            Button {
                showingBulkVisitPicker = true
            } label: {
                Label("Assign to Visit", systemImage: "link")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Button {
                showingBulkDeleteConfirm = true
            } label: {
                Label("Delete \(selectedCaptureIDs.count)", systemImage: "trash")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - Helpers

    private func toggleSelection(_ id: String) {
        if selectedCaptureIDs.contains(id) {
            selectedCaptureIDs.remove(id)
        } else {
            selectedCaptureIDs.insert(id)
        }
    }
}

// MARK: - CaptureRow

struct CaptureRow: View {
    let capture: Capture
    var isSelecting: Bool = false
    var isSelected: Bool = false
    let onTap: () -> Void
    let onDismiss: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Selection indicator
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
            }

            if let urlString = capture.photoURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 56, height: 56)
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    default:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 56, height: 56)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(capture.notes.isEmpty ? "(no note)" : capture.notes)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(capture.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if capture.gpsLat != nil {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isSelecting {
                Button("Dismiss", role: .destructive) { onDismiss() }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.4) {
            onLongPress?()
        }
    }
}

// MARK: - BulkVisitPickerView

struct BulkVisitPickerView: View {
    let captures: [Capture]
    @Binding var isShowing: Bool
    var onDone: () -> Void
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var isLinking = false
    @State private var linkError: String?

    var relevantVisits: [Visit] {
        if searchText.isEmpty { return notion.visits }
        return notion.visits.filter {
            $0.placeName.localizedCaseInsensitiveContains(searchText) ||
            $0.notes?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    var body: some View {
        NavigationStack {
            List(relevantVisits) { visit in
                Button {
                    Task {
                        isLinking = true
                        for capture in captures {
                            try? await notion.linkCapture(
                                capture.id,
                                toVisit: visit.id,
                                captureNotes: capture.photoURL != nil ? "" : capture.notes,
                                photoURL: capture.photoURL
                            )
                        }
                        isShowing = false
                        onDone()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(visit.placeName).font(.headline)
                        HStack {
                            Text(visit.date, style: .date)
                            if let rating = visit.rating {
                                Text("·")
                                Text(String(repeating: "★", count: rating))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .searchable(text: $searchText, prompt: "Search visits")
            .navigationTitle("Link \(captures.count) to Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowing = false }
                }
            }
            .overlay {
                if isLinking {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("Linking…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// MARK: - VisitPickerView

struct VisitPickerView: View {
    let capture: Capture
    @Binding var isShowing: Bool
    var onCreateVisit: (() -> Void)? = nil
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var linkError: String?
    @State private var isLinking = false

    var relevantVisits: [Visit] {
        let base = capture.placeID != nil
            ? notion.visits.filter { $0.placeID == capture.placeID }
            : notion.visits
        if searchText.isEmpty { return base }
        return base.filter {
            $0.placeName.localizedCaseInsensitiveContains(searchText) ||
            $0.notes?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if relevantVisits.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Text(searchText.isEmpty
                            ? (capture.placeID != nil ? "No check-ins for this place yet" : "No visits found")
                            : "No matching visits")
                            .foregroundStyle(.secondary)
                        if searchText.isEmpty && capture.placeID != nil {
                            Button("Create New Visit") {
                                isShowing = false
                                onCreateVisit?()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Close") { isShowing = false }
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    List(relevantVisits) { visit in
                        Button {
                            Task {
                                isLinking = true
                                do {
                                    try await notion.linkCapture(capture.id, toVisit: visit.id, captureNotes: capture.photoURL != nil ? "" : capture.notes, photoURL: capture.photoURL)
                                    isShowing = false
                                } catch {
                                    linkError = error.localizedDescription
                                    isLinking = false
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(visit.placeName).font(.headline)
                                HStack {
                                    Text(visit.date, style: .date)
                                    if let rating = visit.rating {
                                        Text("·")
                                        Text(String(repeating: "★", count: rating))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if let notes = visit.notes {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search visits")
                }
            }
            .navigationTitle("Link to Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowing = false }
                }
            }
            .alert("Link Failed", isPresented: .constant(linkError != nil)) {
                Button("OK") { linkError = nil }
            } message: {
                Text(linkError ?? "")
            }
            .overlay {
                if isLinking {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("Linking…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// MARK: - CreateVisitFromCaptureView

struct CreateVisitFromCaptureView: View {
    let capture: Capture
    @Binding var isShowing: Bool
    @Environment(NotionService.self) private var notion
    @State private var selectedPlace: Place? = nil
    @State private var rating: Int? = nil
    @State private var notes: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingPlacePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingPlacePicker = true
                    } label: {
                        HStack {
                            Text("Place")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(selectedPlace?.name ?? "Select place…")
                                .foregroundStyle(selectedPlace == nil ? .red : .secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    HStack {
                        Text("Date")
                        Spacer()
                        Text(capture.timestamp, style: .date)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Capture note") {
                    Text(capture.notes.isEmpty ? "(no note)" : capture.notes)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }

                Section("Rating (optional)") {
                    StarRatingPicker(rating: $rating)
                }

                Section("Visit notes (optional)") {
                    TextField("Add notes…", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.caption)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text("Create Visit & Link Note")
                                .frame(maxWidth: .infinity)
                                .bold()
                        }
                    }
                    .disabled(isSaving || selectedPlace == nil)
                }
            }
            .navigationTitle("New Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowing = false }
                }
            }
            .sheet(isPresented: $showingPlacePicker) {
                PlacePickerSheet(currentPlaceID: selectedPlace?.id) { place in
                    selectedPlace = place
                }
                .environment(notion)
            }
            .task { resolvePlace() }
        }
    }

    private func resolvePlace() {
        // If capture already has a place linked, use it
        if let id = capture.placeID,
           let place = notion.places.first(where: { $0.id == id }) {
            selectedPlace = place
            return
        }
        // Otherwise find nearest place by GPS
        guard let lat = capture.gpsLat, let lon = capture.gpsLon else { return }
        let capLoc = CLLocation(latitude: lat, longitude: lon)
        selectedPlace = notion.places
            .filter { $0.status != "Archived" }
            .min(by: {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: capLoc) <
                CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: capLoc)
            })
    }

    private func save() async {
        guard let selectedPlace else { return }
        isSaving = true
        do {
            let visitID = try await notion.checkIn(
                place: selectedPlace,
                rating: rating,
                notes: notes.isEmpty ? nil : notes,
                date: capture.timestamp
            )
            try await notion.linkCapture(capture.id, toVisit: visitID, captureNotes: capture.notes, photoURL: capture.photoURL)
            await notion.fetchPlaces()
            await notion.fetchVisits()
            isShowing = false
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

struct PlacePickerSheet: View {
    let currentPlaceID: String?
    let onSelect: (Place) -> Void
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    private var filtered: [Place] {
        let all = notion.places.filter { $0.status != "Archived" }
        if searchText.isEmpty { return all.sorted { $0.name < $1.name } }
        let q = searchText.lowercased()
        return all
            .filter { $0.name.lowercased().contains(q) || $0.city.lowercased().contains(q) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.id) { place in
                    PlacePickerRow(place: place, isSelected: currentPlaceID == place.id) {
                        onSelect(place)
                        dismiss()
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places")
            .navigationTitle("Select Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct PlacePickerRow: View {
    let place: Place
    let isSelected: Bool
    let onTap: () -> Void

    var subtitle: String {
        place.category.isEmpty ? place.city : "\(place.category) · \(place.city)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
