// TraceMacPlacesView.swift
// The Places section: the browsable list, the all-visits browser, one place's
// tabbed detail, and the visit / check-in / edit sheets that hang off them.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 63 (2026-08-02), Phase 1. Lifted verbatim out of
// `TraceMacContentView.swift`, which had grown to 3607 lines holding the app
// shell, the whole of Places, Home and six sheets at once. Nothing here was
// rewritten: the same declarations, in the same order, with the same bodies.
// The shell keeps `TraceMacContentView`, the interaction
// sheets, and the backlink views that People shares with Places.
//
// `TraceMac/` is a synchronized folder in the project, so this file is compiled
// into the target with no project-file edit.

import SwiftUI
import MapKit

// MARK: - TraceMacPlacesView

struct TraceMacPlacesView: View {
    /// Set by `TraceMacContentView` when a wikilink or a `navigateToRecord`
    /// post asks to open a specific place. Consumed in `.task(id:)` below and
    /// cleared. See the deep link note in `TraceMacContentView`.
    var deepLinkPlaceID: Binding<String?>? = nil

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
                    MacEmptyState.placeholder("mappin.circle", "Select a place")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: deepLinkPlaceID?.wrappedValue) {
            guard let id = deepLinkPlaceID?.wrappedValue else { return }
            sidebarMode = .places
            selectedID = id
            deepLinkPlaceID?.wrappedValue = nil
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

    @State private var searchText         = ""
    @State private var selectedCategory:  String? = nil
    @State private var selectedTag:       String? = nil
    @State private var selectedPeopleIDs: Set<String> = []
    @State private var selectedMonth: Date? = nil
    @State private var editingVisit:      Visit? = nil
    @State private var showingLogVisit    = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// Months that actually contain a visit, newest first. Drives the Date menu
    /// so it can never offer a month with nothing in it.
    private var availableMonths: [Date] {
        let cal = Calendar.current
        let months = notionService.visits.compactMap {
            cal.date(from: cal.dateComponents([.year, .month], from: $0.date))
        }
        return Array(Set(months)).sorted(by: >)
    }

    /// `filtered` is already newest-first, so each group keeps that order.
    private var groupedByMonth: [(month: Date, visits: [Visit])] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Visit]] = [:]
        for visit in filtered {
            guard let key = cal.date(from: cal.dateComponents([.year, .month], from: visit.date))
            else { continue }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(visit)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

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
                // month filter
                if let selectedMonth {
                    let cal = Calendar.current
                    guard cal.isDate(visit.date, equalTo: selectedMonth, toGranularity: .month)
                    else { return false }
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
            || selectedMonth != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session 63 (2026-08-02): the sheet chrome is gone.
            //
            // This was `.sheet(isPresented:)` on top of Places until it became a
            // Directory tab, and I promoted it without stripping what only made
            // sense as a modal. It kept a "Done" button wired to `dismiss()` —
            // which in a window closes the *window* — bound to Escape, plus a
            // redundant "All Visits" title above a tab already labelled Visits,
            // and a fixed 680×700 frame that left it floating in the middle of
            // the pane. David: *"clicking the Done button just closes out the
            // app. What is it suppose to do?"* Nothing, any more.
            HStack {
                Spacer()
                Button { showingLogVisit = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("Log Visit")
                Button { Task { await notionService.fetchVisits() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

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

                // Month filter. David: *"visits might benefit from a way to
                // narrow the day. right now if i want to go to June 19th for
                // example i have to drag the scroll bar."*
                //
                // A filter rather than a scroll-to: picking June leaves twenty
                // rows to read instead of hunting a position in eight hundred.
                // Only months that actually contain visits are listed, so the
                // menu never offers an empty result.
                Menu {
                    Button("All Dates") { selectedMonth = nil }
                    Divider()
                    ForEach(availableMonths, id: \.self) { month in
                        Button(Self.monthFormatter.string(from: month)) { selectedMonth = month }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text(selectedMonth.map { Self.monthFormatter.string(from: $0) } ?? "Date")
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selectedMonth != nil ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Clear filters
                if hasActiveFilters {
                    Button("Clear") {
                        selectedCategory = nil
                        selectedTag      = nil
                        selectedPeopleIDs = []
                        selectedMonth    = nil
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
                MacEmptyState.list("clock.arrow.circlepath",
                                   notionService.visits.isEmpty ? "No visits yet" : "No matching visits")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Grouped by month with pinned headers, so scrolling tells
                    // you where you are instead of leaving you to judge it from
                    // the dates on each row.
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedByMonth, id: \.month) { group in
                            Section {
                                ForEach(group.visits) { visit in
                                    Button { editingVisit = visit } label: {
                                        MacVisitRow(visit: visit)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 16)
                                }
                            } header: {
                                HStack {
                                    Text(Self.monthFormatter.string(from: group.month))
                                        .font(MacType.rowEmphasis)
                                    Spacer()
                                    Text("\(group.visits.count)")
                                        .font(MacType.meta)
                                        .foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            MacIconBadge(icon: placeIcon(for: place?.category ?? ""),
                         tint: placeColor(for: place?.category ?? ""),
                         size: .standard)

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
                            MacAvatar(name: person.name, size: .inline)
                        }
                        Text(companions.prefix(4).map {
                            $0.name.components(separatedBy: " ").first ?? $0.name
                        }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let preview = visitNotePreview(visit.notes) {
                    Text(preview)
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

// MARK: - Visit note preview

/// Flattens a visit note for a truncated preview.
///
/// Session 63 (2026-08-02). David: *"why are some of the arlington Lanes visits
/// showing full notes and other are not when all of them have good notes"*.
///
/// They all did. The rows rendered `visit.notes` raw under a `.lineLimit`, and
/// many of these notes start with a markdown heading followed by a blank line —
/// so line one was `# Pool Night at Arlington Lanes` and line two was empty. The
/// entire preview budget went on a title and some whitespace. The notes that
/// looked complete were simply the ones without a heading.
///
/// **A line limit counts lines, not visible content**, so any preview of
/// multi-line text has to be flattened first.
///
/// Headings are dropped rather than folded in: the row already shows a place and
/// a date, and "Pool Night at Arlington Lanes" above `Arlington Lanes · July 22`
/// adds nothing. Unless the heading is all there is — then it *is* the note, and
/// it is shown without its `#`.
///
/// Shared by `MacVisitRow` and the place detail's visits tab, which had the same
/// bug for the same reason.
func visitNotePreview(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let lines = raw
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return nil }

    let body = lines.filter { !$0.hasPrefix("#") }
    let use  = body.isEmpty
        ? lines.map { String($0.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
        : body
    let joined = use.joined(separator: " ")
    return joined.isEmpty ? nil : joined
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
            MacIconBadge(icon: placeIcon(for: place?.category ?? ""),
                         tint: placeColor(for: place?.category ?? ""),
                         size: .compact)
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
    /// Session 67. Ported from `PlaceDetailView` so the Mac's detail carries the
    /// same editing and repair affordances the phone has had all along.
    @State private var isEditingTags    = false
    @State private var newTagText       = ""
    @State private var markedForReview  = false
    @State private var isEnriching      = false
    @State private var enrichError:     String? = nil
    @State private var enrichCandidate: GooglePlace? = nil
    @State private var showingEnrichConfirm = false

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
                Text("Documents").tag(4)
                Text("Settings").tag(5)
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
                case 4: documentsTab
                default: settingsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actionBar
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
                    // Was a static label. iOS has let you change the category
                    // straight from Overview since it shipped; on the Mac the
                    // only route was the edit sheet.
                    Menu {
                        ForEach(Self.categories, id: \.self) { cat in
                            Button(cat) {
                                Task {
                                    try? await notionService.updatePlace(
                                        livePlace,
                                        name: livePlace.name,
                                        category: cat,
                                        status: livePlace.status)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: placeIcon(for: livePlace.category))
                                .foregroundStyle(placeColor(for: livePlace.category))
                            Text(livePlace.category.isEmpty ? "None" : livePlace.category)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if let description = livePlace.notes, !description.isEmpty {
                    MacDetailRow(label: "Description") { Text(description) }
                }
                if let summary = livePlace.aiSummary, !summary.isEmpty {
                    MacDetailRow(label: "Summary") { Text(summary) }
                }
                MacDetailRow(label: "Tags") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !livePlace.tags.isEmpty {
                            // `FlowLayout` rather than iOS's horizontal
                            // ScrollView: the Mac pane is wide and a row that
                            // scrolls sideways hides tags behind an edge with
                            // no scrollbar to say so.
                            FlowLayout(spacing: 6) {
                                ForEach(livePlace.tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag).font(.caption)
                                        Button {
                                            Task { await setTags(livePlace.tags.filter { $0 != tag }) }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2.weight(.semibold))
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                                }
                            }
                        }
                        if isEditingTags {
                            HStack(spacing: 8) {
                                TextField("New tag", text: $newTagText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 180)
                                    .onSubmit { Task { await addTypedTag() } }
                                Button("Add") { Task { await addTypedTag() } }
                                    .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { isEditingTags = false; newTagText = "" }
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        } else {
                            let availableTags = Array(Set(notionService.places.flatMap { $0.tags }))
                                .filter { !livePlace.tags.contains($0) }
                                .sorted()
                            Menu {
                                ForEach(availableTags, id: \.self) { tag in
                                    Button(tag) { Task { await setTags(livePlace.tags + [tag]) } }
                                }
                                if !availableTags.isEmpty { Divider() }
                                Button {
                                    isEditingTags = true
                                } label: {
                                    Label("New tag…", systemImage: "plus")
                                }
                            } label: {
                                Label("Add tag", systemImage: "plus.circle").font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
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

                // The row that answers *"the details are still not there in
                // Lakemore."* Lakemore Resort was saved from Mac Discover with
                // a street line and no state, no postcode, no hours and no
                // maps URL, and the Mac had no way to ask Google again — that
                // button was iOS-only. Repairing a thin record meant picking up
                // the phone, or editing Notion by hand.
                MacDetailRow(label: "Google Places") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            Task { await runEnrich() }
                        } label: {
                            HStack(spacing: 6) {
                                if isEnriching {
                                    ProgressView().scaleEffect(0.6)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text(isEnriching ? "Searching…" : "Re-enrich from Google")
                            }
                            .foregroundStyle(isEnriching ? Color.secondary : Color.blue)
                        }
                        .buttonStyle(.plain)
                        .disabled(isEnriching)
                        if let err = enrichError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                // **At the bottom, and deliberately not interactive.**
                //
                // David asked for it here rather than above the address: the
                // address is the thing you read, the map is the thing you glance
                // at to confirm you are thinking of the right place.
                //
                // `interactionModes: []` because this sits inside a `ScrollView`.
                // A live map swallows scroll and trackpad gestures over its own
                // frame, so the pane would stop scrolling wherever the map is —
                // the same class of problem as D58's invisible cover swallowing
                // clicks, and the same answer: a view that exists to be looked at
                // stays out of the gesture path. Directions is already one tap
                // away in the action bar for the case where you want a real map.
                //
                // Hidden entirely at 0,0 rather than drawn: a place saved by hand
                // with no coordinates would otherwise render the Gulf of Guinea
                // under its address, which looks like data rather than absence.
                if livePlace.latitude != 0 || livePlace.longitude != 0 {
                    MacDetailRow(label: "Map") {
                        // **The whole map is one button, rather than a live map.**
                        //
                        // Making it pannable is the obvious way to let you drill
                        // down and it is the wrong one here: a live map inside a
                        // `ScrollView` eats the scroll gesture over its own frame,
                        // so the pane would stop scrolling exactly where the map
                        // is. Keeping `interactionModes: []` and handling the
                        // click ourselves gives the drill-down without taking the
                        // scroll — and Maps is a better map than a 190pt inset
                        // one could ever be.
                        //
                        // `openMapsPlace`, not `openMapsDirections`: this is "show
                        // me where that is", not "take me there". Directions is
                        // already its own button in the action bar.
                        // **A tap overlay, not a `Button` wrapping the map.**
                        //
                        // Wrapping was the first attempt and it behaved oddly:
                        // David had to press and drag before Maps opened. `Map`
                        // consumes the mouse-down even at `interactionModes: []`,
                        // so the enclosing button never saw a clean click and only
                        // fired once the gesture resolved as something else.
                        //
                        // Third time this exact shape has come up — the cover
                        // photo swallowing tab clicks (D58), the cover drag target
                        // (D67), and now this. **The map does not know where it
                        // was clipped to and should not be in the gesture path at
                        // all; a `Color.clear` sized to what you can see does.**
                        ZStack {
                            Map(initialPosition: .region(MKCoordinateRegion(
                                    center: livePlace.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.006,
                                                           longitudeDelta: 0.006))),
                                interactionModes: []) {
                                Annotation(livePlace.name, coordinate: livePlace.coordinate) {
                                    // The shared pin, so the marker here and the
                                    // one in Discover cannot drift apart.
                                    PlacePin(place: livePlace)
                                }
                            }
                            .frame(height: 190)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .bottomTrailing) {
                                Text("Open in Maps")
                                    .font(MacType.meta)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.thinMaterial, in: Capsule())
                                    .padding(8)
                            }
                            .allowsHitTesting(false)

                            Color.clear
                                .frame(height: 190)
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { openMapsPlace(livePlace) }
                        }
                        .help("Open \(livePlace.name) in Maps")
                    }
                }
            }
            .padding(20)
        }
        // `presenting:` so the message can name what it is about to overwrite.
        // Enrich rewrites Name, Address, City and the coordinates, which is
        // destructive enough that a bare "Update?" is not fair warning.
        .alert("Update from Google Places?",
               isPresented: $showingEnrichConfirm,
               presenting: enrichCandidate) { candidate in
            Button("Update") {
                Task { try? await notionService.enrichPlace(livePlace, from: candidate) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text("\(candidate.name)\n\(candidate.formattedAddress)")
        }
    }

    /// Asks Google for this place again and offers the top hit.
    ///
    /// Same call the iOS detail makes: a `nearbySearch` inside 100m of the
    /// coordinates we already hold, queried by name. Tight radius on purpose —
    /// a text search on "Lakemore Resort" alone can return a namesake three
    /// states over, and this writes straight over the record.
    private func runEnrich() async {
        isEnriching = true
        enrichError = nil
        do {
            let coord = CLLocationCoordinate2D(latitude: livePlace.latitude,
                                               longitude: livePlace.longitude)
            let results = try await GooglePlacesService.shared.nearbySearch(coordinate: coord,
                                                                           query: livePlace.name)
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

    /// One writer for the Tags property. `updatePlace` replaces the whole
    /// multi-select, so add and remove are the same call with a different array
    /// — worth saying once rather than spelling the patch out at three sites.
    private func setTags(_ tags: [String]) async {
        try? await notionService.updatePlace(livePlace,
                                             name: livePlace.name,
                                             category: livePlace.category,
                                             status: livePlace.status,
                                             tags: tags)
    }

    private func addTypedTag() async {
        let tag = newTagText.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !livePlace.tags.contains(tag) else {
            newTagText = ""
            isEditingTags = false
            return
        }
        await setTags(livePlace.tags + [tag])
        newTagText = ""
        isEditingTags = false
    }

    // MARK: - Action bar

    /// The four actions iOS pins to the bottom of every place, in iOS's order.
    ///
    /// David: *"Id like directions to show up like we have in the ios version."*
    /// Directions did not exist anywhere in Mac Places — the only implementation
    /// on this target was `private` to Discover. It is a bar rather than more
    /// header glyphs because these are the verbs you reach for on a place you
    /// are looking at, and a 14pt icon in a row of five reads as chrome.
    ///
    /// Log Visit stays in the header **as well**. It was the Mac's only way in,
    /// and moving a control someone already knows is a worse trade than showing
    /// it twice.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                openMapsDirections(to: livePlace)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Open directions in Maps")

            Button {
                showingLogVisit = true
            } label: {
                Label("Check In", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { try? await notionService.toggleFlagged(livePlace) }
            } label: {
                Image(systemName: livePlace.flagged ? "star.fill" : "star")
                    .frame(width: 20)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(livePlace.flagged ? Color.yellow : Color.secondary)
            .help(livePlace.flagged ? "Unpin this place" : "Pin this place")

            Button {
                Task {
                    try? await notionService.markPlaceForReview(livePlace)
                    markedForReview = true
                }
            } label: {
                Image(systemName: markedForReview ? "exclamationmark.triangle.fill"
                                                  : "exclamationmark.triangle")
                    .frame(width: 20)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(markedForReview ? Color.orange : Color.secondary)
            .help("Flag this record for review")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The Notion "Category" select, spelled the same way iOS spells it.
    private static let categories = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                     "Attraction", "Venue", "House", "Fitness",
                                     "Office", "Airport", "Medical", "Park", "Grocery"]

    // MARK: - Visits

    private var visitsTab: some View {
        Group {
            if placeVisits.isEmpty {
                MacEmptyState.list("clock.arrow.circlepath", "No visits yet")
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
                                        if let notes = visitNotePreview(visit.notes) {
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
        PlaceNotesTab(placeName: livePlace.name, notePath: noteRelativePath)
            .environment(noteStore)
    }

    // MARK: - Documents (backlinks)

    private var documentsTab: some View {
        PlaceDocumentsTab(placeName: livePlace.name)
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

// MARK: - Place Notes tab (own note + content-based backlinks)

/// Wraps the place's own note editor with a "Mentioned in" section below it —
/// other notes elsewhere in the vault whose body `[[wikilinks]]` this place.
struct PlaceNotesTab: View {
    let placeName: String
    let notePath: String

    @Environment(NoteStore.self) private var noteStore
    @State private var mentions: [NoteMention] = []
    @State private var previewTarget: NotePreviewTarget? = nil

    var body: some View {
        VStack(spacing: 0) {
            TraceMacNoteEditor(relativePath: notePath)
                .environment(noteStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            MentionedInSection(mentions: mentions) { mention in
                previewTarget = NotePreviewTarget(path: mention.relativePath)
            }
        }
        .task { await loadMentions() }
        .sheet(item: $previewTarget) { target in
            MacNotePreviewSheet(relativePath: target.path)
                .environment(noteStore)
        }
    }

    private func loadMentions() async {
        let name = placeName
        let excludePath = notePath
        mentions = await Task.detached(priority: .utility) {
            NoteStore.shared.findWikilinkMentions(of: name, excluding: excludePath)
        }.value
    }
}

// MARK: - Place Documents tab (backlinks — Phase 5)

/// Documents linked to a place via the sidecar `linked_note` field.
/// Documents filed to this place's note.
///
/// Session 63 (2026-08-02) — this tab could not show a Satchel document at all.
/// The old filter was `category == "Place" && linkedNote contains placeName`,
/// and `category` is just the `Documents/` subfolder name. Satchel has written
/// to `Documents/<yyyy>/` since 2026-07-28, when folders stopped being a filing
/// decision, so every document captured on the phone had `category == "2026"`
/// and failed the first clause before the second was even reached.
///
/// The folder is not a filing decision, so it has no business in a filing
/// query. Matching is now on `linked_note` alone, exactly, against the same
/// path `noteRelativePath` builds — substring matching on a place name would
/// have made "Starbucks" claim documents filed to "Starbucks Coffee Company".
///
/// Known limitation, unchanged: renaming a place note breaks the link, because
/// the sidecar stores a literal path. `NoteStore.retargetLinkedNotes` exists
/// for exactly this and is currently only wired to project archiving.
struct PlaceDocumentsTab: View {
    let placeName: String

    @Environment(NoteStore.self) private var noteStore
    @State private var docStore: TraceMacDocumentStore? = nil

    private var linkedDocs: [TraceMacDocument] {
        guard let docStore else { return [] }
        let notePath = "Notes/Places/\(noteStore.placeNoteFilename(for: placeName)).md"
        return docStore.documents
            .filter { $0.linkedNote?.localizedCaseInsensitiveCompare(notePath) == .orderedSame }
            .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    var body: some View {
        Group {
            if docStore?.isLoading == true {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if linkedDocs.isEmpty {
                MacEmptyState.list("doc.richtext", "No documents linked to \(placeName)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(linkedDocs) { doc in
                            DocumentBacklinkRow(doc: doc)
                            Divider().padding(.leading, 42)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task {
            if docStore == nil { docStore = TraceMacDocumentStore(noteStore: noteStore) }
            await docStore?.reload()
        }
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

    /// Whether the user actually moved the date.
    ///
    /// **Not `date != visit.date`.** The picker is `displayedComponents: .date`,
    /// so the only thing it can express is a day; comparing instants would call
    /// an untouched picker "changed" for any visit carrying a time.
    private var dateChanged: Bool {
        !Calendar.current.isDate(date, inSameDayAs: visit.date)
    }

    /// Session 64. The date picker was bound to `$date` and `save()` omitted
    /// `date:` entirely, so `updateVisit`'s defaulted `nil` meant editing the
    /// date did nothing — and said nothing, which is the worse half. It is the
    /// only field on this sheet that looked like it worked and did not.
    ///
    /// **The one-line fix would have been a data-loss bug.** Passing
    /// `date: date` unconditionally sends `Date Visited` on every save, and
    /// `NotionService.localDateString` formats with `.withFullDate` only — no
    /// time component. So changing a *rating* would have silently truncated the
    /// visit's timestamp to midnight. `parseVisit`'s own comment says these
    /// records can be full ISO-8601, so that is a real loss, not a theoretical
    /// one: Inspired on 31 Jul is 4:44 PM.
    ///
    /// Sending it only when the day changed means an untouched date is never
    /// written, and a changed one is written at day precision because a day is
    /// all the control can say. Same shape as the `remind:` fix in Session 63:
    /// a save must not rewrite a field it was not asked to change.
    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await notionService.updateVisit(
                visit,
                rating: rating,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
                date: dateChanged ? date : nil
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
