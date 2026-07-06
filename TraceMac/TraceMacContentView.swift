// TraceMacContentView.swift
// Root NavigationSplitView shell for Trace Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import MapKit
import UniformTypeIdentifiers

// MARK: - Sidebar sections

enum MacSection: String, CaseIterable, Identifiable {
    case home      = "Home"
    case daily     = "Daily"
    case projects  = "Projects"
    case places    = "Places"
    case horizons  = "Horizons"
    case people    = "People"
    case discover  = "Discover"
    case billiards = "Billiards"
    case fitness   = "Fitness"
    case documents = "Documents"
    case photos    = "Photos"
    case inbox     = "Inbox"
    case archive   = "Archive"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home:      return "house"
        case .daily:     return "book.pages"
        case .projects:  return "folder"
        case .places:    return "mappin"
        case .horizons:  return "calendar.badge.clock"
        case .people:    return "person.2"
        case .discover:  return "binoculars"
        case .billiards: return "circle.grid.3x3"
        case .fitness:   return "figure.run"
        case .documents: return "doc.richtext"
        case .photos:    return "photo.stack"
        case .inbox:     return "tray"
        case .archive:   return "archivebox"
        }
    }

    var iconColor: Color {
        switch self {
        case .home:      return .traceOrange
        case .daily:     return .traceOrange
        case .projects:  return .blue
        case .places:    return .green
        case .horizons:  return .purple
        case .people:    return .indigo
        case .discover:  return Color(hex: "0EA5E9")
        case .billiards: return Color(hex: "2563EB")
        case .fitness:   return Color(hex: "16A34A")
        case .documents: return Color(hex: "8B5CF6")
        case .photos:    return Color(hex: "DB2777")
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
    @State private var isDropTargeted = false

    var body: some View {
        // Plain HStack instead of NavigationSplitView — eliminates NSSplitView resize
        // arrows entirely. Sidebar is fixed at 200px; detail fills the rest.
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Global drop target overlay — only visible when dragging a file
            if isDropTargeted {
                Color.accentColor.opacity(0.06)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(6)
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleGlobalDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHorizonsFile)) { note in
            if let filename = note.userInfo?["filename"] as? String {
                selectedSection = .horizons
                pendingHorizonsFile = filename
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectDocument)) { note in
            guard note.userInfo?["internal"] as? Bool != true else { return }
            guard let path = note.userInfo?["relativePath"] as? String else { return }
            selectedSection = .documents
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .selectDocument, object: nil,
                                                userInfo: ["relativePath": path, "internal": true])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWikilink)) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
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
        .onReceive(NotificationCenter.default.publisher(for: .navigateToRecord)) { note in
            guard let type = note.userInfo?["type"] as? String,
                  let id   = note.userInfo?["id"]   as? String else { return }
            switch type {
            case "person":
                selectedSection = .people
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .selectPerson, object: nil, userInfo: ["id": id])
                }
            case "place":
                selectedSection = .places
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .selectPlace, object: nil, userInfo: ["id": id])
                }
            default: break
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

    // MARK: - Global file drop

    @discardableResult
    private func handleGlobalDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard error == nil,
                      let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue,
                      !url.lastPathComponent.hasPrefix(".") else { return }
                let ext = url.pathExtension.lowercased()
                guard !["txt", "md", "markdown", "text"].contains(ext) else { return }
                let store = TraceMacDocumentStore(noteStore: noteStore)
                do {
                    try store.importDocument(from: url)
                    Task { @MainActor in
                        // Switch to Documents section and reload
                        selectedSection = .documents
                        NotificationCenter.default.post(name: .reloadDocuments, object: nil)
                    }
                } catch { }
            }
            handled = true
        }
        return handled
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            coloredLabel(.home).tag(MacSection.home)
            coloredLabel(.inbox).tag(MacSection.inbox)

            Section("Journal") {
                ForEach([MacSection.daily, .projects, .horizons]) { section in
                    coloredLabel(section).tag(section)
                }
            }
            Section("Directory") {
                coloredLabel(.people).tag(MacSection.people)
                coloredLabel(.places).tag(MacSection.places)
                coloredLabel(.discover).tag(MacSection.discover)
            }
            Section("Activity") {
                coloredLabel(.billiards).tag(MacSection.billiards)
                coloredLabel(.fitness).tag(MacSection.fitness)
            }
            Section("Library") {
                coloredLabel(.documents).tag(MacSection.documents)
                coloredLabel(.photos).tag(MacSection.photos)
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
        case .home, nil:
            TraceMacHomeView(selectedSection: $selectedSection)
                .environment(noteStore)
                .environment(notionService)
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
        case .discover:
            TraceMacDiscoverView()
                .environment(notionService)
                .environment(noteStore)
        case .billiards:
            TraceMacBilliardsView()
                .environment(notionService)
        case .fitness:
            TraceMacFitnessView()
                .environment(notionService)
        case .documents:
            TraceMacDocumentsView()
                .environment(noteStore)
        case .photos:
            TraceMacPhotosView()
                .environment(noteStore)
                .environment(notionService)
        case .inbox:
            TraceMacInboxView()
                .environment(noteStore)
        case .archive:
            TraceMacArchiveView()
                .environment(noteStore)
                .environment(notionService)
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
    @State private var sidebarVisitDetail: Visit? = nil

    // Resizable sidebar
    @State private var listCollapsed = false
    @State private var sidebarWidth: CGFloat = 220
    @GestureState private var sidebarDrag: CGFloat = 0

    // Sidebar mode
    enum SidebarMode { case places, visits }
    @State private var sidebarMode: SidebarMode = .places
    @State private var hasLoadedVisits = false
    @State private var isLoadingVisits = false

    private var filteredPlaces: [Place] {
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

    private var filteredVisits: [Visit] {
        let sorted = notionService.visits.sorted { $0.date > $1.date }
        guard !searchText.isEmpty else { return sorted }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.placeName.lowercased().contains(q) ||
            ($0.notes?.lowercased().contains(q) ?? false)
        }
    }

    private var selectedPlace: Place? {
        guard let id = selectedID else { return nil }
        return notionService.places.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            if !listCollapsed {
                placesSidebar
                    .frame(width: max(160, sidebarWidth + sidebarDrag))
                // Resize strip
                Rectangle()
                    .fill(Color.primary.opacity(0.001))
                    .frame(width: 6)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .updating($sidebarDrag) { v, state, _ in
                                state = v.translation.width
                            }
                            .onEnded { v in
                                sidebarWidth = max(160, sidebarWidth + v.translation.width)
                            }
                    )
                    .onHover { h in h ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            }
            CollapseHandle(isCollapsed: $listCollapsed, collapsesRight: false, showLine: true, panelColor: .clear)

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
                sidebarMode = .places
            }
        }
        .sheet(isPresented: $showAllVisits) {
            MacAllVisitsView()
                .environment(notionService)
        }
        .sheet(item: $sidebarVisitDetail) { visit in
            MacVisitDetailView(visit: visit)
                .environment(notionService)
        }
    }

    // MARK: - Sidebar

    private var placesSidebar: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Picker("", selection: $sidebarMode) {
                Text("Places").tag(SidebarMode.places)
                Text("Visits").tag(SidebarMode.visits)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .onChange(of: sidebarMode) { _, mode in
                if mode == .visits && !hasLoadedVisits {
                    hasLoadedVisits = true
                    isLoadingVisits = true
                    Task {
                        await notionService.fetchVisits()
                        isLoadingVisits = false
                    }
                }
            }

            Divider()

            if sidebarMode == .places {
                placesSidebarContent
            } else {
                visitsSidebarContent
            }
        }
    }

    @ViewBuilder
    private var placesSidebarContent: some View {
        if filteredPlaces.isEmpty {
            Spacer()
            Text(notionService.places.isEmpty ? "No places yet." : "No matches.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        } else {
            List(filteredPlaces, id: \.id, selection: $selectedID) { place in
                HStack(alignment: .center, spacing: 6) {
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
                    Spacer(minLength: 0)
                    if place.visitCount > 0 {
                        Text("\(place.visitCount)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.vertical, 3)
                .tag(place.id)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private var visitsSidebarContent: some View {
        if isLoadingVisits {
            Spacer()
            ProgressView("Loading…").frame(maxWidth: .infinity)
            Spacer()
        } else if filteredVisits.isEmpty {
            Spacer()
            Text(notionService.visits.isEmpty ? "No visits yet." : "No matches.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredVisits) { visit in
                        Button {
                            sidebarVisitDetail = visit
                        } label: {
                            SidebarVisitRow(visit: visit)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }
}

// MARK: - MacAllVisitsView

struct MacAllVisitsView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var searchText         = ""
    @State private var selectedCategory:  String? = nil
    @State private var selectedTag:       String? = nil
    @State private var selectedPeopleIDs: Set<String> = []
    @State private var editingVisit:      Visit? = nil
    @State private var showingLogVisit    = false

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
                HStack(spacing: 14) {
                    Button {
                        showingLogVisit = true
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("Log Visit")

                    Button {
                        Task { await notionService.fetchVisits() }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
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
        .sheet(isPresented: $showingLogVisit) {
            MacCheckInSheet()
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

// MARK: - SidebarVisitRow (compact, used in Places sidebar Visits mode)

private struct SidebarVisitRow: View {
    let visit: Visit
    @Environment(NotionService.self) private var notionService

    private var place: Place? {
        notionService.places.first { $0.id == visit.placeID }
    }
    private var companions: [Person] {
        notionService.people.filter { visit.peopleIDs.contains($0.id) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(placeColor(for: place?.category ?? "").opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: placeIcon(for: place?.category ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(placeColor(for: place?.category ?? ""))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(visit.placeName)
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(visit.date, style: .date)
                    if let city = place?.city, !city.isEmpty {
                        Text("·"); Text(city)
                    }
                    if let r = visit.rating {
                        Text("·"); Text("\(r)/7")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if !companions.isEmpty {
                    Text(companions.prefix(3).map {
                        $0.name.components(separatedBy: " ").first ?? $0.name
                    }.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - TraceMacPlaceDetail

struct TraceMacPlaceDetail: View {
    let place: Place
    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var selectedTab      = 0
    @State private var radiusStr        = ""
    @State private var dwellStr         = ""
    @State private var editingVisit:    Visit? = nil
    @State private var showingEditPlace = false
    @State private var showingLogVisit  = false

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
        .sheet(isPresented: $showingEditPlace) {
            MacPlaceEditSheet(place: livePlace)
                .environment(notionService)
        }
        .sheet(isPresented: $showingLogVisit) {
            MacCheckInSheet(preselectedPlace: livePlace)
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
                    showingLogVisit = true
                } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("Log Visit")

                Button {
                    showingEditPlace = true
                } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain)
                .help("Edit Place")

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

/// Displays a photo from either a NoteStore relative path ("Photos/...") or a remote HTTPS URL.
struct MacNoteStorePhotoView: View {
    let urlString: String
    let size: CGFloat

    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: urlString) { nsImage = await loadImage() }
    }

    private func loadImage() async -> NSImage? {
        if urlString.hasPrefix("Photos/") {
            guard let fileURL = NoteStore.shared.resolvedURL(for: urlString) else { return nil }
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            let delays: [UInt64] = [300, 500, 1_000, 1_500, 2_000, 3_000]
            for delay in delays {
                if let img = NSImage(contentsOf: fileURL) { return img }
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            return NSImage(contentsOf: fileURL)
        } else if let url = URL(string: urlString) {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        return nil
    }
}

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
    @State private var showDatePopover = false
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false

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

            // Go to Place link
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NotificationCenter.default.post(
                        name: .navigateToRecord, object: nil,
                        userInfo: ["type": "place", "id": visit.placeID]
                    )
                }
            } label: {
                Label("Go to \(visit.placeName)", systemImage: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Date
                    MacDetailRow(label: "Date") {
                        Button { showDatePopover.toggle() } label: {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                            DatePicker("", selection: $date, displayedComponents: .date)
                                .datePickerStyle(.graphical).labelsHidden().padding().frame(width: 280)
                        }
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

                    // Map
                    if let place = livePlace, place.latitude != 0 || place.longitude != 0 {
                        MacDetailRow(label: "Location") {
                            let coord = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                            Map(initialPosition: .region(MKCoordinateRegion(
                                center: coord,
                                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                            ))) {
                                Marker(place.name, coordinate: coord)
                            }
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                        }
                    }

                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }

                    Divider()

                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        if isDeleting {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("Delete Visit", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 660)
        .confirmationDialog(
            "Delete this visit to \(visit.placeName)?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteVisit() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the visit from Notion. It will no longer count toward this place's visit total.")
        }
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

    private func deleteVisit() async {
        isDeleting = true
        errorMessage = nil
        do {
            try await notionService.deleteVisit(id: visit.id)
            await notionService.fetchVisits()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isDeleting = false
        }
    }
}

// MARK: - TraceMacHomeView

struct TraceMacHomeView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(NoteStore.self)     private var noteStore
    @Binding var selectedSection: MacSection?

    @State private var dailyContent = ""
    @State private var dailyLoaded  = false

    // Visit detail sheet
    @State private var selectedVisit: Visit? = nil

    // Interaction / agenda sheets
    @State private var showAddInteraction  = false
    @State private var logInteractionPerson: Person? = nil
    @State private var editInteraction: Interaction? = nil
    @State private var editInteractionPerson: Person? = nil
    @State private var agendaPerson: Person? = nil
    @State private var showAddAgenda = false
    @State private var hoveredPersonID: String? = nil

    // Visit sheet
    @State private var showAddVisit = false

    // MARK: Time-of-day theme

    private enum TimeTheme {
        case morning, afternoon, evening

        static var current: TimeTheme {
            let h = Calendar.current.component(.hour, from: Date())
            switch h {
            case 5..<12: return .morning
            case 12..<17: return .afternoon
            default:     return .evening
            }
        }

        var greeting: String {
            switch self {
            case .morning:   return "Good morning"
            case .afternoon: return "Good afternoon"
            case .evening:   return "Good evening"
            }
        }
        var headerBg: Color {
            switch self {
            case .morning:   return Color(red: 0.882, green: 0.961, blue: 0.933)
            case .afternoon: return Color(red: 0.980, green: 0.933, blue: 0.855)
            case .evening:   return Color(red: 0.933, green: 0.929, blue: 0.996)
            }
        }
        var titleColor: Color {
            switch self {
            case .morning:   return Color(red: 0.016, green: 0.204, blue: 0.173)
            case .afternoon: return Color(red: 0.255, green: 0.141, blue: 0.008)
            case .evening:   return Color(red: 0.149, green: 0.129, blue: 0.361)
            }
        }
        var subColor: Color {
            switch self {
            case .morning:   return Color(red: 0.059, green: 0.431, blue: 0.337)
            case .afternoon: return Color(red: 0.522, green: 0.310, blue: 0.043)
            case .evening:   return Color(red: 0.325, green: 0.290, blue: 0.718)
            }
        }
    }

    private let theme = TimeTheme.current

    // MARK: Computed

    private var recentVisits: [Visit] {
        Array(notionService.visits.sorted { $0.date > $1.date }.prefix(4))
    }

    private struct PersonSighting: Identifiable {
        enum Source {
            case visit(placeName: String)
            case interaction(type: String)
        }
        let person: Person
        let lastSeen: Date
        let source: Source
        var id: String { person.id }
    }

    private var recentPeople: [PersonSighting] {
        var seen: [String: (date: Date, source: PersonSighting.Source)] = [:]
        // Visit-based contacts
        for visit in notionService.visits.sorted(by: { $0.date > $1.date }).prefix(30) {
            for pid in visit.peopleIDs {
                if seen[pid] == nil {
                    seen[pid] = (date: visit.date, source: .visit(placeName: visit.placeName))
                }
            }
        }
        // Interaction-based contacts — override if more recent
        for interaction in notionService.recentInteractions {
            for pid in interaction.personIDs {
                if let existing = seen[pid] {
                    if interaction.date > existing.date {
                        seen[pid] = (date: interaction.date, source: .interaction(type: interaction.type))
                    }
                } else {
                    seen[pid] = (date: interaction.date, source: .interaction(type: interaction.type))
                }
            }
        }
        return seen
            .compactMap { id, entry -> PersonSighting? in
                notionService.people.first { $0.id == id }
                    .map { PersonSighting(person: $0, lastSeen: entry.date, source: entry.source) }
            }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(8)
            .map { $0 }
    }

    private var dateString: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f.string(from: Date())
    }

    private var dailyLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return "Daily · \(f.string(from: Date()))"
    }

    private var dailyPreview: String {
        var lines = dailyContent.components(separatedBy: "\n")
        if let first = lines.first,
           first.hasPrefix("# "),
           first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            lines.removeFirst()
        }
        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { macStripNotePrefix($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func macStripNotePrefix(_ line: String) -> String {
        for prefix in ["### ", "## ", "# "] {
            if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        }
        for prefix in ["- [x] ", "- [ ] ", "• ", "- "] {
            if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        }
        return line
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Header
                VStack(alignment: .leading, spacing: 3) {
                    Text(dateString)
                        .font(.subheadline)
                        .foregroundStyle(theme.subColor)
                    Text("\(theme.greeting), David")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(theme.titleColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(theme.headerBg)

                // Cards
                VStack(alignment: .leading, spacing: 16) {
                    dailyNoteCard
                    HStack(alignment: .top, spacing: 14) {
                        visitsCard
                        peopleCard
                    }
                }
                .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if let content = try? noteStore.readDailyNote() {
                dailyContent = content
            }
            dailyLoaded = true
            async let visits: () = notionService.fetchVisits()
            async let people: () = notionService.fetchPeople()
            async let interactions: () = notionService.fetchRecentInteractions()
            _ = await (visits, people, interactions)
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { _ in
            if let content = try? noteStore.readDailyNote() {
                dailyContent = content
            }
        }
    }

    // MARK: - Daily note card

    private var dailyNoteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                homeLabel("Today's Note")
                Spacer()
                Button { selectedSection = .daily } label: {
                    Text("Open →").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button { selectedSection = .daily } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dailyLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())

                    if !dailyLoaded {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    } else if dailyPreview.isEmpty {
                        Text("No content yet — tap to open the Daily note")
                            .font(.subheadline).foregroundStyle(.tertiary)
                    } else {
                        Text(dailyPreview)
                            .font(.subheadline).foregroundStyle(.primary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recent visits card

    private var visitsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                homeLabel("Recent Visits")
                Spacer()
                Button { showAddVisit = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Log visit")
                Button { selectedSection = .places } label: {
                    Text("All →").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if recentVisits.isEmpty {
                macEmptyCard("No visits recorded yet")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recentVisits) { visit in
                        let place = notionService.places.first { $0.id == visit.placeID }
                        let comps  = notionService.people.filter { visit.peopleIDs.contains($0.id) }
                        if visit.id != recentVisits.first?.id {
                            Divider().padding(.horizontal, 12)
                        }
                        Button {
                            selectedVisit = visit
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(placeColor(for: place?.category ?? ""))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: placeIcon(for: place?.category ?? ""))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(visit.placeName)
                                        .font(.system(.subheadline, weight: .medium))
                                        .foregroundStyle(.primary).lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(macRelativeDate(visit.date))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if !comps.isEmpty {
                                            Text("·").font(.caption).foregroundStyle(.tertiary)
                                            Text(comps.prefix(2)
                                                .map { $0.name.components(separatedBy: " ").first ?? $0.name }
                                                .joined(separator: ", "))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                                if let r = visit.rating {
                                    Text("★ \(r)")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showAddVisit) {
            MacCheckInSheet()
                .environment(notionService)
        }
    }

    // MARK: - Recent people card

    private var peopleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                homeLabel("Recent People")
                Spacer()
                Button { showAddInteraction = true } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Log interaction")
                Button { showAddAgenda = true } label: {
                    Image(systemName: "list.bullet.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit agenda")
                Button { selectedSection = .people } label: {
                    Text("All →").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if recentPeople.isEmpty {
                macEmptyCard("No recent contacts")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recentPeople) { sighting in
                        if sighting.id != recentPeople.first?.id {
                            Divider().padding(.horizontal, 12)
                        }
                        let initials = sighting.person.name
                            .components(separatedBy: " ")
                            .compactMap { $0.first.map { String($0) } }
                            .prefix(2).joined()
                        let colors = macAvatarColors(sighting.person.name)
                        let isHovered = hoveredPersonID == sighting.person.id
                        let lastInteraction = notionService.recentInteractions
                            .first { $0.personIDs.contains(sighting.person.id) }
                        HStack(spacing: 0) {
                            Button {
                                selectedSection = .people
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    NotificationCenter.default.post(name: .selectPerson, object: nil,
                                                                    userInfo: ["id": sighting.person.id])
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Text(initials)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(colors.text)
                                        .frame(width: 28, height: 28)
                                        .background(colors.bg, in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sighting.person.name)
                                            .font(.system(.subheadline, weight: .medium))
                                            .foregroundStyle(.primary).lineLimit(1)
                                        HStack(spacing: 5) {
                                            Text(macRelativeDate(sighting.lastSeen))
                                                .font(.caption).foregroundStyle(.secondary)
                                            sourcePill(sighting.source)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, 12).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)

                            // Hover action buttons
                            HStack(spacing: 2) {
                                Button {
                                    logInteractionPerson = sighting.person
                                } label: {
                                    Image(systemName: "plus.bubble")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26, height: 26)
                                }
                                .buttonStyle(.plain)
                                .help("Log interaction")

                                if lastInteraction != nil {
                                    Button {
                                        editInteraction = lastInteraction
                                        editInteractionPerson = sighting.person
                                    } label: {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 26, height: 26)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Edit last interaction")
                                }

                                Button {
                                    agendaPerson = sighting.person
                                } label: {
                                    Image(systemName: "list.bullet")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26, height: 26)
                                }
                                .buttonStyle(.plain)
                                .help("Edit agenda")
                            }
                            .padding(.trailing, 6)
                            .opacity(isHovered ? 1 : 0)
                            .animation(.easeInOut(duration: 0.15), value: isHovered)
                        }
                        .onHover { hoveredPersonID = $0 ? sighting.person.id : nil }
                        .contextMenu {
                            Button("Log Interaction") {
                                logInteractionPerson = sighting.person
                            }
                            if let li = lastInteraction {
                                Button("Edit Last Interaction") {
                                    editInteraction = li
                                    editInteractionPerson = sighting.person
                                }
                            }
                            Divider()
                            Button("Edit Agenda") {
                                agendaPerson = sighting.person
                            }
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $selectedVisit) { visit in
            MacVisitDetailView(visit: visit)
                .environment(notionService)
        }
        .sheet(isPresented: $showAddInteraction) {
            MacLogInteractionSheet(preselectedPerson: nil)
                .environment(notionService)
        }
        .sheet(item: $logInteractionPerson) { person in
            MacLogInteractionSheet(preselectedPerson: person)
                .environment(notionService)
        }
        .sheet(item: $editInteraction) { interaction in
            MacEditInteractionSheet(interaction: interaction, person: editInteractionPerson)
                .environment(notionService)
        }
        .sheet(item: $agendaPerson) { person in
            MacAgendaSheet(preselectedPerson: person)
                .environment(notionService)
        }
        .sheet(isPresented: $showAddAgenda) {
            MacAgendaSheet()
                .environment(notionService)
        }
    }

    // MARK: - Helpers

    private func homeLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func macEmptyCard(_ msg: String) -> some View {
        Text(msg)
            .font(.subheadline).foregroundStyle(.tertiary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func sourcePill(_ source: PersonSighting.Source) -> some View {
        switch source {
        case .visit(let placeName):
            Text(placeName.isEmpty ? "Visit" : placeName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.green.opacity(0.85), in: Capsule())
                .frame(maxWidth: 90)
        case .interaction(let type):
            Text(type.capitalized)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.purple.opacity(0.80), in: Capsule())
        }
    }

    private func macRelativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7  { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: date)
    }

    private func macAvatarColors(_ name: String) -> (bg: Color, text: Color) {
        let palette: [(Color, Color)] = [
            (Color(red: 0.933, green: 0.929, blue: 0.996), Color(red: 0.149, green: 0.129, blue: 0.361)),
            (Color(red: 0.882, green: 0.961, blue: 0.933), Color(red: 0.016, green: 0.204, blue: 0.173)),
            (Color(red: 0.980, green: 0.927, blue: 0.906), Color(red: 0.290, green: 0.113, blue: 0.047)),
            (Color(red: 0.900, green: 0.953, blue: 0.871), Color(red: 0.092, green: 0.428, blue: 0.067)),
        ]
        return palette[abs(name.hashValue) % palette.count]
    }
}

// MARK: - MacLogInteractionSheet

struct MacLogInteractionSheet: View {
    var preselectedPerson: Person?
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var personSearch   = ""
    @State private var selectedPerson: Person? = nil
    @State private var date           = Date()
    @State private var type           = "other"
    @State private var summary        = ""
    @State private var notes          = ""
    @State private var isSaving       = false
    @State private var saveError: String?
    @State private var pendingPhotos: [NSImage] = []
    @State private var showingPhotoPicker = false
    @State private var isDropTargeted    = false

    private let types = [
        "visit", "dinner", "lunch", "coffee", "call", "video call",
        "text", "email", "meeting", "event", "workout", "other"
    ]

    private var filteredPeople: [Person] {
        guard selectedPerson == nil, !personSearch.isEmpty else { return [] }
        return notionService.people
            .filter { $0.name.localizedCaseInsensitiveContains(personSearch) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log Interaction")
                .font(.headline)

            // Person
            VStack(alignment: .leading, spacing: 4) {
                Text("Person").font(.caption).foregroundStyle(.secondary)
                if let p = selectedPerson ?? preselectedPerson {
                    HStack {
                        Text(p.name).font(.body)
                        Spacer()
                        if preselectedPerson == nil {
                            Button { selectedPerson = nil; personSearch = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    TextField("Search people…", text: $personSearch)
                        .textFieldStyle(.roundedBorder)
                    if !filteredPeople.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredPeople) { person in
                                Button { selectedPerson = person; personSearch = "" } label: {
                                    Text(person.name)
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                if person.id != filteredPeople.last?.id { Divider() }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            // Date + Type
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Date").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(types, id: \.self) { t in
                            Button(t.capitalized) { type = t }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(type.capitalized)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Summary
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").font(.caption).foregroundStyle(.secondary)
                TextField("Brief summary…", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }

            // Notes
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }

            // Photos
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Photos").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.purple)
                }

                if pendingPhotos.isEmpty {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDropTargeted ? Color.purple.opacity(0.1) : Color.secondary.opacity(0.06))
                        .frame(height: 56)
                        .overlay(
                            VStack(spacing: 3) {
                                Image(systemName: "photo.badge.plus")
                                    .foregroundStyle(isDropTargeted ? .purple : .secondary)
                                Text("Drop photos here or click Add")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isDropTargeted ? Color.purple.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers)
                        }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingPhotos.indices, id: \.self) { i in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: pendingPhotos[i])
                                        .resizable().scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Button {
                                        pendingPhotos.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                                            .font(.system(size: 15))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                }
                            }
                            Button {
                                showingPhotoPicker = true
                            } label: {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(width: 72, height: 72)
                                    .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingPhotoPicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        let _ = url.startAccessingSecurityScopedResource()
                        if let img = NSImage(contentsOf: url) { pendingPhotos.append(img) }
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled((selectedPerson == nil && preselectedPerson == nil) || isSaving)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage {
                        DispatchQueue.main.async { pendingPhotos.append(img) }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func save() {
        guard let person = selectedPerson ?? preselectedPerson else { return }
        isSaving = true
        Task {
            do {
                let interaction = try await notionService.createInteraction(
                    personID: person.id, summary: summary, date: date, type: type, notes: notes)
                // Upload photos after the page exists
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                for (i, photo) in pendingPhotos.enumerated() {
                    if let tiff = photo.tiffRepresentation,
                       let bmp = NSBitmapImageRep(data: tiff),
                       let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        let filename = "interaction-\(formatter.string(from: date))-\(i).jpg"
                        let path = try NoteStore.shared.writePhoto(jpeg, category: "Interactions", filename: filename)
                        try await notionService.addPhotoToPage(interaction.id, photoURL: path)
                    }
                }
                await notionService.fetchRecentInteractions()
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - MacEditInteractionSheet

struct MacEditInteractionSheet: View {
    let interaction: Interaction
    let person: Person?
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var date           = Date()
    @State private var type           = "other"
    @State private var summary        = ""
    @State private var notes          = ""
    @State private var isSaving       = false
    @State private var saveError: String?
    @State private var pendingPhotos: [NSImage] = []
    @State private var showingPhotoPicker = false
    @State private var isDropTargeted    = false

    private let types = [
        "visit", "dinner", "lunch", "coffee", "call", "video call",
        "text", "email", "meeting", "event", "workout", "other"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Edit Interaction")
                    .font(.headline)
                if let p = person {
                    Text("— \(p.name)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            // Date + Type
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Date").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(types, id: \.self) { t in
                            Button(t.capitalized) { type = t }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(type.capitalized)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").font(.caption).foregroundStyle(.secondary)
                TextField("Brief summary…", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }

            // Photos
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Photos").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Add", systemImage: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.purple)
                }

                let existingURLs = interaction.photoURLs
                let hasAny = !existingURLs.isEmpty || !pendingPhotos.isEmpty

                if !hasAny {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDropTargeted ? Color.purple.opacity(0.1) : Color.secondary.opacity(0.06))
                        .frame(height: 56)
                        .overlay(
                            VStack(spacing: 3) {
                                Image(systemName: "photo.badge.plus")
                                    .foregroundStyle(isDropTargeted ? .purple : .secondary)
                                Text("Drop photos here or click Add")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isDropTargeted ? Color.purple.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers)
                        }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // Existing photos (read display only)
                            ForEach(existingURLs, id: \.self) { urlString in
                                MacNoteStorePhotoView(urlString: urlString, size: 72)
                            }
                            // Pending new photos (removable)
                            ForEach(pendingPhotos.indices, id: \.self) { i in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: pendingPhotos[i])
                                        .resizable().scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Button {
                                        pendingPhotos.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                                            .font(.system(size: 15))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                }
                            }
                            // Add more button
                            Button {
                                showingPhotoPicker = true
                            } label: {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(width: 72, height: 72)
                                    .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingPhotoPicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        let _ = url.startAccessingSecurityScopedResource()
                        if let img = NSImage(contentsOf: url) { pendingPhotos.append(img) }
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            date    = interaction.date
            type    = interaction.type
            summary = interaction.summary
            notes   = interaction.notes ?? ""
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage {
                        DispatchQueue.main.async { pendingPhotos.append(img) }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await notionService.updateInteraction(
                    id: interaction.id, summary: summary, type: type, date: date, notes: notes)
                // Upload any new photos
                if !pendingPhotos.isEmpty {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                    for (i, photo) in pendingPhotos.enumerated() {
                        if let tiff = photo.tiffRepresentation,
                           let bmp = NSBitmapImageRep(data: tiff),
                           let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                            let filename = "interaction-\(formatter.string(from: date))-\(i).jpg"
                            let path = try NoteStore.shared.writePhoto(jpeg, category: "Interactions", filename: filename)
                            try await notionService.addPhotoToPage(interaction.id, photoURL: path)
                        }
                    }
                }
                await notionService.fetchRecentInteractions()
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - MacAgendaSheet

struct MacAgendaSheet: View {
    // nil = home-screen entry point; presents a search picker first.
    // Row-level entry points (peopleCard hover/context-menu) still pass a fixed person.
    var preselectedPerson: Person? = nil
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPerson: Person?
    @State private var personSearch = ""
    @State private var agenda    = ""
    @State private var isSaving  = false
    @State private var saveError: String?

    init(preselectedPerson: Person? = nil) {
        self.preselectedPerson = preselectedPerson
        _selectedPerson = State(initialValue: preselectedPerson)
        _agenda         = State(initialValue: preselectedPerson?.agenda ?? "")
    }

    private var filteredPeople: [Person] {
        let q = personSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let all = notionService.people
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let person = selectedPerson {
                HStack {
                    Text("Agenda — \(person.name)").font(.headline)
                    // Only offer to change the person when we got here via the
                    // open-ended entry point — row-level entry points are locked.
                    if preselectedPerson == nil {
                        Spacer()
                        Button {
                            selectedPerson = nil
                            agenda = ""
                            personSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("One item per line. Shows as talking points in 1:1 meetings.")
                    .font(.caption).foregroundStyle(.secondary)

                TextEditor(text: $agenda)
                    .font(.body)
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                if let err = saveError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                }
            } else {
                Text("Edit Agenda").font(.headline)
                TextField("Search people…", text: $personSearch)
                    .textFieldStyle(.roundedBorder)
                if filteredPeople.isEmpty {
                    Text("No matches.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredPeople.prefix(8)) { p in
                                Button {
                                    selectedPerson = p
                                    agenda = p.agenda ?? ""
                                } label: {
                                    Text(p.name)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                                if p.id != filteredPeople.prefix(8).last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func save() {
        guard let person = selectedPerson else { return }
        isSaving = true
        Task {
            do {
                try await notionService.updatePersonAgenda(id: person.id, agenda: agenda)
                if let idx = notionService.people.firstIndex(where: { $0.id == person.id }) {
                    notionService.people[idx].agenda = agenda.isEmpty ? nil : agenda
                }
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - MacCheckInSheet

struct MacCheckInSheet: View {
    var preselectedPlace: Place? = nil
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlace: Place?
    @State private var placeSearch   = ""
    @State private var date          = Date()
    @State private var rating:  Int? = nil
    @State private var notes         = ""
    @State private var isSaving      = false
    @State private var saveError:    String?

    init(preselectedPlace: Place? = nil) {
        self.preselectedPlace = preselectedPlace
        _selectedPlace = State(initialValue: preselectedPlace)
    }

    private var effectivePlace: Place? { selectedPlace ?? preselectedPlace }

    private var filteredPlaces: [Place] {
        let q = placeSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let all = notionService.places.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return q.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(q) || $0.city.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Text("Log Visit").font(.headline)
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().scaleEffect(0.8) }
                    else        { Text("Save").bold() }
                }
                .disabled(effectivePlace == nil || isSaving)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    // Place
                    MacDetailRow(label: "Place") {
                        if let fixed = preselectedPlace {
                            // Pre-filled from place detail — read only
                            HStack(spacing: 8) {
                                Image(systemName: placeIcon(for: fixed.category))
                                    .foregroundStyle(placeColor(for: fixed.category))
                                Text(fixed.name).fontWeight(.medium)
                                if !fixed.city.isEmpty {
                                    Text("·").foregroundStyle(.secondary)
                                    Text(fixed.city).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            // Searchable place picker
                            VStack(alignment: .leading, spacing: 6) {
                                if let picked = selectedPlace {
                                    HStack {
                                        Image(systemName: placeIcon(for: picked.category))
                                            .foregroundStyle(placeColor(for: picked.category))
                                        Text(picked.name).fontWeight(.medium)
                                        Spacer()
                                        Button {
                                            selectedPlace = nil
                                            placeSearch   = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } else {
                                    TextField("Search places…", text: $placeSearch)
                                        .textFieldStyle(.roundedBorder)
                                    if !placeSearch.isEmpty {
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(filteredPlaces.prefix(8)) { place in
                                                Button {
                                                    selectedPlace = place
                                                    placeSearch   = ""
                                                } label: {
                                                    HStack {
                                                        Image(systemName: placeIcon(for: place.category))
                                                            .foregroundStyle(placeColor(for: place.category))
                                                            .frame(width: 18)
                                                        VStack(alignment: .leading, spacing: 1) {
                                                            Text(place.name).foregroundStyle(.primary)
                                                            if !place.city.isEmpty {
                                                                Text(place.city).font(.caption).foregroundStyle(.secondary)
                                                            }
                                                        }
                                                        Spacer()
                                                    }
                                                    .contentShape(Rectangle())
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 7)
                                                }
                                                .buttonStyle(.plain)
                                                if place.id != filteredPlaces.prefix(8).last?.id { Divider() }
                                            }
                                        }
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                        )
                                    }
                                }
                            }
                        }
                    }

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
                            if let r = rating {
                                Button {
                                    rating = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary).font(.callout)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 4)
                                Text("\(r)/7").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Notes
                    MacDetailRow(label: "Notes") {
                        TextEditor(text: $notes)
                            .font(.body)
                            .frame(minHeight: 100)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    if let err = saveError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: preselectedPlace != nil ? 480 : 540)
    }

    private func save() async {
        guard let place = effectivePlace else { return }
        isSaving   = true
        saveError  = nil
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await notionService.checkIn(
                place:  place,
                rating: rating,
                notes:  trimmed.isEmpty ? nil : trimmed,
                date:   date
            )
            await notionService.fetchVisits()
            logToWeeklyNote(place: place)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            isSaving  = false
        }
    }

    // Mirrors CheckInView.logToWeeklyNote (iOS) — B9 follow-up: the Mac check-in
    // sheet called notionService.checkIn directly but never appended the
    // Check-in Log line to the week's Horizons note, so Mac-added visits never
    // showed up there. No companions field on this sheet (Mac has no people
    // picker here), so the line is just time + place + optional rating.
    private func logToWeeklyNote(place: Place) {
        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = TimeZone.current
        timeFmt.dateFormat = "h:mm a"
        let timeStr = timeFmt.string(from: date)

        var parts: [String] = ["\(timeStr) — [[\(place.name)]]"]
        if let r = rating, r > 0 {
            parts.append(String(repeating: "★", count: r))
        }

        try? NoteStore.shared.appendToWeeklyCheckInLog(parts.joined(separator: " "), date: date)
    }
}

// MARK: - MacPlaceEditSheet

private let macPlaceEditCategories = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                      "Attraction", "Venue", "House", "Fitness",
                                      "Office", "Airport", "Medical", "Park", "Grocery"]

struct MacPlaceEditSheet: View {
    let place: Place
    @Environment(NotionService.self) private var notionService
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
        _name               = State(initialValue: place.name)
        _category           = State(initialValue: place.category.isEmpty ? "Restaurant" : place.category)
        _status             = State(initialValue: place.status.isEmpty  ? "Visited"    : place.status)
        _city               = State(initialValue: place.city)
        _notes              = State(initialValue: place.notes ?? "")
        _dwellTimeText      = State(initialValue: place.dwellTime.map      { String($0) } ?? "")
        _geofenceRadiusText = State(initialValue: place.geofenceRadius.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Text("Edit Place").font(.headline)
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().scaleEffect(0.8) }
                    else        { Text("Save").bold() }
                }
                .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    MacDetailRow(label: "Name") {
                        TextField("Place name", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    MacDetailRow(label: "City") {
                        TextField("City", text: $city)
                            .textFieldStyle(.roundedBorder)
                    }

                    MacDetailRow(label: "Category") {
                        Picker("", selection: $category) {
                            ForEach(macPlaceEditCategories, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }

                    MacDetailRow(label: "Status") {
                        Picker("", selection: $status) {
                            Text("Visited").tag("Visited")
                            Text("Want to Visit").tag("Want to Visit")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                        .labelsHidden()
                    }

                    MacDetailRow(label: "Description") {
                        TextEditor(text: $notes)
                            .font(.body)
                            .frame(minHeight: 80)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    HStack(spacing: 40) {
                        MacDetailRow(label: "Dwell Time") {
                            HStack {
                                TextField("3", text: $dwellTimeText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                Text("min").foregroundStyle(.secondary)
                            }
                        }
                        MacDetailRow(label: "Geofence Radius") {
                            HStack {
                                TextField(place.frequent ? "200" : "50", text: $geofenceRadiusText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                Text("m").foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }

                    if let err = saveError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }

                    Divider()

                    Button(role: .destructive) {
                        showingArchiveConfirm = true
                    } label: {
                        Label("Archive Place", systemImage: "archivebox")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 560)
        .confirmationDialog(
            "Archive \(place.name)?",
            isPresented: $showingArchiveConfirm,
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                Task {
                    try? await notionService.archivePlace(place)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This place will be hidden from all views.")
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        saveError = nil
        do {
            try await notionService.updatePlace(
                place,
                name: trimmed,
                category: category,
                status: status,
                city: city.trimmingCharacters(in: .whitespaces),
                notes: notes.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : notes.trimmingCharacters(in: .whitespaces)
            )
            let newDwell  = Int(dwellTimeText.trimmingCharacters(in: .whitespaces))
            let newRadius = Int(geofenceRadiusText.trimmingCharacters(in: .whitespaces))
            if newDwell != place.dwellTime {
                try await notionService.setDwellTime(place, minutes: newDwell)
            }
            if newRadius != place.geofenceRadius {
                try await notionService.setGeofenceRadius(place, metres: newRadius)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
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
