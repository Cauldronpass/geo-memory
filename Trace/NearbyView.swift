import SwiftUI
import CoreLocation

struct NearbyView: View {
    var onCalendarStateChange: ((Bool) -> Void)? = nil

    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @State private var searchText = ""
    @State private var selectedPlace: Place? = nil
    @State private var showPinnedOnly = false
    @State private var selectedCategory: String? = nil
    @State private var selectedTag: String? = nil
    @State private var dayNoteAction: DayNoteAction?
    @State private var showCalendar = false
    @State private var selectedBucketScope: String?
    @State private var noteToDelete: DayNote? = nil
    @State private var noteToMove: DayNote? = nil
    @State private var showMoveNote = false

    private let bucketScopes = ["This Week", "Next Week", "This Month", "Next Month"]
    private let bucketAbbrevs = ["This Week": "TW", "Next Week": "NW", "This Month": "TM", "Next Month": "NM"]

    private var availableCategories: [String] {
        Array(Set(notionService.places
            .filter { !$0.category.isEmpty }
            .map { $0.category }
        )).sorted()
    }

    private var availableTags: [String] {
        Array(Set(notionService.places.flatMap { $0.tags })).sorted()
    }

    private var hasActiveFilters: Bool {
        showPinnedOnly || selectedCategory != nil || selectedTag != nil
    }

    var filteredPlaces: [Place] {
        notionService.places
            .filter {
                (searchText.isEmpty ||
                 $0.name.localizedCaseInsensitiveContains(searchText) ||
                 $0.category.localizedCaseInsensitiveContains(searchText))
                && (!showPinnedOnly || $0.flagged)
                && (selectedCategory == nil || $0.category == selectedCategory)
                && (selectedTag == nil || $0.tags.contains(selectedTag!))
            }
            .sorted { a, b in
                // Frequent places always appear above non-frequent
                if a.frequent != b.frequent { return a.frequent }
                let distA = locationManager.distance(to: a) ?? .infinity
                let distB = locationManager.distance(to: b) ?? .infinity
                return distA < distB
            }
    }

    var recentPlaces: [Place] {
        guard searchText.isEmpty else { return [] }
        let recentIDs = notionService.visits
            .sorted { $0.date > $1.date }
            .reduce(into: [String]()) { result, visit in
                if !result.contains(visit.placeID) { result.append(visit.placeID) }
            }
            .prefix(5)
        return recentIDs.compactMap { id in
            notionService.places.first { $0.id == id }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if showCalendar {
                    ScrollView {
                        DayNotesCalendarView()
                            .environment(notionService)
                            .padding(.vertical)
                    }
                } else {
                    listView
                }
            }
            .navigationTitle(showCalendar ? "Notes" : "Nearby")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await notionService.fetchPlaces()
                            await notionService.fetchVisits()
                            await notionService.fetchDayNotes()
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        withAnimation { showCalendar.toggle() }
                    } label: {
                        Image(systemName: showCalendar ? "list.bullet" : "calendar")
                    }
                }
            }
            .sheet(item: $selectedPlace) { place in
                PlaceDetailView(place: place)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            }
            .onChange(of: showCalendar) { _, new in onCalendarStateChange?(new) }
            .sheet(item: $dayNoteAction) { action in
                DayNoteSheet(action: action).environment(notionService)
            }
            .sheet(isPresented: $showMoveNote) {
                if let note = noteToMove {
                    MoveDatePickerSheet(initialDate: Date()) { newDate in
                        Task {
                            try? await notionService.moveDayNote(id: note.id, toDate: newDate)
                            await notionService.fetchDayNotes()
                        }
                    }
                }
            }
            .confirmationDialog("Delete this note?", isPresented: Binding(
                get: { noteToDelete != nil },
                set: { if !$0 { noteToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let note = noteToDelete {
                        Task {
                            try? await notionService.deleteDayNote(id: note.id)
                            noteToDelete = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) { noteToDelete = nil }
            }
            .sheet(isPresented: Binding(
                get: { selectedBucketScope != nil },
                set: { if !$0 { selectedBucketScope = nil } }
            )) {
                if let scope = selectedBucketScope {
                    BucketNoteSheet(
                        scope: scope,
                        onEdit: { note in
                            selectedBucketScope = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                dayNoteAction = .tapBucket(scope, note)
                            }
                        }
                    )
                    .environment(notionService)
                }
            }
        }
    }

    // MARK: - List view

    private var listView: some View {
        VStack(spacing: 0) {
            // Filter chips
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

                Group {
                    if locationManager.authorizationStatus == .notDetermined {
                        VStack(spacing: 16) {
                            Image(systemName: "location.circle")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                            Text("Location access lets Trace show places near you.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                            Button("Allow Location Access") {
                                locationManager.requestPermission()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                    } else {
                        List {
                            // Today note card
                            todayNoteSection

                            if !recentPlaces.isEmpty {
                                Section(header: HStack(alignment: .firstTextBaseline, spacing: 4) {
    Text("Recent")
    Text("(unaffected by filters)").font(.caption2).foregroundStyle(.secondary)
}) {
                                    ForEach(recentPlaces) { place in
                                        Button { selectedPlace = place } label: {
                                            NearbyPlaceRow(place: place)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            Section(searchText.isEmpty && !hasActiveFilters ? "" : "Results") {
                                ForEach(filteredPlaces) { place in
                                    Button { selectedPlace = place } label: {
                                        NearbyPlaceRow(place: place)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .searchable(text: $searchText, prompt: "Search places")
                        .refreshable {
                            await notionService.fetchPlaces()
                            await notionService.fetchVisits()
                        }
                    }
                }
        }
    }

    // MARK: - Today note section

    @ViewBuilder
    private var todayNoteSection: some View {
        let todayNotes = notionService.dayNotes.filter { note in
            guard let d = note.date else { return false }
            return Calendar.current.isDateInToday(d)
        }

        Section {
            if todayNotes.isEmpty {
                Button {
                    dayNoteAction = .tapDate(Date(), nil)
                } label: {
                    Label("Add a note for today", systemImage: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                TabView {
                    ForEach(todayNotes) { note in
                        TodayNoteCard(note: note) {
                            dayNoteAction = .tapDate(Date(), note)
                        } onDelete: {
                            noteToDelete = note
                        } onMove: {
                            noteToMove = note
                            showMoveNote = true
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: todayNotes.count > 1 ? .always : .never))
                .frame(height: 110)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        } header: {
            HStack {
                Text("Today")
                if todayNotes.count > 1 {
                    Text("· \(todayNotes.count) notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dayNoteAction = .tapDate(Date(), nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

// MARK: - Today note card

struct TodayNoteCard: View {
    let note: DayNote
    let onTap: () -> Void
    let onDelete: () -> Void
    let onMove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.body)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

            HStack {
                Spacer()
                Button {
                    onMove()
                } label: {
                    Image(systemName: "calendar.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color(.systemGray5), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(6)
                        .background(Color(.systemGray5), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }
}

struct NearbyPlaceRow: View {
    let place: Place
    @Environment(LocationManager.self) private var locationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(place.name)
                    .font(.headline)
                if place.flagged {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            HStack {
                Text(place.category.isEmpty ? place.city : "\(place.category) · \(place.city)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(locationManager.formattedDistance(to: place) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Day Notes Calendar View

struct DayNotesCalendarView: View {
    @Environment(NotionService.self) private var notion
    @State private var dayNoteAction: DayNoteAction?
    @State private var selectedBucketScope: String?
    @State private var selectedDayDate: Date? = nil

    private let bucketScopes = ["This Week", "Next Week", "This Month", "Next Month"]
    private let bucketAbbrevs = ["This Week": "TW", "Next Week": "NW", "This Month": "TM", "Next Month": "NM"]

    private var bucketNotesList: [DayNote] { notion.dayNotes.filter { $0.scope != nil } }
    private func bucketCount(for scope: String) -> Int {
        bucketNotesList.filter { $0.scope == scope }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            CalendarGridView(
                entries: [],
                notesByDate: notion.dayNotesByDate,
                bucketNotes: [],
                showBucketControls: false,
                weekSecondary: { _ in nil },
                monthStats: { _ in [] },
                onSelect: { _ in },
                onNoteAction: { action in
                    // If there are existing notes for this day, show the list first
                    if case .tapDate(let date, let note) = action, note != nil {
                        selectedDayDate = date
                    } else {
                        dayNoteAction = action
                    }
                }
            )

            // Bucket tiles
            HStack(spacing: 8) {
                ForEach(bucketScopes, id: \.self) { scope in
                    let abbrev = bucketAbbrevs[scope] ?? scope
                    let count = bucketCount(for: scope)
                    Button { selectedBucketScope = scope } label: {
                        VStack(spacing: 3) {
                            Text(abbrev)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("\(count)")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(count > 0 ? Color.orange : Color(.tertiaryLabel))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheet(item: $dayNoteAction) { action in
            DayNoteSheet(action: action).environment(notion)
        }
        .sheet(isPresented: Binding(
            get: { selectedDayDate != nil },
            set: { if !$0 { selectedDayDate = nil } }
        )) {
            if let date = selectedDayDate {
                DayNotesListSheet(
                    date: date,
                    onEdit: { note in
                        selectedDayDate = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            dayNoteAction = .tapDate(date, note)
                        }
                    }
                )
                .environment(notion)
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedBucketScope != nil },
            set: { if !$0 { selectedBucketScope = nil } }
        )) {
            if let scope = selectedBucketScope {
                BucketNoteSheet(
                    scope: scope,
                    onEdit: { note in
                        selectedBucketScope = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            dayNoteAction = .tapBucket(scope, note)
                        }
                    }
                )
                .environment(notion)
            }
        }
    }
}

// MARK: - Day Notes List Sheet

struct DayNotesListSheet: View {
    let date: Date
    let onEdit: (DayNote) -> Void

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var quickNote = ""
    @State private var isSaving = false
    @FocusState private var fieldFocused: Bool

    private var notes: [DayNote] {
        let cal = Calendar.current
        return notion.dayNotes.filter {
            guard let d = $0.date else { return false }
            return cal.isDate(d, inSameDayAs: date)
        }
    }

    private var title: String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text(notes.isEmpty ? "No notes" : "\(notes.count) note\(notes.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .font(.body.weight(.medium))
            }
            .padding()

            Divider()

            if notes.isEmpty {
                Spacer()
                ContentUnavailableView("No notes yet", systemImage: "note.text",
                    description: Text("Type below to add your first note for this day"))
                Spacer()
            } else {
                List {
                    ForEach(notes) { note in
                        Button { onEdit(note) } label: {
                            Text(note.body)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.systemGray5))
                                .padding(.vertical, 3)
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { try? await notion.deleteDayNote(id: note.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { onEdit(note) } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider()

            // Inline quick-add
            VStack(spacing: 8) {
                TextEditor(text: $quickNote)
                    .focused($fieldFocused)
                    .frame(minHeight: 60, maxHeight: 100)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .overlay(alignment: .topLeading) {
                        if quickNote.isEmpty {
                            Text("Add a note…")
                                .foregroundStyle(Color(.placeholderText))
                                .font(.body)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 4)

                HStack {
                    Spacer()
                    Button {
                        Task { await saveQuick() }
                    } label: {
                        if isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .disabled(quickNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func saveQuick() async {
        let text = quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSaving = true
        try? await notion.saveDayNote(date: date, noteBody: text)
        quickNote = ""
        fieldFocused = false
        isSaving = false
    }
}
