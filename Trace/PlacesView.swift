import SwiftUI

struct PlacesView: View {
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""

    var filtered: [Place] {
        if searchText.isEmpty { return notion.places }
        return notion.places.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.city.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var flagged: [Place] { filtered.filter { $0.flagged } }
    var unflagged: [Place] { filtered.filter { !$0.flagged } }

    var body: some View {
        NavigationStack {
            Group {
                if notion.isLoading {
                    ProgressView("Loading places...")
                } else if notion.places.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "mappin.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No places yet")
                            .foregroundColor(.secondary)
                        Text("Check your Notion token in Settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        if !flagged.isEmpty {
                            Section("Starred") {
                                ForEach(flagged) { place in
                                    PlaceRow(place: place)
                                }
                            }
                        }
                        Section("All Places (\(unflagged.count))") {
                            ForEach(unflagged) { place in
                                PlaceRow(place: place)
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search places")
                }
            }
            .navigationTitle("Places")
            .refreshable {
                await notion.fetchPlaces()
            }
        }
    }
}

struct PlaceRow: View {
    let place: Place

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(place.name).font(.body)
                if place.flagged {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
            }
            HStack {
                Text(place.city)
                if !place.category.isEmpty {
                    Text("·")
                    Text(place.category)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
