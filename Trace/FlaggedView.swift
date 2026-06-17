import SwiftUI
import CoreLocation

struct FlaggedView: View {
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var selectedPlace: Place? = nil

    var flagged: [Place] {
        let f = notion.places.filter { $0.flagged }
        if searchText.isEmpty { return f }
        return f.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.city.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if notion.places.isEmpty {
                    ProgressView("Loading...")
                } else if flagged.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "star.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No flagged places")
                            .foregroundColor(.secondary)
                        Text("Star a place to pin it here")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(flagged) { place in
                            FlaggedPlaceRow(place: place) {
                                selectedPlace = place
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search flagged")
                }
            }
            .navigationTitle("Pinned")
        }
        .sheet(item: $selectedPlace) { place in
            PlaceDetailView(place: place)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
    }
}

struct FlaggedPlaceRow: View {
    let place: Place
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Info area — tap opens detail
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.body)
                    .foregroundStyle(.primary)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            // Action links — independent tap targets
            HStack(spacing: 16) {
                if let mapsURL = place.googleMapsURL, let url = URL(string: mapsURL) {
                    Link(destination: url) {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle")
                            .font(.caption)
                    }
                } else {
                    Link(destination: appleMapsURL(for: place)) {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle")
                            .font(.caption)
                    }
                }

                if let phone = place.phone, let url = URL(string: "tel:\(phone.filter { $0.isNumber })") {
                    Link(destination: url) {
                        Label("Call", systemImage: "phone")
                            .font(.caption)
                    }
                }

                if let website = place.website, let url = URL(string: website) {
                    Link(destination: url) {
                        Label("Website", systemImage: "globe")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    func appleMapsURL(for place: Place) -> URL {
        let query = "\(place.name) \(place.address)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "maps://?q=\(query)&ll=\(place.latitude),\(place.longitude)")!
    }
}
