import SwiftUI

// Sheet routing enum — avoids multiple .sheet() conflicts on same view
enum VisitDetailSheet: Identifiable {
    case place(Place)
    case person(Person)
    case spots(Visit)
    /// Pick an existing interaction to attach to this visit.
    case linkInteraction
    /// Read an interaction already attached.
    case interaction(Interaction)
    /// One just created from this visit — opens straight into editing so the
    /// notes can be written while the thing is still in mind.
    case newInteraction(Interaction)

    var id: String {
        switch self {
        case .place(let p): return "place-\(p.id)"
        case .person(let p): return "person-\(p.id)"
        case .spots(let v): return "spots-\(v.id)"
        case .linkInteraction: return "link-interaction"
        case .interaction(let i): return "interaction-\(i.id)"
        case .newInteraction(let i): return "new-interaction-\(i.id)"
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
    /// Interactions already attached to this visit. Fetched per attendee rather
    /// than filtered out of `recentInteractions`, which is bounded and would
    /// quietly miss the links on an older visit.
    @State private var linkedInteractions: [Interaction] = []
    @State private var isLinking = false
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
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { try? await notion.deleteWorkout(id: w.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
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

                interactionsSection

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
                case .linkInteraction:
                    VisitInteractionLinkerSheet(visit: visit, attendees: attendees) { linked in
                        linkedInteractions.append(linked)
                    }
                    .environment(NotionService.shared)
                case .interaction(let i):
                    InteractionDetailSheet(interaction: i) {
                        Task { await loadLinkedInteractions() }
                    }
                    .environment(NotionService.shared)
                case .newInteraction(let i):
                    InteractionDetailSheet(interaction: i, onSaved: {
                        Task { await loadLinkedInteractions() }
                    }, startInEditing: true)
                    .environment(NotionService.shared)
                }
            }
        }
    }

    // MARK: Interactions
    //
    // A visit and an interaction can describe the same lunch from two sides:
    // where you were, and who you were with. The relation between them has
    // existed in Notion all along and was never written or shown.
    //
    // **Deliberately two buttons and nothing automatic.** Attaching every visit
    // that has a person on it to a new interaction would double-record
    // everything you do with anyone, and a wrong guess is harder to find and
    // undo than a missing link is to add. David's call, and the right one.

    @ViewBuilder
    private var interactionsSection: some View {
        Section("Interactions") {
            ForEach(linkedInteractions) { interaction in
                Button {
                    activeSheet = .interaction(interaction)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(interaction.summary.isEmpty
                                 ? interaction.type.capitalized : interaction.summary)
                                .foregroundStyle(Color.primary)
                            Text(peopleNames(for: interaction))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Create. One tap per attendee, because the visit already knows the
            // date, the place and who was there — every field the interaction
            // needs is on screen, and retyping them is the waste worth removing.
            if attendees.isEmpty {
                Text("Add someone to this visit to log an interaction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(attendees) { person in
                        Button(person.name) { logInteraction(with: [person]) }
                    }
                    // One interaction naming everyone, rather than one each.
                    // A dinner with two people is one dinner; logging it twice
                    // makes their two cards disagree about what happened.
                    if attendees.count > 1 {
                        Divider()
                        Button("Everyone (\(attendees.count))") {
                            logInteraction(with: attendees)
                        }
                    }
                } label: {
                    Label(isLinking ? "Logging…" : "Log an interaction",
                          systemImage: "bubble.left.and.bubble.right")
                }
                .disabled(isLinking)
            }

            // Link. For the case you logged both separately, which is most of
            // what already exists.
            Button {
                activeSheet = .linkInteraction
            } label: {
                Label("Link an existing interaction", systemImage: "link")
            }
            .disabled(isLinking)
        }
    }

    private var attendees: [Person] {
        personIDs.compactMap { id in notion.people.first { $0.id == id } }
    }

    private func peopleNames(for interaction: Interaction) -> String {
        let names = interaction.personIDs.compactMap { id in
            notion.people.first { $0.id == id }?.name
        }
        return names.isEmpty ? interaction.date.formatted(.dateTime.month(.abbreviated).day())
                             : names.joined(separator: ", ")
    }

    /// Creates an interaction already attached to this visit, taking its date,
    /// its summary and its person from what the visit already knows.
    private func logInteraction(with people: [Person]) {
        guard !people.isEmpty else { return }
        isLinking = true
        Task {
            defer { isLinking = false }
            do {
                let created = try await notion.createInteraction(
                    personIDs: people.map(\.id),
                    // "Visit to Inspired", not a bare "Inspired". David's
                    // choice of the two options mocked up on 2026-07-31: a bare
                    // place name reads as a different species of record sitting
                    // among lunches and calls. Overwritable — the edit sheet
                    // opens straight after this.
                    summary: "Visit to \(visit.placeName)",
                    date: date,
                    type: "visit",
                    notes: "",
                    visitID: visit.id
                )
                linkedInteractions.append(created)
                // Straight into editing. The record now exists and is linked;
                // what it is still missing is the only part a human writes.
                activeSheet = .newInteraction(created)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Asks Notion which interactions name this visit.
    ///
    /// **Was: fetch per attendee and filter.** That derived the answer from the
    /// visit's people, and the two are not the same fact — link an interaction
    /// to a visit whose attendee list does not include that person and it
    /// vanished. One query against the relation, which is the thing that is
    /// actually true.
    private func loadLinkedInteractions() async {
        linkedInteractions = (try? await notion.fetchInteractions(visitID: visit.id)) ?? []
    }

    private func refreshFromNotion() async {
        await loadLinkedInteractions()
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

// MARK: - Link an existing interaction to a visit

/// Pick an interaction already logged and attach it to this visit.
///
/// Modelled on `BilliardsVisitLinkerSheet`, which solves the same problem from
/// the other direction and got the shape right: show a short, relevant list
/// rather than everything, and link on tap with no confirmation, because the
/// action is trivially reversible.
///
/// **Candidates are the attendees' own interactions, unlinked, within a week of
/// the visit.** Not every interaction ever logged: the useful answer is almost
/// always "the one from that day", and a list you have to search is a worse
/// answer than a list of four.
struct VisitInteractionLinkerSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let visit: Visit
    let attendees: [Person]
    var onLinked: (Interaction) -> Void

    @State private var candidates: [Interaction] = []
    @State private var isLoading = true
    @State private var isLinking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        "Nothing to link",
                        systemImage: "link",
                        description: Text(attendees.isEmpty
                            ? "Add someone to this visit first."
                            : "No unlinked interactions for these people near this date.")
                    )
                } else {
                    List(candidates) { interaction in
                        Button {
                            link(interaction)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(interaction.summary.isEmpty
                                     ? interaction.type.capitalized : interaction.summary)
                                    .foregroundStyle(Color.primary)
                                Text(interaction.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isLinking)
                    }
                }
            }
            .navigationTitle("Link an interaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Could not link", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await load() }
        }
    }

    private func load() async {
        defer { isLoading = false }
        let window: TimeInterval = 7 * 24 * 60 * 60
        var found: [Interaction] = []
        for person in attendees {
            let all = (try? await notion.fetchInteractions(personID: person.id)) ?? []
            found.append(contentsOf: all.filter {
                $0.visitID == nil && abs($0.date.timeIntervalSince(visit.date)) <= window
            })
        }
        var seen = Set<String>()
        candidates = found.filter { seen.insert($0.id).inserted }
            .sorted { $0.date > $1.date }
    }

    private func link(_ interaction: Interaction) {
        isLinking = true
        Task {
            defer { isLinking = false }
            do {
                try await notion.linkInteractionToVisit(interactionID: interaction.id,
                                                        visitID: visit.id)
                var linked = interaction
                linked.visitID = visit.id
                onLinked(linked)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
