import SwiftUI

struct VisitsView: View {
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var selectedVisit: Visit?
    @State private var selectedCategory: String? = nil
    @State private var selectedTag: String? = nil

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

    private var hasActiveFilters: Bool {
        selectedCategory != nil || selectedTag != nil
    }

    var filtered: [Visit] {
        notion.visits
            .filter { searchText.isEmpty || $0.placeName.localizedCaseInsensitiveContains(searchText) }
            .filter { visit in
                guard selectedCategory != nil || selectedTag != nil else { return true }
                guard let place = notion.places.first(where: { $0.id == visit.placeID }) else { return false }
                if let cat = selectedCategory, place.category != cat { return false }
                if let tag = selectedTag, !place.tags.contains(tag) { return false }
                return true
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter chips
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

                        if hasActiveFilters {
                            Button {
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
            .navigationTitle("Visits")
            .drawerToolbar()
            .sheet(item: $selectedVisit) { visit in
                VisitDetailView(visit: visit)
                    .environment(NotionService.shared)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await notion.fetchVisits() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
