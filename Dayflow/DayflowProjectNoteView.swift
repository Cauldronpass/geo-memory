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
                            Button { openEndeavorID = e.id } label: {
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
            .sheet(item: Binding(
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
                                // Same reasoning as DayflowDailyNoteEditor: project-note
                                // checkboxes are local-only in Dayflow, no Send to
                                // Things/Tweek menu (that's a Trace-only concept).
                                checklistSendEnabled: false,
                                // Must come after checklistSendEnabled — Swift call-site
                                // argument order has to match MarkdownEditorView's
                                // declaration order (onCaptureTap is declared after
                                // checklistSendEnabled/onPinSucceeded/onPinFailed).
                                onCaptureTap: { id in tappedCaptureID = id },
                                attachTrigger: $attachRequest
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            // E-CHIP, 2026-07-28. Same render-time sidecar query
                            // as the day note and as Trace's Place and Person
                            // notes. The bar shows unconditionally here: this is
                            // a full screen, not a card competing for room.
                            // Tags above the document chips: tags say what the
                            // note is about, documents are things attached to it,
                            // and the first is closer to the note itself.
                            DayflowNoteTagBar(text: $content, onCommit: { save($0) }, attach: $attachRequest)
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
                            SatchelAddDocumentButton(notePath: relativePath, style: .bar)

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
                        }
                    }
                }
            }
            // Skin fix 2026-07-22 (Session 37) — this screen only ever got the
            // font fix in Session 32 ("no background/card added" — logged at
            // the time as a known, not-forgotten gap). David hit this
            // directly while testing the Related Notes feature; fixed now.
            .dayflowCard()
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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
    }

    // MARK: Header — back chevron / centered serif title / trailing "link a
    // note" Menu + pin toggle (Session 37 — used to be an invisible spacer).

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(title)
                .font(.dayflowSerif(18))
                .lineLimit(1)
                .padding(.horizontal, 8)
            Spacer()
            HStack(spacing: 6) {
                Menu {
                    dayflowLinkKindMenuItems { kind in activeLinkFlow = kind }
                } label: {
                    // Explicit ink color — Menu's label tinting defaults to
                    // the system accent (blue) otherwise, same bug class
                    // Session 30 already found and fixed on ContentView's own
                    // top-bar Menu icon.
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.dayflowInk)
                        .frame(width: 28, height: 28)
                        .background(.quaternary.opacity(0.6), in: Circle())
                }
                .accessibilityLabel("Link a note")

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
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
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
        guard !trimmed.isEmpty else { return }
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
