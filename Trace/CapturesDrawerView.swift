import SwiftUI

struct CapturesDrawerView: View {
    @Binding var isShowing: Bool
    @Environment(NotionService.self) private var notion
    @State private var selectedCapture: Capture?
    @State private var actionCapture: Capture?
    @State private var showingVisitPicker = false
    @State private var showingActions = false
    @State private var showingCreateVisit = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pending")
                    .font(.title2.bold())
                Spacer()
                Button("Done") {
                    withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
                }
                .bold()
            }
            .padding()
            .background(Color(UIColor.systemBackground))

            Divider()

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
                                CaptureRow(capture: capture) {
                                    actionCapture = capture
                                    showingActions = true
                                } onDismiss: {
                                    Task { try? await notion.dismissCapture(capture.id) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
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
                VisitPickerView(capture: capture, isShowing: $showingVisitPicker)
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
        .task {
            await notion.fetchCaptures()
        }
    }
}

struct CaptureRow: View {
    let capture: Capture
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(capture.notes.isEmpty ? "(no note)" : capture.notes)
                .lineLimit(2)
            Text(capture.timestamp, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Dismiss", role: .destructive) { onDismiss() }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

struct VisitPickerView: View {
    let capture: Capture
    @Binding var isShowing: Bool
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""

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
                    VStack(spacing: 12) {
                        Spacer()
                        Text(searchText.isEmpty
                            ? (capture.placeID != nil ? "No check-ins for this place yet" : "No visits found")
                            : "No matching visits")
                            .foregroundStyle(.secondary)
                        Button("Close") { isShowing = false }
                            .padding(.top, 4)
                        Spacer()
                    }
                } else {
                    List(relevantVisits) { visit in
                        Button {
                            Task {
                                try? await notion.linkCapture(capture.id, toVisit: visit.id)
                                isShowing = false
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
        }
    }
}
struct CreateVisitFromCaptureView: View {
    let capture: Capture
    @Binding var isShowing: Bool
    @Environment(NotionService.self) private var notion
    @State private var rating: Int? = nil
    @State private var notes: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var place: Place? {
        guard let id = capture.placeID else { return nil }
        return notion.places.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Place")
                        Spacer()
                        Text(capture.placeName ?? "No place")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Date")
                        Spacer()
                        Text(Date(), style: .date)
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
                    .disabled(isSaving || place == nil)
                }

                if place == nil {
                    Section {
                        Text("This capture has no place attached. Link it to an existing visit instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowing = false }
                }
            }
        }
    }

    private func save() async {
        guard let place else { return }
        isSaving = true
        do {
            let visitID = try await notion.checkIn(
                place: place,
                rating: rating,
                notes: notes.isEmpty ? nil : notes
            )
            try await notion.linkCapture(capture.id, toVisit: visitID)
            await notion.fetchPlaces()
            await notion.fetchVisits()
            isShowing = false
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
