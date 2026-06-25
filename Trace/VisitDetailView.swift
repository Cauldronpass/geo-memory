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
    @State private var isDeleting = false
    @State private var showDeleteVisitConfirm = false
    @State private var errorMessage: String?
    @State private var activeSheet: VisitDetailSheet?
    @State private var showingBilliardsWizard = false
    @State private var isSummarizing = false
    @State private var showingWorkoutWizard = false
    @State private var selectedWorkoutForDetail: Workout?
    @State private var isSummarizingWorkout = false

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

    var isBilliardsPlace: Bool {
        livePlace?.category.lowercased() == "billiards"
    }

    var isFitnessPlace: Bool {
        livePlace?.category.lowercased() == "fitness"
    }

    var linkedWorkouts: [Workout] {
        notion.workouts
            .filter { $0.visitID == visit.id }
            .sorted { $0.date > $1.date }
    }

    var linkedBilliardsSessions: [BilliardsSession] {
        notion.billiardsSessions
            .filter { $0.visitID == visit.id }
            .sorted { ($0.matchNumber ?? 0) < ($1.matchNumber ?? 0) }
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

                // Billiards sessions linked to this visit
                if isBilliardsPlace {
                    Section {
                        if linkedBilliardsSessions.isEmpty {
                            Text("No matches logged for this visit")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        } else {
                            ForEach(linkedBilliardsSessions) { session in
                                NavigationLink(destination: BilliardsSessionDetailView(session: session)) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                if let result = session.result {
                                                    Text(result)
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(result == "Win" ? .green : .red)
                                                }
                                                Text(session.format)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                if let m = session.matchNumber {
                                                    Text("M\(m)")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Text("vs \(session.opponent.isEmpty ? "Opponent" : session.opponent)")
                                                .font(.body)
                                            if let notes = session.notes, !notes.isEmpty {
                                                Text(notes)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        if let tp = session.myTeamPoints {
                                            Text("\(tp) pts")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(tp > 0 ? .green : .secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Label("Billiards", systemImage: "8.circle.fill")
                            Spacer()
                            if !linkedBilliardsSessions.isEmpty {
                                Button {
                                    Task { await summarizeBilliardsNight() }
                                } label: {
                                    if isSummarizing {
                                        ProgressView().scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "sparkles")
                                            .font(.body)
                                            .foregroundStyle(.purple)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isSummarizing)
                                .padding(.trailing, 6)
                            }
                            Button {
                                showingBilliardsWizard = true
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Workout sessions linked to this visit
                if isFitnessPlace {
                    Section {
                        if linkedWorkouts.isEmpty {
                            Text("No workouts logged for this visit")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        } else {
                            ForEach(linkedWorkouts) { w in
                                Button {
                                    selectedWorkoutForDetail = w
                                } label: {
                                    WorkoutRow(workout: w)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        HStack {
                            Label("Workouts", systemImage: "figure.run")
                            Spacer()
                            if !linkedWorkouts.isEmpty {
                                Button {
                                    Task { await summarizeWorkoutVisit() }
                                } label: {
                                    if isSummarizingWorkout {
                                        ProgressView().scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "sparkles")
                                            .font(.body)
                                            .foregroundStyle(.purple)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isSummarizingWorkout)
                                .padding(.trailing, 6)
                            }
                            Button {
                                showingWorkoutWizard = true
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.body)
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                        }
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

                Section {
                    Button(role: .destructive) {
                        showDeleteVisitConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text("Delete Visit")
                            }
                            Spacer()
                        }
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
            .confirmationDialog("Delete this visit?", isPresented: $showDeleteVisitConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    isDeleting = true
                    Task {
                        try? await notion.deleteVisit(id: visit.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .sheet(isPresented: $showingBilliardsWizard) {
                Task { await notion.fetchBilliardsSessions() }
            } content: {
                BilliardsWizardView(visitID: visit.id, initialDate: visit.date)
                    .environment(notion)
            }
            .sheet(isPresented: $showingWorkoutWizard) {
                Task { await notion.fetchWorkouts() }
            } content: {
                WorkoutWizardView(visitID: visit.id, initialDate: visit.date)
                    .environment(notion)
            }
            .sheet(item: $selectedWorkoutForDetail) { w in
                WorkoutDetailView(workout: w)
                    .environment(notion)
            }
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
        if notion.places.isEmpty { await notion.fetchPlaces() }   // ensures isBilliardsPlace / isFitnessPlace evaluate correctly
        if isBilliardsPlace { await notion.fetchBilliardsSessions() }
        if isFitnessPlace { await notion.fetchWorkouts() }
        if let fresh = notion.visits.first(where: { $0.id == visit.id }) {
            notes = fresh.notes ?? ""
            rating = fresh.rating
            date = fresh.date
            personIDs = fresh.peopleIDs
        }
    }

    private func summarizeBilliardsNight() async {
        guard !linkedBilliardsSessions.isEmpty else { return }
        isSummarizing = true

        // Build match descriptions for the prompt
        let matchLines = linkedBilliardsSessions.enumerated().map { idx, s -> String in
            let result  = s.result ?? "Unknown"
            let opp     = s.opponent.isEmpty ? "opponent" : s.opponent
            let score   = [s.myScore, s.opponentScore].compactMap { $0 }.joined(separator: " vs ")
            let pts     = s.myTeamPoints.map { "\($0) team pts" } ?? ""
            let matchNotes = s.notes ?? ""
            return "Match \(idx + 1): \(result) vs \(opp) (\(s.format))\(score.isEmpty ? "" : ", score \(score)")\(pts.isEmpty ? "" : ", \(pts)")\(matchNotes.isEmpty ? "" : "\nNotes: \(matchNotes)")"
        }.joined(separator: "\n\n")

        let placeName = visit.placeName
        let dateStr   = visit.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        let prompt    = """
            Summarize this pool night as a short journal entry (2-4 sentences, first person, casual tone). \
            Include overall result, highlights from the matches, and any interesting observations from the notes. \
            Do not start with "I" — vary the opening. No bullet points.

            Location: \(placeName)
            Date: \(dateStr)

            \(matchLines)
            """

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]]
        ]

        do {
            guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
                  let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                isSummarizing = false
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(Config.claudeAPIKey,  forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01",          forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json",    forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData

            let (data, _) = try await URLSession.shared.data(for: req)
            if let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = (json["content"] as? [[String: Any]])?.first,
               let text    = content["text"] as? String {
                let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
                notes = notes.isEmpty ? summary : notes + "\n\n" + summary
            }
        } catch {
            errorMessage = "Summary failed: \(error.localizedDescription)"
        }

        isSummarizing = false
    }

    private func summarizeWorkoutVisit() async {
        guard !linkedWorkouts.isEmpty else { return }
        isSummarizingWorkout = true

        let feelLabels = ["", "😴 exhausted", "😕 rough", "😐 okay", "🙂 good", "😊 great", "💪 strong", "🔥 on fire"]

        let workoutLines = linkedWorkouts.map { w -> String in
            var parts: [String] = []
            parts.append("\(w.type)\(w.classType.map { " · \($0)" } ?? "")")
            if let feel = w.feel, feel > 0, feel < feelLabels.count {
                parts.append("feel: \(feelLabels[feel])")
            }
            if let dur = w.duration { parts.append("\(dur) min") }
            if let splats = w.splatPoints { parts.append("\(splats) splat points") }
            if let cal = w.calories { parts.append("\(cal) cal") }
            if let hrAvg = w.heartRateAvg, let hrMax = w.heartRateMax {
                parts.append("HR \(hrAvg) avg / \(hrMax) max")
            } else if let hrAvg = w.heartRateAvg {
                parts.append("HR \(hrAvg) avg")
            }
            let zones = [w.zone1, w.zone2, w.zone3, w.zone4, w.zone5].compactMap { $0 }
            if zones.count == 5 {
                parts.append("zones: \(zones[0])/\(zones[1])/\(zones[2])/\(zones[3])/\(zones[4]) min")
            }
            if let dist = w.distance { parts.append(String(format: "%.1f mi", dist)) }
            if let notes = w.notes, !notes.isEmpty { parts.append("notes: \(notes)") }
            return parts.joined(separator: ", ")
        }.joined(separator: "\n")

        let dateStr = visit.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        let prompt = """
            Summarize this workout visit as a short journal entry (2-4 sentences, first person, casual tone). \
            Include how the workout felt, any standout stats, and observations from the notes. \
            Do not start with "I" — vary the opening. No bullet points.

            Location: \(visit.placeName)
            Date: \(dateStr)

            \(workoutLines)
            """

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]]
        ]

        do {
            guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
                  let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                isSummarizingWorkout = false
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(Config.claudeAPIKey,   forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01",           forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json",     forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData

            let (data, _) = try await URLSession.shared.data(for: req)
            if let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = (json["content"] as? [[String: Any]])?.first,
               let text    = content["text"] as? String {
                let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
                notes = notes.isEmpty ? summary : notes + "\n\n" + summary
            }
        } catch {
            errorMessage = "Summary failed: \(error.localizedDescription)"
        }

        isSummarizingWorkout = false
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
