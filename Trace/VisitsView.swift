import SwiftUI

struct VisitsView: View {
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var selectedVisit: Visit?

    var filtered: [Visit] {
        if searchText.isEmpty { return notion.visits }
        return notion.visits.filter {
            $0.placeName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if notion.isLoading {
                    ProgressView("Loading visits...")
                } else if notion.visits.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No visits yet")
                            .foregroundColor(.secondary)
                    }
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
                    .sheet(item: $selectedVisit) { visit in
                        VisitDetailView(visit: visit)
                            .environment(NotionService.shared)
                    }
                }
            }
            .navigationTitle("Visits")
            .refreshable {
                await notion.fetchVisits()
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
