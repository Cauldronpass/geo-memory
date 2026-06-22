import SwiftUI

struct LifeView: View {
    @Environment(NotionService.self) private var notion

    var body: some View {
        NavigationStack {
            List {
                LifeMenuRow(icon: "calendar", color: .indigo, title: "Calendar", subtitle: "Visits, workouts & notes") {
                    LifeCalendarView().environment(notion)
                }
                LifeMenuRow(icon: "airplane", color: .blue, title: "Trips", subtitle: "Upcoming & past trips") {
                    LifePlaceholderView(title: "Trips", icon: "airplane")
                }
                LifeMenuRow(icon: "figure.run", color: .orange, title: "Fitness", subtitle: "Workouts & OrangeTheory") {
                    FitnessView()
                }
                LifeMenuRow(icon: "8.circle.fill", color: .green, title: "Billiards", subtitle: "Match journal & season stats") {
                    LifePlaceholderView(title: "Billiards", icon: "8.circle.fill")
                }
                LifeMenuRow(icon: "person.2.fill", color: .purple, title: "People", subtitle: "Personal contacts & connections") {
                    LifePeopleView()
                }
                LifeMenuRow(icon: "mappin.and.ellipse", color: .red, title: "Places", subtitle: "Your saved places") {
                    PlacesView()
                        .environment(notion)
                        .environment(LocationManager.shared)
                }
            }
            .navigationTitle("Life")
            .drawerToolbar()
        }
    }
}

// MARK: - Menu Row

struct LifeMenuRow<Destination: View>: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Placeholder

struct LifePlaceholderView: View {
    let title: String
    let icon: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: icon,
            description: Text("Coming soon")
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .drawerToolbar()
    }
}

// MARK: - People List

struct LifePeopleView: View {
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var selectedRelationship: String? = nil
    @State private var selectedPerson: Person? = nil
    @State private var showAddPerson = false

    private var relationshipTypes: [String] {
        Array(Set(notion.people.compactMap { $0.relationship })).sorted()
    }

    private var filtered: [Person] {
        notion.people.filter { person in
            let matchesSearch = searchText.isEmpty
                || person.name.localizedCaseInsensitiveContains(searchText)
            let matchesType = selectedRelationship == nil
                || person.relationship == selectedRelationship
            return matchesSearch && matchesType
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search people", text: $searchText)
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
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Filter pills
                if !relationshipTypes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            PeoplePill(label: "All", isActive: selectedRelationship == nil) {
                                selectedRelationship = nil
                            }
                            ForEach(relationshipTypes, id: \.self) { type in
                                PeoplePill(label: type, isActive: selectedRelationship == type) {
                                    selectedRelationship = selectedRelationship == type ? nil : type
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                }

                // People list
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { person in
                        Button {
                            selectedPerson = person
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.purple.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Text(String(person.name.prefix(1)))
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.purple)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name)
                                        .foregroundStyle(.primary)
                                        .font(.body)
                                    if let rel = person.relationship {
                                        Text(rel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if person.id != filtered.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .drawerToolbar()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddPerson = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $selectedPerson) { person in
            PersonDetailView(personID: person.id, personName: person.name)
                .environment(NotionService.shared)
        }
        .sheet(isPresented: $showAddPerson) {
            AddPersonView()
                .environment(notion)
        }
    }
}

// MARK: - People Filter Pill

struct PeoplePill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isActive ? Color.purple : Color(.secondarySystemGroupedBackground))
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Life Calendar View (all-inclusive)

struct LifeCalendarView: View {
    @Environment(NotionService.self) private var notion
    @State private var dayNoteAction: DayNoteAction?
    @State private var dayWorkouts: [Workout]? = nil
    @State private var dayWorkoutsTitle: String? = nil
    @State private var selectedWorkout: Workout? = nil
    @State private var dayVisits: [Visit]? = nil
    @State private var dayVisitsTitle: String? = nil
    @State private var mixedDayEntries: [CalendarEntry]?
    @State private var selectedBucketScope: String?
    @State private var showAllNotes = false
    @State private var showQuickNote = false
    @State private var dayNotesListDate: Date? = nil

    private let bucketScopes = ["This Week", "Next Week", "This Month", "Next Month"]
    private let bucketAbbrevs = ["This Week": "TW", "Next Week": "NW", "This Month": "TM", "Next Month": "NM"]

    private var bucketNotesList: [DayNote] {
        notion.dayNotes.filter { $0.scope != nil }
    }
    private func bucketCount(for scope: String) -> Int {
        bucketNotesList.filter { $0.scope == scope }.count
    }

    private func dateKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    // Workouts → CalendarEntry (prefixed "w-" so monthStats can distinguish)
    private var workoutEntries: [CalendarEntry] {
        notion.workouts.map { w in
            CalendarEntry(
                id: "w-\(w.id)",
                date: w.date,
                color: .orange,
                cellStat: nil,
                displayName: w.name.isEmpty ? w.type : w.name,
                value: w.distance,
                shape: .square
            )
        }
    }

    // Visits → CalendarEntry (prefixed "v-")
    private var visitEntries: [CalendarEntry] {
        notion.visits.map { v in
            CalendarEntry(
                id: "v-\(v.id)",
                date: v.date,
                color: .teal,
                cellStat: nil,
                displayName: v.placeName,
                value: nil,
                shape: .circle
            )
        }
    }

    private var allEntries: [CalendarEntry] {
        (workoutEntries + visitEntries).sorted { $0.date > $1.date }
    }

    private func monthStats(_ monthEntries: [CalendarEntry]) -> [(String, String)] {
        let workouts = monthEntries.filter { $0.id.hasPrefix("w-") }.count
        let visits   = monthEntries.filter { $0.id.hasPrefix("v-") }.count
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let activeNotes = notion.dayNotes.filter {
            if $0.scope != nil { return true }
            guard let d = $0.date else { return false }
            return cal.startOfDay(for: d) >= today
        }.count
        var stats: [(String, String)] = []
        if workouts > 0 { stats.append(("\(workouts)", "workouts")) }
        if visits   > 0 { stats.append(("\(visits)",   "visits"))   }
        if activeNotes > 0 { stats.append(("\(activeNotes)", "notes")) }
        return stats
    }

    private func route(_ entry: CalendarEntry) {
        let cal = Calendar.current
        if entry.id.hasPrefix("w-") {
            let wid = String(entry.id.dropFirst(2))
            if let w = notion.workouts.first(where: { $0.id == wid }) {
                // Specific workout (from picker) → go direct to detail
                selectedWorkout = w
            } else {
                // Fallback: show all workouts for that day
                let sorted = notion.workouts
                    .filter { cal.isDate($0.date, inSameDayAs: entry.date) }
                    .sorted { $0.date > $1.date }
                dayWorkouts = sorted.isEmpty ? nil : sorted
            }
        } else if entry.id.hasPrefix("v-") {
            let sorted = notion.visits
                .filter { cal.isDate($0.date, inSameDayAs: entry.date) }
                .sorted { $0.date > $1.date }
            dayVisits = sorted.isEmpty ? nil : sorted
        } else if entry.id.hasPrefix("note-") {
            // Extract specific note ID (strip "note-" prefix)
            let nid = String(entry.id.dropFirst(5))
            if let note = notion.dayNotes.first(where: { $0.id == nid }) {
                dayNoteAction = .tapDate(entry.date, note)
            } else {
                dayNotesListDate = entry.date
            }
        }
    }

    var body: some View {
        ScrollView {
            CalendarGridView(
                entries: allEntries,
                notesByDate: notion.dayNotesByDate,
                bucketNotes: [],
                showBucketControls: false,
                weekSecondary: { _ in nil },
                monthStats: monthStats,
                onSelect: { dayEntries in
                    guard !dayEntries.isEmpty else { return }
                    let cal = Calendar.current
                    let dayNotesList = notion.dayNotes.filter { n in
                        guard let nd = n.date, n.scope == nil else { return false }
                        return cal.isDate(nd, inSameDayAs: dayEntries[0].date)
                    }
                    let hasNote = !dayNotesList.isEmpty
                    let wEntries = dayEntries.filter { $0.id.hasPrefix("w-") }
                    let vEntries = dayEntries.filter { $0.id.hasPrefix("v-") }
                    // Pure workout day → single workout direct, multiple workout list
                    if !wEntries.isEmpty && vEntries.isEmpty && !hasNote {
                        if wEntries.count == 1 {
                            route(wEntries[0])
                        } else {
                            let sorted = notion.workouts
                                .filter { cal.isDate($0.date, inSameDayAs: wEntries[0].date) }
                                .sorted { $0.date > $1.date }
                            dayWorkouts = sorted.isEmpty ? nil : sorted
                        }
                        return
                    }
                    // Pure visit day → visit list sheet
                    if !vEntries.isEmpty && wEntries.isEmpty && !hasNote {
                        route(vEntries[0])
                        return
                    }
                    // Mixed → picker with one entry per note
                    var all = dayEntries
                    for note in dayNotesList {
                        let preview = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
                        let label = preview.isEmpty ? "Note" : String(preview.prefix(40))
                        all.append(CalendarEntry(
                            id: "note-\(note.id)",
                            date: dayEntries[0].date,
                            color: .indigo,
                            cellStat: nil,
                            displayName: label,
                            value: nil,
                            shape: .circle
                        ))
                    }
                    mixedDayEntries = all
                },
                onNoteAction: { action in
                    if case .tapDate(let date, let note) = action, note != nil {
                        // Day has existing notes — open list sheet showing all of them
                        dayNotesListDate = date
                    } else {
                        // No existing note (or bucket tap) — open editor to create
                        dayNoteAction = action
                    }
                },
                onStatTap: { label, monthEntries in
                    if label == "workouts" {
                        let ids = Set(monthEntries.filter { $0.id.hasPrefix("w-") }.map { String($0.id.dropFirst(2)) })
                        let sorted = notion.workouts.filter { ids.contains($0.id) }.sorted { $0.date > $1.date }
                        if !sorted.isEmpty {
                            let monthTitle = sorted[0].date.formatted(.dateTime.month(.wide).year())
                            dayWorkoutsTitle = "\(monthTitle) — Workouts"
                            dayWorkouts = sorted
                        }
                    } else if label == "visits" {
                        let ids = Set(monthEntries.filter { $0.id.hasPrefix("v-") }.map { String($0.id.dropFirst(2)) })
                        let sorted = notion.visits.filter { ids.contains($0.id) }.sorted { $0.date > $1.date }
                        if !sorted.isEmpty {
                            let monthTitle = sorted[0].date.formatted(.dateTime.month(.wide).year())
                            dayVisitsTitle = "\(monthTitle) — Visits"
                            dayVisits = sorted
                        }
                    } else if label == "notes" {
                        showAllNotes = true
                    }
                }
            )
            .padding(.vertical)

            bottomBar
                .padding(.horizontal)
                .padding(.bottom, 20)
        }
        .task {
            if notion.workouts.isEmpty {
                await notion.fetchWorkouts()
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.large)
        .drawerToolbar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task {
                        await notion.fetchDayNotes()
                        await notion.fetchWorkouts()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showQuickNote = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
            }
        }
        .sheet(isPresented: $showQuickNote) {
            QuickNoteSheet().environment(notion)
        }
        .sheet(isPresented: Binding(get: { dayWorkouts != nil }, set: { if !$0 { dayWorkouts = nil; dayWorkoutsTitle = nil } })) {
            if let workouts = dayWorkouts {
                DayWorkoutsSheet(workouts: workouts, titleOverride: dayWorkoutsTitle).environment(notion)
            }
        }
        .sheet(item: $selectedWorkout) { w in
            WorkoutDetailView(workout: w).environment(notion)
        }
        .sheet(isPresented: Binding(get: { dayVisits != nil }, set: { if !$0 { dayVisits = nil; dayVisitsTitle = nil } })) {
            if let visits = dayVisits {
                DayVisitsSheet(visits: visits, titleOverride: dayVisitsTitle).environment(notion)
            }
        }
        .sheet(item: $dayNoteAction) { action in
            DayNoteSheet(action: action).environment(notion)
        }
        .sheet(isPresented: $showAllNotes) {
            AllNotesSheet().environment(notion)
        }
        .sheet(isPresented: Binding(
            get: { mixedDayEntries != nil },
            set: { if !$0 { mixedDayEntries = nil } }
        )) {
            if let entries = mixedDayEntries {
                MixedDayPickerSheet(entries: entries) { entry in
                    route(entry)
                    mixedDayEntries = nil
                }
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
        .sheet(isPresented: Binding(
            get: { dayNotesListDate != nil },
            set: { if !$0 { dayNotesListDate = nil } }
        )) {
            if let date = dayNotesListDate {
                DayNotesListSheet(date: date) { note in
                    dayNotesListDate = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        dayNoteAction = .tapDate(date, note)
                    }
                }
                .environment(notion)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Compact legend
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 8, height: 8)
                    Text("Workout").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.teal).frame(width: 8, height: 8)
                    Text("Visit").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.indigo).frame(width: 5, height: 5)
                    Text("Note").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 10)

            // Bucket note tiles
            HStack(spacing: 6) {
                ForEach(bucketScopes, id: \.self) { scope in
                    let abbrev = bucketAbbrevs[scope] ?? scope
                    let count = bucketCount(for: scope)
                    Button { selectedBucketScope = scope } label: {
                        VStack(spacing: 1) {
                            Text(abbrev)
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("\(count)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(count > 0 ? Color.orange : Color(.tertiaryLabel))
                        }
                        .frame(width: 38, height: 38)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Bucket Note Sheet

struct BucketNoteSheet: View {
    let scope: String
    let onEdit: (DayNote) -> Void

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var quickNote = ""
    @State private var isSaving = false
    @FocusState private var fieldFocused: Bool

    private var notes: [DayNote] {
        notion.dayNotes.filter { $0.scope == scope }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scope).font(.title2.bold())
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
                    description: Text("Type below to add your first note for \(scope.lowercased())"))
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
        try? await notion.saveBucketNote(scope: scope, noteBody: text)
        quickNote = ""
        fieldFocused = false
        isSaving = false
    }
}

// MARK: - Quick Note Sheet

struct QuickNoteSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var noteText = ""
    @State private var scope = "This Week"
    @State private var isSaving = false

    private let bucketScopes = ["This Week", "Next Week", "This Month", "Next Month"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Quick Note")
                    .font(.title3.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 20)

            // Scope picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Today") { scope = "today" }
                        .scopeChip(selected: scope == "today")
                    ForEach(bucketScopes, id: \.self) { s in
                        Button(s) { scope = s }
                            .scopeChip(selected: scope == s)
                    }
                }
                .padding(.horizontal)
            }

            // Text input
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                TextEditor(text: $noteText)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .padding(8)
                    .frame(minHeight: 120)
                if noteText.isEmpty {
                    Text("What do you want to remember?")
                        .foregroundStyle(Color(.placeholderText))
                        .font(.body)
                        .padding(.top, 16)
                        .padding(.leading, 13)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal)

            // Save button
            Button {
                Task { await save() }
            } label: {
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Save")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.orange.opacity(0.4) : Color.orange,
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            .padding(.horizontal)

            Spacer()
        }
        .onAppear { focused = true }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func save() async {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSaving = true
        if scope == "today" {
            try? await notion.saveDayNote(date: Date(), noteBody: text)
        } else {
            try? await notion.saveBucketNote(scope: scope, noteBody: text)
        }
        dismiss()
    }
}

private extension Button where Label == Text {
    func scopeChip(selected: Bool) -> some View {
        self
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Color.orange : Color(.systemGray5), in: Capsule())
            .buttonStyle(.plain)
    }
}

// MARK: - All Notes Sheet

struct AllNotesSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var editAction: DayNoteAction? = nil
    @State private var quickNote = ""
    @State private var quickScope = "This Week"
    @FocusState private var fieldFocused: Bool
    @State private var isSaving = false

    private let bucketScopes = ["This Week", "Next Week", "This Month", "Next Month"]

    private struct NoteGroup: Identifiable {
        let id: String
        let title: String
        let notes: [DayNote]
    }

    private var groups: [NoteGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let endOfWeek = cal.date(byAdding: .day, value: 7, to: today)!
        let notes = notion.dayNotes

        let todayNotes = notes.filter {
            guard let d = $0.date, $0.scope == nil else { return false }
            return cal.isDate(d, inSameDayAs: today)
        }
        let tomorrowNotes = notes.filter {
            guard let d = $0.date, $0.scope == nil else { return false }
            return cal.isDate(d, inSameDayAs: tomorrow)
        }
        let weekDayNotes = notes.filter {
            guard let d = $0.date, $0.scope == nil else { return false }
            let ds = cal.startOfDay(for: d)
            return ds > tomorrow && ds < endOfWeek
        }.sorted { $0.date! < $1.date! }
        let futureDayNotes = notes.filter {
            guard let d = $0.date, $0.scope == nil else { return false }
            return cal.startOfDay(for: d) >= endOfWeek
        }.sorted { $0.date! < $1.date! }

        var result: [NoteGroup] = []
        if !todayNotes.isEmpty        { result.append(.init(id: "today",   title: "Today",                   notes: todayNotes)) }
        if !tomorrowNotes.isEmpty     { result.append(.init(id: "tmrw",    title: "Tomorrow",                notes: tomorrowNotes)) }
        if !weekDayNotes.isEmpty      { result.append(.init(id: "wkdays",  title: "This Week — Dates",       notes: weekDayNotes)) }
        let tw = notes.filter { $0.scope == "This Week" }
        let nw = notes.filter { $0.scope == "Next Week" }
        let tm = notes.filter { $0.scope == "This Month" }
        let nm = notes.filter { $0.scope == "Next Month" }
        if !tw.isEmpty { result.append(.init(id: "tw", title: "This Week",  notes: tw)) }
        if !nw.isEmpty { result.append(.init(id: "nw", title: "Next Week",  notes: nw)) }
        if !tm.isEmpty { result.append(.init(id: "tm", title: "This Month", notes: tm)) }
        if !nm.isEmpty { result.append(.init(id: "nm", title: "Next Month", notes: nm)) }
        if !futureDayNotes.isEmpty    { result.append(.init(id: "future",   title: "Coming Up",              notes: futureDayNotes)) }
        return result
    }

    private var activeCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return notion.dayNotes.filter {
            if $0.scope != nil { return true }
            guard let d = $0.date else { return false }
            return cal.startOfDay(for: d) >= today
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes").font(.title2.bold())
                    Text("\(activeCount) active note\(activeCount == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.font(.body.weight(.medium))
            }
            .padding()
            Divider()

            if groups.isEmpty {
                Spacer()
                ContentUnavailableView("No notes", systemImage: "note.text",
                    description: Text("Add your first note below"))
                Spacer()
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.notes) { note in
                                Button { editAction = noteAction(for: note) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let date = note.date {
                                            Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(Color.indigo.opacity(0.7))
                                        }
                                        Text(note.body)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(3)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.indigo.opacity(0.09))
                                        .padding(.vertical, 3)
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { try? await notion.deleteDayNote(id: note.id) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button { editAction = noteAction(for: note) } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.indigo)
                                }
                            }
                        } header: {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider()

            // Quick-add with bucket/today picker
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("Add to:")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("Today") { quickScope = "today" }
                        Divider()
                        ForEach(bucketScopes, id: \.self) { scope in
                            Button(scope) { quickScope = scope }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(quickScope == "today" ? "Today" : quickScope)
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.indigo, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                TextEditor(text: $quickNote)
                    .focused($fieldFocused)
                    .frame(minHeight: 52, maxHeight: 90)
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
                    Button { Task { await saveQuick() } } label: {
                        if isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 10))
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $editAction) { action in
            DayNoteSheet(action: action).environment(notion)
        }
    }

    private func noteAction(for note: DayNote) -> DayNoteAction {
        if let scope = note.scope { return .tapBucket(scope, note) }
        return .tapDate(note.date ?? Date(), note)
    }

    private func saveQuick() async {
        let text = quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSaving = true
        if quickScope == "today" {
            try? await notion.saveDayNote(date: Date(), noteBody: text)
        } else {
            try? await notion.saveBucketNote(scope: quickScope, noteBody: text)
        }
        quickNote = ""
        fieldFocused = false
        isSaving = false
    }
}

// MARK: - Day Workouts Sheet

struct DayWorkoutsSheet: View {
    let workouts: [Workout]
    var titleOverride: String? = nil
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var selectedWorkout: Workout? = nil

    private var title: String {
        titleOverride ?? (workouts.first?.date).map {
            $0.formatted(.dateTime.weekday(.wide).month(.wide).day())
        } ?? "Workouts"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text("\(workouts.count) workout\(workouts.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.font(.body.weight(.medium))
            }
            .padding()
            Divider()
            List {
                ForEach(workouts) { w in
                    Button { selectedWorkout = w } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(w.name.isEmpty ? w.type : w.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                HStack(spacing: 12) {
                                    if let dur = w.duration {
                                        Label("\(dur) min", systemImage: "timer")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let dist = w.distance {
                                        Label(String(format: "%.1f mi", dist), systemImage: "figure.run")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let cal = w.calories {
                                        Label("\(cal) cal", systemImage: "flame")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(Color.orange.opacity(0.6))
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.12))
                            .padding(.vertical, 3)
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $selectedWorkout) { w in
            WorkoutDetailView(workout: w).environment(notion)
        }
    }
}

// MARK: - Day Visits Sheet

struct DayVisitsSheet: View {
    let visits: [Visit]
    var titleOverride: String? = nil
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var selectedVisit: Visit? = nil

    private var title: String {
        titleOverride ?? (visits.first?.date).map {
            $0.formatted(.dateTime.weekday(.wide).month(.wide).day())
        } ?? "Visits"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text("\(visits.count) visit\(visits.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.font(.body.weight(.medium))
            }
            .padding()
            Divider()
            List {
                ForEach(visits) { v in
                    Button { selectedVisit = v } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(v.placeName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    Text(v.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let rating = v.rating, rating > 0 {
                                        HStack(spacing: 2) {
                                            ForEach(0..<5) { i in
                                                Image(systemName: i < rating ? "star.fill" : "star")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(Color.teal.opacity(0.6))
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.teal.opacity(0.12))
                            .padding(.vertical, 3)
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $selectedVisit) { v in
            VisitDetailView(visit: v).environment(notion)
        }
    }
}

// MARK: - Mixed Day Picker Sheet

struct MixedDayPickerSheet: View {
    let entries: [CalendarEntry]
    let onSelect: (CalendarEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    private var date: Date { entries[0].date }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 3) {
                Text(date.formatted(.dateTime.weekday(.wide)))
                    .font(.title2.bold())
                Text(date.formatted(.dateTime.month(.wide).day(.defaultDigits)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ForEach(entries) { entry in
                Button {
                    onSelect(entry)
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        entryIcon(entry)
                        Text(entry.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                if entry.id != entries.last?.id {
                    Divider().padding(.leading, 60)
                }
            }

            Spacer()
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func entryIcon(_ entry: CalendarEntry) -> some View {
        if entry.shape == .square {
            RoundedRectangle(cornerRadius: 6)
                .fill(entry.color)
                .frame(width: 32, height: 32)
        } else {
            Circle()
                .fill(entry.color)
                .frame(width: 32, height: 32)
        }
    }
}

// MARK: - Add Person

struct AddPersonView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    private let relationships = ["colleague", "friend", "family", "neighbor", "client", "mentor", "Pool Team", "other"]
    private let strengthOptions = ["new", "active", "dormant"]
    private let tagOptions = ["Family", "Business", "Friend", "Network", "Work", "Pool", "Reference"]

    @State private var name = ""
    @State private var relationship = ""
    @State private var relationshipStrength = "new"
    @State private var phone = ""
    @State private var email = ""
    @State private var companyContext = ""
    @State private var city = ""
    @State private var howWeMet = ""
    @State private var address = ""
    @State private var selectedTags: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingAddTag = false
    @State private var newTagText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Full name", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Identity") {
                    Picker("Category", selection: $relationship) {
                        Text("None").tag("")
                        ForEach(relationships, id: \.self) { r in
                            Text(r.capitalized).tag(r)
                        }
                    }
                    Picker("Status", selection: $relationshipStrength) {
                        ForEach(strengthOptions, id: \.self) { s in
                            Text(s.capitalized).tag(s)
                        }
                    }
                    TextField("Company / Context", text: $companyContext)
                    TextField("City", text: $city)
                    TextField("How We Met", text: $howWeMet)
                }

                Section("Contact") {
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Address", text: $address)
                }

                Section("Tags") {
                    let customTags = Array(selectedTags).filter { !tagOptions.contains($0) }.sorted()
                    FlowLayout(spacing: 8) {
                        ForEach(tagOptions, id: \.self) { tag in tagChip(tag) }
                        ForEach(customTags, id: \.self) { tag in tagChip(tag) }
                        Button { showingAddTag = true } label: {
                            Label("Add", systemImage: "plus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.1))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Add Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Adding…" : "Add") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    .fontWeight(.semibold)
                }
            }
            .alert("Add Tag", isPresented: $showingAddTag) {
                TextField("Tag name", text: $newTagText)
                    .autocorrectionDisabled()
                Button("Add") {
                    let tag = newTagText.trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { selectedTags.insert(tag) }
                    newTagText = ""
                }
                Button("Cancel", role: .cancel) { newTagText = "" }
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        Button {
            if selectedTags.contains(tag) { selectedTags.remove(tag) }
            else { selectedTags.insert(tag) }
        } label: {
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selectedTags.contains(tag) ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(selectedTags.contains(tag) ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func save() async {
        isSaving = true
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            let person = try await notion.addPerson(name: trimmedName)
            let hasOptional = !relationship.isEmpty || !phone.isEmpty || !email.isEmpty ||
                              !companyContext.isEmpty || !city.isEmpty || !howWeMet.isEmpty ||
                              !address.isEmpty || !selectedTags.isEmpty
            if hasOptional {
                try await notion.enrichPerson(
                    id: person.id,
                    relationship: relationship.isEmpty ? nil : relationship,
                    relationshipStrength: relationshipStrength,
                    companyContext: companyContext.isEmpty ? nil : companyContext,
                    city: city.isEmpty ? nil : city,
                    howWeMet: howWeMet.isEmpty ? nil : howWeMet,
                    tags: Array(selectedTags),
                    phone: phone.isEmpty ? nil : phone,
                    email: email.isEmpty ? nil : email,
                    address: address.isEmpty ? nil : address
                )
            }
            await notion.fetchPeople()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
