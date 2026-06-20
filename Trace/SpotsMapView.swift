import SwiftUI
import MapKit

// MARK: - Source enum

enum SpotsSource {
    case visit(Visit)
    case place(Place)
}

// MARK: - Sheet enum

enum SpotsSheet: Identifiable {
    case addNote(Capture)
    case saveAsPlace(Capture)
    var id: String {
        switch self {
        case .addNote(let c): return "note-\(c.id)"
        case .saveAsPlace(let c): return "place-\(c.id)"
        }
    }
}

// MARK: - SpotsMapView

struct SpotsMapView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let source: SpotsSource

    @State private var spots: [Capture] = []
    @State private var isLoading = true
    @State private var selectedSpot: Capture?
    @State private var showingPlaceCallout = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var activeSheet: SpotsSheet?
    @State private var confirmDeleteSpot: Capture?
    @State private var spotsVersion = 0

    private var contextPlace: Place? {
        switch source {
        case .visit(let v): return notion.places.first { $0.id == v.placeID }
        case .place(let p): return notion.places.first { $0.id == p.id } ?? p
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition) {
                    UserAnnotation()

                    // Place pin — red, tappable
                    if let p = contextPlace {
                        Annotation(p.name,
                                   coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)) {
                            Button {
                                withAnimation(.spring(duration: 0.25)) {
                                    selectedSpot = nil
                                    showingPlaceCallout.toggle()
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 34, height: 34)
                                        .shadow(radius: showingPlaceCallout ? 6 : 3)
                                    Image(systemName: placeIcon(for: p.category))
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                                .scaleEffect(showingPlaceCallout ? 1.12 : 1)
                                .animation(.spring(duration: 0.2), value: showingPlaceCallout)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Spot pins — orange
                    ForEach(spots) { spot in
                        if let lat = spot.gpsLat, let lon = spot.gpsLon {
                            Annotation(spot.placeName ?? spot.notes,
                                       coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                                Button {
                                    withAnimation(.spring(duration: 0.25)) {
                                        showingPlaceCallout = false
                                        selectedSpot = selectedSpot?.id == spot.id ? nil : spot
                                    }
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(selectedSpot?.id == spot.id ? Color.orange : Color.orange.opacity(0.85))
                                            .frame(width: 30, height: 30)
                                            .shadow(radius: selectedSpot?.id == spot.id ? 5 : 2)
                                        Image(systemName: "mappin")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                    .scaleEffect(selectedSpot?.id == spot.id ? 1.15 : 1)
                                    .animation(.spring(duration: 0.2), value: selectedSpot?.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                // Map overlay buttons — top trailing
                .overlay(alignment: .topTrailing) {
                    VStack(spacing: 8) {
                        Button {
                            if let coord = LocationManager.shared.location?.coordinate {
                                withAnimation {
                                    cameraPosition = .region(MKCoordinateRegion(
                                        center: coord,
                                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                                    ))
                                }
                            }
                        } label: {
                            Image(systemName: "location.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(10)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }

                        Button {
                            withAnimation { fitCamera() }
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(10)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                }

                // Place callout
                if showingPlaceCallout, let p = contextPlace {
                    placeCallout(p)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                }

                // Spot callout
                if let spot = selectedSpot {
                    spotCallout(spot)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                }
            }
            .navigationTitle("Spots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bold()
                }
                if selectedSpot != nil || showingPlaceCallout {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") {
                            withAnimation {
                                selectedSpot = nil
                                showingPlaceCallout = false
                            }
                        }
                    }
                }
            }
            .overlay {
                if isLoading {
                    Color.black.opacity(0.1).ignoresSafeArea()
                    ProgressView("Loading spots…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task(id: spotsVersion) { await loadSpots() }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .addNote(let capture):
                    SpotNoteSheet(capture: capture) {
                        spotsVersion += 1
                    }
                    .environment(NotionService.shared)
                case .saveAsPlace(let capture):
                    SaveCaptureAsPlaceSheet(capture: capture)
                        .environment(NotionService.shared)
                }
            }
            .confirmationDialog(
                "Delete this spot?",
                isPresented: Binding(
                    get: { confirmDeleteSpot != nil },
                    set: { if !$0 { confirmDeleteSpot = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let spot = confirmDeleteSpot {
                    Button("Delete", role: .destructive) {
                        Task {
                            try? await notion.deleteCapture(spot.id)
                            withAnimation {
                                if selectedSpot?.id == spot.id { selectedSpot = nil }
                            }
                            spotsVersion += 1
                        }
                        confirmDeleteSpot = nil
                    }
                }
                Button("Cancel", role: .cancel) { confirmDeleteSpot = nil }
            }
        }
    }

    // MARK: - Place callout

    @ViewBuilder
    private func placeCallout(_ p: Place) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name)
                    .font(.headline)
                    .lineLimit(1)
                if !p.city.isEmpty {
                    Text(p.city)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let url = URL(string: "maps://?daddr=\(p.latitude),\(p.longitude)") {
                Link(destination: url) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.accentColor, in: Capsule())
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    // MARK: - Spot callout

    @ViewBuilder
    private func spotCallout(_ spot: Capture) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(spot.placeName ?? spot.notes)
                        .font(.headline)
                        .lineLimit(1)
                    Text(spot.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let lat = spot.gpsLat, let lon = spot.gpsLon,
                   let url = URL(string: "maps://?daddr=\(lat),\(lon)") {
                    Link(destination: url) {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }

            // Additional notes (anything after the first line)
            if let extra = spotExtraNotes(for: spot) {
                Text(extra)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Divider()

            // Action row
            HStack(spacing: 20) {
                Button {
                    activeSheet = .addNote(spot)
                } label: {
                    Label("Add Note", systemImage: "note.text.badge.plus")
                        .font(.caption.bold())
                }
                Button {
                    activeSheet = .saveAsPlace(spot)
                } label: {
                    Label("Save as Place", systemImage: "mappin.and.ellipse")
                        .font(.caption.bold())
                }
                Spacer()
                Button {
                    confirmDeleteSpot = spot
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private func spotExtraNotes(for spot: Capture) -> String? {
        let lines = spot.notes.components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }
        let extra = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? nil : extra
    }

    // MARK: - Data

    private func loadSpots() async {
        isLoading = true
        do {
            switch source {
            case .visit(let v):
                spots = try await notion.fetchCapturesForVisit(visitID: v.id)
            case .place(let p):
                spots = try await notion.fetchCapturesForPlace(placeID: p.id)
            }
        } catch {
            spots = []
        }
        fitCamera()
        isLoading = false
    }

    private func fitCamera() {
        var coords: [CLLocationCoordinate2D] = []
        if let p = contextPlace {
            coords.append(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
        }
        for spot in spots {
            if let lat = spot.gpsLat, let lon = spot.gpsLon {
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
        guard !coords.isEmpty else { return }
        guard coords.count > 1 else {
            cameraPosition = .region(MKCoordinateRegion(
                center: coords[0],
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
            return
        }
        var minLat = coords[0].latitude, maxLat = coords[0].latitude
        var minLon = coords[0].longitude, maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.003),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.003)
        )
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }
}

// MARK: - SpotNoteSheet

struct SpotNoteSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let capture: Capture
    var onSave: () -> Void = {}

    @State private var noteText = ""
    @State private var isSaving = false

    private var existingAdditionalNotes: String? {
        let lines = capture.notes.components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }
        let extra = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? nil : extra
    }

    var body: some View {
        NavigationStack {
            Form {
                if let existing = existingAdditionalNotes {
                    Section("Previous notes") {
                        Text(existing)
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
                Section("New note") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $noteText)
                            .frame(minHeight: 100)
                        if noteText.isEmpty {
                            Text("Add a note…")
                                .foregroundStyle(Color(.placeholderText))
                                .font(.body)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .navigationTitle(capture.placeName ?? "Add Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let trimmed = noteText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        Task {
            try? await notion.appendCaptureNotes(id: capture.id, text: trimmed)
            onSave()
            dismiss()
        }
    }
}
