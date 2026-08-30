// DayflowNotesInboxView.swift — new file, Dayflow app target.
//
// MARK: - DayflowNotesInboxView
//
// Session 44 addendum 10 — David's "Inbox" concept, discussed and designed
// together before this was built: evergreen notes jotted down for later
// processing (something for a current/future project, an interaction with a
// person, a visit to a place — not tied to a specific day the way the Daily
// Note is), reviewed here in batches and filed to their real home. David's
// explicit framing: "make a habit of processing them," and he wanted this
// "not front and center" so it doesn't compete with Dayflow's calendar-first
// home screen. Deliberately NOT part of the top-bar Browse menu (Upcoming/
// Anytime/Unfiled Tasks/Search, see DayflowContentView.swift's `topBar`) —
// reached only by swiping right on the home screen (see that file's
// `.gesture(...)` on the root VStack), a separate, quieter door.
//
// **Naming**: this is the ONLY thing called "Inbox" in Dayflow as of this
// addendum. `DayflowInboxView.swift` (unfiled Things tasks) was renamed to
// "Unfiled Tasks" in the same addendum specifically to free up this name —
// see that file's header comment for the full reasoning. Don't reuse
// "Inbox" for anything else in this app; it means notes-staging now.
//
// **Storage**: `Notes/Inbox/<timestamp>.md`, one file per note — a
// convention that already existed before this view: Trace's own
// `QuickAppendSheet.swift` can already write new captures there, and
// `TraceMacInboxView.swift` already browses/edits/deletes them on Mac (this
// view's `loadFiles()`/empty-state below mirror that Mac view's own
// approach, adapted for iOS with `List`+`.swipeActions` instead of a
// `List(selection:)` two-pane layout, since there's no room for a
// permanently-visible left pane on a phone screen). This view is the first
// place that reads inbox notes FROM Dayflow, and — together with
// `NoteStore.fileInboxNote(_:to:)` — the first place anywhere that files one
// OUT of the inbox into a real destination.
//
// **Filing UX**: confirmed directly with David — swipe-action per row
// (Mail-style), not tap-to-open-then-pick. Swiping reveals "File…" (opens
// `DayflowInboxFilingSheet`, a destination picker) and "Delete". Tapping a
// row still opens the note for reading/light editing first
// (`DayflowInboxNoteEditSheet`) — useful before deciding where something
// goes, and low-risk to include alongside the swipe actions since it's a
// different gesture (tap vs. swipe) that doesn't compete with them.
//
// **Creating a note**: added right after the rest of this view shipped —
// the first build had no way to add a note FROM Dayflow at all, only
// browse/file ones already there. The header's trailing "+" (`createNote()`
// below) fixes that: same filename/template convention
// `QuickAppendSheet.swift`'s `.inbox` case and `TraceMacInboxView.swift`'s
// own "+" already use, opening straight into `DayflowInboxNoteEditSheet` so
// typing can start immediately.
//
// **Trace CRM hand-off** — added 2026-07-24, `DayflowInboxFilingSheet` only.
// David's ask: filing a note to a Person or Place normally just appends its
// text to that entity's standing note file; for notes that are real CRM
// material he wanted the option to route them into Trace's structured
// Interaction/Visit records instead. Person/Place rows in the filing sheet
// now carry a second swipe action ("Log as Interaction"/"Log as Visit",
// alongside the existing tap-to-file) that hands the note to Trace via the
// same `trace://loginteraction`/`trace://checkin` deep link + Claude-prefill
// pattern `DayflowWikiSummaryView.swift`'s hand-off buttons already use —
// see `DayflowInboxFilingSheet`'s own header comment for the full design
// writeup and the locked remove-from-Inbox-immediately decision.
//
// **New project from the filing sheet** — added 2026-07-27, David's ask: the
// Project section listed only projects that already existed, so filing a note
// into a brand-new project meant leaving this sheet entirely. A "New project…"
// row now sits at the top of that section (name prompt → creates and files in
// one step). See `showNewProjectPrompt`/`fileToNewProject()` below.

import SwiftUI

struct DayflowNotesInboxView: View {

    /// Open straight into a blank note instead of the list.
    ///
    /// **The swipe is a capture gesture, not a browse gesture.** David,
    /// 2026-08-14: *"swiping right gets me to the inbox but Id like to be
    /// automatically placed in a new note when i do that. I dont see any reason
    /// i should have to hit the plus key next."* Right — the Inbox is where
    /// evergreen jottings land, and the reason to reach for it in a hurry is to
    /// write one.
    ///
    /// A parameter rather than unconditional behaviour, even though the swipe is
    /// the only door today. "Show me the Inbox" and "start an Inbox note" are
    /// different intents, and a second door built to review the backlog must not
    /// silently create a note on arrival.
    var startInNewNote: Bool = false
    /// Session 77 step (d): hosted inside the Notes tab as the "To file"
    /// segment (the design's rename of this feature) — hides this screen's
    /// own header; the Notes tab provides the chrome. The swipe-right
    /// capture door on Home still presents the full screen with the header.
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var files: [InboxNoteFile] = []
    @State private var isLoading = true
    @State private var filingTarget: InboxNoteFile?
    @State private var editingTarget: InboxNoteFile?
    @State private var deleteCandidate: InboxNoteFile?
    @State private var showDeleteConfirm = false
    /// One-shot. `.task` can run again — `hasAccess` flipping, a re-entry — and
    /// a second run must not open a second note.
    @State private var didAutoOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded { header }
            // Skin: same card treatment as DayflowInboxView.swift and the
            // other Browse screens (DayflowSkin.swift), for visual
            // consistency even though this isn't reached from that menu.
            Group {
                if isLoading && files.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 36, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("Your inbox is clear.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(files) { file in
                            row(file)
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing) {
                                    // Order matters: the LAST button here is
                                    // closest to the trailing edge, so it's
                                    // what a small/quick swipe reveals first.
                                    // Delete first (fuller swipe needed),
                                    // File… last (the fast, one-swipe
                                    // action) — matches David's stated goal
                                    // of making a habit of quickly filing
                                    // these away.
                                    Button(role: .destructive) {
                                        deleteCandidate = file
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        filingTarget = file
                                    } label: {
                                        Label("File…", systemImage: "tray.and.arrow.down")
                                    }
                                    .tint(Color.dayflowAccent)
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await loadFiles() }
                }
            }
            // Embedded in the Notes tab (Session 78 redesign) the panel and
            // its insets drop away — the tab is already Editorial paper; the
            // standalone cover (New Note quick action, FAB hold) keeps them.
            .dayflowCard(enabled: !embedded)
            .padding(.horizontal, embedded ? 0 : 16)
            .padding(.bottom, embedded ? 0 : 16)
        }
        .dayflowSkinBackground()
        .task {
            await loadFiles()
            // After the load, deliberately: `openBlankNote` reuses an existing
            // empty note when there is one, and it can only see that once
            // `files` is populated.
            guard startInNewNote, !didAutoOpen else { return }
            didAutoOpen = true
            openBlankNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreInboxDidChange)) { _ in
            Task { await loadFiles() }
        }
        .sheet(item: $filingTarget) { file in
            DayflowInboxFilingSheet(file: file) {
                Task { await loadFiles() }
            }
        }
        .sheet(item: $editingTarget) { file in
            DayflowInboxNoteEditSheet(file: file) {
                Task { await loadFiles() }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.title ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { delete(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: Header

    private var header: some View {
        // BACK BY REVERSING THE GESTURE THAT GOT YOU HERE.
        //
        // David, after the first TestFlight round: *"When I swipe left for
        // Notes Id like to swipe right to go back to where i started… Same for
        // when I am in the Inbox screen i should be able to swipe left to go
        // back."* One rule to hold in the head, and the arrow stays where it is
        // for anyone who would rather tap.
        //
        // **On the header, not the whole screen**, for the reason the home
        // screen's pull-down already records. Here it is not theoretical: this
        // screen's rows carry `.swipeActions`, which ARE a horizontal drag, and
        // a screen-wide gesture would race File and Delete on every row.
        // `fullScreenCover` has no interactive dismissal of its own, which is
        // why this has to be built rather than inherited.
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()
            Text("Inbox")
                .font(.dayflowSerif(20))
            Spacer()

            // Added 2026-07-24 — until this, there was no way to create an
            // inbox note FROM Dayflow at all, only browse/file ones already
            // there (David had to use Trace's QuickAppendSheet or the Mac
            // app's own "+" button). Same blank-template-then-edit flow
            // TraceMacInboxView.swift's own "+" toolbar button already
            // uses, see `createNote()` below. Replaces the trailing
            // `Color.clear` spacer that used to just balance the leading
            // back button — same 32x32 sizing, so the centered title still
            // sits dead center.
            Button { openBlankNote() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    // Leftward, the reverse of the rightward swipe that opens
                    // this screen from Home.
                    let h = value.translation.width
                    guard h < -50,
                          abs(h) > abs(value.translation.height) * 1.5 else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dismiss()
                }
        )
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: Row

    private func row(_ file: InboxNoteFile) -> some View {
        // Redesign (Session 78): serif title over a faint caps date — the
        // same row anatomy as the tab's Days and Projects lists.
        VStack(alignment: .leading, spacing: 2) {
            Text(file.title)
                .font(.dayflowSerif(15, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
                .lineLimit(2)
            if let created = file.created {
                Text(dayflowToFileDate(created))
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color.dayflowFaint)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { editingTarget = file }
    }

    private func dayflowToFileDate(_ created: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(created) { return "TODAY" }
        if cal.isDateInYesterday(created) { return "YESTERDAY" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: created).uppercased()
    }

    // MARK: - Loading

    /// Same shape as TraceMacInboxView.swift's own `loadFiles()` — first
    /// non-empty line as the title (with a leading "#" heading marker
    /// stripped), sorted newest-first by the file's real creation date. A
    /// still-empty note (nothing typed yet — see `createNote()`'s own
    /// header comment for why it starts truly blank) shows a friendly
    /// "New Note" placeholder here rather than the raw timestamp filename —
    /// display-only, never written to the actual file.
    private func loadFiles() async {
        let names = (try? NoteStore.shared.listFiles(in: "Notes/Inbox")) ?? []
        let loaded: [InboxNoteFile] = names.compactMap { filename in
            let path = "Notes/Inbox/\(filename)"
            let content = (try? NoteStore.shared.readFile(path)) ?? ""
            let firstLine = content.components(separatedBy: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let title = firstLine?
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            let url = NoteStore.shared.resolvedURL(for: path)
            let created = url.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.creationDate] as? Date
            }
            return InboxNoteFile(filename: filename,
                                 title: (title?.isEmpty == false ? title! : "New Note"),
                                 created: created,
                                 isEmpty: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        isLoading = false
        files = loaded.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    private func delete(_ file: InboxNoteFile) {
        try? NoteStore.shared.deleteFile("Notes/Inbox/\(file.filename)")
        files.removeAll { $0.id == file.id }
        deleteCandidate = nil
    }

    /// Same filename convention Trace's own `QuickAppendSheet.swift` already
    /// uses for its `.inbox` destination (`inboxTimestamp()`). Inserts
    /// locally at the top for instant feedback, then opens it straight into
    /// `DayflowInboxNoteEditSheet` so typing can start immediately instead
    /// of creating a blank row you then have to tap separately — the
    /// `noteStoreInboxDidChange` post from `writeFile` below will also
    /// trigger `loadFiles()` shortly after via this view's own
    /// `.onReceive`, which just confirms the same state, not a race.
    ///
    /// **Starts truly empty, not `"# Note\n\n"`** — fixed 2026-07-24, David
    /// caught the actual symptom: typing over the placeholder "Note" text
    /// permanently shrank the heading font. Root cause: `MarkdownTextStorage`
    /// hides the "# " heading marker as real-but-invisible characters
    /// (`styleHeading`, `MarkdownTextStorage.swift`) — selecting the visible
    /// word "Note" and retyping over it is very easy to do in a way that
    /// also consumes those two hidden characters immediately before it,
    /// since there's nothing visually marking where they are. Once the line
    /// no longer starts with "# ", `styleHeading` never fires again for it
    /// and it permanently renders at the plain 16pt body size instead of
    /// 22pt semibold — not a transient glitch, a real, persistent loss of
    /// the heading marker. `TraceMacInboxView.swift`'s own "+" still writes
    /// the `"# Note\n\n"` template and could plausibly hit the identical
    /// issue on Mac (NSTextView, not UITextView, but the same hidden-marker
    /// mechanism) — that file wasn't touched here since it's Mac-only and
    /// out of scope, but worth knowing if it comes up there too. Starting
    /// empty sidesteps the whole class of bug for Dayflow's Inbox: no
    /// heading marker exists yet for a fresh note, so there's nothing to
    /// accidentally corrupt — the first line only becomes a real heading if
    /// the person deliberately types "# " themselves.
    /// The blank note to type in: the newest one that is still empty, or a new
    /// one if every note has something in it.
    ///
    /// **Reuse rather than create-every-time**, and the swipe is why. The plus
    /// button is a deliberate act a few times a day; a swipe is cheap and will
    /// be made by accident, and a screen that mints a file on arrival would
    /// leave a drift of empty timestamped notes behind it. Deleting them on
    /// dismissal was the alternative and it is worse: it races the editor's own
    /// save, and the failure mode of that race is losing a sentence David just
    /// typed. Reuse has no destructive path in it at all.
    ///
    /// The plus button routes through here too. It had the same accumulation,
    /// just more slowly.
    private func openBlankNote() {
        // `files` is sorted newest-first, so this is the most recent blank.
        if let blank = files.first(where: { $0.isEmpty }) {
            editingTarget = blank
        } else {
            createNote()
        }
    }

    private func createNote() {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "\(fmt.string(from: Date())).md"
        let path = "Notes/Inbox/\(filename)"
        try? NoteStore.shared.writeFile(path, content: "")
        let newFile = InboxNoteFile(filename: filename, title: "New Note",
                                    created: Date(), isEmpty: true)
        files.insert(newFile, at: 0)
        editingTarget = newFile
    }
}

/// Deliberately a distinct type from TraceMacInboxView.swift's own
/// `InboxFile` — same shape, but that one's Mac-only and this one's iOS-only
/// (different app targets), so there's no compile-time collision either way;
/// kept distinct anyway so the two are never mixed up reading the flat vault
/// mirror, where both files live side by side.
struct InboxNoteFile: Identifiable, Hashable {
    var id: String { filename }
    let filename: String
    var title: String
    var created: Date?
    /// Nothing typed yet. Read once during `loadFiles`, which already has the
    /// file's contents in hand, rather than re-read per lookup.
    var isEmpty: Bool = false
}

// MARK: - Filing sheet

/// The destination picker a swiped "File…" action opens. Plain grouped
/// list, not a fancier picker — the same "get the common case right, don't
/// over-build" call QuickAppendSheet.swift's own destination Menu already
/// made, just as a full sheet instead of a Menu since there are now four
/// categories (Daily/Project/Person/Place) instead of two-and-a-half
/// (Daily/Inbox/Project). Project candidates come from
/// `NoteStore.listFiles(in: "Notes/Projects")` (same source QuickAppendSheet
/// already uses); Person/Place candidates come from
/// `NotionService.shared.people`/`.places` (same source
/// DayflowRelatedNotesEngine's own candidate lists already use) rather than
/// scanning `Notes/People`/`Notes/Places` — those folders only contain
/// people/places that already have a note file, but the Notion database is
/// the actual source of truth for who/where exists at all.
struct DayflowInboxFilingSheet: View {
    let file: InboxNoteFile
    var onFiled: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedDate = Date()
    @State private var errorMessage: String?
    /// Added 2026-07-24 — David's ask: "if I decide that a note im adding to
    /// the dayflow inbox is for the CRM or visit then can we send it to Trace
    /// for futher refinement." A swipe action on Person/Place rows (parallel
    /// to the row's own tap-to-file behavior, doesn't replace it — David only
    /// asked for the *option*, not for every Person/Place filing to detour
    /// through Trace) hands the note off to Trace's real Interaction/Visit
    /// sheets instead of appending it as plain text to the entity's standing
    /// note. Reuses `DayflowInteractionPrefillService.suggestForPerson`/
    /// `suggestForPlace` exactly as `DayflowWikiSummaryView.swift`'s own
    /// hand-off buttons do — same `trace://loginteraction`/`trace://checkin`
    /// URL shape, same CRM-light boundary (this only ever suggests a
    /// prefill; David still has to tap Save in Trace, nothing here writes to
    /// Notion). One difference: that view's `resolveSourceText` has to go
    /// *find* the right excerpt inside a longer note by searching for a
    /// wikilink; here there's nothing to find — David already explicitly
    /// picked this person/place from this exact sheet, so the whole inbox
    /// note's text already IS the deliberately-scoped excerpt.
    /// `resolveSourceText` is skipped entirely for this call site — the note
    /// text is read fresh from disk and handed straight to
    /// `suggestForPerson`/`suggestForPlace`.
    ///
    /// **Locked with David:** sending to Trace removes the note from the
    /// Inbox immediately, same as normal filing — one save, not two. There's
    /// no callback path from Trace confirming the Interaction/Visit actually
    /// got saved (the hand-off is fire-and-forget, same as the wiki-summary
    /// buttons), so an abandoned Trace draft does mean the source note is
    /// gone with no record — David's explicit call, weighed against forcing
    /// a second manual dismiss for every CRM-routed note.
    @State private var isLoggingToTrace = false
    /// Added 2026-07-24 — David's ask: don't show every Project/Person/Place
    /// up front, only the 5 most-recently-modified per category, with
    /// search revealing the rest. Ranking uses `NoteStore.fileModifiedDate`
    /// on each entity's own note file — a Person/Place with no note file
    /// yet (real, since `NotionService.shared.people`/`.places` is the
    /// source of truth for who/where exists, not the Notes folders — see
    /// this file's earlier header comment) falls back to `.distantPast`,
    /// so entities with genuinely active notes surface first rather than
    /// being interleaved alphabetically with ones that have never been
    /// written to.
    @State private var searchText = ""
    /// Added 2026-07-27 — David's ask: "the inbox should allow me to add a new
    /// project." The Project section only ever listed what `Notes/Projects`
    /// already held, so a note belonging to a not-yet-existing project meant
    /// backing out of this sheet, creating the project over in
    /// DayflowNotesView (itself behind that view's Projects scope pill), then
    /// coming back and re-filing. No new NoteStore work was needed:
    /// `fileInboxNote`'s `.project` case routes through `appendToNamedNote`,
    /// which already writes the file with a `# Title` template when it
    /// doesn't exist yet — so "create a project and file into it" is just an
    /// ordinary `.project(name)` filing with a name that isn't in the list.
    @State private var showNewProjectPrompt = false
    @State private var newProjectName = ""

    private var projectCandidates: [(name: String, modified: Date)] {
        ((try? NoteStore.shared.listFiles(in: "Notes/Projects")) ?? [])
            .map { $0.replacingOccurrences(of: ".md", with: "") }
            .map { name in
                (name: name, modified: NoteStore.shared.fileModifiedDate("Notes/Projects/\(name).md") ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    private var personCandidates: [(name: String, modified: Date)] {
        NotionService.shared.people.map(\.name)
            .map { name in
                (name: name, modified: NoteStore.shared.fileModifiedDate("Notes/People/\(name).md") ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    private var placeCandidates: [(name: String, modified: Date)] {
        NotionService.shared.places.map(\.name)
            .map { name in
                let path = "Notes/Places/\(NoteStore.shared.placeNoteFilename(for: name)).md"
                return (name: name, modified: NoteStore.shared.fileModifiedDate(path) ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// No search text → top 5 by modified date (already sorted going in).
    /// Search text → every match across the FULL list, not just the top 5 —
    /// this is the "search uncovers the rest" half of David's ask.
    private func visible(_ candidates: [(name: String, modified: Date)]) -> [(name: String, modified: Date)] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(candidates.prefix(5)) }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Daily Note") {
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                    Button("File to Daily Note") { file(to: .daily(selectedDate)) }
                }

                Section("Project") {
                    // Above the list, not below it: this is the row that
                    // matters when nothing in the list is right, and the list
                    // is capped at 5 + search (see `visible`), so a trailing
                    // create row would sit at an unpredictable offset.
                    Button {
                        newProjectName = ""
                        showNewProjectPrompt = true
                    } label: {
                        Label("New project\u{2026}", systemImage: "plus.circle.fill")
                    }
                    filingRows(all: projectCandidates, emptyText: "No projects yet") { name in
                        file(to: .project(name))
                    }
                }

                Section("Person") {
                    filingRows(
                        all: personCandidates, emptyText: "No people yet",
                        onSelect: { name in file(to: .person(name)) },
                        traceLabel: "Log as Interaction", onTrace: { name in logToTrace(personName: name) }
                    )
                }

                Section("Place") {
                    filingRows(
                        all: placeCandidates, emptyText: "No places yet",
                        onSelect: { name in file(to: .place(name)) },
                        traceLabel: "Log as Visit", onTrace: { name in logToTrace(placeName: name) }
                    )
                }
            }
            .searchable(text: $searchText, prompt: "Search Projects, People, Places")
            .navigationTitle("File to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't file note", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Check iCloud, then try again.")
            }
            // Same `.alert` + `TextField` + Create pattern
            // DayflowNotesView.swift's own "New Project Note" prompt uses, so
            // creating a project feels identical on both screens.
            .alert("New Project", isPresented: $showNewProjectPrompt) {
                TextField("Project name", text: $newProjectName)
                Button("Cancel", role: .cancel) { newProjectName = "" }
                Button("Create & File") { fileToNewProject() }
            } message: {
                Text("Files this note into a new project note.")
            }
            // Loading overlay while the Claude prefill call for a "Log as
            // Interaction"/"Log as Visit" swipe action is in flight — a swipe
            // action itself has nowhere to host a spinner (it collapses the
            // instant it's tapped, unlike the full-width hand-off buttons in
            // DayflowWikiSummaryView.swift that can show one inline), so this
            // covers the whole sheet instead, same as any other
            // network-bound sheet action.
            .overlay {
                if isLoggingToTrace {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView()
                    }
                }
            }
            .disabled(isLoggingToTrace)
        }
    }

    /// Shared row-building for the Project/Person/Place sections above —
    /// same "no candidates at all" vs. "candidates exist, just none match
    /// the current search" distinction in all three, so pulled out once
    /// rather than tripled. `traceLabel`/`onTrace` are nil for Project (no
    /// Trace hand-off exists for projects) and set for Person/Place — when
    /// set, adds a second swipe action next to the row's own tap-to-file
    /// behavior rather than replacing it.
    @ViewBuilder
    private func filingRows(
        all candidates: [(name: String, modified: Date)],
        emptyText: String,
        onSelect: @escaping (String) -> Void,
        traceLabel: String? = nil,
        onTrace: ((String) -> Void)? = nil
    ) -> some View {
        let shown = visible(candidates)
        if candidates.isEmpty {
            Text(emptyText).foregroundStyle(.secondary)
        } else if shown.isEmpty {
            Text("No matches").foregroundStyle(.secondary)
        } else {
            ForEach(shown, id: \.name) { item in
                Button(item.name) { onSelect(item.name) }
                    .swipeActions(edge: .trailing) {
                        if let traceLabel, let onTrace {
                            Button {
                                onTrace(item.name)
                            } label: {
                                Label(traceLabel, systemImage: "arrow.up.forward.app")
                            }
                            .tint(.purple)
                        }
                    }
            }
        }
    }

    /// Creates the project by filing into it — see `showNewProjectPrompt`'s
    /// comment above for why no explicit create step is needed.
    ///
    /// Case-insensitive reuse rather than blind create: typing "endeavor" when
    /// "Endeavor" already exists should file into that project, not spawn a
    /// near-duplicate beside it. `fileInboxNote` builds the path from the name
    /// unsanitized and untouched (deliberately — see its own doc comment), so
    /// the two really would be separate files on a case-sensitive volume and
    /// an unpredictable single one otherwise.
    ///
    /// "/" is rejected outright for the same unsanitized-path reason: it would
    /// either land the note in a phantom subfolder or fail the write. Not a
    /// case DayflowNotesView's `createProject()` guards either, but worth
    /// catching here rather than carrying the gap forward.
    private func fileToNewProject() {
        let typed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        guard !typed.isEmpty else { return }
        guard !typed.contains("/") else {
            errorMessage = "Project names can't contain \"/\"."
            return
        }
        let match = projectCandidates.first {
            $0.name.localizedCaseInsensitiveCompare(typed) == .orderedSame
        }
        file(to: .project(match?.name ?? typed))
    }

    private func file(to destination: NoteStore.InboxFilingDestination) {
        do {
            try NoteStore.shared.fileInboxNote(file.filename, to: destination)
            dismiss()
            onFiled()
        } catch {
            errorMessage = "Check iCloud, then try again."
        }
    }

    // MARK: - Trace hand-off (Person → Interaction, Place → Visit)

    /// Mirrors `DayflowWikiSummaryView.swift`'s "Log an Interaction in
    /// Trace" button exactly (same URL host/query-param names, same
    /// `openURL` environment call), skipping only the `resolveSourceText`
    /// step since the whole inbox note is already the right excerpt — see
    /// this type's own header comment above for the full reasoning. Reads
    /// the note fresh from disk rather than trusting any cached text, since
    /// `DayflowInboxNoteEditSheet` may have edited it since `loadFiles()`
    /// last ran.
    private func logToTrace(personName: String) {
        guard let person = NotionService.shared.people.first(where: { $0.name == personName }) else {
            errorMessage = "Couldn't find that person."
            return
        }
        isLoggingToTrace = true
        Task {
            let noteText = (try? NoteStore.shared.readFile("Notes/Inbox/\(file.filename)")) ?? ""
            var comps = URLComponents()
            comps.scheme = "trace"
            comps.host = "loginteraction"
            var items = [URLQueryItem(name: "personID", value: person.id)]
            if let suggestion = await DayflowInteractionPrefillService.suggestForPerson(
                sourceText: noteText, personName: person.name
            ) {
                if let type = suggestion.type {
                    items.append(URLQueryItem(name: "type", value: type))
                }
                if let notes = suggestion.notes {
                    items.append(URLQueryItem(name: "notes", value: notes))
                }
            }
            comps.queryItems = items
            isLoggingToTrace = false
            if let url = comps.url { openURL(url) }
            // Same removal-on-hand-off David locked above — fires even if
            // the Claude suggestion came back empty, since a blank-prefill
            // hand-off to Trace is still a completed hand-off.
            try? NoteStore.shared.deleteFile("Notes/Inbox/\(file.filename)")
            dismiss()
            onFiled()
        }
    }

    /// Place counterpart to `logToTrace(personName:)` above — mirrors
    /// `DayflowWikiSummaryView.swift`'s "Log a Visit in Trace" button
    /// exactly (`trace://checkin`, no `type` param since `CheckInView` has
    /// no Type field, only Notes).
    private func logToTrace(placeName: String) {
        guard let place = NotionService.shared.places.first(where: { $0.name == placeName }) else {
            errorMessage = "Couldn't find that place."
            return
        }
        isLoggingToTrace = true
        Task {
            let noteText = (try? NoteStore.shared.readFile("Notes/Inbox/\(file.filename)")) ?? ""
            var comps = URLComponents()
            comps.scheme = "trace"
            comps.host = "checkin"
            var items = [URLQueryItem(name: "placeID", value: place.id)]
            if let suggestion = await DayflowInteractionPrefillService.suggestForPlace(
                sourceText: noteText, placeName: place.name
            ), let notes = suggestion.notes {
                items.append(URLQueryItem(name: "notes", value: notes))
            }
            comps.queryItems = items
            isLoggingToTrace = false
            if let url = comps.url { openURL(url) }
            try? NoteStore.shared.deleteFile("Notes/Inbox/\(file.filename)")
            dismiss()
            onFiled()
        }
    }
}

// MARK: - Read/edit sheet

/// Opened by tapping a row — a chance to read (or lightly edit) a note
/// before deciding where it goes. Same `MarkdownEditorView` +
/// Cancel/Save-toolbar pattern QuickAppendSheet.swift already uses for
/// editing markdown text in a modal sheet, so the formatting toolbar looks
/// and behaves identically to every other note-editing surface in this app.
///
/// **`checklistSendEnabled: false`** — caught by David 2026-07-24, right
/// after this shipped: `MarkdownEditorView`'s checkbox button defaults to
/// `checklistSendEnabled = true`, which pops a "Keep local / Send to
/// Things / Send to Tweek" menu — a Trace-only concept (QuickAppendSheet.swift
/// wants that, since Trace really does sync checkboxes to Things). Dayflow's
/// OWN note-editing surfaces don't — `DayflowDailyNoteEditor.swift` already
/// established this exact convention (`checklistSendEnabled: false`, "always
/// local-only"), and this Inbox sheet is a Dayflow surface too, so it should
/// match Dayflow's convention, not Trace's. The bare `MarkdownEditorView
/// (text:placeholder:)` call this used at first silently inherited the
/// `true` default instead — fixed by setting it explicitly, same as
/// DayflowDailyNoteEditor.swift does.
struct DayflowInboxNoteEditSheet: View {
    let file: InboxNoteFile
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            MarkdownEditorView(
                text: $text,
                placeholder: "Write something…",
                checklistSendEnabled: false
            )
                .navigationTitle(file.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(isSaving)
                    }
                }
        }
        .task {
            text = (try? NoteStore.shared.readFile("Notes/Inbox/\(file.filename)")) ?? ""
        }
    }

    private func save() {
        isSaving = true
        try? NoteStore.shared.writeFile("Notes/Inbox/\(file.filename)", content: text)
        isSaving = false
        dismiss()
        onSaved()
    }
}
