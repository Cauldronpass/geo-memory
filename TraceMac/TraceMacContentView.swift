// TraceMacContentView.swift
// Root NavigationSplitView shell for Trace Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

// MARK: - Sidebar sections

enum MacSection: String, CaseIterable, Identifiable {
    case daily     = "Daily"
    case projects  = "Projects"
    case places    = "Places"
    case horizons  = "Horizons"
    case people    = "People"
    case billiards = "Billiards"
    case fitness   = "Fitness"
    case documents = "Documents"
    case inbox     = "Inbox"
    case archive   = "Archive"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .daily:     return "book.pages"
        case .projects:  return "folder"
        case .places:    return "mappin"
        case .horizons:  return "calendar.badge.clock"
        case .people:    return "person.2"
        case .billiards: return "circle.grid.3x3"
        case .fitness:   return "figure.run"
        case .documents: return "doc.richtext"
        case .inbox:     return "tray"
        case .archive:   return "archivebox"
        }
    }

    var iconColor: Color {
        switch self {
        case .daily:     return .traceOrange
        case .projects:  return .blue
        case .places:    return .green
        case .horizons:  return .purple
        case .people:    return .indigo
        case .billiards: return Color(hex: "2563EB")
        case .fitness:   return Color(hex: "16A34A")
        case .documents: return Color(hex: "8B5CF6")
        case .inbox:     return .gray
        case .archive:   return Color(hex: "92400E")
        }
    }
}

// MARK: - Root view

struct TraceMacContentView: View {

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @Binding var selectedSection: MacSection?
    @State private var pendingHorizonsFile: String? = nil

    var body: some View {
        // Plain HStack instead of NavigationSplitView — eliminates NSSplitView resize
        // arrows entirely. Sidebar is fixed at 200px; detail fills the rest.
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHorizonsFile)) { note in
            if let filename = note.userInfo?["filename"] as? String {
                selectedSection = .horizons
                pendingHorizonsFile = filename
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWikilink)) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            // Check people first, then places
            if let person = notionService.people.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                selectedSection = .people
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(name: .selectPerson, object: nil,
                                                    userInfo: ["id": person.id])
                }
            } else if let place = notionService.places.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                selectedSection = .places
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(name: .selectPlace, object: nil,
                                                    userInfo: ["id": place.id])
                }
            }
        }
        .task {
            async let p: ()  = notionService.fetchPlaces()
            async let pe: () = notionService.fetchPeople()
            async let b: ()  = notionService.fetchBilliardsSessions()
            async let w: ()  = notionService.fetchWorkouts()
            _ = await (p, pe, b, w)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section("Journal") {
                ForEach([MacSection.daily, .projects, .horizons]) { section in
                    coloredLabel(section).tag(section)
                }
            }
            Section("Directory") {
                coloredLabel(.people).tag(MacSection.people)
                coloredLabel(.places).tag(MacSection.places)
            }
            Section("Activity") {
                coloredLabel(.billiards).tag(MacSection.billiards)
                coloredLabel(.fitness).tag(MacSection.fitness)
            }
            Section("Library") {
                coloredLabel(.documents).tag(MacSection.documents)
                coloredLabel(.inbox).tag(MacSection.inbox)
            }
            Section("Archive") {
                coloredLabel(.archive).tag(MacSection.archive)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 200)
    }

    private func coloredLabel(_ section: MacSection) -> some View {
        Label {
            Text(section.rawValue)
        } icon: {
            if section == .billiards {
                BilliardsRackIcon(color: section.iconColor)
            } else {
                Image(systemName: section.icon)
                    .foregroundStyle(section.iconColor)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .daily:
            TraceMacJournalView(section: .daily)
                .environment(noteStore)
                .environment(notionService)
        case .projects:
            TraceMacJournalView(section: .projects)
                .environment(noteStore)
                .environment(notionService)
        case .places:
            TraceMacPlacesView()
                .environment(noteStore)
                .environment(notionService)
        case .horizons:
            TraceMacJournalView(section: .horizons, deepLinkFile: $pendingHorizonsFile)
                .environment(noteStore)
                .environment(notionService)
        case .people:
            TraceMacPeopleView()
                .environment(notionService)
        case .billiards:
            TraceMacBilliardsView()
                .environment(notionService)
        case .fitness:
            TraceMacFitnessView()
                .environment(notionService)
        case .documents:
            TraceMacDocumentsView()
                .environment(noteStore)
        case .inbox:
            TraceMacInboxView()
                .environment(noteStore)
        case .archive:
            TraceMacArchiveView()
                .environment(noteStore)
                .environment(notionService)
        case nil:
            VStack(spacing: 12) {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text("Trace")
                    .font(.title2).fontWeight(.medium)
                Text("Select a section to get started")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - TraceMacPlacesView

struct TraceMacPlacesView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(NoteStore.self)     private var noteStore

    @State private var selectedID: String?    = nil
    @State private var searchText              = ""
    @State private var showAllVisits           = false

    private var filtered: [Place] {
        let sorted = notionService.places.sorted {
            $0.name.localizedCompare($1.name) == .orderedAscending
        }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.city.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedPlace: Place? {
        guard let id = selectedID else { return nil }
        return notionService.places.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: place list
            VStack(spacing: 0) {
                // Header row
                HStack {
                    Text("Places")
                        .font(.headline)
                    Spacer()
                    Button {
                        showAllVisits = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .help("All Visits")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

                TextField("Search places", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)

                List(filtered, id: \.id, selection: $selectedID) { place in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(.system(.body, weight: .medium))
                            .lineLimit(1)
                        if !place.city.isEmpty {
                            Text(place.city)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(place.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(width: 220)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            // Right: detail or placeholder
            Group {
                if let place = selectedPlace {
                    TraceMacPlaceDetail(place: place)
                        .environment(noteStore)
                        .id(place.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "mappin.circle")
                            .font(.system(size: 44, weight: .ultraLight))
                            .foregroundStyle(.tertiary)
                        Text("Select a place")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectPlace)) { note in
            if let id = note.userInfo?["id"] as? String {
                selectedID = id
            }
        }
        .sheet(isPresented: $showAllVisits) {
            MacAllVisitsView()
                .environment(notionService)
        }
    }
}

// MARK: - MacAllVisitsView

struct MacAllVisitsView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var searchText        = ""
    @State private var selectedCategory: String? = nil
    @State private var selectedTag:      String? = nil
    @State private var selectedPeopleIDs: Set<String> = []
    @State private var editingVisit:     Visit? = nil

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    @ViewBuilder
    private func peopleMenuItems() -> some View {
        Button("Anyone") { selectedPeopleIDs = [] }
        Divider()
        ForEach(availablePeople) { (person: Person) in
            Button {
                if selectedPeopleIDs.contains(person.id) {
                    selectedPeopleIDs.remove(person.id)
                } else {
                    selectedPeopleIDs.insert(person.id)
                }
            } label: {
                HStack {
                    Text(person.name)
                    if selectedPeopleIDs.contains(person.id) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private var availableCategories: [String] {
        let usedIDs = Set(notionService.visits.map { $0.placeID })
        return Array(Set(notionService.places
            .filter { usedIDs.contains($0.id) && !$0.category.isEmpty }
            .map { $0.category }
        )).sorted()
    }

    private var availableTags: [String] {
        let usedIDs = Set(notionService.visits.map { $0.placeID })
        return Array(Set(notionService.places
            .filter { usedIDs.contains($0.id) }
            .flatMap { $0.tags }
        )).sorted()
    }

    private var availablePeople: [Person] {
        let usedIDs = Set(notionService.visits.flatMap { $0.peopleIDs })
        return notionService.people
            .filter { usedIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filtered: [Visit] {
        notionService.visits
            .sorted { $0.date > $1.date }
            .filter { visit in
                // search
                if !searchText.isEmpty {
                    let q = searchText.lowercased()
                    let inName  = visit.placeName.lowercased().contains(q)
                    let inNotes = visit.notes?.lowercased().contains(q) ?? false
                    let inDate  = Self.dateFormatter.string(from: visit.date).lowercased().contains(q)
                    if !inName && !inNotes && !inDate { return false }
                }
                // people filter
                if !selectedPeopleIDs.isEmpty,
                   selectedPeopleIDs.isDisjoint(with: Set(visit.peopleIDs)) { return false }
                // place-based filters
                if selectedCategory != nil || selectedTag != nil {
                    guard let place = notionService.places.first(where: { $0.id == visit.placeID }) else { return false }
                    if let cat = selectedCategory, place.category != cat { return false }
                    if let tag = selectedTag, !place.tags.contains(tag)  { return false }
                }
                return true
            }
    }

    private var hasActiveFilters: Bool {
        selectedCategory != nil || selectedTag != nil || !selectedPeopleIDs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Text("All Visits").font(.headline)
                Spacer()
                Button {
                    Task { await notionService.fetchVisits() }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 44)  // balance the Done button width
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Search + filters
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search visits", text: $searchText)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity)

                // Category filter
                Menu {
                    Button("All Categories") { selectedCategory = nil }
                    Divider()
                    ForEach(availableCategories, id: \.self) { cat in
                        Button(cat) { selectedCategory = cat }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                        Text(selectedCategory ?? "Category")
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selectedCategory != nil ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Tag filter
                if !availableTags.isEmpty {
                    Menu {
                        Button("All Tags") { selectedTag = nil }
                        Divider()
                        ForEach(availableTags, id: \.self) { tag in
                            Button(tag) { selectedTag = tag }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tag")
                            Text(selectedTag ?? "Tag")
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(selectedTag != nil ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                // People filter
                if !availablePeople.isEmpty {
                    Menu {
                        peopleMenuItems()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person")
                            Text(selectedPeopleIDs.isEmpty ? "With" : "\(selectedPeopleIDs.count) selected")
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(!selectedPeopleIDs.isEmpty ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                // Clear filters
                if hasActiveFilters {
                    Button("Clear") {
                        selectedCategory = nil
                        selectedTag      = nil
                        selectedPeopleIDs = []
                    }
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Visit list
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text(notionService.visits.isEmpty ? "No visits yet" : "No matching visits")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { visit in
                            Button { editingVisit = visit } label: {
                                MacVisitRow(visit: visit)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(width: 680, height: 700)
        .task {
            if notionService.visits.isEmpty { await notionService.fetchVisits() }
        }
        .sheet(item: $editingVisit) { visit in
            MacVisitDetailView(visit: visit)
                .environment(notionService)
        }
    }
}

// MARK: - MacVisitRow

private struct MacVisitRow: View {
    let visit: Visit
    @Environment(NotionService.self) private var notionService

    private var place: Place? {
        notionService.places.first { $0.id == visit.placeID }
    }

    private var companions: [Person] {
        notionService.people.filter { visit.peopleIDs.contains($0.id) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Category icon
            ZStack {
                Circle()
                    .fill(placeColor(for: place?.category ?? "").opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: placeIcon(for: place?.category ?? ""))
                    .font(.system(size: 14))
                    .foregroundStyle(placeColor(for: place?.category ?? ""))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(visit.placeName)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text(visit.date, style: .date)
                    if let city = place?.city, !city.isEmpty {
                        Text("·"); Text(city)
                    }
                    if let rating = visit.rating {
                        Text("·")
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                            Text("\(rating)/7").font(.caption)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !companions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(companions.prefix(4))) { (person: Person) in
                            let initials = person.name
                                .components(separatedBy: " ")
                                .compactMap { $0.first.map { String($0) } }
                                .prefix(2).joined()
                            Text(initials)
                                .font(.system(size: 8, weight: .medium))
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.accentColor.opacity(0.2)))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(companions.prefix(4).map {
                            $0.name.components(separatedBy: " ").first ?? $0.name
                        }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let notes = visit.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - TraceMacPlaceDetail

struct TraceMacPlaceDetail: View {
    let place: Place
    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var selectedTab  = 0
    @State private var radiusStr    = ""
    @State private var dwellStr     = ""
    @State private var editingVisit: Visit? = nil

    private var livePlace: Place {
        notionService.places.first { $0.id == place.id } ?? place
    }

    private var placeVisits: [Visit] {
        notionService.visits
            .filter { $0.placeID == place.id }
            .sorted { $0.date > $1.date }
    }

    private var noteRelativePath: String {
        "Notes/Places/\(noteStore.placeNoteFilename(for: place.name)).md"
    }

    var body: some View {
        VStack(spacing: 0) {
            placeHeader
            Divider()
            Picker("", selection: $selectedTab) {
                Text("Overview").tag(0)
                Text("Info").tag(1)
                Text("Visits").tag(2)
                Text("Notes").tag(3)
                Text("Settings").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            Group {
                switch selectedTab {
                case 0: overviewTab
                case 1: infoTab
                case 2: visitsTab
                case 3: notesTab
                default: settingsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            if notionService.visits.isEmpty { await notionService.fetchVisits() }
        }
        .onAppear {
            radiusStr = livePlace.geofenceRadius.map { String($0) } ?? ""
            dwellStr  = livePlace.dwellTime.map { String($0) } ?? ""
        }
        .sheet(item: $editingVisit) { visit in
            MacVisitDetailView(visit: visit)
                .environment(notionService)
        }
    }

    // MARK: - Header

    private var placeHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(livePlace.name)
                    .font(.title2).fontWeight(.bold)
                HStack(spacing: 4) {
                    if !livePlace.category.isEmpty { Text(livePlace.category) }
                    if !livePlace.city.isEmpty {
                        if !livePlace.category.isEmpty { Text("·") }
                        Text(livePlace.city)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 14) {
                Button {
                    selectedTab = 2  // jump to Visits tab
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.plain)
                .help("Visits")

                Button {
                    Task {
                        await notionService.fetchPlaces()
                        await notionService.fetchVisits()
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .help("Refresh")

                Button {
                    let notionID = livePlace.id.replacingOccurrences(of: "-", with: "")
                    if let url = URL(string: "https://notion.so/\(notionID)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain)
                .help("Open in Notion")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Overview

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MacDetailRow(label: "Status") {
                    Text(livePlace.status)
                        .foregroundStyle(livePlace.status == "Visited" ? .green : .orange)
                        .fontWeight(.semibold)
                }
                MacDetailRow(label: "Category") {
                    HStack(spacing: 6) {
                        Image(systemName: placeIcon(for: livePlace.category))
                            .foregroundStyle(placeColor(for: livePlace.category))
                        Text(livePlace.category.isEmpty ? "None" : livePlace.category)
                    }
                }
                if let description = livePlace.notes, !description.isEmpty {
                    MacDetailRow(label: "Description") { Text(description) }
                }
                if let summary = livePlace.aiSummary, !summary.isEmpty {
                    MacDetailRow(label: "Summary") { Text(summary) }
                }
                MacDetailRow(label: "Tags") {
                    if livePlace.tags.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        // Simple wrapping chip row
                        FlowLayout(spacing: 6) {
                            ForEach(livePlace.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                if let rating = livePlace.ratingPersonal {
                    MacDetailRow(label: "Your rating") { MacStarDisplay(rating: rating) }
                }
                if let external = livePlace.ratingExternal {
                    MacDetailRow(label: "Google rating") {
                        Text(String(format: "%.1f ★", external))
                    }
                }
                MacDetailRow(label: "Visits") { Text("\(livePlace.visitCount)") }
                if let last = livePlace.lastVisited {
                    MacDetailRow(label: "Last visited") { Text(last, style: .date) }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Info

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !livePlace.address.isEmpty {
                    MacDetailRow(label: "Address") { Text(livePlace.address) }
                }
                if let phone = livePlace.phone, !phone.isEmpty {
                    MacDetailRow(label: "Phone") {
                        Button(phone) {
                            if let url = URL(string: "tel://\(phone.filter { $0.isNumber })") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
                if let website = livePlace.website, !website.isEmpty {
                    MacDetailRow(label: "Website") {
                        Button {
                            if let url = URL(string: website) { NSWorkspace.shared.open(url) }
                        } label: {
                            Text(website).foregroundStyle(.blue).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let hours = livePlace.hours, !hours.isEmpty {
                    MacDetailRow(label: "Hours") { Text(hours) }
                }
                MacDetailRow(label: "Notion") {
                    Button("Open in Notion") {
                        let notionID = livePlace.id.replacingOccurrences(of: "-", with: "")
                        if let url = URL(string: "https://notion.so/\(notionID)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Visits

    private var visitsTab: some View {
        Group {
            if placeVisits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 38, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("No visits yet")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(placeVisits) { visit in
                            Button {
                                editingVisit = visit
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(visit.date, style: .date)
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            if !visit.photoURLs.isEmpty {
                                                Label("\(visit.photoURLs.count)", systemImage: "photo")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            if let rating = visit.rating {
                                                MacStarDisplay(rating: rating)
                                            }
                                        }
                                        if let notes = visit.notes, !notes.isEmpty {
                                            Text(notes)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 2)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 20)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notes

    private var notesTab: some View {
        TraceMacNoteEditor(relativePath: noteRelativePath)
            .environment(noteStore)
    }

    // MARK: - Settings

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MacSettingsSection(title: "Behavior") {
                    MacToggleRow(label: "Pinned", isOn: livePlace.flagged) {
                        Task { try? await notionService.toggleFlagged(livePlace) }
                    }
                    Divider()
                    MacToggleRow(label: "Frequent", isOn: livePlace.frequent) {
                        Task { try? await notionService.toggleFrequent(livePlace) }
                    }
                    Divider()
                    MacToggleRow(label: "Skip Enrichment", isOn: livePlace.skipEnrichment) {
                        Task { try? await notionService.toggleSkipEnrichment(livePlace) }
                    }
                    Divider()
                    MacToggleRow(label: "Prompt Log on Exit", isOn: livePlace.promptLog) {
                        Task { try? await notionService.togglePromptLog(livePlace) }
                    }
                }
                MacSettingsSection(title: "Geofencing",
                                   footer: "Radius default: 50m (200m for frequent). Dwell default: 3 min.") {
                    MacToggleRow(label: "Exclude from Geofencing", isOn: livePlace.geofenceExcluded) {
                        Task { try? await notionService.toggleGeofenceExcluded(livePlace) }
                    }
                    Divider()
                    HStack {
                        Text("Radius")
                        Spacer()
                        TextField("default", text: $radiusStr)
                            .frame(width: 64).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Text("m").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    Divider()
                    HStack {
                        Text("Dwell Time")
                        Spacer()
                        TextField("default", text: $dwellStr)
                            .frame(width: 64).multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Text("min").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Save Geofencing Settings") {
                            Task {
                                try? await notionService.setGeofenceRadius(livePlace, metres: Int(radiusStr))
                                try? await notionService.setDwellTime(livePlace, minutes: Int(dwellStr))
                            }
                        }
                        .disabled(
                            Int(radiusStr) == livePlace.geofenceRadius &&
                            Int(dwellStr)  == livePlace.dwellTime
                        )
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Mac supporting views

private struct MacDetailRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MacToggleRow: View {
    let label: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct MacSettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let footer {
                Text(footer).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct MacStarDisplay: View {
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

// MARK: - MacVisitDetailView

struct MacVisitDetailView: View {
    let visit: Visit
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var rating: Int?
    @State private var notes: String
    @State private var date: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(visit: Visit) {
        self.visit = visit
        _rating = State(initialValue: visit.rating)
        _notes  = State(initialValue: visit.notes ?? "")
        _date   = State(initialValue: visit.date)
    }

    private var livePlace: Place? {
        notionService.places.first { $0.id == visit.placeID }
    }

    private var isBilliardsPlace: Bool {
        livePlace?.category.lowercased() == "billiards"
    }

    private var linkedSessions: [BilliardsSession] {
        notionService.billiardsSessions
            .filter { $0.visitID == visit.id }
            .sorted { ($0.matchNumber ?? 0) < ($1.matchNumber ?? 0) }
    }

    private var livePhotoURLs: [String] {
        notionService.visits.first { $0.id == visit.id }?.photoURLs ?? visit.photoURLs
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Text(visit.placeName)
                    .font(.headline)
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text("Save").bold()
                    }
                }
                .disabled(isSaving)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Date
                    MacDetailRow(label: "Date") {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                    }

                    // Rating
                    MacDetailRow(label: "Rating") {
                        HStack(spacing: 6) {
                            ForEach(1...7, id: \.self) { star in
                                Button {
                                    rating = rating == star ? nil : star
                                } label: {
                                    Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                                        .font(.title3)
                                        .foregroundStyle(star <= (rating ?? 0) ? .yellow : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            if rating != nil {
                                Button {
                                    rating = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.callout)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 4)
                            }
                        }
                    }

                    // Notes
                    MacDetailRow(label: "Notes") {
                        TextEditor(text: $notes)
                            .font(.body)
                            .frame(minHeight: 160)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    // Photos
                    if !livePhotoURLs.isEmpty {
                        MacDetailRow(label: "Photos") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(livePhotoURLs, id: \.self) { urlString in
                                        if let url = URL(string: urlString) {
                                            AsyncImage(url: url) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().scaledToFill()
                                                        .frame(width: 120, height: 120)
                                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                                default:
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color.secondary.opacity(0.12))
                                                        .frame(width: 120, height: 120)
                                                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Billiards sessions (if applicable)
                    if isBilliardsPlace && !linkedSessions.isEmpty {
                        MacDetailRow(label: "Billiards Sessions") {
                            VStack(spacing: 0) {
                                ForEach(linkedSessions) { session in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 8) {
                                                if let result = session.result {
                                                    Text(result)
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(result == "Win" ? .green : .red)
                                                }
                                                Text("vs \(session.opponent.isEmpty ? "Opponent" : session.opponent)")
                                                    .font(.subheadline)
                                                if let m = session.matchNumber {
                                                    Text("M\(m)").font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                            if let n = session.notes, !n.isEmpty {
                                                Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        if let tp = session.myTeamPoints {
                                            Text("\(tp) pts")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(tp > 0 ? .green : .secondary)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    if session.id != linkedSessions.last?.id { Divider() }
                                }
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 600)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await notionService.updateVisit(
                visit,
                rating: rating,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
            )
            await notionService.fetchVisits()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Custom billiards rack icon (triangle of circles)

struct BilliardsRackIcon: View {
    var color: Color = .purple

    var body: some View {
        Canvas { ctx, size in
            let d: CGFloat = 3.6          // ball diameter
            let hStep: CGFloat = 4.8      // horizontal center-to-center
            let vStep: CGFloat = hStep * 0.866  // equilateral triangle row height

            // Rack: 3 rows — 1 ball (top), 2 balls, 3 balls (bottom)
            let rows: [(count: Int, indent: CGFloat)] = [
                (1, hStep),        // top
                (2, hStep / 2),    // middle
                (3, 0),            // bottom
            ]

            let rackWidth  = 2 * hStep + d
            let rackHeight = 2 * vStep + d
            let ox = (size.width  - rackWidth)  / 2
            let oy = (size.height - rackHeight) / 2

            for (rowIdx, row) in rows.enumerated() {
                let y = oy + CGFloat(rowIdx) * vStep
                for col in 0..<row.count {
                    let x = ox + row.indent + CGFloat(col) * hStep
                    let rect = CGRect(x: x, y: y, width: d, height: d)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .frame(width: 18, height: 18)
    }
}
