import SwiftUI

struct VisitDetailView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let visit: Visit

    @State private var rating: Int?
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingPlace = false

    init(visit: Visit) {
        self.visit = visit
        _rating = State(initialValue: visit.rating)
        _notes = State(initialValue: visit.notes ?? "")
    }

    var livePlace: Place? {
        notion.places.first { $0.id == visit.placeID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Place")
                        Spacer()
                        if livePlace != nil {
                            Button(visit.placeName) {
                                showingPlace = true
                            }
                            .foregroundStyle(.blue)
                        } else {
                            Text(visit.placeName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Date")
                        Spacer()
                        Text(visit.date, format: .dateTime.month(.wide).day().year())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Rating") {
                    HStack(spacing: 8) {
                        ForEach(1...7, id: \.self) { star in
                            Button {
                                rating = rating == star ? nil : star
                            } label: {
                                Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                                    .font(.title2)
                                    .foregroundStyle(star <= (rating ?? 0) ? .yellow : .gray)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        if let rating {
                            Text("\(rating)/7")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle(visit.placeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .disabled(isSaving)
                }
            }
            .sheet(isPresented: $showingPlace) {
                if let place = livePlace {
                    PlaceDetailView(place: place)
                        .environment(NotionService.shared)
                        .environment(LocationManager.shared)
                }
            }
        }
    }

    func save() {
        isSaving = true
        Task {
            do {
                try await notion.updateVisit(visit, rating: rating, notes: notes.isEmpty ? nil : notes)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
