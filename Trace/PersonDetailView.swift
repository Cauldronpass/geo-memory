import SwiftUI
import CoreLocation
import PhotosUI

// MARK: - Person photo helpers

private func personInitials(_ name: String) -> String {
    let parts = name.split(separator: " ")
    if parts.count >= 2 {
        return String(parts[0].prefix(1)) + String(parts[1].prefix(1))
    }
    return String(name.prefix(2)).uppercased()
}

/// Returns a filesystem-safe filename stem from a person's name (e.g. "Bryan Weiss").
private func sanitizedPersonFilename(_ name: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
    return name.components(separatedBy: bad).joined(separator: "_")
}

/// Returns the canonical NoteStore path for a person's photo if the file exists locally;
/// otherwise returns `fallbackURL` (a legacy Notion external URL).
/// Checks .jpg, .jpeg, .png, and .heic so the extension of the source file doesn't matter.
private func resolvePersonPhoto(name: String, fallbackURL: String?) -> String? {
    let stem = sanitizedPersonFilename(name)
    for ext in ["jpg", "jpeg", "png", "heic"] {
        let path = "Photos/People/\(stem).\(ext)"
        if let url = NoteStore.shared.resolvedURL(for: path),
           FileManager.default.fileExists(atPath: url.path) {
            return path
        }
    }
    return fallbackURL
}

/// Loads a person photo from either a NoteStore relative path ("Photos/People/xxx.jpg")
/// or a remote https:// URL. Triggers iCloud file download when needed.
private struct PersonPhotoCircle: View {
    let urlString: String
    let size: CGFloat
    let initials: String

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: size, height: size)
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.33, weight: .medium))
                            .foregroundStyle(.purple)
                    )
            }
        }
        .task(id: urlString) {
            image = await load()
        }
    }

    private func load() async -> UIImage? {
        if urlString.hasPrefix("Photos/") {
            return await loadNoteStorePhoto()
        }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    private func loadNoteStorePhoto() async -> UIImage? {
        guard let fileURL = NoteStore.shared.resolvedURL(for: urlString) else { return nil }
        // Queue an iCloud download if the file is a cloud-only placeholder.
        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        // Poll with backoff — iCloud downloads typically take a few seconds.
        // Total wait ceiling: ~17 s before giving up.
        let delays: [UInt64] = [300, 500, 1_000, 1_500, 2_000, 3_000, 4_000, 5_000]
        for delay in delays {
            if let data = try? Data(contentsOf: fileURL),
               let img = UIImage(data: data) {
                return img
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
        return (try? Data(contentsOf: fileURL)).flatMap { UIImage(data: $0) }
    }
}

// MARK: - PersonDetailView

struct PersonDetailView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let personID: String
    let personName: String

    @State private var detail: PersonDetail?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedTab: PersonTab

    /// Session 48 follow-up — David wants tapping an agenda-queued person on
    /// Home's Coming Up card to land directly on their Log tab (Agenda +
    /// Interactions) instead of the default Info tab. `openToAgenda` only
    /// affects which tab is selected on first appearance; everywhere else
    /// that constructs this view (People list, Activity/Notes deep links,
    /// etc.) keeps calling the plain two-arg form, which still defaults to
    /// Info via this init's default parameter.
    /// `openToNotes` is the `trace://note?path=Notes/People/<name>.md` hand-off
    /// from Satchel — landing on Info and making the user find the Notes tab
    /// would defeat the point of jumping here from a document.
    /// Both flags default false, so every existing call site is untouched.
    init(personID: String, personName: String,
         openToAgenda: Bool = false, openToNotes: Bool = false) {
        self.personID = personID
        self.personName = personName
        _selectedTab = State(initialValue: openToNotes ? .notes : (openToAgenda ? .log : .info))
    }

    // Info tab
    @State private var isArchived = false
    /// Session 72, for the inline tag editor.
    @State private var isEditingTags = false
    @State private var newTagText = ""
    @State private var phoneForAction: String? = nil
    @State private var selectedPlace: Place? = nil
    @State private var showingPlacePicker = false
    @State private var isCreatingPlace = false
    @State private var createPlaceError: String? = nil

    // Activity tab
    @State private var showAllVisits = false
    @State private var selectedVisit: Visit? = nil

    // Log tab — agenda
    @State private var agendaItems: [String] = []
    /// The item being edited in `AgendaItemSheet`, or a blank one when adding.
    @State private var editingAgenda: AgendaItem? = nil
    /// Read from the person's note each time the agenda changes, not cached —
    /// the note is the record and he may edit it in Obsidian.
    @State private var completedItems: [(date: String, text: String)] = []
    @State private var showCompleted = false
    @State private var birthdayReminderState: ReminderButtonState = .idle
    @State private var isSavingAgenda = false

    // Log tab — interactions
    @State private var interactions: [Interaction] = []
    @State private var isLoadingInteractions = false
    @State private var showAllInteractions = false
    @State private var selectedInteraction: Interaction? = nil
    @State private var showingLogInteraction = false

    // Notes tab — NoteStore-backed markdown file
    @State private var noteStoreText = ""
    @State private var isLoadingNoteStore = false

    // Edit sheet
    @State private var showingEdit = false
    @State private var confirmingDelete = false

    private enum PersonTab: String, CaseIterable {
        case info = "Info"
        case activity = "Activity"
        case log = "Log"
        case notes = "Notes"
    }

    private var sharedVisits: [Visit] {
        notion.visits
            .filter { $0.peopleIDs.contains(personID) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let detail {
                    cardBody(detail)
                } else if let err = loadError {
                    Text(err).foregroundStyle(.red).padding()
                }
            }
            .navigationTitle(personName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        if detail != nil {
                            Button("Edit") { showingEdit = true }
                            Button {
                                let newVal = !isArchived
                                isArchived = newVal
                                Task {
                                    try? await notion.updatePersonStatus(
                                        id: personID,
                                        relationshipStrength: newVal ? "archived" : ""
                                    )
                                }
                            } label: {
                                Image(systemName: isArchived ? "archivebox.fill" : "archivebox")
                                    .foregroundStyle(isArchived ? Color.accentColor : .secondary)
                            }
                            // DELETE, added 2026-07-31 on David's ask. Seventh
                            // instance this week of a capability that exists
                            // being unreachable on iOS: `deletePerson` has always
                            // been in NotionService and **only TraceMac used it**,
                            // exactly like `updateInteraction` earlier today.
                            //
                            // Behind a Menu and a confirmation rather than beside
                            // Edit: archiving is the reversible neighbour and the
                            // two should not sit a thumb's width apart.
                            Menu {
                                Button(role: .destructive) {
                                    confirmingDelete = true
                                } label: {
                                    Label("Delete Person…", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            let cleanID = personID.replacingOccurrences(of: "-", with: "")
                            if let url = URL(string: "https://notion.so/\(cleanID)") {
                                openURL(url)
                            }
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
            }
            .task {
                await loadDetail()
                await loadInteractions()
            }
            .sheet(item: $selectedInteraction) { interaction in
                InteractionDetailSheet(interaction: interaction) {
                    Task { await loadInteractions() }
                }
                .environment(notion)
            }
            .sheet(isPresented: $showingLogInteraction) {
                LogInteractionSheet(personID: personID, personName: personName) {
                    Task { await loadInteractions() }
                }
                .environment(notion)
            }
            .sheet(item: $editingAgenda) { item in
                AgendaItemSheet(item: item, personID: personID, personName: personName) { due, text in
                    saveAgendaItem(original: item, due: due, text: text)
                }
            }
            .confirmationDialog("Delete \(personName)?",
                                isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete Person", role: .destructive) {
                    Task {
                        // Archives the Notion page and drops it from the cached
                        // list, which is what `deletePerson` already does. Their
                        // note file in the container is deliberately NOT touched:
                        // it may hold years of writing, and removing a person from
                        // a directory is not the same as burning what you wrote
                        // about them. Delete it by hand if that is what you meant.
                        try? await notion.deletePerson(id: personID)
                        // Same rule as the swipe delete in PeopleView: a note
                        // that was never written in goes too, or it keeps the
                        // person alive in Satchel's file-scanning picker.
                        NoteStore.shared.deletePersonNoteIfUntouched(name: personName)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes them from your people. Anything written in their note is kept.")
            }
            .sheet(isPresented: $showingEdit) {
                if let d = detail {
                    PersonEditSheet(personID: personID, detail: d)
                        .environment(notion)
                        .onDisappear { Task { await loadDetail() } }
                }
            }
            .sheet(isPresented: $showingPlacePicker) {
                PersonPlacePickerSheet(places: notion.places) { place in
                    Task {
                        try? await notion.linkPersonToPlace(personID: personID, placeID: place.id)
                        await loadDetail()
                    }
                }
                .environment(notion)
            }
            .sheet(item: $selectedPlace) { place in
                PlaceDetailView(place: place)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            }
            .sheet(item: $selectedVisit) { visit in
                VisitDetailView(visit: visit)
                    .environment(NotionService.shared)
            }
        }
    }

    // MARK: - Card Body

    @ViewBuilder
    private func cardBody(_ d: PersonDetail) -> some View {
        Form {
            // Hero — always visible
            Section {
                heroSection(d)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)

            // Tab picker
            Section {
                Picker("", selection: $selectedTab) {
                    ForEach(PersonTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listRowBackground(Color.clear)

            // Tab content
            switch selectedTab {
            case .info:         infoTab(d)
            case .activity:     activityTab(d)
            case .log:          logTab(d)
            case .notes:        notesTab(d)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .notes { loadNoteStoreNote() }
        }
        .confirmationDialog("", isPresented: Binding(
            get: { phoneForAction != nil },
            set: { if !$0 { phoneForAction = nil } }
        )) {
            if let phone = phoneForAction {
                let digits = phone.filter { $0.isNumber || $0 == "+" }
                Button("Call") {
                    if let url = URL(string: "tel:\(digits)") { openURL(url) }
                }
                Button("Message") {
                    if let url = URL(string: "sms:\(digits)") { openURL(url) }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    // MARK: - Info Tab

    @ViewBuilder
    private func infoTab(_ d: PersonDetail) -> some View {
        Section {
            row("Relationship", value: d.relationship.map { $0.capitalized } ?? "None")
            if let co = d.companyContext, !co.isEmpty { row("Company", value: co) }
            if let city = d.city, !city.isEmpty { row("City", value: city) }
            if let bday = d.birthday {
                row("Birthday", value: bday.formatted(.dateTime.month(.wide).day()))
                // Coming Up already shows birthdays, but Coming Up does not speak
                // up — it waits to be looked at. This is the one place a date the
                // app already knows can become something that actually arrives.
                // A MENU, NOT A FIXED WEEK. David: *"is there a way to add a
                // reminder different than 7 days before a birthday? or again on
                // the birthday itself?"* — the second half is the giveaway that
                // one lead time was never going to be enough. A week out is when
                // you buy something; the day itself is when you call.
                //
                // Each choice adds its own reminder rather than replacing the
                // last, so "two weeks AND on the day" is two taps and not a
                // setting to reconsider.
                Menu {
                    ForEach(BirthdayLead.allCases) { lead in
                        Button(lead.label) { remindAboutBirthday(d, on: bday, lead: lead) }
                    }
                } label: {
                    HStack {
                        Label(birthdayReminderState == .added ? "Reminder added" : "Remind me",
                              systemImage: birthdayReminderState == .added ? "checkmark" : "bell")
                            .font(.subheadline)
                        Spacer()
                        if birthdayReminderState == .working { ProgressView() }
                    }
                }
                .disabled(birthdayReminderState == .working)
                if case .failed(let why) = birthdayReminderState {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
            }
            if let met = d.howWeMet, !met.isEmpty { row("How We Met", value: met) }
        }

        Section("Contact") {
            if let phone = d.phone, !phone.isEmpty {
                Button { phoneForAction = phone } label: {
                    HStack {
                        Text("Phone").foregroundStyle(.secondary)
                        Spacer()
                        Text(phone).foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
            if let email = d.email, !email.isEmpty {
                Button {
                    if let url = URL(string: "mailto:\(email)") { openURL(url) }
                } label: {
                    HStack {
                        Text("Email").foregroundStyle(.secondary)
                        Spacer()
                        Text(email).foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
            if let address = d.address, !address.isEmpty {
                Button {
                    let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "maps://?q=\(encoded)") { openURL(url) }
                } label: {
                    HStack(alignment: .top) {
                        Text("Address").foregroundStyle(.secondary)
                        Spacer()
                        Text(address).foregroundStyle(.blue).multilineTextAlignment(.trailing)
                    }
                }
                .buttonStyle(.plain)
            }
        }

        Section("Place") {
            placeSection(d)
        }

        // Editable in place, Session 72, and the section is **always** shown —
        // it used to appear only when there were tags, which is right for a
        // display and wrong for an editor: a person with no tags is the one you
        // want to tag. `enrichPerson` has always taken `tags:`; the edit sheet
        // was the only door. Same control the place Overview has had since it
        // shipped, so the two records are tagged the same way.
        Section("Tags") {
            VStack(alignment: .leading, spacing: 8) {
                if !d.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(d.tags, id: \.self) { tag in
                                HStack(spacing: 4) {
                                    Text(tag).font(.caption)
                                    Button {
                                        Task { await setTags(d.tags.filter { $0 != tag }) }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption2.weight(.semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if isEditingTags {
                    HStack(spacing: 8) {
                        TextField("New tag", text: $newTagText)
                            .font(.subheadline)
                            .submitLabel(.done)
                            .onSubmit { Task { await addTypedTag(to: d) } }
                        Button("Add") { Task { await addTypedTag(to: d) } }
                            .font(.subheadline)
                            .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { isEditingTags = false; newTagText = "" }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // No menu of tags already in use, unlike the place editor:
                    // `Person` has no `tags` field — they live on
                    // `PersonDetail`, fetched one person at a time — so
                    // offering the vocabulary would mean a detail fetch per
                    // contact. Plain Add until `fetchPeople` carries tags.
                    Button {
                        isEditingTags = true
                    } label: {
                        Label("Add tag", systemImage: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Activity Tab

    @ViewBuilder
    private func activityTab(_ d: PersonDetail) -> some View {
        Section {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sharedVisits.count)")
                        .font(.title2.bold())
                    Text("visits together")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lv = d.lastVisitDate {
                    Divider().frame(height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lv.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.subheadline.weight(.medium))
                        Text("last seen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }

        Section {
            if sharedVisits.isEmpty {
                Text("No visits together yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding(.vertical, 4)
            } else {
                let visitsToShow = showAllVisits ? sharedVisits : Array(sharedVisits.prefix(5))
                ForEach(visitsToShow) { visit in
                    Button { selectedVisit = visit } label: {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visit.placeName)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let rating = visit.rating, rating > 0 {
                                Text(String(repeating: "★", count: min(rating, 7)))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                if sharedVisits.count > 5 {
                    Button(showAllVisits ? "Show less" : "Show all \(sharedVisits.count) visits") {
                        showAllVisits.toggle()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Visits")
        }
    }

    // MARK: - Log Tab (Agenda + Interactions)

    @ViewBuilder
    private func logTab(_ d: PersonDetail) -> some View {
        // Agenda
        Section {
            if agendaItems.isEmpty {
                Text("Nothing queued")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(agendaItems, id: \.self) { raw in
                    let item = AgendaLine.parse(raw)
                    Button {
                        editingAgenda = item
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            if let days = item.daysAway, let due = item.due {
                                Text(dueLabel(days, due))
                                    .font(.caption)
                                    .foregroundStyle(item.isOverdue ? .orange : .secondary)
                            } else {
                                // Said out loud, because it is the difference
                                // between an item that will surface and one that
                                // never will.
                                Text("No date")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            completeAgendaItem(raw)
                        } label: {
                            Label("Done", systemImage: "checkmark")
                        }
                    }
                }
            }

        } header: {
            HStack {
                Text("Agenda")
                if isSavingAgenda {
                    ProgressView().scaleEffect(0.7).padding(.leading, 4)
                }
                Spacer()
                Button {
                    editingAgenda = AgendaItem(raw: "", due: nil, text: "")
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }

        // DONE, WHERE THE QUEUE IS. David: *"how do i surface the done items?"*
        // They are written to the person's note, which the Notes tab already
        // shows — but making him change tabs to see what he just ticked is the
        // same mistake as a capability with no door. Collapsed, so history never
        // competes with the live queue. Same shape as Dayflow's archived projects.
        if !completedItems.isEmpty {
            Section {
                if showCompleted {
                    ForEach(Array(completedItems.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            Text(entry.text)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if !entry.date.isEmpty {
                                Text(entry.date)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showCompleted.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Done")
                        Text("\(completedItems.count)").foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Kept in this person's note. Edit or clear them there.")
            }
        }

        // Interactions
        Section {
            if isLoadingInteractions {
                ProgressView().frame(maxWidth: .infinity)
            } else if interactions.isEmpty {
                Text("No interactions logged yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding(.vertical, 4)
            } else {
                let shown = showAllInteractions ? interactions : Array(interactions.prefix(5))
                ForEach(shown) { interaction in
                    Button { selectedInteraction = interaction } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Label(interaction.type.capitalized,
                                          systemImage: interactionIcon(interaction.type))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(interaction.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let notes = interaction.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 3)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                if interactions.count > 5 {
                    Button(showAllInteractions ? "Show less" : "Show all \(interactions.count)") {
                        showAllInteractions.toggle()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Text("Interactions")
                Spacer()
                Button {
                    showingLogInteraction = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Notes Tab

    /// The one place this person's note path is spelled out. It was written
    /// inline in four separate spots, which is three chances for the Satchel
    /// hand-off below to send a path that does not match what Trace actually
    /// reads and writes.
    private var personNotePath: String { "Notes/People/\(personName).md" }

    @ViewBuilder
    private func notesTab(_ d: PersonDetail) -> some View {
        if isLoadingNoteStore {
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        } else {
            Section {
                // Scope §7b — capture a document already filed to this note.
                // Above the editor rather than below it: the editor is 420pt
                // tall, so anything under it starts off the bottom of the screen.
                SatchelAddDocumentButton(notePath: personNotePath)
                // Scope §7a — the documents already filed to this note. Insets
                // zeroed because the view supplies its own padding, and when
                // there are no documents it renders nothing, so the row must
                // collapse to invisible rather than leave a bare separator.
                SatchelDocumentChips(notePath: personNotePath)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                MarkdownEditorView(
                    text: $noteStoreText,
                    onSave: { content in
                        try? NoteStore.shared.writeFile(personNotePath, content: content)
                    },
                    placeholder: "Notes about \(personName)…",
                    relativePath: personNotePath
                )
                .frame(minHeight: 420)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    // MARK: - Hero Section

    @ViewBuilder
    private func heroSection(_ d: PersonDetail) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                if let phone = d.phone, !phone.isEmpty {
                    let digits = phone.filter { $0.isNumber || $0 == "+" }
                    quickActionButton(icon: "phone.fill", label: "Call", color: .green) {
                        if let url = URL(string: "tel:\(digits)") { openURL(url) }
                    }
                    quickActionButton(icon: "message.fill", label: "Message", color: .blue) {
                        if let url = URL(string: "sms:\(digits)") { openURL(url) }
                    }
                }
                if let email = d.email, !email.isEmpty {
                    quickActionButton(icon: "envelope.fill", label: "Email", color: .orange) {
                        if let url = URL(string: "mailto:\(email)") { openURL(url) }
                    }
                }
            }
            Spacer()
            if let urlStr = d.photoURL, !urlStr.isEmpty {
                PersonPhotoCircle(urlString: urlStr, size: 120, initials: personInitials(d.name))
            } else {
                initialsCircle(d.name, size: 120)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func quickActionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Place section

    @ViewBuilder
    private func placeSection(_ d: PersonDetail) -> some View {
        if let placeID = d.homePlaceID,
           let place = notion.places.first(where: { normalizeID($0.id) == normalizeID(placeID) }) {
            Button {
                selectedPlace = place
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: placeIcon(for: place.category))
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(placeColor(for: place.category))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).foregroundStyle(.primary)
                        if !place.city.isEmpty {
                            Text(place.city).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                Task {
                    try? await notion.linkPersonToPlace(personID: personID, placeID: nil)
                    await loadDetail()
                }
            } label: {
                Text("Unlink Place").font(.subheadline)
            }
        } else {
            Button("Link to Existing Place") {
                showingPlacePicker = true
            }
            if let address = d.address, !address.isEmpty {
                Button {
                    Task { await createPlaceFromAddress(address, for: d) }
                } label: {
                    if isCreatingPlace {
                        HStack { ProgressView(); Text("Creating place…").foregroundStyle(.secondary) }
                    } else {
                        Text("Create Place from Address")
                    }
                }
                .disabled(isCreatingPlace)
            }
            if let err = createPlaceError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func initialsCircle(_ name: String, size: CGFloat = 80) -> some View {
        let parts = name.split(separator: " ")
        let initials = parts.count >= 2
            ? String(parts[0].prefix(1)) + String(parts[1].prefix(1))
            : String(name.prefix(2)).uppercased()
        Circle()
            .fill(Color.purple.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.33, weight: .medium))
                    .foregroundStyle(.purple)
            )
    }

    private func normalizeID(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func interactionIcon(_ type: String) -> String {
        InteractionStyle.icon(for: type)
    }

    // MARK: - Agenda

    /// Next occurrence of a birthday, a week ahead of it.
    ///
    /// The stored year is whatever Notion has on file and is not meaningful, so
    /// this rolls to this year or next — the same rule Home's Coming Up uses. A
    /// reminder set for the birth year would land decades in the past and never
    /// fire, silently.
    private func remindAboutBirthday(_ d: PersonDetail, on birthday: Date, lead: BirthdayLead) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var comps = cal.dateComponents([.month, .day], from: birthday)
        comps.year = cal.component(.year, from: today)
        guard var next = cal.date(from: comps) else { return }
        if next < today {
            comps.year = (comps.year ?? 0) + 1
            guard let rolled = cal.date(from: comps) else { return }
            next = rolled
        }
        let fireOn = cal.date(byAdding: .day, value: -lead.days, to: next) ?? next

        birthdayReminderState = .working
        Task {
            do {
                let id = try await ReminderService.add(
                    title: lead.days == 0
                        ? "\(d.name)'s birthday is today"
                        : "\(d.name)'s birthday \(lead.phrase)",
                    due: fireOn,
                    notes: "Trace · \(next.formatted(.dateTime.month(.wide).day()))",
                    // A birthday is annual. Set once, not once a year.
                    repeatsYearly: true)
                // Keyed by lead as well as person, so adding "two weeks" does not
                // overwrite the link for "on the day". Two reminders, two links.
                ReminderService.link(id, to: "birthday|\(personID)|\(lead.rawValue)")
                birthdayReminderState = .added
            } catch ReminderService.Failure.denied {
                birthdayReminderState = .failed("Trace does not have access to Reminders. Settings › Privacy › Reminders.")
            } catch {
                birthdayReminderState = .failed("Could not add the reminder.")
            }
        }
    }

    private func dueLabel(_ days: Int, _ due: Date) -> String {
        let stamp = due.formatted(.dateTime.month(.abbreviated).day())
        if days < 0  { return "Overdue by \(-days) day\(days == -1 ? "" : "s") · \(stamp)" }
        if days == 0 { return "Today · \(stamp)" }
        return "In \(days) day\(days == 1 ? "" : "s") · \(stamp)"
    }

    /// Writes an edited or new item back. Matching on `original.raw` and not on
    /// text: the date is part of the stored line, so changing only the date still
    /// has to find the old line.
    private func saveAgendaItem(original: AgendaItem, due: Date?, text: String) {
        let composed = AgendaLine.compose(due: due, text: text)
        guard !composed.isEmpty else { return }
        if original.raw.isEmpty {
            agendaItems.append(composed)
        } else if let idx = agendaItems.firstIndex(of: original.raw) {
            agendaItems[idx] = composed
        } else {
            agendaItems.append(composed)
        }
        // The reminder link is keyed by the stored line, so an edit has to carry
        // it across or the reminder is orphaned and can never be ticked shut.
        let newKey = "\(personID)|\(composed)"
        ReminderService.relink(from: "\(personID)|\(original.raw)", to: newKey)
        // The KEY moving is not enough — the reminder still carries the old day.
        if due != original.due {
            Task { await ReminderService.reschedule(key: newKey, to: due) }
        }
        persistAgenda()
    }

    /// Ticking an item: keep a record, drop it from the queue, close the reminder.
    private func completeAgendaItem(_ raw: String) {
        let item = AgendaLine.parse(raw)
        NoteStore.shared.logCompletedAgendaItem(person: personName, text: item.text)
        agendaItems.removeAll { $0 == raw }
        completedItems = NoteStore.shared.completedAgendaItems(person: personName)
        persistAgenda()
        Task { await ReminderService.complete(key: "\(personID)|\(raw)") }
    }

    private func persistAgenda() {
        let combined = agendaItems.joined(separator: "\n")
        isSavingAgenda = true
        Task {
            try? await notion.updatePersonAgenda(id: personID, agenda: combined)
            isSavingAgenda = false
        }
    }

    // MARK: - Data loading

    /// Writes a new tag set and re-reads the person. Everything else is `nil`,
    /// which `enrichPerson` reads as "leave alone".
    private func setTags(_ tags: [String]) async {
        try? await notion.enrichPerson(
            id: personID,
            relationship: nil,
            relationshipStrength: nil,
            companyContext: nil,
            city: nil,
            howWeMet: nil,
            tags: tags
        )
        await loadDetail()
    }

    private func addTypedTag(to d: PersonDetail) async {
        let tag = newTagText.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !d.tags.contains(tag) else {
            newTagText = ""
            isEditingTags = false
            return
        }
        newTagText = ""
        isEditingTags = false
        await setTags(d.tags + [tag])
    }

    private func loadDetail() async {
        isLoading = true
        do {
            // Always bypass the cache so photos/edits made on other devices are visible immediately.
            notion.personDetailCache.removeValue(forKey: personID)
            var d = try await notion.fetchPersonDetail(id: personID)
            // NoteStore photo (Photos/People/<Name>.jpg) takes precedence over any Notion external URL.
            d.photoURL = resolvePersonPhoto(name: d.name, fallbackURL: d.photoURL)
            detail = d
            isArchived = d.isArchived
            agendaItems = (d.agenda ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            completedItems = NoteStore.shared.completedAgendaItems(person: d.name)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadInteractions() async {
        isLoadingInteractions = true
        interactions = (try? await notion.fetchInteractions(personID: personID)) ?? []
        isLoadingInteractions = false
    }

    private func loadNoteStoreNote() {
        guard !isLoadingNoteStore else { return }
        isLoadingNoteStore = true
        Task {
            noteStoreText = (try? NoteStore.shared.readFile(personNotePath)) ?? ""
            isLoadingNoteStore = false
        }
    }

    private func createPlaceFromAddress(_ address: String, for d: PersonDetail) async {
        isCreatingPlace = true
        createPlaceError = nil
        do {
            let geocoder = CLGeocoder()
            let placemarks = try await geocoder.geocodeAddressString(address)
            guard let placemark = placemarks.first, let location = placemark.location else {
                createPlaceError = "Could not geocode address"
                isCreatingPlace = false
                return
            }
            let city = placemark.locality ?? d.city ?? ""
            let placeName = "\(d.name.components(separatedBy: " ").first ?? d.name)'s"
            let placeID = try await notion.addPlace(
                name: placeName,
                address: address,
                city: city,
                category: "house",
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                googlePlaceID: nil,
                phone: nil,
                website: nil
            )
            try await notion.linkPersonToPlace(personID: personID, placeID: placeID)
            await notion.fetchPlaces()
            await loadDetail()
        } catch {
            createPlaceError = error.localizedDescription
        }
        isCreatingPlace = false
    }
}

// MARK: - Person Edit Sheet

struct PersonEditSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    let personID: String
    let detail: PersonDetail

    private let relationships = ["colleague", "friend", "family", "neighbor", "client", "mentor", "business", "Pool Team", "other"]
    private let tagOptions = ["Family", "Business", "Friend", "Network", "Work", "Pool", "Reference"]

    @State private var name = ""
    @State private var relationship = ""
    @State private var isArchived = false
    @State private var phone = ""
    @State private var email = ""
    @State private var companyContext = ""
    @State private var city = ""
    @State private var howWeMet = ""
    @State private var address = ""
    @State private var hasBirthday = false
    @State private var birthday = Date()
    @State private var selectedTags: Set<String> = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingAddTag = false
    @State private var newTagText = ""

    // Photo
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var pickedImage: UIImage? = nil
    @State private var isUploadingPhoto = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ZStack(alignment: .bottomTrailing) {
                            if let img = pickedImage {
                                Image(uiImage: img)
                                    .resizable().scaledToFill()
                                    .frame(width: 90, height: 90)
                                    .clipShape(Circle())
                            } else if let url = detail.photoURL, !url.isEmpty {
                                PersonPhotoCircle(
                                    urlString: url,
                                    size: 90,
                                    initials: personInitials(detail.name)
                                )
                            } else {
                                personInitialsView
                            }

                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Image(systemName: isUploadingPhoto ? "arrow.triangle.2.circlepath" : "camera.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Color.orange, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))

                    if isUploadingPhoto {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Saving photo…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if pickedImage != nil {
                        Label("Photo ready to save", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

                Section("Name") {
                    TextField("Full name", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Identity") {
                    Picker("Category", selection: $relationship) {
                        Text("None").tag("")
                        ForEach(relationships, id: \.self) { r in
                            Text(r.capitalized).tag(r)
                        }
                    }
                    Toggle("Archived", isOn: $isArchived)
                    TextField("Company / Context", text: $companyContext)
                    TextField("City", text: $city)
                    TextField("How We Met", text: $howWeMet)
                    Toggle("Birthday", isOn: $hasBirthday.animation(.snappy(duration: 0.2)))
                    if hasBirthday {
                        DatePicker("Date", selection: $birthday,
                                   displayedComponents: .date)
                    }
                }

                Section("Contact") {
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Address", text: $address)
                }

                tagSection

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(detail.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(isSaving)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { prefill() }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    isUploadingPhoto = true
                    defer { isUploadingPhoto = false }
                    guard let data = try? await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    pickedImage = image
                    // Use person name as filename so Photos/People/ stays legible.
                    // Delete the old photo file if it was a NoteStore-relative path.
                    if let oldPath = detail.photoURL, oldPath.hasPrefix("Photos/") {
                        try? NoteStore.shared.deleteFile(oldPath)
                    }
                    let safeName = sanitizedPersonFilename(detail.name)
                    let filename = "\(safeName).jpg"
                    // Write to NoteStore (iCloud). Not stored in Notion — resolvePersonPhoto
                    // picks this file up by name at next load.
                    _ = try? NoteStore.shared.writePhoto(data, category: "People", filename: filename)
                }
            }
            .alert("Add Tag", isPresented: $showingAddTag) {
                TextField("Tag name", text: $newTagText)
                    .autocorrectionDisabled()
                Button("Add") {
                    let tag = newTagText.trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty { selectedTags.insert(tag) }
                    newTagText = ""
                }
                Button("Cancel", role: .cancel) { newTagText = "" }
            }
        }
    }

    private var tagSection: some View {
        Section("Tags") {
            let customTags = Array(selectedTags).filter { !tagOptions.contains($0) }.sorted()
            FlowLayout(spacing: 8) {
                ForEach(tagOptions, id: \.self) { tag in tagChip(tag) }
                ForEach(customTags, id: \.self) { tag in tagChip(tag) }
                Button { showingAddTag = true } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        Button {
            if selectedTags.contains(tag) { selectedTags.remove(tag) }
            else { selectedTags.insert(tag) }
        } label: {
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selectedTags.contains(tag) ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(selectedTags.contains(tag) ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func prefill() {
        name = detail.name
        relationship = detail.relationship ?? ""
        isArchived = detail.isArchived
        phone = detail.phone ?? ""
        email = detail.email ?? ""
        companyContext = detail.companyContext ?? ""
        city = detail.city ?? ""
        howWeMet = detail.howWeMet ?? ""
        address = detail.address ?? ""
        hasBirthday = detail.birthday != nil
        // Defaults to a plausible adult birth year rather than today, so the
        // wheel does not open on 2026 and make him spin back sixty years.
        birthday = detail.birthday
            ?? Calendar.current.date(from: DateComponents(year: 1970, month: 1, day: 1))
            ?? Date()
        selectedTags = Set(detail.tags)
    }

    private var personInitialsView: some View {
        let initials = detail.name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0) }.joined()
        return Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 90, height: 90)
            .background(Color.purple.opacity(0.6), in: Circle())
    }

    private func save() async {
        isSaving = true
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        do {
            try await notion.enrichPerson(
                id: personID,
                name: trimmedName == detail.name ? nil : trimmedName,
                relationship: relationship,
                relationshipStrength: isArchived ? "archived" : "",
                companyContext: companyContext,
                city: city,
                howWeMet: howWeMet,
                tags: Array(selectedTags),
                phone: phone,
                email: email,
                address: address,
                birthday: .some(hasBirthday ? birthday : nil)
                // photoURL intentionally omitted — photo lives in NoteStore at
                // Photos/People/<Name>.jpg and is resolved at load time, not stored in Notion.
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

/// Rectangular photo tile for interaction detail — loads from NoteStore path or HTTPS URL.
private struct InteractionPhotoTile: View {
    let urlString: String
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .task(id: urlString) { image = await load() }
    }

    private func load() async -> UIImage? {
        if urlString.hasPrefix("Photos/") {
            guard let fileURL = NoteStore.shared.resolvedURL(for: urlString) else { return nil }
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            let delays: [UInt64] = [300, 500, 1_000, 1_500, 2_000, 3_000, 4_000, 5_000]
            for delay in delays {
                if let data = try? Data(contentsOf: fileURL),
                   let img = UIImage(data: data) { return img }
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            return (try? Data(contentsOf: fileURL)).flatMap { UIImage(data: $0) }
        }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Interaction Detail Sheet

// Visibility dropped from `private` to internal — Session 48 follow-up,
// same category of fix as LogInteractionSheet just below (Dayflow hand-off
// note applies to that one). HomeView.swift's Recent > Interactions column
// now opens this directly on tap instead of the containing person's whole
// card, per David's request — `private` restricted it to file scope.
struct InteractionDetailSheet: View {
    let interaction: Interaction
    /// Called after a successful save so the person's list can re-read. Optional
    /// with a no-op default: the Dayflow hand-off and any other caller that does
    /// not own a list can ignore it.
    var onSaved: () -> Void = {}
    /// Opens straight into editing rather than the read-only view.
    ///
    /// Used when the interaction was just created and has nothing in it yet.
    /// David, after logging one from a visit: *"the interaction itself doesnt
    /// have a note section which is the main point of the interaction."* Right —
    /// creating an empty record and making him find his way back into it to
    /// write the only part that matters is the wrong shape. Create, then land
    /// in the notes field.
    var startInEditing: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(NotionService.self) private var notion

    // EDITING, added 2026-07-31. David: *"i see that lunch with Bronwyn is a
    // recent interaction. I wanted to add more notes to this but i have no way
    // of editing do i?"* He did not.
    //
    // `NotionService.updateInteraction` has existed all along and **TraceMac
    // already uses it** through its own edit sheet, so the same interaction was
    // editable on the Mac and read-only on the phone. Not a hidden door this
    // time: a screen that was built once and never carried across. Sixth
    // instance this week of a capability that exists being unreachable.
    //
    // Fields match the Mac sheet exactly (summary, type, date, notes) so the two
    // cannot drift into editing different things. Photos are deliberately not
    // editable here — the Mac sheet uploads them and that path has no iOS
    // equivalent yet; adding one is its own piece of work, not a tail on this.
    @State private var isEditing = false
    @State private var summary = ""
    @State private var type = "other"
    @State private var date = Date()
    @State private var notes = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var openVisit: Visit? = nil
    @State private var openPerson: Person? = nil

    /// Everyone this interaction names.
    ///
    /// `personIDs` has always been an array on the model and was **rendered
    /// nowhere on this card** — David, 2026-07-31: *"wouldnt it be good to have
    /// the people listed in the Inspired interaction card?"* It matters more now
    /// that an interaction can name several: log one from a visit with two
    /// attendees and the card said nothing about either of them.
    private var people: [Person] {
        interaction.personIDs.compactMap { id in notion.people.first { $0.id == id } }
    }

    /// The visit this interaction is attached to, if any.
    ///
    /// `visitID` has been parsed off every interaction since the model was
    /// written and displayed **nowhere**, so a link was invisible even once made.
    /// Shown here, and tappable, because a stored relation nobody can see is the
    /// same as no relation.
    private var linkedVisit: Visit? {
        guard let visitID = interaction.visitID else { return nil }
        return notion.visits.first { $0.id == visitID }
    }

    private let typeOptions = [
        "visit", "dinner", "lunch", "coffee", "call", "video call",
        "text", "email", "meeting", "event", "workout", "other"
    ]

    var body: some View {
        NavigationStack {
            List {
                if isEditing {
                    Section {
                        TextField("Summary", text: $summary)
                        Picker("Type", selection: $type) {
                            ForEach(typeOptions, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                    }
                    Section("Notes") {
                        TextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(4...12)
                    }
                    if let saveError {
                        Section {
                            Text(saveError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                Section {
                    LabeledContent("Type", value: interaction.type.capitalized)
                    LabeledContent("Date", value: interaction.date.formatted(.dateTime.month(.wide).day().year()))
                }
                if !people.isEmpty {
                    // Plural header only when it is. A card headed "People" over
                    // a single name reads like something is missing.
                    Section(people.count == 1 ? "Person" : "People") {
                        ForEach(people) { person in
                            Button {
                                openPerson = person
                            } label: {
                                HStack {
                                    Label(person.name, systemImage: "person.crop.circle.fill")
                                        .foregroundStyle(Color.primary)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                // Always drawn, even when empty. It used to be omitted when
                // there were no notes, so an interaction with none showed a
                // screen with a type and a date on it and nothing else — which
                // reads as a broken record rather than an empty one, and gives
                // no hint that notes are the point of the thing.
                Section("Notes") {
                    if let notes = interaction.notes, !notes.isEmpty {
                        Text(notes).font(.body)
                    } else {
                        Text("No notes yet. Tap Edit to add some.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let linkedVisit {
                    Section("Visit") {
                        Button {
                            openVisit = linkedVisit
                        } label: {
                            HStack {
                                Label(linkedVisit.placeName, systemImage: "mappin.circle.fill")
                                    .foregroundStyle(Color.primary)
                                Spacer(minLength: 8)
                                Text(linkedVisit.date.formatted(.dateTime.month(.abbreviated).day()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !interaction.photoURLs.isEmpty {
                    Section("Photos") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(interaction.photoURLs, id: \.self) { urlString in
                                    InteractionPhotoTile(urlString: urlString, size: 160)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section {
                    Button {
                        let cleanID = interaction.id.replacingOccurrences(of: "-", with: "")
                        if let url = URL(string: "https://notion.so/\(cleanID)") {
                            openURL(url)
                        }
                    } label: {
                        Label("Open in Notion", systemImage: "arrow.up.right.square")
                            .foregroundStyle(.blue)
                    }
                }
                }
            }
            .onAppear { if startInEditing, !isEditing { startEditing() } }
            .sheet(item: $openVisit) { visit in
                VisitDetailView(visit: visit)
                    .environment(notion)
            }
            .sheet(item: $openPerson) { person in
                PersonDetailView(personID: person.id, personName: person.name)
                    .environment(notion)
            }
            .navigationTitle(interaction.summary.isEmpty ? interaction.type.capitalized : interaction.summary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button("Cancel") { isEditing = false; saveError = nil }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button(isSaving ? "Saving…" : "Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(isSaving)
                    } else {
                        Button("Edit") { startEditing() }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !isEditing {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    private func startEditing() {
        summary = interaction.summary
        type = typeOptions.contains(interaction.type) ? interaction.type : "other"
        date = interaction.date
        notes = interaction.notes ?? ""
        saveError = nil
        isEditing = true
    }

    /// Dismisses on success rather than dropping back to the read-only view.
    /// The sheet renders from the `interaction` it was handed, which is a value
    /// captured when the row was tapped — staying open would show the OLD text
    /// straight after saving the new one, which reads exactly like a failed save.
    /// `onSaved` re-reads the list behind it.
    private func save() {
        isSaving = true
        saveError = nil
        Task {
            do {
                try await notion.updateInteraction(
                    id: interaction.id,
                    summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: type,
                    date: date,
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                isSaving = false
                onSaved()
                dismiss()
            } catch {
                // Stay on the sheet. Dismissing on failure is what made the
                // Endeavor details sheet indistinguishable from success.
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

// MARK: - Log Interaction Sheet

// Visibility dropped from `private` to internal 2026-07-21 (Session 26) — Dayflow
// hand-off, fifth button ("Log an Interaction in Trace"). ContentView.swift's new
// `loginteraction` .onOpenURL case needs to construct this from outside this file;
// `private` restricted it to file scope, same category of blocker Session 25 hit
// with CheckInView's unused `preselectedPlace` init, just a visibility fix instead
// of a missing param. Behavior and every existing call site (this file's own
// per-person "Log Interaction" button, ~line 213) are unchanged.
struct LogInteractionSheet: View {
    let personID: String
    let personName: String
    let onSaved: () -> Void

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss

    private let typeOptions = [
        "visit", "dinner", "lunch", "coffee", "call", "video call",
        "text", "email", "meeting", "event", "workout", "other"
    ]

    @State private var selectedType: String
    @State private var date = Date()
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var capturedPhoto: UIImage? = nil

    /// AI-prefill, Session 28 — optional suggested Type/Notes riding in on the
    /// `trace://loginteraction` URL's query params (see DayflowWikiSummaryView.swift's
    /// personLogTab). Defaults to blank for every other existing way of opening this
    /// sheet — in particular this file's own per-person "Log Interaction" button
    /// (~line 213) is unaffected, it never passes these. `prefillType` is validated
    /// against `typeOptions` rather than trusted outright — a Claude response that
    /// somehow returns a value outside the fixed list would otherwise select nothing
    /// in the type picker instead of falling back to the "visit" default.
    init(personID: String, personName: String, prefillType: String? = nil, prefillNotes: String? = nil, onSaved: @escaping () -> Void) {
        self.personID = personID
        self.personName = personName
        self.onSaved = onSaved
        let validatedType = typeOptions.contains(prefillType ?? "") ? prefillType! : "visit"
        _selectedType = State(initialValue: validatedType)
        _notes = State(initialValue: prefillNotes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(typeOptions, id: \.self) { t in
                                let selected = selectedType == t
                                Button { selectedType = t } label: {
                                    Text(t.capitalized)
                                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(selected ? Color.accentColor
                                                             : Color(.secondarySystemFill),
                                                    in: Capsule())
                                        .foregroundStyle(selected ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                Section("Date") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                }
                Section("Notes (optional)") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $notes)
                            .frame(minHeight: 80)
                        if notes.isEmpty {
                            Text("What did you talk about?")
                                .foregroundStyle(Color(.placeholderText))
                                .font(.body)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                }
                Section("Photo (optional)") {
                    if let photo = capturedPhoto {
                        HStack(spacing: 12) {
                            Image(uiImage: photo)
                                .resizable().scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Text("Change photo")
                            }
                            Spacer()
                            Button(role: .destructive) { capturedPhoto = nil; selectedPhotoItem = nil } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("Add photo", systemImage: "photo.badge.plus")
                        }
                    }
                }
                if let err = errorMessage {
                    Section { Text(err).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle("Log Interaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Save") { save() }
                    }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        capturedPhoto = image
                    }
                }
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                let interaction = try await notion.createInteraction(
                    personID: personID,
                    summary: "\(selectedType.capitalized) with \(personName)",
                    date: date,
                    type: selectedType,
                    notes: notes
                )
                // Upload photo after creating the interaction page
                if let photo = capturedPhoto,
                   let data = photo.jpegData(compressionQuality: 0.85) {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                    let filename = "interaction-\(formatter.string(from: date)).jpg"
                    let photoPath = try NoteStore.shared.writePhoto(data, category: "Interactions", filename: filename)
                    try await notion.addPhotoToPage(interaction.id, photoURL: photoPath)
                }
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

/// How far ahead of a birthday to be told.
///
/// A fixed set rather than a date picker: the useful answers to "when do you want
/// to know about a birthday" are few and all of them are relative to the day. A
/// picker would make him do arithmetic against a date he cannot see.
enum BirthdayLead: Int, CaseIterable, Identifiable {
    case onTheDay = 0
    case oneDay = 1
    case threeDays = 3
    case oneWeek = 7
    case twoWeeks = 14

    var id: Int { rawValue }
    var days: Int { rawValue }

    var label: String {
        switch self {
        case .onTheDay:  return "On the day"
        case .oneDay:    return "1 day before"
        case .threeDays: return "3 days before"
        case .oneWeek:   return "1 week before"
        case .twoWeeks:  return "2 weeks before"
        }
    }

    /// Reads after a name: "Bronwyn's birthday is in a week".
    var phrase: String {
        switch self {
        case .onTheDay:  return "is today"
        case .oneDay:    return "is tomorrow"
        case .threeDays: return "is in 3 days"
        case .oneWeek:   return "is in a week"
        case .twoWeeks:  return "is in 2 weeks"
        }
    }
}

// MARK: - Agenda item editor
//
// Replaced double-tap-to-edit-inline, 2026-08-01, when agenda items gained dates.
// A date needs a picker and a reminder needs a button, and neither fits on a row
// you edit in place. One sheet does add and edit both — an empty `AgendaItem` is
// the "add" case, which is why `saveAgendaItem` keys off `original.raw` being
// empty rather than a separate mode flag.

struct AgendaItemSheet: View {
    let item: AgendaItem
    let personID: String
    let personName: String
    /// `(due, text)` — the caller composes and persists the line.
    var onSave: (Date?, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var hasDate: Bool
    @State private var due: Date
    @State private var reminderState: ReminderButtonState = .idle


    init(item: AgendaItem, personID: String, personName: String,
         onSave: @escaping (Date?, String) -> Void) {
        self.item = item
        self.personID = personID
        self.personName = personName
        self.onSave = onSave
        _text = State(initialValue: item.text)
        _hasDate = State(initialValue: item.due != nil)
        _due = State(initialValue: item.due ?? Date())
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to raise?", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    Toggle("Give it a date", isOn: $hasDate.animation(.snappy(duration: 0.2)))
                    if hasDate {
                        DatePicker("Due", selection: $due, displayedComponents: .date)
                    }
                } footer: {
                    // Stated plainly because it is the rule that keeps Coming Up
                    // from becoming the pile it was.
                    Text(hasDate
                         ? "Shows in Coming Up, and stays there until you tick it off."
                         : "No date means it stays here as a someday item and never appears in Coming Up.")
                }

                if hasDate {
                    Section {
                        Button {
                            addReminder()
                        } label: {
                            HStack {
                                Label("Remind me in Reminders", systemImage: "bell")
                                Spacer()
                                switch reminderState {
                                case .working: ProgressView()
                                case .added:   Image(systemName: "checkmark").foregroundStyle(.green)
                                default:       EmptyView()
                                }
                            }
                        }
                        .disabled(trimmed.isEmpty || reminderState == .working)
                        if case .failed(let why) = reminderState {
                            Text(why).font(.caption).foregroundStyle(.orange)
                        }
                    } footer: {
                        // Honest about what this does and does not do. Trace owns
                        // the date; the reminder is a copy that nothing reads back.
                        Text("Adds a separate reminder in Apple's Reminders app. Ticking it there will not clear this item.")
                    }
                }
            }
            .navigationTitle(item.raw.isEmpty ? "New item" : "Agenda item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(hasDate ? due : nil, trimmed)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmed.isEmpty)
                }
            }
        }
    }

    private func addReminder() {
        reminderState = .working
        Task {
            do {
                let id = try await ReminderService.add(title: trimmed,
                                                       due: hasDate ? due : nil,
                                                       notes: "Trace · \(personName)")
                // Linked against the line this will BECOME, not the one it was —
                // Save composes the same string, so ticking it later finds this.
                ReminderService.link(id, to: "\(personID)|\(AgendaLine.compose(due: hasDate ? due : nil, text: trimmed))")
                reminderState = .added
            } catch ReminderService.Failure.denied {
                reminderState = .failed("Trace does not have access to Reminders. Settings › Privacy › Reminders.")
            } catch {
                reminderState = .failed("Could not add the reminder.")
            }
        }
    }
}
