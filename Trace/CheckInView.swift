import SwiftUI

// MARK: - CheckInView

struct CheckInView: View {
    @Environment(NotionService.self) private var notionService
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlace: Place? = nil
    @State private var rating: Int? = nil
    @State private var notes: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showSuccess = false

    private var sortedPlaces: [Place] {
        notionService.places
            .filter { $0.status != "Archived" }
            .sorted {
                let d1 = locationManager.distance(to: $0) ?? .infinity
                let d2 = locationManager.distance(to: $1) ?? .infinity
                return d1 < d2
            }
    }

    var body: some View {
        NavigationStack {
            if let place = selectedPlace {
                ratingView(for: place)
            } else {
                placeListView
            }
        }
    }

    // MARK: - Place list

    private var placeListView: some View {
        List(sortedPlaces) { place in
            Button {
                selectedPlace = place
                rating = nil
                notes = ""
            } label: {
                CheckInPlaceRow(place: place, locationManager: locationManager)
            }
            .tint(.primary)
        }
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    // MARK: - Rating + notes

    @ViewBuilder
    private func ratingView(for place: Place) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.headline)
                    if let dist = locationManager.formattedDistance(to: place) {
                        Text(dist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Rating (optional)") {
                StarRatingPicker(rating: $rating)
            }

            Section("Notes (optional)") {
                TextField("How was it?", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section {
                Button {
                    Task { await performCheckIn(place: place) }
                } label: {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        Text("Check In")
                            .frame(maxWidth: .infinity)
                            .bold()
                    }
                }
                .disabled(isLoading)
            }
        }
        .navigationTitle("Check In")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { selectedPlace = nil }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if showSuccess {
                CheckInSuccessOverlay(placeName: place.name)
            }
        }
    }

    // MARK: - Action

    private func performCheckIn(place: Place) async {
        isLoading = true
        do {
            _ = try await notionService.checkIn(
                place: place,
                rating: rating,
                notes: notes.isEmpty ? nil : notes
            )
            await notionService.fetchPlaces()
            await notionService.fetchVisits()
            withAnimation {
                showSuccess = true
            }
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Star rating picker

struct StarRatingPicker: View {
    @Binding var rating: Int?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(1...7, id: \.self) { star in
                Button {
                    rating = rating == star ? nil : star
                } label: {
                    Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(star <= (rating ?? 0) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if rating != nil {
                Button("Clear") { rating = nil }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Place row

struct CheckInPlaceRow: View {
    let place: Place
    let locationManager: LocationManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if !place.category.isEmpty {
                        Text(place.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let dist = locationManager.formattedDistance(to: place) {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(dist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Success overlay

struct CheckInSuccessOverlay: View {
    let placeName: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Checked in!")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(placeName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .transition(.opacity)
    }
}
