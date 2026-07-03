import SwiftUI
import CoreLocation

struct PlaceDetailView: View {
    let place: Place
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var placeNoteContent: String = ""
    @State private var placeNoteLoaded = false
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    @State private var showingCheckIn = false
    @State private var editingVisit: Visit? = nil
    @State private var showingEditPlace = false
    @State private var showingSpots = false
    @State private var isEditingTags = false
    @State private var newTagText = ""
    @State private var markedForReview = false
    @State private var isEnriching = false
    @State private var enrichError: String?
    @State private var enrichCandidate: GooglePlace?
    @State private var showingEnrichConfirm = false
    @State private var radiusStr: String = ""
    @State private var dwellStr: String = ""
    @FocusState private var settingsFieldFocused: Bool

    private var placeVisits: [Visit] {
        notionService.visits
            .filter { $0.placeID == place.id }
            .sorted { $0.date > $1.date }
    }
    private var livePlace: Place {
        notionService.places.first { $0.id == place.id } ?? place
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                placeHeader
                Picker("", selection: $selectedTab) {
                    Text("Overview").tag(0)
                    Text("Info").tag(1)
                    Text("Visits").tag(2)
                    Text("Notes").tag(3)
                    Text("Settings").tag(4)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                TabView(selection: $selectedTab) {
                    overviewTab.tag(0)
                    infoTab.tag(1)
                    visitsTab.tag(2)
                    notesTab.tag(3)
                    settingsTab.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                actionBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 16) {
                        Button {
                            let notionID = livePlace.id.replacingOccurrences(of: "-", with: "")
                            if let url = URL(string: "https://notion.so/\(notionID)") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        Button {
                            showingEditPlace = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        Button {
                            Task {
                                await notionService.fetchPlaces()
                                await notionService.fetchVisits()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingCheckIn) {
            CheckInView(preselectedPlace: livePlace)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(item: $editingVisit) { visit in
            VisitDetailView(visit: visit)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingEditPlace) {
            PlaceEditSheet(place: livePlace)
                .environment(NotionService.shared)
        }
        .sheet(isPresented: $showingSpots) {
            SpotsMapView(source: .place(livePlace))
                .environment(NotionService.shared)
        }
    }

    // MARK: - Tag helpers

    private func addTag() async {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !livePlace.tags.contains(trimmed) else { return }
        let newTags = livePlace.tags + [trimmed]
        try? await notionService.updatePlace(livePlace, name: livePlace.name, category: livePlace.category, status: livePlace.status, tags: newTags)
        newTagText = ""
        isEditingTags = false
    }

    private func addTagDirect(_ tag: String) async {
        guard !livePlace.tags.contains(tag) else { return }
        let newTags = livePlace.tags + [tag]
        try? await notionService.updatePlace(livePlace, name: livePlace.name, category: livePlace.category, status: livePlace.status, tags: newTags)
    }

    // MARK: - Header

    private var placeHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(place.name)
                .font(.title2.bold())
            HStack(spacing: 4) {
                if !place.category.isEmpty {
                    Text(place.category)
                }
                if !place.city.isEmpty {
                    Text("·")
                    Text(place.city)
                }
                if let dist = locationManager.formattedDistance(to: place) {
                    Text("·")
                    Text(dist)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: - Overview

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailRow(label: "Status") {
                    Text(livePlace.status)
                        .foregroundStyle(livePlace.status == "Visited" ? .green : .orange)
                        .bold()
                }
                DetailRow(label: "Category") {
                    Menu {
                        ForEach(["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                 "Attraction", "Venue", "House", "Fitness",
                                 "Office", "Airport", "Medical", "Park", "Grocery"], id: \.self) { cat in
                            Button(cat) {
                                Task {
                                    try? await notionService.updatePlace(livePlace, name: livePlace.name, category: cat, status: livePlace.status)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: placeIcon(for: livePlace.category))
                                .foregroundStyle(placeColor(for: livePlace.category))
                                .font(.subheadline)
                            Text(livePlace.category.isEmpty ? "None" : livePlace.category)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
                if let description = place.notes, !description.isEmpty {
                    DetailRow(label: "Description") {
                        Text(description)
                    }
                }
                if let summary = place.aiSummary, !summary.isEmpty {
                    DetailRow(label: "Summary") {
                        Text(summary)
                    }
                }
                DetailRow(label: "Tags") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !livePlace.tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(livePlace.tags, id: \.self) { tag in
                                        HStack(spacing: 4) {
                                            Text(tag)
                                                .font(.caption)
                                            Button {
                                                Task {
                                                    let newTags = livePlace.tags.filter { $0 != tag }
                                                    try? await notionService.updatePlace(livePlace, name: livePlace.name, category: livePlace.category, status: livePlace.status, tags: newTags)
                                                }
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.caption2.weight(.semibold))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        if isEditingTags {
                            HStack(spacing: 8) {
                                TextField("New tag", text: $newTagText)
                                    .font(.subheadline)
                                    .submitLabel(.done)
                                    .onSubmit { Task { await addTag() } }
                                Button("Add") { Task { await addTag() } }
                                    .font(.subheadline)
                                    .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { isEditingTags = false; newTagText = "" }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            // Picker of all existing tags across places, filtered to ones not already on this place
                            let availableTags = Array(Set(
                                notionService.places.flatMap { $0.tags }
                            ))
                            .filter { !livePlace.tags.contains($0) }
                            .sorted()

                            Menu {
                                ForEach(availableTags, id: \.self) { tag in
                                    Button(tag) {
                                        Task { await addTagDirect(tag) }
                                    }
                                }
                                Divider()
                                Button {
                                    isEditingTags = true
                                } label: {
                                    Label("New tag…", systemImage: "plus")
                                }
                            } label: {
                                Label("Add tag", systemImage: "plus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let rating = place.ratingPersonal {
                    DetailRow(label: "Your rating") {
                        StarDisplay(rating: rating)
                    }
                }
                if let external = place.ratingExternal {
                    DetailRow(label: "Google rating") {
                        Text(String(format: "%.1f", external))
                    }
                }
                DetailRow(label: "Visits") {
                    Text("\(place.visitCount)")
                }
                if let last = place.lastVisited {
                    DetailRow(label: "Last visited") {
                        Text(last, style: .date)
                    }
                }
                Button {
                    showingSpots = true
                } label: {
                    Label("View Spots", systemImage: "map.fill")
                        .font(.subheadline)
                }
            }
            .padding()
        }
    }

    // MARK: - Info

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !place.address.isEmpty {
                    DetailRow(label: "Address") {
                        Text(place.address)
                    }
                }
                if let phone = place.phone, !phone.isEmpty {
                    Button {
                        if let url = URL(string: "tel://\(phone.filter { $0.isNumber })") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        DetailRow(label: "Phone") {
                            Text(phone).foregroundStyle(.blue)
                        }
                    }
                    .tint(.primary)
                }
                if let website = place.website, !website.isEmpty {
                    Button {
                        if let url = URL(string: website) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        DetailRow(label: "Website") {
                            Text(website)
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .tint(.primary)
                }
                if let hours = place.hours, !hours.isEmpty {
                    DetailRow(label: "Hours") {
                        Text(hours)
                    }
                }
                Button {
                    let notionID = livePlace.id.replacingOccurrences(of: "-", with: "")
                    if let url = URL(string: "https://notion.so/\(notionID)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    DetailRow(label: "Notion") {
                        HStack {
                            Text("Open in Notion")
                                .foregroundStyle(.blue)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .tint(.primary)

                // Re-enrich
                DetailRow(label: "Google Places") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            Task { await runEnrich() }
                        } label: {
                            HStack(spacing: 6) {
                                if isEnriching {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text(isEnriching ? "Searching…" : "Re-enrich from Google")
                                    .font(.subheadline)
                            }
                        }
                        .disabled(isEnriching)
                        .tint(.blue)
                        if let err = enrichError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding()
        }
        .alert("Update from Google Places?", isPresented: $showingEnrichConfirm, presenting: enrichCandidate) { candidate in
            Button("Update") {
                Task { try? await notionService.enrichPlace(livePlace, from: candidate) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text("\(candidate.name)\n\(candidate.formattedAddress)")
        }
    }

    private func runEnrich() async {
        isEnriching = true
        enrichError = nil
        do {
            let coord = CLLocationCoordinate2D(latitude: livePlace.latitude, longitude: livePlace.longitude)
            let results = try await GooglePlacesService.shared.nearbySearch(coordinate: coord, query: livePlace.name)
            if let top = results.first {
                enrichCandidate = top
                showingEnrichConfirm = true
            } else {
                enrichError = "No match found on Google Places."
            }
        } catch {
            enrichError = error.localizedDescription
        }
        isEnriching = false
    }

    // MARK: - Notes

    private var notesTab: some View {
        MarkdownEditorView(
            text: $placeNoteContent,
            onSave: { newText in
                let path = "Notes/Places/\(NoteStore.shared.placeNoteFilename(for: place.name)).md"
                if !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? NoteStore.shared.writeFile(path, content: newText)
                    NotificationCenter.default.post(name: .noteStorePlaceNoteDidChange, object: place.name)
                }
            },
            placeholder: "Notes about \(place.name)…",
            onWikiTap: { name in
                if let p = notionService.places.first(where: { $0.name == name }) {
                    wikiLinkTarget = .place(p)
                } else if let p = notionService.people.first(where: { $0.name == name }) {
                    wikiLinkTarget = .person(p)
                }
            },
            wikiSuggestions: { query in
                let q = query.lowercased()
                let places = notionService.places
                    .map { $0.name }
                    .filter { q.isEmpty || $0.lowercased().contains(q) }
                    .sorted()
                    .map { (name: $0, isPlace: true) }
                let people = notionService.people
                    .map { $0.name }
                    .filter { n in (q.isEmpty || n.lowercased().contains(q)) && !places.contains(where: { $0.name == n }) }
                    .sorted()
                    .map { (name: $0, isPlace: false) }
                return Array((places + people).prefix(8))
            }
        )
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                switch target {
                case .place(let p):
                    PlaceDetailView(place: p)
                        .environment(notionService)
                        .environment(locationManager)
                case .person(let p):
                    PersonDetailView(personID: p.id, personName: p.name)
                        .environment(notionService)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            guard !placeNoteLoaded else { return }
            placeNoteLoaded = true
            let path = "Notes/Places/\(NoteStore.shared.placeNoteFilename(for: place.name)).md"
            placeNoteContent = (try? NoteStore.shared.readFile(path)) ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStorePlaceNoteDidChange)) { notification in
            // Reload if another route (e.g. capture triage) just wrote this place's note
            guard let updatedPlace = notification.object as? String,
                  updatedPlace == place.name else { return }
            let path = "Notes/Places/\(NoteStore.shared.placeNoteFilename(for: place.name)).md"
            let fresh = (try? NoteStore.shared.readFile(path)) ?? ""
            if fresh != placeNoteContent { placeNoteContent = fresh }
        }
    }

    // MARK: - Settings

    private var settingsTab: some View {
        Form {
            Section("Behavior") {
                Toggle("Pinned", isOn: Binding(
                    get: { livePlace.flagged },
                    set: { _ in Task { try? await notionService.toggleFlagged(livePlace) } }
                ))
                Toggle("Frequent", isOn: Binding(
                    get: { livePlace.frequent },
                    set: { _ in Task { try? await notionService.toggleFrequent(livePlace) } }
                ))
                Toggle("Skip Enrichment", isOn: Binding(
                    get: { livePlace.skipEnrichment },
                    set: { _ in Task { try? await notionService.toggleSkipEnrichment(livePlace) } }
                ))
                Toggle("Prompt Log on Exit", isOn: Binding(
                    get: { livePlace.promptLog },
                    set: { _ in Task { try? await notionService.togglePromptLog(livePlace) } }
                ))
            }

            Section {
                Toggle("Exclude from Geofencing", isOn: Binding(
                    get: { livePlace.geofenceExcluded },
                    set: { _ in Task { try? await notionService.toggleGeofenceExcluded(livePlace) } }
                ))
                HStack {
                    Text("Radius")
                    Spacer()
                    TextField("default", text: $radiusStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($settingsFieldFocused)
                    Text("m").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Dwell Time")
                    Spacer()
                    TextField("default", text: $dwellStr)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($settingsFieldFocused)
                    Text("min").foregroundStyle(.secondary)
                }
                Button("Save Geofencing Settings") {
                    settingsFieldFocused = false
                    Task {
                        try? await notionService.setGeofenceRadius(livePlace, metres: Int(radiusStr))
                        try? await notionService.setDwellTime(livePlace, minutes: Int(dwellStr))
                    }
                }
                .disabled(
                    Int(radiusStr) == livePlace.geofenceRadius &&
                    Int(dwellStr) == livePlace.dwellTime
                )
            } header: {
                Text("Geofencing")
            } footer: {
                Text("Radius default: 50m (200m for frequent places). Dwell default: 3 min.")
            }
        }
        .onAppear {
            radiusStr = livePlace.geofenceRadius.map { String($0) } ?? ""
            dwellStr = livePlace.dwellTime.map { String($0) } ?? ""
        }
    }

    // MARK: - Visits

    private var visitsTab: some View {
        ScrollView {
            if placeVisits.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No visits yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(placeVisits) { visit in
                        Button {
                            editingVisit = visit
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(visit.date, style: .date)
                                            .font(.subheadline.bold())
                                        Spacer()
                                        if !visit.photoURLs.isEmpty {
                                            Label("\(visit.photoURLs.count)", systemImage: "photo")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let rating = visit.rating {
                                            StarDisplay(rating: rating)
                                        }
                                    }
                                    if let notes = visit.notes, !notes.isEmpty {
                                        Text(notes)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 4)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { try? await notionService.deleteVisit(id: visit.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Divider()
                    }
                }
                .padding()
            }
        }
        .refreshable { await notionService.fetchVisits() }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                let url = URL(string: "maps://?daddr=\(place.latitude),\(place.longitude)")!
                UIApplication.shared.open(url)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                showingCheckIn = true
            } label: {
                Label("Check In", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { try? await notionService.toggleFlagged(place) }
            } label: {
                Image(systemName: livePlace.flagged ? "star.fill" : "star")
                    .font(.title3)
                    .frame(width: 36)
            }
            .buttonStyle(.bordered)
            .tint(livePlace.flagged ? .yellow : .secondary)

            Button {
                Task {
                    try? await notionService.markPlaceForReview(livePlace)
                    markedForReview = true
                }
            } label: {
                Image(systemName: markedForReview ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    .font(.title3)
                    .frame(width: 36)
            }
            .buttonStyle(.bordered)
            .tint(markedForReview ? .orange : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Visit Edit Sheet

struct VisitEditSheet: View {
    let visit: Visit
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var rating: Int
    @State private var notes: String
    @State private var isSaving = false

    init(visit: Visit) {
        self.visit = visit
        _rating = State(initialValue: visit.rating ?? 0)
        _notes = State(initialValue: visit.notes ?? "")
    }

    private var livePhotoURLs: [String] {
        notion.visits.first { $0.id == visit.id }?.photoURLs ?? visit.photoURLs
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Text(visit.date, style: .date)
                        .foregroundStyle(.secondary)
                }
                if !livePhotoURLs.isEmpty {
                    Section("Photos") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(livePhotoURLs, id: \.self) { urlString in
                                    if let url = URL(string: urlString) {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable()
                                                    .scaledToFill()
                                                    .frame(width: 130, height: 130)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                            case .failure:
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.secondary.opacity(0.15))
                                                    .frame(width: 130, height: 130)
                                                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                                            default:
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.secondary.opacity(0.1))
                                                    .frame(width: 130, height: 130)
                                                    .overlay(ProgressView())
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                }
                Section("Rating") {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { star in
                            Button {
                                rating = (rating == star) ? 0 : star
                            } label: {
                                Image(systemName: star <= rating ? "star.fill" : "star")
                                    .foregroundStyle(star <= rating ? .yellow : .secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                        if rating > 0 {
                            Button { rating = 0 } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Notes") {
                    TextField("Add notes…", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text("Save").frame(maxWidth: .infinity).bold()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .refreshable { await refreshFromNotion() }
            .navigationTitle("Edit Visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await refreshFromNotion() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isSaving)
                }
            }
            .task { await refreshFromNotion() }
        }
    }

    private func refreshFromNotion() async {
        await notion.fetchVisits()
        if let fresh = notion.visits.first(where: { $0.id == visit.id }) {
            notes = fresh.notes ?? ""
            rating = fresh.rating ?? 0
        }
    }

    private func save() async {
        isSaving = true
        try? await notion.updateVisit(
            visit,
            rating: rating == 0 ? nil : rating,
            notes: notes.isEmpty ? nil : notes
        )
        await notion.fetchVisits()
        dismiss()
    }
}

// MARK: - Place Edit Sheet

private let placeEditCategories = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                    "Attraction", "Venue", "House", "Fitness",
                                    "Office", "Airport", "Medical", "Park", "Grocery"]

struct PlaceEditSheet: View {
    let place: Place
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var category: String
    @State private var status: String
    @State private var city: String
    @State private var notes: String
    @State private var dwellTimeText: String
    @State private var geofenceRadiusText: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showingArchiveConfirm = false

    init(place: Place) {
        self.place = place
        _name     = State(initialValue: place.name)
        _category = State(initialValue: place.category.isEmpty ? "Restaurant" : place.category)
        _status   = State(initialValue: place.status.isEmpty ? "Visited" : place.status)
        _city     = State(initialValue: place.city)
        _notes    = State(initialValue: place.notes ?? "")
        _dwellTimeText      = State(initialValue: place.dwellTime.map { String($0) } ?? "")
        _geofenceRadiusText = State(initialValue: place.geofenceRadius.map { String($0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Place name", text: $name)
                }

                Section("Location") {
                    TextField("City", text: $city)
                }

                Section {
                    HStack {
                        Text("Category")
                        Spacer()
                        Picker("Category", selection: $category) {
                            ForEach(placeEditCategories, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    Picker("Status", selection: $status) {
                        Text("Visited").tag("Visited")
                        Text("Want to Visit").tag("Want to Visit")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Description") {
                    TextField("Short description…", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    HStack {
                        Text("Dwell time")
                        Spacer()
                        TextField("3", text: $dwellTimeText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("min")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Geofence radius")
                        Spacer()
                        TextField(place.frequent ? "200" : "50", text: $geofenceRadiusText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("m")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Geofencing")
                } footer: {
                    Text("Leave blank to use defaults (3 min dwell, 50 m radius / 200 m if Frequent).")
                }

                if place.enrichmentStatus == "Needs Review" {
                    Section {
                        Button {
                            Task {
                                try? await notion.clearReviewFlag(place)
                                dismiss()
                            }
                        } label: {
                            Label("Clear Review Flag", systemImage: "checkmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("Marks this place as Enriched and removes it from the Needs Review list.")
                    }
                }

                if let err = saveError {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else {
                            Text("Save").frame(maxWidth: .infinity).bold()
                        }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    Button(role: .destructive) {
                        showingArchiveConfirm = true
                    } label: {
                        Label("Archive Place", systemImage: "archivebox")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Archived places are hidden from all views but not deleted.")
                }
            }
            .navigationTitle("Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog("Archive \(place.name)?", isPresented: $showingArchiveConfirm, titleVisibility: .visible) {
                Button("Archive", role: .destructive) {
                    Task {
                        try? await notion.archivePlace(place)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This place will be hidden from all views.")
            }
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        saveError = nil
        do {
            try await notion.updatePlace(
                place,
                name: trimmed,
                category: category,
                status: status,
                city: city.trimmingCharacters(in: .whitespaces),
                notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes.trimmingCharacters(in: .whitespaces)
            )
            let newDwell  = Int(dwellTimeText.trimmingCharacters(in: .whitespaces))
            let newRadius = Int(geofenceRadiusText.trimmingCharacters(in: .whitespaces))
            if newDwell != place.dwellTime {
                try await notion.setDwellTime(place, minutes: newDwell)
            }
            if newRadius != place.geofenceRadius {
                try await notion.setGeofenceRadius(place, metres: newRadius)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Supporting views

struct DetailRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StarDisplay: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...7, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
            }
        }
    }
}
