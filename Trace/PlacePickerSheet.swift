import SwiftUI

struct PersonPlacePickerSheet: View {
    let places: [Place]
    let onSelect: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [Place] {
        guard !search.isEmpty else { return places.sorted { $0.name < $1.name } }
        return places.filter { $0.name.localizedCaseInsensitiveContains(search) ||
                                $0.city.localizedCaseInsensitiveContains(search) ||
                                $0.category.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { place in
                Button {
                    onSelect(place)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: placeIcon(for: place.category))
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(placeColor(for: place.category))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).font(.body).foregroundStyle(.primary)
                            Text(place.city.isEmpty ? place.category : "\(place.category) · \(place.city)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Search places")
            .navigationTitle("Choose Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
