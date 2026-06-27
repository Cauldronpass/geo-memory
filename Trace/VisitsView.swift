import SwiftUI

enum PeopleFilterMode: Hashable {
    case matchAll
    case matchAny
}

struct VisitsView: View {
    var onCalendarStateChange: ((Bool) -> Void)? = nil

    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var selectedVisit: Visit?
    @State private var selectedCategory: String? = nil
    @State private var selectedTag: String? = nil
    @State private var selectedPeopleIDs: Set<String> = []
    @State private var peopleFilterMode: PeopleFilterMode = .matchAll
    @State private var showingPeopleFilter = false
    @State private var showCalendar = false

    private var availableCategories: [String] {
        let placeIDs = Set(notion.visits.map { $0.placeID })
        return Array(Set(notion.places
            .filter { placeIDs.contains($0.id) && !$0.category.isEmpty }
            .map { $0.category }
        )).sorted()
    }

    private var availableTags: [String] {
        let placeIDs = Set(notion.visits.map { $0.placeID })
        return Array(Set(notion.places
            .filter { placeIDs.contains($0.id) }
            .flatMap { $0.tags }
        )).sorted()
    }

    private var availablePeople: [Person] {
        let usedIDs = Set(notion.visits.flatMap { $0.peopleIDs })
        return notion.people
            .filter { usedIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var hasActiveFilters: Bool {
        selectedCategory != nil || selectedTag != nil || !selectedPeopleIDs.isEmpty
    }

    private var peopleChipLabel: String {
        switch selectedPeopleIDs.count {
        case 0: return "With"
        case 1:
            let name = availablePeople.first { selectedPeopleIDs.contains($0.id) }?.name ?? "1 person"
            return name.components(separatedBy: " ").first ?? name
        default:
            let mode = peopleFilterMode == .matchAll ? "All" : "Any"
            return "\(mode): \(selectedPeopleIDs.count)"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func visitMatchesSearch(_ visit: Visit) -> Bool {
        guard !searchText.isEmpty else { return true }
        if visit.placeName.localizedCaseInsensitiveContains(searchText) { return true }
        if let notes = visit.notes, notes.localizedCaseInsensitiveContains(searchText) { return true }
        if Self.dateFormatter.string(from: visit.date).localizedCaseInsensitiveContains(searchText) { return true }
        return false
    }

    var filtered: [Visit] {
        notion.visits
            .filter { visitMatchesSearch($0) }
            .filter { visit in
                if !selectedPeopleIDs.isEmpty {
                    switch peopleFilterMode {
                    case .matchAll:
                        if !selectedPeopleIDs.isSubset(of: Set(visit.peopleIDs)) { return false }
                    case .matchAny:
                        if selectedPeopleIDs.isDisjoint(with: Set(visit.peopleIDs)) { return false }
                    }
                }
                guard selectedCategory != nil || selectedTag != nil else { return true }
                guard let place = notion.places.first(where: { $0.id == visit.placeID }) else { return false }
                if let cat = selectedCategory, place.category != cat { return false }
                if let tag = selectedTag, !place.tags.contains(tag) { return false }
                return true
            }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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

                if !availablePeople.isEmpty {
                    MapFilterChip(
                        title: peopleChipLabel,
                        systemImage: "person",
                        isActive: !selectedPeopleIDs.isEmpty,
                        showChevron: true) {
                        showingPeopleFilter = true
                    }
                }

                if hasActiveFilters {
                    Button {
                        selectedCategory = nil
                        selectedTag = nil
                        selectedPeopleIDs = []
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
    }

    var body: some View {
        NavigationStack {
            Group {
                if showCalendar {
                    VStack(spacing: 0) {
                        filterChips
                        ScrollView {
                            VisitsCalendarView(visits: filtered)
                                .environment(notion)
                                .padding(.vertical)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        filterChips

                        if notion.isLoading {
                            ProgressView("Loading visits...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if notion.visits.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                Text("No visits yet")
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List {
                                ForEach(filtered) { visit in
                                    Button {
                                        selectedVisit = visit
                                    } label: {
                                        VisitRow(visit: visit)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .searchable(text: $searchText, prompt: "Search visits")
                            .refreshable { await notion.fetchVisits() }
                        }
                    }
                }
            }
            .onChange(of: showCalendar) { _, new in onCalendarStateChange?(new) }
            .navigationTitle("Visits")
            .drawerToolbar()
            .sheet(item: $selectedVisit) { visit in
                VisitDetailView(visit: visit)
                    .environment(NotionService.shared)
            }
            .sheet(isPresented: $showingPeopleFilter) {
                PeopleFilterSheet(
                    people: availablePeople,
                    initialSelectedIDs: selectedPeopleIDs,
                    initialMode: peopleFilterMode,
                    onApply: { ids, newMode in
                        selectedPeopleIDs = ids
                        peopleFilterMode = newMode
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await notion.fetchVisits() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        withAnimation { showCalendar.toggle() }
                    } label: {
                        Image(systemName: showCalendar ? "list.bullet" : "calendar")
                    }
                }
            }
        }
    }
}

// MARK: - People Filter Sheet

struct PeopleFilterSheet: View {
    let people: [Person]
    let initialSelectedIDs: Set<String>
    let initialMode: PeopleFilterMode
    let onApply: (Set<String>, PeopleFilterMode) -> Void

    @State private var selectedIDs: Set<String> = []
    @State private var mode: PeopleFilterMode = .matchAll
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredPeople: [Person] {
        guard !searchText.isEmpty else { return people }
        return people.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Clear") { selectedIDs = [] }
                    .disabled(selectedIDs.isEmpty)
                Spacer()
                Text("Filter by Person").font(.headline)
                Spacer()
                Button("Done") {
                    onApply(selectedIDs, mode)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // AND / OR mode toggle
            HStack(spacing: 0) {
                Button {
                    mode = .matchAll
                } label: {
                    Text("Match All")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(mode == .matchAll ? Color.accentColor : Color(.systemGray5))
                        .foregroundStyle(mode == .matchAll ? .white : .primary)
                }
                Button {
                    mode = .matchAny
                } label: {
                    Text("Match Any")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(mode == .matchAny ? Color.accentColor : Color(.systemGray5))
                        .foregroundStyle(mode == .matchAny ? .white : .primary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Text(mode == .matchAll
                 ? "All selected people must be present"
                 : "Any selected person must be present")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    personRows()
                }
            }
        }
        .onAppear {
            selectedIDs = initialSelectedIDs
            mode = initialMode
        }
    }

    // Extracted to a @ViewBuilder func so the compiler resolves ForEach
    // in isolation — avoids the Binding<C> overload ambiguity.
    @ViewBuilder
    private func personRows() -> some View {
        ForEach(filteredPeople, id: \.id) { (person: Person) in
            Button {
                if selectedIDs.contains(person.id) {
                    selectedIDs.remove(person.id)
                } else {
                    selectedIDs.insert(person.id)
                }
            } label: {
                HStack {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.teal)
                    Text(person.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    if selectedIDs.contains(person.id) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                            .fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 16)
        }
    }
}

// MARK: - Visits Calendar View (thin wrapper over CalendarGridView)

struct VisitsCalendarView: View {
    let visits: [Visit]
    @Environment(NotionService.self) private var notion
    @State private var selectedVisit: Visit?
    @State private var mixedDayEntries: [CalendarEntry]?

    private var entries: [CalendarEntry] {
        visits.map { v in
            let category = notion.places.first { $0.id == v.placeID }?.category ?? ""
            return CalendarEntry(
                id: v.id,
                date: v.date,
                color: superCategoryColor(for: category),
                cellStat: nil,
                displayName: v.placeName,
                value: nil,
                shape: .circle
            )
        }
    }

    private func monthStats(_ monthEntries: [CalendarEntry]) -> [(String, String)] {
        let ids = Set(monthEntries.map { $0.id })
        let vs = visits.filter { ids.contains($0.id) }
        let uniquePlaces = Set(vs.map { $0.placeID }).count
        return [
            ("\(vs.count)", "visits"),
            ("\(uniquePlaces)", "places")
        ]
    }

    var body: some View {
        CalendarGridView(
            entries: entries,
            weekSecondary: { _ in nil },
            monthStats: monthStats,
            onSelect: { dayEntries in
                mixedDayEntries = dayEntries
            }
        )
        .sheet(item: $selectedVisit) { visit in
            VisitDetailView(visit: visit).environment(notion)
        }
        .sheet(isPresented: Binding(
            get: { mixedDayEntries != nil },
            set: { if !$0 { mixedDayEntries = nil } }
        )) {
            if let entries = mixedDayEntries {
                MixedDayPickerSheet(entries: entries) { entry in
                    selectedVisit = visits.first { $0.id == entry.id }
                    mixedDayEntries = nil
                }
            }
        }
    }
}

struct VisitRow: View {
    let visit: Visit
    @Environment(NotionService.self) private var notion

    var city: String? {
        notion.places.first { $0.id == visit.placeID }?.city
    }

    private func companionRow(_ people: [Person]) -> some View {
        HStack(spacing: 4) {
            ForEach(people.prefix(4)) { person in
                let initials = person.name
                    .components(separatedBy: " ")
                    .compactMap { $0.first.map { String($0) } }
                    .prefix(2).joined()
                let colors = companionColors(person.name)
                Text(initials)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(colors.text)
                    .frame(width: 16, height: 16)
                    .background(colors.bg, in: Circle())
            }
            Text(people.map { $0.name.components(separatedBy: " ").first ?? $0.name }
                .joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func companionColors(_ name: String) -> (bg: Color, text: Color) {
        let options: [(Color, Color)] = [
            (Color(red: 0.933, green: 0.929, blue: 0.996), Color(red: 0.149, green: 0.129, blue: 0.361)),
            (Color(red: 0.882, green: 0.961, blue: 0.933), Color(red: 0.016, green: 0.204, blue: 0.173)),
            (Color(red: 0.980, green: 0.927, blue: 0.906), Color(red: 0.290, green: 0.113, blue: 0.047)),
            (Color(red: 0.900, green: 0.953, blue: 0.871), Color(red: 0.092, green: 0.428, blue: 0.067)),
        ]
        return options[abs(name.hashValue) % options.count]
    }

    var body: some View {
        let visitPeople = notion.people.filter { visit.peopleIDs.contains($0.id) }

        return VStack(alignment: .leading, spacing: 3) {
            Text(visit.placeName)
                .font(.body)
            HStack {
                Text(visit.date, style: .date)
                if let city, !city.isEmpty {
                    Text("·")
                    Text(city)
                }
                if let rating = visit.rating {
                    Text("·")
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                        Text("\(rating)/7")
                            .font(.caption)
                    }
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            if !visitPeople.isEmpty {
                companionRow(visitPeople)
            }
            if let notes = visit.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
