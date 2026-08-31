import SwiftUI

// MARK: - DayflowProjectNoteView
//
// View + append screen for a single project note (`Notes/Projects/<title>.md`),
// reached from DayflowNotesView (Session 11, 2026-07-20). Independent of the
// calendar/date flow per David's ask — this is the same NoteStore-backed
// markdown file Trace's own Notes tab already manages under Notes/Projects/,
// just a small Dayflow-specific screen around it, same precedent as
// DayflowDailyNoteEditor.swift for the calendar-day note.
//
// Uses the identical MarkdownEditorView + native (focus-triggered) formatting
// toolbar Daily Note itself uses — David asked for "something close to the
// daily note's own markdown," not a plain text box. Load/save mirrors
// DayflowDailyNoteEditor's header-strip convention exactly, just swapping the
// "# YYYY-MM-DD" date header for "# <title>" (the same header format Trace's
// own NotesView.swift already writes when a project note is created via its
// promote/move-block flows, so a project note edited from either app reads
// consistently).
//
// **Wikilink taps wired 2026-07-20 (Session 13), David asked for this
// directly — "allowing the people and places links to work... thats major."**
// Copied verbatim from DayflowDailyNoteEditor.swift: same NotionService.shared
// people/places lookup, same DayflowWikiSummaryView sheet (the lightweight
// Dayflow-specific read-only stand-in for Trace's real PersonDetailView/
// PlaceDetailView — those two are deliberately out of Dayflow's target per
// David's Session 1 call, see Dayflow-Design-Plan.md "Open questions"; not
// revisited here). [[Person]]/[[Place]] links inside a project note now
// resolve exactly the same way they already do inside the Daily Note.
//
// **Pin/flag, added 2026-07-22 (Session 37).** See DayflowNotesView.swift's
// `sortedProjectNames` for the list-side half; this file adds the pin toggle
// itself so you can flag from inside the note, not just the browse list.
//
// **Related Notes rebuilt as a native section, 2026-07-22 (Session 37
// addendum, same day).** Session 37's first pass wrote a real markdown table
// directly into the note body (Option A of three options walked through with
// David — plain portable markdown vs. structured app-only data vs. a hybrid).
// David tried it and reported two real problems: this screen still didn't
// match the rest of the app's warm/serif skin at all (a pre-existing gap from
// Session 32 — that session only fixed this file's font, not its background/
// card, see Dayflow-HANDOFF.md — now actually fixed below), and the raw
// `| Note | Relationship |` pipe-table syntax showed up as ugly unrendered
// text in MarkdownEditorView, which doesn't render markdown tables visually
// (it renders headers/checklists/wikilinks specially, but not table syntax) —
// confirmed by inspecting that shared, Trace-owned component rather than
// guessing, and deliberately not modified since it's shared and delicate.
//
// Fix: the underlying storage is UNCHANGED — still the exact same portable
// `## Related Notes` markdown table living in the note file, still fully
// readable/editable by hand or in Trace. What changed is Dayflow's own
// display: `load()` now splits that section OUT of what MarkdownEditorView
// shows (so the editor only ever sees prose, never raw table syntax) and
// parses it into `relatedNotes`, rendered as a real native SwiftUI list
// below the editor. Any edit (add/remove a row) re-serializes the table and
// writes the full file back, same format as before.
//
// **Multi-type linking, same addendum, then Visit (Session 37 addendum 4).**
// Daily/Project/Person/Place/Visit — see this screen's top-bar Menu.
//
// **Extracted to a shared engine + views, 2026-07-23 (Session 38).** David
// asked to bring the same Related Notes feature to the Daily Note. Rather
// than duplicate this ~450-line feature into DayflowDailyNoteEditor.swift,
// the whole thing (model, parsing/serialization, candidate lists, and the
// section/sheet UI) moved into the new DayflowRelatedNotes.swift, shared by
// both screens. This file now only keeps what's genuinely screen-specific:
// the "# <title>" header format (vs. Daily Note's "# yyyy-MM-dd"), the pin
// toggle (Daily Note has no equivalent), and this screen's own top-bar Menu
// (Daily Note instead gets an inline "Link a note" affordance built into the
// shared section itself, since it has no single top bar shared between its
// card and full-page forms — see DayflowRelatedNotes.swift's own header
// comment). `RelatedNoteRow`/`DayflowLinkKind` are now the shared types from
// that file, no longer private to this one.

/// One field, so `.sheet(item:)` has something Identifiable to hold. Fourth of
/// these in the app; each screen keeps its own, as `DayflowAgendaSection` and
/// `DayflowWikiSummaryView` already do.
private struct ProjectNoteEndeavorRef: Identifiable {
    let id: String
}

struct DayflowProjectNoteView: View {
    let title: String
    var onBack: () -> Void

    @State private var content: String = ""
    /// Endeavors whose body links this note. Session 72, loaded in `load()`.
    @State private var endeavors: [Endeavor] = []
    /// Which one the chip row was asked to open.
    @State private var openEndeavorID: String? = nil
    @State private var relatedNotes: [RelatedNoteRow] = []
    /// Collapsed by default — three rows visible, scrollable past that. See
    /// DayflowRelatedNotesSection for the expand/collapse sizing.
    @State private var relatedNotesExpanded = false
    /// Fully collapsed — only the "RELATED NOTES (n)" header row shows, every
    /// relationship row hidden. Independent of `relatedNotesExpanded` (that
    /// one only decides how big the row list is *when visible*) — David
    /// asked for this as a separate, additional level, not a replacement.
    @State private var relatedNotesHidden = false
    @State private var isLoading = true
    /// Which attachment picker the visible Attach button asked for. Cleared by
    /// `MarkdownEditorView` once it has fired. Added 2026-07-30: the paperclip
    /// used to live only on the keyboard accessory bar, so attaching required
    /// already typing.
    @State private var attachRequest: MarkdownAttachKind? = nil
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    /// Session 45 addendum 6 — set by MarkdownEditorView's onCaptureTap when a
    /// `[label](capture://open?id=ID)` marker is tapped. Same isPresented-Binding
    /// pattern as peekDate below (String isn't Identifiable, so not .sheet(item:)).
    @State private var tappedCaptureID: String? = nil

    /// Set when a tapped `[[yyyy-MM-dd]]` wikilink (in prose, or a Related
    /// Notes row) resolves to a real date. Presented via the `!= nil` binding
    /// trick already used elsewhere in this app (e.g. ContentView's
    /// `saveErrorMessage`) since the sheet needs the actual date, not just a
    /// flag that one was tapped.
    @State private var peekDate: Date? = nil
    /// Set when a Related Notes row pointing at another project is tapped —
    /// opens that project note in the same kind of sheet.
    @State private var openProjectTitle: String? = nil
    /// Set when a Related Notes row pointing at a Visit is tapped — presents
    /// the existing, lightweight `DayflowVisitDetailView` (Session 20), same
    /// as Person/Place's own Visits/Activity tabs already do.
    @State private var activeVisit: Visit? = nil
    /// An OPEN TASKS row being edited (Session 78).
    @State private var editingTask: ThingsTask? = nil
    /// The add-a-task sheet (Session 78 round two) — from the OPEN TASKS
    /// header's plus or the top-bar Menu's "Add a task".
    @State private var addingTask = false

    /// Presents DayflowLinkFlowSheet (DayflowRelatedNotes.swift) fresh each
    /// time — its own @State resets for free on each presentation, no
    /// manual resetLinkFlow() needed (see that file's header comment).
    @State private var activeLinkFlow: DayflowLinkKind? = nil

    private var relativePath: String { "Notes/Projects/\(title).md" }

    /// The chip row, and its own sheet host.
    ///
    /// **The sheet hangs off this row, not off the screen.** D36: two `.sheet`
    /// modifiers on one view is a coin flip the later one wins in silence, and
    /// this screen already carries others. Same one-field Identifiable wrapper
    /// the agenda and wiki-summary screens use for the same jump.
    @ViewBuilder
    private var endeavorChips: some View {
        if !endeavors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("ENDEAVORS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(endeavors, id: \.id) { e in
                            Button {
                                // No slide — same disabled-animation present
                                // as the Endeavors list (round three).
                                var instant = Transaction()
                                instant.disablesAnimations = true
                                withTransaction(instant) { openEndeavorID = e.id }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "suitcase.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.indigo)
                                    Text(e.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            // Cover, not sheet (Session 78, same rule as the Endeavors
            // list): destinations get the full view.
            .fullScreenCover(item: Binding(
                get: { openEndeavorID.map(ProjectNoteEndeavorRef.init) },
                set: { openEndeavorID = $0?.id }
            )) { ref in
                NavigationStack {
                    DayflowEndeavorView(endeavorID: ref.id)
                }
            }
        }
    }
    private var isFlagged: Bool { DayflowFlagStore.shared.isFlagged(relativePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // GeometryReader so DayflowRelatedNotesSection can size its
                    // expanded state as a fraction of the actual available card
                    // height. Session 38 addendum 3 briefly removed this on the
                    // theory it was causing a scroll/background bug David hit
                    // on the Daily Note full page — reverted in addendum 4
                    // after removing it didn't fix the full page and newly
                    // broke the Daily Note home card, so it wasn't the actual
                    // cause. Left in place here (was never confirmed broken on
                    // this screen either way).
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 0) {
                            MarkdownEditorView(
                                text: $content,
                                onSave: { newText in save(newText) },
                                placeholder: "Nothing here yet — start writing.",
                                relativePath: relativePath,
                                onWikiTap: { name in resolveWikiLink(name) },
                                wikiSuggestions: { query in wikiSuggestions(for: query) },
                                // Argument order has to match
                                // MarkdownEditorView's declaration order.
                                onCaptureTap: { id in tappedCaptureID = id },
                                attachTrigger: $attachRequest,
                                // Checkbox → task (Session 78): right swipe on
                                // a ☐ line files a real task linked to this
                                // note's agenda anchor — it appears in OPEN
                                // TASKS below AND on the meeting's AGENDA
                                // line. Undated, Inbox: the agenda is its
                                // home (the D175 workflow rules).
                                onPromoteTask: { line, done in
                                    promoteChecklistLine(line, completion: done)
                                },
                                onCompletePromoted: { line in
                                    completePromotedTask(titled: line)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            // ENDEAVORS, Session 72. The reverse of the Endeavor
                            // screen's own Notes chip row: that one asks "which
                            // notes does this endeavor link", this asks "which
                            // endeavors link this note", off the same
                            // `wikilinkTargets` parser so the two cannot
                            // disagree.
                            //
                            // Above the documents, below the tags, for the reason
                            // the comment beside the tag bar gives: tags say what
                            // the note is about, this says what it is part of,
                            // documents are things hanging off it. Nothing is
                            // drawn when there are none — most notes belong to no
                            // endeavor and a permanent empty row is furniture.
                            endeavorChips
                            SatchelDocumentChips(notePath: relativePath)

                            // OPEN TASKS (Session 78) — every open task linked
                            // [[agendaAnchor]]: the full-ability home of a
                            // promoted checkbox, and the same set the
                            // meeting's AGENDA line shows. Real rows — the
                            // circle completes, tapping the title opens the
                            // standard edit sheet, person/place chips ride
                            // under the title.
                            openTasksSection

                            DayflowRelatedNotesSection(
                                relatedNotes: relatedNotes,
                                expanded: $relatedNotesExpanded,
                                hidden: $relatedNotesHidden,
                                availableHeight: geo.size.height,
                                // nil — this screen keeps its existing top-bar Menu as
                                // the sole "link a note" entry point (unchanged
                                // behavior); a second inline one would be redundant.
                                onStartLink: nil,
                                onOpen: { kind in open(kind) },
                                onRemove: { row in removeRelatedNote(row) }
                            )

                            addBand
                        }
                    }
                }
            }
            // Redesign (Session 78, approved mockup): the floating card is
            // retired — full-bleed paper, like the day-note full page. The
            // Session 37 card fix served until the screen earned its real
            // Editorial dress.
        }
        .dayflowSkinBackground()
        .task { await load() }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                // sourceNoteText: content — Session 28 AI-prefill, same reasoning as
                // DayflowDailyNoteEditor.swift: this is the other of the two note
                // sources the locked design covers.
                DayflowWikiSummaryView(target: target, sourceNoteText: content)
            }
        }
        .sheet(isPresented: Binding(
            get: { tappedCaptureID != nil },
            set: { if !$0 { tappedCaptureID = nil } }
        )) {
            if let id = tappedCaptureID {
                CaptureSummaryView(captureID: id)
                    .environment(NotionService.shared)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: Binding(
            get: { peekDate != nil },
            set: { if !$0 { peekDate = nil } }
        )) {
            if let date = peekDate {
                DayflowDailyNotePeekSheet(date: date, onBack: { peekDate = nil })
            }
        }
        .sheet(isPresented: Binding(
            get: { openProjectTitle != nil },
            set: { if !$0 { openProjectTitle = nil } }
        )) {
            if let t = openProjectTitle {
                DayflowProjectNoteView(title: t, onBack: { openProjectTitle = nil })
            }
        }
        .sheet(isPresented: Binding(
            get: { activeLinkFlow != nil },
            set: { if !$0 { activeLinkFlow = nil } }
        )) {
            if let kind = activeLinkFlow {
                DayflowLinkFlowSheet(
                    initialKind: kind,
                    excludeProjectTitle: title,
                    onConfirm: { rowKind, description in
                        addRelatedNote(kind: rowKind, description: description)
                    },
                    onDismiss: { activeLinkFlow = nil }
                )
            }
        }
        .sheet(item: $activeVisit) { visit in
            NavigationStack {
                DayflowVisitDetailView(visit: visit)
            }
        }
        .sheet(isPresented: $addingTask) {
            DayflowNoteTaskSheet(anchor: agendaAnchor)
        }
        .sheet(item: $editingTask) { task in
            // An OPEN TASKS row taps into the standard edit sheet, same as
            // the person/place records (D172); the store refresh redraws the
            // section on return.
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await ReminderTaskStore.shared.refreshAll() }
            }
        }
    }

    // MARK: Header — back chevron / centered serif title / trailing "link a
    // note" Menu + pin toggle (Session 37 — used to be an invisible spacer).

    private var header: some View {
        // Redesign (Session 78, approved mockup): Editorial masthead —
        // chevron and pin up top, PROJECT kicker in accent, serif title,
        // one ink rule. The link Menu moved into the bottom band's LINK
        // (David's unify call: two doors both meaning "add something").
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    DayflowFlagStore.shared.toggleFlag(relativePath)
                } label: {
                    Image(systemName: isFlagged ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundStyle(isFlagged ? Color.dayflowInk : .secondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFlagged ? "Unpin this project" : "Pin this project")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("PROJECT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(Color.dayflowAccent)
                Text(title)
                    .font(.dayflowSerif(26, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(2)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
        }
        .padding(.bottom, 2)
    }

    /// The one quiet band (Session 78, David's unify call): everything you
    /// can ADD to this note. LINK leads in accent (the old top-right menu),
    /// then TASK, then the tag/attach controls (DayflowNoteTagBar in its
    /// editorial dress), then DOCUMENT.
    private var addBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
            HStack(spacing: 17) {
                Menu {
                    dayflowLinkKindMenuItems { kind in activeLinkFlow = kind }
                } label: {
                    Text("LINK")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Color.dayflowAccent)
                        .contentShape(Rectangle())
                }
                Button { addingTask = true } label: {
                    Text("TASK")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.4)
                        .foregroundStyle(Color.dayflowFaint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                DayflowNoteTagBar(text: $content, onCommit: { save($0) },
                                  attach: $attachRequest, editorial: true)
                SatchelAddDocumentButton(notePath: relativePath, style: .caps)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: Load / save — same "# <title>" header strip/re-add pattern
    // DayflowDailyNoteEditor uses for "# YYYY-MM-DD", and the same pattern
    // Trace's NotesView.swift already writes via promoteBlock()/moveBlock()
    // for project notes created there. Session 37 addendum: also splits the
    // "## Related Notes" section out of what the editor displays/edits, via
    // the shared DayflowRelatedNotesEngine (Session 38).

    private func load() async {
        isLoading = true
        let raw = (try? NoteStore.shared.readFile(relativePath)) ?? ""
        let stripped = Self.stripTitleHeader(raw, title: title)
        let (prose, notes) = DayflowRelatedNotesEngine.split(stripped)
        content = prose
        relatedNotes = notes
        // Matched on the note's TITLE, which is what a `[[wikilink]]` in an
        // endeavor body carries, and which this screen is keyed by anyway.
        endeavors = EndeavorFile.loadAll(from: NoteStore.shared)
            .filter { $0.linksNote(titled: title) }
        isLoading = false
    }

    private static func stripTitleHeader(_ text: String, title: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first == "# \(title)" else { return text }
        lines.removeFirst()
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Checkbox → task (Session 78) + the OPEN TASKS section

    /// One anchor for this note everywhere: the matched person/place when the
    /// title names one, else the title itself — the exact name the meeting's
    /// AGENDA line filters by, so this section and that line always agree.
    private var agendaAnchor: String { DayflowAgendaMatch.agendaAnchor(forTitle: title) }

    /// Checking a dimmed ↗ line completes the task it spawned (round two).
    /// Resolved by exact title among this note's linked open tasks — the
    /// same set OPEN TASKS shows — so a renamed task is simply not found.
    private func completePromotedTask(titled taskTitle: String) {
        guard let task = linkedOpenTasks.first(where: { $0.title == taskTitle }) else { return }
        Task { await ReminderTaskStore.shared.complete(taskID: task.id) }
    }

    private func promoteChecklistLine(_ line: String, completion: @escaping (Bool) -> Void) {
        Task {
            let ok = await ReminderTaskStore.shared.addTask(
                title: line,
                list: ReminderTaskStore.inboxListName,
                notes: "[[\(agendaAnchor)]]\n")
            completion(ok)
        }
    }

    private var linkedOpenTasks: [ThingsTask] {
        ReminderTaskStore.shared.allTasks.filter {
            ($0.notes ?? "").contains("[[\(agendaAnchor)]]")
        }
    }

    @ViewBuilder
    private var openTasksSection: some View {
        let tasks = linkedOpenTasks
        // The header (and its plus) draws even with ZERO tasks — David:
        // "I dont see the plus to add a fresh one," after completing the
        // only task collapsed the whole section and took the add door with
        // it. This screen already keeps Add Document visible
        // unconditionally, so a one-line band is its established density,
        // not new furniture.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("OPEN TASKS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(Color.dayflowFaint)
                    Spacer()
                    Button { addingTask = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dayflowFaint)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a task")
                }
                .padding(.bottom, 4)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                ForEach(tasks) { task in
                    HStack(spacing: 12) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await ReminderTaskStore.shared.complete(taskID: task.id) }
                        } label: {
                            Circle()
                                .strokeBorder(Color.secondary, lineWidth: 1.4)
                                .frame(width: 18, height: 18)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 1) {
                            Button { editingTask = task } label: {
                                Text(task.title)
                                    .font(.dayflowSerif(15))
                                    .foregroundStyle(Color.dayflowInk)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            DayflowTaskWikiChips(task: task) { target in
                                wikiLinkTarget = target
                            }
                        }
                        Spacer(minLength: 0)
                        // The Mac row's bolt (D239) — runs without opening.
                        if let source = task.dayflowSource, source.icon == "bolt" {
                            Button {
                                UIApplication.shared.open(source.url)
                            } label: {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Color.dayflowAccent)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        // D229 marks (Session 81) — same pair as Today's rows.
                        if task.hasNoteProse {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.dayflowAccent)
                        }
                        if task.hasFollowableLink {
                            Image(systemName: "link")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.dayflowAccent)
                        }
                        Text(openTaskWhenLabel(task).uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.0)
                            .foregroundStyle(task.date == nil ? Color.dayflowFaint : Color.dayflowAccent)
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
    }

    private func openTaskWhenLabel(_ task: ThingsTask) -> String {
        guard let date = task.date else {
            return task.list == ReminderTaskStore.somedayListName ? "Someday" : "Anytime"
        }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return f.string(from: date)
    }

    private func save(_ text: String) {
        content = text
        persistFullNote(prose: text)
    }

    /// Reassembles title header + prose + (if any) the serialized Related
    /// Notes table, and writes the whole thing back — same single-file
    /// format this note has always used, just composed from two pieces of
    /// SwiftUI state instead of one editor's raw text.
    private func persistFullNote(prose: String) {
        var body = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        let table = DayflowRelatedNotesEngine.serialize(relatedNotes)
        if !table.isEmpty {
            if !body.isEmpty { body += "\n\n" }
            body += table
        }
        let fileContent = body.isEmpty ? "" : "# \(title)\n\n\(body)"
        try? NoteStore.shared.writeFile(relativePath, content: fileContent)
    }

    // MARK: Wikilinks — identical logic to DayflowDailyNoteEditor's own
    // wikiSuggestions/resolveWikiLink for Person/Place, plus the Session 37
    // date-pattern addition for Related Notes rows pointing at a Daily Note.

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
        return Array(results.prefix(8))
    }

    private func resolveWikiLink(_ name: String) {
        if let date = DayflowRelatedNotesEngine.parseDailyNoteDate(name) {
            peekDate = date
            return
        }
        if let place = NotionService.shared.places.first(where: { $0.name == name }) {
            wikiLinkTarget = .place(place)
        } else if let person = NotionService.shared.people.first(where: { $0.name == name }) {
            wikiLinkTarget = .person(person)
        }
    }

    // MARK: Related Notes — add/remove (parsing/serialization/candidate
    // lists/rendering all live in DayflowRelatedNotes.swift now).

    private func addRelatedNote(kind: RelatedNoteRow.Kind, description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty is ALLOWED (Session 78 round three) — Person/Place/Day links
        // may carry no relationship text; the link sheet still requires it
        // for Project and Visit, where the reason is the content.
        // Newest at top, per David's ask — the table's row order IS the
        // display order (no hidden timestamp field), so inserting at 0 here
        // is also what keeps the persisted file's top row the most recent
        // one for anyone hand-editing it directly.
        relatedNotes.insert(RelatedNoteRow(kind: kind, description: trimmed), at: 0)
        persistFullNote(prose: content)
    }

    private func removeRelatedNote(_ row: RelatedNoteRow) {
        relatedNotes.removeAll { $0.id == row.id }
        persistFullNote(prose: content)
    }

    private func open(_ kind: RelatedNoteRow.Kind) {
        switch kind {
        case .daily(let date):
            peekDate = date
        case .project(let name):
            openProjectTitle = name
        case .person(let name):
            if let person = NotionService.shared.people.first(where: { $0.name == name }) {
                wikiLinkTarget = .person(person)
            }
        case .place(let name):
            if let place = NotionService.shared.places.first(where: { $0.name == name }) {
                wikiLinkTarget = .place(place)
            }
        case .visit(let id):
            if let visit = NotionService.shared.visits.first(where: { $0.id == id }) {
                activeVisit = visit
            }
        case .unknown:
            break
        }
    }
}


// MARK: - Add a task linked to this note (Session 78 round two)

/// Compact capture pre-linked to the note's agenda anchor — the same sheet
/// shape as DayflowMeetingTaskSheet (D175), minus the event: undated, Inbox
/// by default, notes carry [[anchor]] so the task lands in OPEN TASKS above
/// and on the meeting's AGENDA line at once.
struct DayflowNoteTaskSheet: View {
    let anchor: String
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var armed = false
    @State private var list: String = ReminderTaskStore.inboxListName
    @FocusState private var focused: Bool

    private var listOptions: [String] {
        var out = [ReminderTaskStore.inboxListName]
        out += ReminderTaskStore.shared.listNames.filter { $0 != ReminderTaskStore.inboxListName }
        if !out.contains(ReminderTaskStore.somedayListName) {
            out.append(ReminderTaskStore.somedayListName)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TASK FOR")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Color.dayflowFaint)
            Text(anchor)
                .font(.dayflowSerif(20, weight: .heavy))
                .foregroundStyle(Color.dayflowInk)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Circle()
                    .strokeBorder(Color.dayflowFaint, lineWidth: 1.6)
                    .frame(width: 20, height: 20)
                TextField("New to-do", text: $title)
                    .font(.dayflowSerif(19, weight: .semibold))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save() }
            }
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
            HStack {
                Menu {
                    ForEach(listOptions, id: \.self) { name in
                        Button(name) { list = name }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("LINKED TO \(anchor.uppercased()) \u{00B7} \(list.uppercased())")
                            .tracking(1.5)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dayflowFaint)
                    .contentShape(Rectangle())
                }
                Spacer()
                Button { save() } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dayflowPaper)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(title.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.dayflowFaint : Color.dayflowInk,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.height(230)])
        .presentationBackground(Color.dayflowPaper)
        .interactiveDismissDisabled(!armed)
        .onAppear {
            // The armed/focus timing pair every gesture-presented sheet in
            // this app uses (D175's sheet documents why).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { armed = true }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let destination = list
        let link = anchor
        focused = false
        dismiss()
        Task {
            _ = await ReminderTaskStore.shared.addTask(
                title: trimmed, list: destination, notes: "[[\(link)]]")
        }
    }
}
