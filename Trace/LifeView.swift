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
                LifeMenuRow(icon: "8.circle.fill", color: .black, title: "Billiards", subtitle: "Match journal & season stats") {
                    BilliardsView()
                        .environment(notion)
                }
                LifeMenuRow(icon: "person.2.fill", color: .purple, title: "People", subtitle: "Personal contacts & connections") {
                    LifePeopleView()
                }
                LifeMenuRow(icon: "mappin.and.ellipse", color: .red, title: "Places", subtitle: "Your saved places") {
                    PlacesView()
                        .environment(notion)
                        .environment(LocationManager.shared)
                }
                LifeMenuRow(icon: "note.text", color: .teal, title: "Notes", subtitle: "Daily notes, buckets & places") {
                    NotesView()
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
    @State private var dayWorkouts: [Workout]? = nil
    @State private var dayWorkoutsTitle: String? = nil
    @State private var selectedWorkout: Workout? = nil
    @State private var dayVisits: [Visit]? = nil
    @State private var dayVisitsTitle: String? = nil
    @State private var mixedDayEntries: [CalendarEntry]?
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

        var stats: [(String, String)] = []
        if workouts > 0 { stats.append(("\(workouts)", "workouts")) }
        if visits   > 0 { stats.append(("\(visits)",   "visits"))   }
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
        }
    }

    var body: some View {
        ScrollView {
            CalendarGridView(
                entries: allEntries,
                showBucketControls: false,
                weekSecondary: { _ in nil },
                monthStats: monthStats,
                onSelect: { dayEntries in
                    guard !dayEntries.isEmpty else { return }
                    let cal = Calendar.current
                    let wEntries = dayEntries.filter { $0.id.hasPrefix("w-") }
                    let vEntries = dayEntries.filter { $0.id.hasPrefix("v-") }
                    if !wEntries.isEmpty && vEntries.isEmpty {
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
                    if !vEntries.isEmpty && wEntries.isEmpty {
                        route(vEntries[0])
                        return
                    }
                    mixedDayEntries = dayEntries
                },
                onNoteAction: nil,
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
                    }
                }
            )
            .padding(.vertical)

            bottomBar
                .padding(.leading, 16)
                .padding(.trailing, 76)   // keep clear of FAB
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
                    Task { await notion.fetchWorkouts() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
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
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 8, height: 8)
                Text("Workout").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.teal).frame(width: 8, height: 8)
                Text("Visit").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
