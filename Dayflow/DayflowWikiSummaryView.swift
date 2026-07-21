import SwiftUI

// MARK: - DayflowWikiSummaryView
//
// Dayflow-specific stand-in for Trace's PlaceDetailView.swift / PersonDetailView.swift.
// Neither of those is reusable as-is — see Dayflow-Design-Plan.md "Open questions":
// PlaceDetailView.swift drags in CheckInView/VisitDetailView/SpotsMapView/
// BilliardsWizardView/WorkoutWizardView/SaveCaptureAsPlaceSheet, and PersonDetailView.swift
// has the same cascade once PlaceDetailView is unchecked. David's call (2026-07-19,
// Session 1) was to skip both and build a small Dayflow-specific summary view instead.
//
// **Upgraded 2026-07-20 (Session 17) — same tabs as Trace, most fields editable,
// visit/check-in logging deliberately left out.** David's framing: Trace stays the
// CRM (new people/places, visit + check-in logging, billiards/workout), Dayflow gets
// full visibility into a record plus the light-touch edits that don't require any of
// that cascade. Concretely:
//   - Person tabs: Info / Activity / Log / Notes (same 4 as PersonDetailView.swift).
//   - Place tabs: Info / Visits / Notes (trimmed from Trace's 5 — Overview folded into
//     Info, Settings dropped since it's geofencing/dwell-time config for Trace's
//     location-triggered check-in flow, not relevant here).
//   - Editable: relationship/company/city/how-we-met/phone/email/address/tags/archived
//     (person), category/city/description/tags (place), agenda items (person Log tab),
//     and each record's own Notes-tab markdown file (`Notes/People/<name>.md` /
//     `Notes/Places/<name>.md` — the exact same NoteStore file Trace's own Notes tab
//     reads/writes, not a copy). All via the same NotionService/NoteStore calls
//     PersonEditSheet/PlaceEditSheet/PersonDetailView already use — see NotionService.swift
//     `enrichPerson`/`updatePlace`/`updatePersonAgenda`.
//   - Deliberately NOT editable here, same as Trace's own edit sheets: name (renaming
//     risks breaking wikilink matching elsewhere until everything re-syncs), photo
//     (needs PhotosPicker + NoteStore.writePhoto — real feature, not "read the record"),
//     birthday (Trace's own PersonEditSheet doesn't expose this either), place
//     phone/website/hours (Trace only sets these via Google-Places re-enrichment, never
//     by hand), and place dwell-time/geofence radius (Trace-only location-check-in
//     config, meaningless in Dayflow).
//   - Activity/Log's Interactions list and the Visits list (both tabs) — updated
//     2026-07-20 (Session 20): now tap-through to a small, Dayflow-only, READ-ONLY
//     drill-in (DayflowVisitDetailView / DayflowInteractionDetailView, new file). NOT
//     a reuse of Trace's own VisitDetailView.swift — that one has its own buttons to
//     log a billiards session, a workout, or open the Spots map, exactly the cascade
//     Session 1 skipped, and it stays skipped here too: no rating edit, no notes edit,
//     no photo add/remove. Tapping an attendee name (on either card) or an
//     Interaction's linked Visit chains one hop further — same nested
//     .sheet(item:) pattern this file already uses on itself for wikilink taps,
//     just extended one hop past Person/Place.
//   - New: a "Mentioned In" backlinks section on the Notes tab, powered by
//     `NoteStore.shared.findWikilinkMentions(of:excluding:)` — this already existed and
//     already worked, just only wired into TraceMacPeopleView.swift/
//     TraceMacContentView.swift (the Mac Catalyst target) before now. `NoteStore.swift`
//     was already in Dayflow's target, so this is a read of an existing shared method,
//     not new plumbing.
//   - **Mentioned In rows made tappable — Session 22 addendum, 2026-07-2X.**
//     David's observation: this section already computes `mentions` eagerly
//     the moment the tab loads (`loadMentions`, above), unlike the lazy
//     tap-triggered scan DayflowBacklinksView.swift added for Notes search —
//     so routing a tap through a whole separate screen here would just be
//     slower for no reason. Rows now dispatch by folder prefix (Project /
//     Calendar / Place / Person), same four cases DayflowBacklinksView.
//     openMention handles. One deliberate difference: a Calendar (daily
//     note) mention is a PEEK here, not a navigate — it opens on its own
//     local, un-synced date state and leaves the main screen's selected day
//     untouched, per David: "I'd be exploring, not wanting to go to a note
//     when I'm doing this." Person/Place/Project mentions still open the
//     real shared record (via `wikiLinkTarget` / `mentionProjectTarget`).
//   - `DayflowApp.swift`'s launch `.task` gained `await notionService.fetchVisits()`
//     alongside the existing `fetchPlaces()`/`fetchPeople()` calls — needed so
//     `NotionService.shared.visits` is actually populated for the Activity/Visits tabs.
//     Same freshness characteristics as people/places already have (fetched once at
//     launch, no periodic refresh) — no new staleness behavior introduced.

// MARK: - MentionProjectTarget
//
// Sheet target for a "Mentioned In" row that resolves to a project note
// (Session 22 addendum, Mentioned In tap-through). Local to this file since
// WikiLinkTarget (Models.swift, shared with Trace) only covers Person/Place
// — a project mention needs its own tiny Identifiable wrapper around the
// title string, same "small helper duplicated per file" convention already
// used by DayflowBacklinksView.swift.
private struct MentionProjectTarget: Identifiable {
    let id: String
    var title: String { id }
}

struct DayflowWikiSummaryView: View {
    let target: WikiLinkTarget
    /// AI-prefill source text — Session 28. Only `DayflowDailyNoteEditor.swift`
    /// and `DayflowProjectNoteView.swift` pass their live `content` here (the
    /// two note sources the locked design covers); every other call site
    /// (search, Backlinks, Visit/Interaction detail, this file's own nested
    /// wikilink case) leaves this nil, which naturally disables the prefill —
    /// no special-casing needed, per the design's own call-site audit.
    let sourceNoteText: String?

    @Environment(\.dismiss) private var dismiss
    /// Trace hand-off buttons — 2026-07-21 (Session 25). CRM-light boundary
    /// (Session 1) still holds: this file never logs a visit itself, it just
    /// opens Trace's real Check In flow via `trace://checkin?placeID=…`,
    /// which Trace's ContentView.swift now resolves back to this exact place
    /// (`checkInPreselectedPlace`) so David doesn't have to re-pick it there.
    @Environment(\.openURL) private var openURL

    @State private var currentPerson: Person?
    @State private var currentPlace: Place?

    /// AI-prefill in-flight flags — Session 28. Separate per button since the
    /// person and place hand-offs are independent tabs; both gate the button
    /// to a spinner for the (usually sub-second, occasionally a couple
    /// seconds) Claude round trip so the tap doesn't look unresponsive.
    @State private var isResolvingLogInteractionPrefill = false
    @State private var isResolvingVisitPrefill = false

    init(target: WikiLinkTarget, sourceNoteText: String? = nil) {
        self.target = target
        self.sourceNoteText = sourceNoteText
        switch target {
        case .person(let p): _currentPerson = State(initialValue: p)
        case .place(let p):  _currentPlace  = State(initialValue: p)
        }
    }

    // MARK: Person state

    @State private var personDetail: PersonDetail? = nil
    @State private var personDetailLoadFailed = false
    private enum PersonTab: String, CaseIterable { case info = "Info", activity = "Activity", log = "Log", notes = "Notes" }
    @State private var personTab: PersonTab = .info

    @State private var isEditingPerson = false
    @State private var editRelationship = ""
    @State private var editCompanyContext = ""
    @State private var editCity = ""
    @State private var editHowWeMet = ""
    @State private var editPhone = ""
    @State private var editEmail = ""
    @State private var editAddress = ""
    @State private var editTags: Set<String> = []
    @State private var editIsArchived = false
    @State private var isSavingPerson = false
    @State private var personSaveError: String? = nil

    @State private var agendaItems: [String] = []
    @State private var isAddingAgendaItem = false
    @State private var newAgendaItem = ""
    @State private var isSavingAgenda = false
    @State private var editingAgendaItem: String? = nil
    @State private var editingAgendaText = ""

    @State private var interactions: [Interaction] = []
    @State private var isLoadingInteractions = false

    private let relationshipOptions = ["colleague", "friend", "family", "neighbor", "client", "mentor", "business", "Pool Team", "other"]
    private let personTagOptions = ["Family", "Business", "Friend", "Network", "Work", "Pool", "Reference"]

    // MARK: Place state

    private enum PlaceTab: String, CaseIterable { case info = "Info", visits = "Visits", notes = "Notes" }
    @State private var placeTab: PlaceTab = .info

    @State private var isEditingPlace = false
    @State private var editPlaceCategory = ""
    @State private var editPlaceCity = ""
    @State private var editPlaceNotes = ""
    @State private var editPlaceTags: Set<String> = []
    @State private var isSavingPlace = false
    @State private var placeSaveError: String? = nil

    private let placeCategoryOptions = ["Restaurant", "Bar", "Cafe", "Hotel", "Shop",
                                         "Attraction", "Venue", "House", "Fitness",
                                         "Office", "Airport", "Medical", "Park", "Grocery"]
    private let placeTagOptions = ["Family", "Friends", "Work", "Favorite", "Want to Visit"]

    // MARK: Notes tab (shared — NoteStore markdown file, both person + place)

    @State private var noteStoreText = ""
    @State private var isLoadingNoteStore = false
    @State private var noteStoreLoadedOnce = false
    @State private var wikiLinkTarget: WikiLinkTarget? = nil

    // MARK: Mentioned In (shared — content-based backlinks)

    @State private var mentions: [NoteMention] = []
    @State private var isLoadingMentions = false
    @State private var mentionsLoadedOnce = false

    // MARK: Visit/Interaction drill-in (shared — Session 20, both Person and Place tabs feed these)

    @State private var selectedVisit: Visit? = nil
    @State private var selectedInteraction: Interaction? = nil

    // MARK: Mentioned In tap-through (Session 22 addendum)
    //
    // Generalizes DayflowBacklinksView.openMention's four-case dispatch
    // (Project / Calendar / Place / Person) to this file's own Mentioned In
    // section. Daily note taps are a deliberate PEEK, not a navigate — David's
    // call: "I'd be exploring, not wanting to go to a note when I'm doing
    // this." So `mentionDailyNoteDate` is its own local, un-synced @State,
    // unlike DayflowBacklinksView/DayflowNotesView's daily-note taps, which
    // share a real `selectedDate` binding back to the main screen and do
    // change what day the app lands on after everything's dismissed. Here,
    // closing the daily note just returns you to this card exactly as it was.
    @State private var mentionProjectTarget: MentionProjectTarget? = nil
    @State private var mentionDailyNoteDate = Date()
    @State private var showMentionDailyNote = false

    var body: some View {
        Group {
            switch target {
            case .place:
                if let place = currentPlace { placeBody(place) }
            case .person:
                if let person = currentPerson { personBody(person) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                editToolbarButton
            }
        }
        .sheet(item: $wikiLinkTarget) { nested in
            NavigationStack {
                DayflowWikiSummaryView(target: nested)
            }
        }
        .sheet(item: $selectedVisit) { visit in
            NavigationStack {
                DayflowVisitDetailView(visit: visit)
            }
        }
        .sheet(item: $selectedInteraction) { interaction in
            NavigationStack {
                DayflowInteractionDetailView(interaction: interaction)
            }
        }
        .sheet(item: $mentionProjectTarget) { target in
            NavigationStack {
                DayflowProjectNoteView(title: target.title, onBack: { mentionProjectTarget = nil })
            }
        }
        .fullScreenCover(isPresented: $showMentionDailyNote) {
            DayflowNoteFullPageView(selectedDate: $mentionDailyNoteDate)
        }
    }

    @ViewBuilder
    private var editToolbarButton: some View {
        switch target {
        case .person:
            if personTab == .info, personDetail != nil {
                if isEditingPerson {
                    HStack(spacing: 16) {
                        Button("Cancel") { isEditingPerson = false }
                        Button(isSavingPerson ? "Saving…" : "Save") { Task { await savePerson() } }
                            .fontWeight(.semibold)
                            .disabled(isSavingPerson)
                    }
                } else {
                    Button("Edit") { startEditingPerson() }
                }
            }
        case .place:
            if placeTab == .info {
                if isEditingPlace {
                    HStack(spacing: 16) {
                        Button("Cancel") { isEditingPlace = false }
                        Button(isSavingPlace ? "Saving…" : "Save") { Task { await savePlace() } }
                            .fontWeight(.semibold)
                            .disabled(isSavingPlace)
                    }
                } else {
                    Button("Edit") { startEditingPlace() }
                }
            }
        }
    }

    // MARK: - Place body

    @ViewBuilder
    private func placeBody(_ place: Place) -> some View {
        List {
            Section {
                Picker("", selection: $placeTab) {
                    ForEach(PlaceTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)

            switch placeTab {
            case .info:   placeInfoTab(place)
            case .visits: placeVisitsTab(place)
            case .notes:  placeNotesTab(place)
            }
        }
        .navigationTitle(place.name)
        .onChange(of: placeTab) { _, tab in
            if tab == .notes {
                loadNoteStoreNote(path: placeNotePath(place), excludeFromMentions: placeNotePath(place), mentionName: place.name)
            }
        }
    }

    @ViewBuilder
    private func placeInfoTab(_ place: Place) -> some View {
        if isEditingPlace {
            Section {
                Picker("Category", selection: $editPlaceCategory) {
                    ForEach(placeCategoryOptions, id: \.self) { Text($0).tag($0) }
                }
                TextField("City", text: $editPlaceCity)
            }
            Section("Description") {
                TextField("Short description…", text: $editPlaceNotes, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section("Tags") {
                editableTagGrid(options: placeTagOptions, selected: $editPlaceTags)
            }
            if let err = placeSaveError {
                Section { Text(err).foregroundStyle(.red).font(.caption) }
            }
        } else {
            Section {
                if !place.category.isEmpty { LabeledContent("Category", value: place.category) }
                if !place.address.isEmpty { LabeledContent("Address", value: place.address) }
                if !place.city.isEmpty { LabeledContent("City", value: place.city) }
                if let hours = place.hours, !hours.isEmpty { LabeledContent("Hours", value: hours) }
                if let rating = place.ratingPersonal { LabeledContent("My Rating", value: "\(rating)/5") }
                if let rating = place.ratingExternal { LabeledContent("Rating", value: String(format: "%.1f", rating)) }
            }
            if let phone = place.phone, !phone.isEmpty {
                Section { LabeledContent("Phone", value: phone) }
            }
            if let website = place.website, !website.isEmpty {
                Section { LabeledContent("Website", value: website) }
            }
            if !place.tags.isEmpty {
                Section("Tags") {
                    Text(place.tags.joined(separator: ", "))
                }
            }
            if let summary = place.aiSummary, !summary.isEmpty {
                Section("Summary") { Text(summary) }
            }
            if let notes = place.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
        }
    }

    @ViewBuilder
    private func placeVisitsTab(_ place: Place) -> some View {
        let visits = NotionService.shared.visits
            .filter { $0.placeID == place.id }
            .sorted { $0.date > $1.date }
        Section {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(visits.count)").font(.title2.bold())
                    Text("visits").font(.caption).foregroundStyle(.secondary)
                }
                if let last = visits.first {
                    Divider().frame(height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last.date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.subheadline.weight(.medium))
                        Text("last visit").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        Section {
            Button {
                // AI-prefill, Session 28 — resolve source text + ask Claude for a
                // notes summary *before* opening the hand-off URL, then ride the
                // suggestion along as a query param. Same three-tier resolution as
                // the person hand-off below; CheckInView has no Type field, so only
                // "notes" applies here. Falls straight through to today's blank
                // Notes field if sourceNoteText is nil, resolution finds nothing, or
                // the Claude call fails for any reason — never blocks the hand-off.
                isResolvingVisitPrefill = true
                Task {
                    var comps = URLComponents()
                    comps.scheme = "trace"
                    comps.host = "checkin"
                    var items = [URLQueryItem(name: "placeID", value: place.id)]
                    if let source = DayflowInteractionPrefillService.resolveSourceText(
                        noteText: sourceNoteText, targetName: place.name
                    ), let suggestion = await DayflowInteractionPrefillService.suggestForPlace(
                        sourceText: source, placeName: place.name
                    ), let notes = suggestion.notes {
                        items.append(URLQueryItem(name: "notes", value: notes))
                    }
                    comps.queryItems = items
                    isResolvingVisitPrefill = false
                    if let url = comps.url { openURL(url) }
                }
            } label: {
                if isResolvingVisitPrefill {
                    HStack {
                        Label("Log a Visit in Trace", systemImage: "arrow.up.forward.app")
                        Spacer()
                        ProgressView().scaleEffect(0.8)
                    }
                } else {
                    Label("Log a Visit in Trace", systemImage: "arrow.up.forward.app")
                }
            }
            .disabled(isResolvingVisitPrefill)
        }
        Section("History") {
            if visits.isEmpty {
                Text("No visits logged yet").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(visits) { visit in
                    Button {
                        selectedVisit = visit
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.subheadline)
                                    Spacer()
                                    if let rating = visit.rating, rating > 0 {
                                        Text(String(repeating: "★", count: min(rating, 7)))
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                let names = visit.peopleIDs.compactMap { id in
                                    NotionService.shared.people.first(where: { $0.id == id })?.name
                                }
                                if !names.isEmpty {
                                    Text(names.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let notes = visit.notes, !notes.isEmpty {
                                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func placeNotesTab(_ place: Place) -> some View {
        if isLoadingNoteStore {
            Section { HStack { Spacer(); ProgressView(); Spacer() } }
        } else {
            Section {
                MarkdownEditorView(
                    text: $noteStoreText,
                    onSave: { newText in
                        try? NoteStore.shared.writeFile(placeNotePath(place), content: newText)
                        NotificationCenter.default.post(name: .noteStorePlaceNoteDidChange, object: place.name)
                    },
                    placeholder: "Notes about \(place.name)…",
                    relativePath: placeNotePath(place),
                    onWikiTap: { name in resolveWikiLink(name) },
                    wikiSuggestions: { query in wikiSuggestions(for: query) },
                    checklistSendEnabled: false
                )
                .frame(minHeight: 320)
                .listRowInsets(EdgeInsets())
            }
        }
        mentionedInSection
    }

    private func placeNotePath(_ place: Place) -> String {
        "Notes/Places/\(NoteStore.shared.placeNoteFilename(for: place.name)).md"
    }

    private func startEditingPlace() {
        guard let place = currentPlace else { return }
        editPlaceCategory = place.category.isEmpty ? placeCategoryOptions[0] : place.category
        editPlaceCity = place.city
        editPlaceNotes = place.notes ?? ""
        editPlaceTags = Set(place.tags)
        placeSaveError = nil
        isEditingPlace = true
    }

    private func savePlace() async {
        guard let place = currentPlace else { return }
        isSavingPlace = true
        placeSaveError = nil
        do {
            try await NotionService.shared.updatePlace(
                place,
                name: place.name,
                category: editPlaceCategory,
                status: place.status,
                tags: Array(editPlaceTags),
                city: editPlaceCity,
                notes: editPlaceNotes
            )
            currentPlace?.category = editPlaceCategory
            currentPlace?.city = editPlaceCity
            currentPlace?.notes = editPlaceNotes
            currentPlace?.tags = Array(editPlaceTags)
            isEditingPlace = false
        } catch {
            placeSaveError = error.localizedDescription
        }
        isSavingPlace = false
    }

    // MARK: - Person body

    @ViewBuilder
    private func personBody(_ person: Person) -> some View {
        List {
            if let photoURLString = personDetail?.photoURL, let photoURL = URL(string: photoURLString) {
                Section {
                    HStack {
                        Spacer()
                        AsyncImage(url: photoURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                Picker("", selection: $personTab) {
                    ForEach(PersonTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)

            if let detail = personDetail {
                switch personTab {
                case .info:     personInfoTab(detail, fallback: person)
                case .activity: personActivityTab(person)
                case .log:      personLogTab
                case .notes:    personNotesTab(person)
                }
            } else if !personDetailLoadFailed {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else {
                // Fetch failed — fall back to the thin list-fetch fields so something useful still shows.
                Section {
                    if let rel = person.relationship, !rel.isEmpty {
                        LabeledContent("Relationship", value: rel)
                    }
                }
            }
        }
        .navigationTitle(person.name)
        .task(id: person.id) {
            guard personDetail == nil else { return }
            do {
                personDetail = try await NotionService.shared.fetchPersonDetail(id: person.id)
                agendaItems = (personDetail?.agenda ?? "")
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                isLoadingInteractions = true
                interactions = (try? await NotionService.shared.fetchInteractions(personID: person.id)) ?? []
                isLoadingInteractions = false
            } catch {
                personDetailLoadFailed = true
            }
        }
        .onChange(of: personTab) { _, tab in
            if tab == .notes {
                loadNoteStoreNote(path: personNotePath(person), excludeFromMentions: personNotePath(person), mentionName: person.name)
            }
        }
    }

    @ViewBuilder
    private func personInfoTab(_ detail: PersonDetail, fallback person: Person) -> some View {
        if isEditingPerson {
            Section {
                Picker("Relationship", selection: $editRelationship) {
                    Text("None").tag("")
                    ForEach(relationshipOptions, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Toggle("Archived", isOn: $editIsArchived)
                TextField("Company / Context", text: $editCompanyContext)
                TextField("City", text: $editCity)
                TextField("How We Met", text: $editHowWeMet)
            }
            Section("Contact") {
                TextField("Phone", text: $editPhone).keyboardType(.phonePad)
                TextField("Email", text: $editEmail).keyboardType(.emailAddress).autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Address", text: $editAddress)
            }
            Section("Tags") {
                editableTagGrid(options: personTagOptions, selected: $editTags)
            }
            if let err = personSaveError {
                Section { Text(err).foregroundStyle(.red).font(.caption) }
            }
        } else {
            Section {
                if let rel = detail.relationship, !rel.isEmpty {
                    LabeledContent("Relationship", value: rel.capitalized)
                }
                if let co = detail.companyContext, !co.isEmpty { LabeledContent("Company", value: co) }
                if let city = detail.city, !city.isEmpty { LabeledContent("City", value: city) }
                if let bday = detail.birthday {
                    LabeledContent("Birthday", value: bday.formatted(.dateTime.month(.wide).day()))
                }
                if let met = detail.howWeMet, !met.isEmpty { LabeledContent("How We Met", value: met) }
            }
            if let phone = detail.phone, !phone.isEmpty {
                Section { LabeledContent("Phone", value: phone) }
            }
            if let email = detail.email, !email.isEmpty {
                Section { LabeledContent("Email", value: email) }
            }
            if let address = detail.address, !address.isEmpty {
                Section { LabeledContent("Address", value: address) }
            }
            if !detail.tags.isEmpty {
                Section("Tags") { Text(detail.tags.joined(separator: ", ")) }
            }
        }
    }

    @ViewBuilder
    private func personActivityTab(_ person: Person) -> some View {
        let visits = NotionService.shared.visits
            .filter { $0.peopleIDs.contains(person.id) }
            .sorted { $0.date > $1.date }
        Section {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(visits.count)").font(.title2.bold())
                    Text("visits together").font(.caption).foregroundStyle(.secondary)
                }
                if let last = visits.first {
                    Divider().frame(height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last.date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.subheadline.weight(.medium))
                        Text("last seen").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        Section("Visits") {
            if visits.isEmpty {
                Text("No visits together yet").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(visits) { visit in
                    Button {
                        selectedVisit = visit
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visit.placeName).font(.subheadline)
                                Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let rating = visit.rating, rating > 0 {
                                Text(String(repeating: "★", count: min(rating, 7)))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var personLogTab: some View {
        Section {
            if agendaItems.isEmpty && !isAddingAgendaItem {
                Text("Nothing queued").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(agendaItems, id: \.self) { item in
                    Group {
                        if editingAgendaItem == item {
                            TextField("", text: $editingAgendaText)
                                .font(.subheadline)
                                .onSubmit { commitAgendaEdit(original: item) }
                        } else {
                            Text(item)
                                .font(.subheadline)
                                .onTapGesture(count: 2) {
                                    editingAgendaItem = item
                                    editingAgendaText = item
                                }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            agendaItems.removeAll { $0 == item }
                            editingAgendaItem = nil
                            persistAgenda()
                        } label: {
                            Label("Done", systemImage: "checkmark")
                        }
                    }
                }
            }
            if isAddingAgendaItem {
                HStack {
                    TextField("Add item…", text: $newAgendaItem)
                        .onSubmit { commitAgendaItem() }
                    Button("Add") { commitAgendaItem() }
                        .disabled(newAgendaItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            HStack {
                Text("Agenda")
                if isSavingAgenda { ProgressView().scaleEffect(0.7).padding(.leading, 4) }
                Spacer()
                Button {
                    isAddingAgendaItem = true
                } label: {
                    Image(systemName: "plus").font(.caption.weight(.semibold))
                }
                .disabled(isAddingAgendaItem)
            }
        }

        // Fifth Dayflow hand-off button, 2026-07-21 (Session 26) — same CRM-light boundary
        // as "Log a Visit in Trace" above (placeVisitsTab): this file never logs an
        // interaction itself, it opens Trace's real per-person LogInteractionSheet via
        // trace://loginteraction?personID=…, which Trace's ContentView.swift resolves back
        // to this exact person so David doesn't have to re-pick them there. Full-width row,
        // same visual treatment as the other four hand-off buttons in this app (not a small
        // "+" in the section header like Agenda's own pattern above) — kept consistent since
        // every other hand-off button already uses this convention and the header "+" is
        // reserved for in-app creation (Agenda items), a different action entirely.
        Section {
            if let person = currentPerson {
                Button {
                    // AI-prefill, Session 28 — same shape as the place hand-off in
                    // placeVisitsTab above, plus a suggested Type since
                    // LogInteractionSheet has that field and CheckInView doesn't.
                    isResolvingLogInteractionPrefill = true
                    Task {
                        var comps = URLComponents()
                        comps.scheme = "trace"
                        comps.host = "loginteraction"
                        var items = [URLQueryItem(name: "personID", value: person.id)]
                        if let source = DayflowInteractionPrefillService.resolveSourceText(
                            noteText: sourceNoteText, targetName: person.name
                        ), let suggestion = await DayflowInteractionPrefillService.suggestForPerson(
                            sourceText: source, personName: person.name
                        ) {
                            if let type = suggestion.type {
                                items.append(URLQueryItem(name: "type", value: type))
                            }
                            if let notes = suggestion.notes {
                                items.append(URLQueryItem(name: "notes", value: notes))
                            }
                        }
                        comps.queryItems = items
                        isResolvingLogInteractionPrefill = false
                        if let url = comps.url { openURL(url) }
                    }
                } label: {
                    if isResolvingLogInteractionPrefill {
                        HStack {
                            Label("Log an Interaction in Trace", systemImage: "arrow.up.forward.app")
                            Spacer()
                            ProgressView().scaleEffect(0.8)
                        }
                    } else {
                        Label("Log an Interaction in Trace", systemImage: "arrow.up.forward.app")
                    }
                }
                .disabled(isResolvingLogInteractionPrefill)
            }
        }

        Section("Interactions") {
            if isLoadingInteractions {
                ProgressView().frame(maxWidth: .infinity)
            } else if interactions.isEmpty {
                Text("No interactions logged yet").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(interactions.sorted { $0.date > $1.date }) { interaction in
                    Button {
                        selectedInteraction = interaction
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Label(interaction.type.capitalized, systemImage: interactionIcon(interaction.type))
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(interaction.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let notes = interaction.notes, !notes.isEmpty {
                                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func personNotesTab(_ person: Person) -> some View {
        if isLoadingNoteStore {
            Section { HStack { Spacer(); ProgressView(); Spacer() } }
        } else {
            Section {
                MarkdownEditorView(
                    text: $noteStoreText,
                    onSave: { newText in
                        try? NoteStore.shared.writeFile(personNotePath(person), content: newText)
                    },
                    placeholder: "Notes about \(person.name)…",
                    relativePath: personNotePath(person),
                    onWikiTap: { name in resolveWikiLink(name) },
                    wikiSuggestions: { query in wikiSuggestions(for: query) },
                    checklistSendEnabled: false
                )
                .frame(minHeight: 320)
                .listRowInsets(EdgeInsets())
            }
        }
        mentionedInSection
    }

    private func personNotePath(_ person: Person) -> String {
        "Notes/People/\(person.name).md"
    }

    private func startEditingPerson() {
        guard let detail = personDetail else { return }
        editRelationship = detail.relationship ?? ""
        editCompanyContext = detail.companyContext ?? ""
        editCity = detail.city ?? ""
        editHowWeMet = detail.howWeMet ?? ""
        editPhone = detail.phone ?? ""
        editEmail = detail.email ?? ""
        editAddress = detail.address ?? ""
        editTags = Set(detail.tags)
        editIsArchived = detail.isArchived
        personSaveError = nil
        isEditingPerson = true
    }

    private func savePerson() async {
        guard let person = currentPerson else { return }
        isSavingPerson = true
        personSaveError = nil
        do {
            try await NotionService.shared.enrichPerson(
                id: person.id,
                relationship: editRelationship,
                relationshipStrength: editIsArchived ? "archived" : "",
                companyContext: editCompanyContext,
                city: editCity,
                howWeMet: editHowWeMet,
                tags: Array(editTags),
                phone: editPhone,
                email: editEmail,
                address: editAddress
            )
            personDetail?.relationship = editRelationship.isEmpty ? nil : editRelationship
            personDetail?.relationshipStrength = editIsArchived ? "archived" : nil
            personDetail?.companyContext = editCompanyContext.isEmpty ? nil : editCompanyContext
            personDetail?.city = editCity.isEmpty ? nil : editCity
            personDetail?.howWeMet = editHowWeMet.isEmpty ? nil : editHowWeMet
            personDetail?.phone = editPhone.isEmpty ? nil : editPhone
            personDetail?.email = editEmail.isEmpty ? nil : editEmail
            personDetail?.address = editAddress.isEmpty ? nil : editAddress
            personDetail?.tags = Array(editTags)
            isEditingPerson = false
        } catch {
            personSaveError = error.localizedDescription
        }
        isSavingPerson = false
    }

    // MARK: - Agenda persistence

    private func commitAgendaEdit(original: String) {
        let trimmed = editingAgendaText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let idx = agendaItems.firstIndex(of: original) {
            agendaItems[idx] = trimmed
            persistAgenda()
        }
        editingAgendaItem = nil
        editingAgendaText = ""
    }

    private func commitAgendaItem() {
        let trimmed = newAgendaItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agendaItems.append(trimmed)
        newAgendaItem = ""
        isAddingAgendaItem = false
        persistAgenda()
    }

    private func persistAgenda() {
        guard let person = currentPerson else { return }
        let combined = agendaItems.joined(separator: "\n")
        isSavingAgenda = true
        Task {
            try? await NotionService.shared.updatePersonAgenda(id: person.id, agenda: combined)
            isSavingAgenda = false
        }
    }

    private func interactionIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "call":    return "phone"
        case "email":   return "envelope"
        case "meeting": return "person.2"
        case "coffee":  return "cup.and.saucer"
        case "social":  return "figure.socialdance"
        default:        return "bubble.left"
        }
    }

    // MARK: - Tag grid (shared editable-chip UI, person + place)

    @ViewBuilder
    private func editableTagGrid(options: [String], selected: Binding<Set<String>>) -> some View {
        let customTags = selected.wrappedValue.filter { !options.contains($0) }.sorted()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { tag in
                    tagChip(tag, isOn: selected.wrappedValue.contains(tag)) {
                        if selected.wrappedValue.contains(tag) { selected.wrappedValue.remove(tag) }
                        else { selected.wrappedValue.insert(tag) }
                    }
                }
                ForEach(customTags, id: \.self) { tag in
                    tagChip(tag, isOn: true) { selected.wrappedValue.remove(tag) }
                }
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notes tab loading (shared)

    private func loadNoteStoreNote(path: String, excludeFromMentions excludePath: String, mentionName: String) {
        guard !noteStoreLoadedOnce else { return }
        noteStoreLoadedOnce = true
        isLoadingNoteStore = true
        Task {
            noteStoreText = (try? NoteStore.shared.readFile(path)) ?? ""
            isLoadingNoteStore = false
        }
        loadMentions(of: mentionName, excluding: excludePath)
    }

    private func loadMentions(of name: String, excluding excludePath: String) {
        guard !mentionsLoadedOnce else { return }
        mentionsLoadedOnce = true
        isLoadingMentions = true
        Task.detached(priority: .utility) {
            let found = NoteStore.shared.findWikilinkMentions(of: name, excluding: excludePath)
            await MainActor.run {
                mentions = found
                isLoadingMentions = false
            }
        }
    }

    private func mentionLabel(for relativePath: String) -> String {
        if relativePath.hasPrefix("Calendar/") { return "Daily Note" }
        if relativePath.hasPrefix("Notes/Projects/") { return "Project" }
        if relativePath.hasPrefix("Notes/Places/") { return "Place" }
        if relativePath.hasPrefix("Notes/People/") { return "Person" }
        if relativePath.hasPrefix("Notes/Horizons/") { return "Horizon" }
        return "Note"
    }

    @ViewBuilder
    private var mentionedInSection: some View {
        if isLoadingMentions {
            Section { HStack { Spacer(); ProgressView(); Spacer() } }
        } else if !mentions.isEmpty {
            Section("Mentioned In (\(mentions.count))") {
                ForEach(mentions.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }) { mention in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mention.title).font(.subheadline)
                            Text(mentionLabel(for: mention.relativePath))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let modified = mention.modified {
                            Text(modified.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        if isMentionOpenable(mention) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { openMention(mention) }
                }
            }
        }
    }

    /// Whether a Mentioned In row has anywhere to go. Mirrors
    /// DayflowBacklinksView.isOpenable — Notes/Horizons/ has no Dayflow
    /// destination (no chevron shown, tap is a silent no-op below).
    private func isMentionOpenable(_ mention: NoteMention) -> Bool {
        !mention.relativePath.hasPrefix("Notes/Horizons/")
    }

    /// Generalized version of DayflowBacklinksView.openMention's dispatch,
    /// local to this file (see header comment on `mentionProjectTarget`
    /// above for why Calendar taps deliberately don't touch a shared
    /// selectedDate here). Deliberately NOT reusing `resolveWikiLink` below:
    /// that one matches a literal `[[Name]]` typed in a note body against
    /// `place.name`/`person.name` directly. A mention row's `.title` here is
    /// the MENTIONING note's own title, which for a Place is the filesystem-
    /// sanitized filename (`NoteStore.placeNoteFilename`), not necessarily
    /// the place's real display name — same mismatch DayflowBacklinksView.
    /// openMention already had to reverse-lookup around.
    private func openMention(_ mention: NoteMention) {
        let path = mention.relativePath
        if path.hasPrefix("Notes/Projects/") {
            mentionProjectTarget = MentionProjectTarget(id: mention.title)
        } else if path.hasPrefix("Calendar/") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: mention.title) {
                mentionDailyNoteDate = parsed
                showMentionDailyNote = true
            }
        } else if path.hasPrefix("Notes/Places/") {
            if let place = NotionService.shared.places.first(where: {
                NoteStore.shared.placeNoteFilename(for: $0.name) == mention.title
            }) {
                wikiLinkTarget = .place(place)
            }
        } else if path.hasPrefix("Notes/People/") {
            if let person = NotionService.shared.people.first(where: { $0.name == mention.title }) {
                wikiLinkTarget = .person(person)
            }
        }
        // Notes/Horizons/ and anything else: no Dayflow destination, silent no-op.
    }

    // MARK: - Wikilink resolution (notes tab → nested summary sheet)

    private func resolveWikiLink(_ name: String) {
        if let place = NotionService.shared.places.first(where: { $0.name == name }) {
            wikiLinkTarget = .place(place)
        } else if let person = NotionService.shared.people.first(where: { $0.name == name }) {
            wikiLinkTarget = .person(person)
        }
    }

    private func wikiSuggestions(for query: String) -> [(name: String, isPlace: Bool)] {
        let q = query.lowercased()
        var results: [(name: String, isPlace: Bool)] = []
        let placeMatches = NotionService.shared.places
            .map { $0.name }
            .filter { q.isEmpty || $0.lowercased().contains(q) }
            .sorted()
            .map { (name: $0, isPlace: true) }
        results.append(contentsOf: placeMatches)
        let peopleMatches = NotionService.shared.people
            .map { $0.name }
            .filter { name in
                (q.isEmpty || name.lowercased().contains(q)) &&
                !results.contains(where: { $0.name == name })
            }
            .sorted()
            .map { (name: $0, isPlace: false) }
        results.append(contentsOf: peopleMatches)
        return results
    }
}
