import SwiftUI

// Sheet routing enum — avoids multiple .sheet() conflicts on same view
enum VisitDetailSheet: Identifiable {
    case place(Place)
    case person(Person)
    case spots(Visit)

    var id: String {
        switch self {
        case .place(let p): return "place-\(p.id)"
        case .person(let p): return "person-\(p.id)"
        case .spots(let v): return "spots-\(v.id)"
        }
    }
}

struct VisitDetailView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let visit: Visit

    @State private var rating: Int?
    @State private var notes: String
    @State private var date: Date
    @State private var personIDs: [String]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var activeSheet: VisitDetailSheet?

    init(visit: Visit) {
        self.visit = visit
        _rating = State(initialValue: visit.rating)
        _notes = State(initialValue: visit.notes ?? "")
        _date = State(initialValue: visit.date)
        _personIDs = State(initialValue: visit.peopleIDs)
    }

    var livePlace: Place? {
        notion.places.first { $0.id == visit.placeID }
    }

    var livePhotoURLs: [String] {
        notion.visits.first { $0.id == visit.id }?.photoURLs ?? visit.photoURLs
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Place")
                        Spacer()
                        if let place = livePlace {
                            Button(visit.placeName) {
                                activeSheet = .place(place)
                            }
                            .foregroundStyle(.blue)
                        } else {
                            Text(visit.placeName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                if !livePhotoURLs.isEmpty {
                    Section("Photos") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(livePhotoURLs, id: \.self) { urlString in
                                    if let url = URL(string: urlString) {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable()
                                                    .scaledToFill()
                                                    .frame(width: 130, height: 130)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                            case .failure:
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.secondary.opacity(0.15))
                                                    .frame(width: 130, height: 130)
                                                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                                            default:
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(Color.secondary.opacity(0.1))
                                                    .frame(width: 130, height: 130)
                                                    .overlay(ProgressView())
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                }

                Section {
                    Button {
                        activeSheet = .spots(visit)
                    } label: {
                        Label("View Spots Map", systemImage: "map.fill")
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

                PeoplePickerSection(selectedIDs: $personIDs, onPersonTap: { person in
                    activeSheet = .person(person)
                })

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
            .refreshable { await refreshFromNotion() }
            .navigationTitle(visit.placeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await refreshFromNotion() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .disabled(isSaving)
                }
            }
            .task { await refreshFromNotion() }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .place(let place):
                    PlaceDetailView(place: place)
                        .environment(NotionService.shared)
                        .environment(LocationManager.shared)
                case .person(let person):
                    PersonDetailView(personID: person.id, personName: person.name)
                        .environment(NotionService.shared)
                case .spots(let v):
                    SpotsMapView(source: .visit(v))
                        .environment(NotionService.shared)
                }
            }
        }
    }

    private func refreshFromNotion() async {
        await notion.fetchVisits()
        if notion.people.isEmpty { await notion.fetchPeople() }
        if let fresh = notion.visits.first(where: { $0.id == visit.id }) {
            notes = fresh.notes ?? ""
            rating = fresh.rating
            date = fresh.date
            personIDs = fresh.peopleIDs
        }
    }

    func save() {
        isSaving = true
        Task {
            do {
                try await notion.updateVisit(visit, rating: rating, notes: notes.isEmpty ? nil : notes, date: date, people: personIDs.isEmpty ? nil : personIDs)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
