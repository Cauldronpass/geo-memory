import SwiftUI

// MARK: - DayflowDailyNoteEditor
//
// Dayflow-Design-Plan.md "Daily Note section" (build order step 4). This is
// the shared load/save/wikilink core, reused by both surfaces the design
// plan calls for:
//   - DayflowDailyNoteSection — the bounded, internally-scrollable card on
//     the main screen (caller applies a fixed `.frame(height:)`).
//   - DayflowNoteFullPageView — the full-page expand view (caller lets this
//     fill all remaining space instead).
// Factored out as its own view (rather than duplicating load/save/wiki logic
// in both callers) since the two surfaces are explicitly "same note, same
// text" per the design plan — only the chrome around it differs.
//
// Backend: NoteStore.shared's markdown-file API (readDailyNote/writeFile),
// confirmed during research as the correct backend — NOT DayNoteSheet.swift's
// Notion-backed DayNote system, which is a different, unrelated Trace
// feature that happens to have a similar name.
//
// Formatting toolbar: MarkdownEditorView.swift attaches its own toolbar as a
// native `UITextView.inputAccessoryView` — it appears above the keyboard
// only while the field is focused, exactly like Trace's own NotesView.swift
// usage. The mockup's HTML shows the toolbar as a permanently-visible strip
// under the note body, but that's a static-HTML demo simplification (no real
// keyboard to attach to); the design plan explicitly says this toolbar is
// "not new work" and should be reused "as-is" from MarkdownEditorView.swift,
// so its real (focus-triggered) behavior is what Dayflow gets too. Logged
// here rather than silently guessed at, per David's ground-truth-vs-mockup
// rule — see Dayflow-HANDOFF.md Session 5.
//
// Wikilink taps: PersonDetailView.swift/PlaceDetailView.swift are not in
// Dayflow's target (too entangled with Trace's check-in/visit/billiards
// stack — see Dayflow-Design-Plan.md "Open questions"). Taps resolve to the
// small Dayflow-specific read-only DayflowWikiSummaryView instead, flagged
// as the plan for exactly this situation.
//
// **Related Notes linking, added 2026-07-23 (Session 38).** David asked
// whether Daily Notes could link to other notes the same way Project Notes
// already do (Session 37/37.4), then asked to build it. Reuses the shared
// engine/UI extracted into DayflowRelatedNotes.swift that same session
// (DayflowProjectNoteView.swift was migrated onto it in this same round) —
// same "## Related Notes" table format, same five link types (Daily/
// Project/Person/Place/Visit), same native rendering. Two differences from
// Project Note's version, both necessary rather than stylistic:
//   - The file header is "# yyyy-MM-dd" here, not "# <title>" — `load()`/
//     `persistFullNote(prose:)` below still own that format themselves,
//     same as Project Note owns its own "# <title>" header. The shared file
//     only owns the *Related Notes* section, not the whole document shape.
//   - Project Note has one screen-level top bar to put a "link a note" Menu
//     in; this editor is embedded in two different wrapper chromes
//     (DayflowDailyNoteSection's card header, DayflowNoteFullPageView's
//     page header) with no shared bar between them. Rather than duplicate a
//     Menu into both wrappers, DayflowRelatedNotesSection grows its own
//     inline "+ Link a note" affordance whenever it's given a non-nil
//     `onStartLink` — Daily Note passes one, Project Note still passes nil
//     and keeps its existing top-bar Menu as the sole entry point.
//
// `save(_:)` no longer writes directly — MarkdownEditorView's onSave only
// ever hands back the prose it edited, so a save mid-typing can't be allowed
// to blow away whatever Related Notes table already lives in the file.
// `persistFullNote(prose:)` reassembles date header + prose + (if any) the
// serialized table, mirroring Project Note's own `persistFullNote`.
//
// **Card vs. full-page entry point, addendum same day.** David tried the
// home card and correctly flagged that an always-visible "Link a note" row
// under a short note ate real estate the card can't spare. Fix: the card
// now triggers linking from its existing header pencil icon instead (see
// DayflowDailyNoteSection's header — wrapped in a Menu now), and passes
// `showInlineLinkAffordance: false` here so the section hides completely
// until something's actually linked, exactly like Project Note's own
// top-bar-Menu-plus-hidden-when-empty pattern. The full page keeps the
// original inline affordance (`showInlineLinkAffordance` defaults `true`)
// since it has room to spare and no equivalent header icon slot. Because the
// card's pencil icon lives in a sibling view (DayflowDailyNoteSection), not
// inside this one, `activeLinkFlow` can now be owned externally via
// `externalActiveLinkFlow` — when the card supplies one, it's the single
// source of truth; when nil (full page, and DayflowDailyNotePeekSheet's
// embedded peek), this view manages its own state exactly as before. Kept
// as an optional external binding with an internal fallback, rather than
// making every caller supply one, specifically so the peek sheet's use of
// this editor needed zero changes.

struct DayflowDailyNoteEditor: View {
    let date: Date
    /// Session 38 addendum 5 — an externally-bumpable counter that forces a
    /// reload even though `date` itself hasn't changed. DayflowDailyNoteSection
    /// (the home card) passes this through from ContentView, which bumps it
    /// whenever the full-page view — a separate DayflowDailyNoteEditor
    /// instance editing the same file — is dismissed, so the card picks up
    /// what was just saved there. See ContentView's own comment on this for
    /// the full "why doesn't the card just already know" reasoning.
    /// DayflowNoteFullPageView and DayflowDailyNotePeekSheet leave this at
    /// its default; they don't need it.
    var reloadToken: Int = 0

    @State private var content: String = ""
    @State private var relatedNotes: [RelatedNoteRow] = []
    @State private var relatedNotesExpanded = false
    @State private var relatedNotesHidden = false
    @State private var isLoading = true
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    /// Session 45 addendum 6 — set by MarkdownEditorView's onCaptureTap when a
    /// `[label](capture://open?id=ID)` marker is tapped. Same isPresented-Binding
    /// pattern as peekDate below (String isn't Identifiable, so not .sheet(item:)).
    @State private var tappedCaptureID: String? = nil
    /// Tracks focus so the `.noteStoreCalendarDidChange` reload below (added
    /// 2026-07-25) never fires while David is actively typing here — see
    /// that modifier's own comment for the full bug this fixes.
    @State private var isFocused = false

    /// Set when a Related Notes row (or an inline `[[yyyy-MM-dd]]` wikilink,
    /// same as Project Note) points at a Daily Note — peeked via
    /// DayflowDailyNotePeekSheet rather than navigating in place, so this
    /// editor instance's own in-progress edit isn't disturbed.
    @State private var peekDate: Date? = nil
    /// Set when a Related Notes row points at a project — opens that note.
    @State private var openProjectTitle: String? = nil
    /// Set when a Related Notes row points at a Visit — same read-only
    /// DayflowVisitDetailView (Session 20) Project Note's version uses.
    @State private var activeVisit: Visit? = nil

    // MARK: Link flow state — see this file's header comment on the card's
    // pencil-icon vs. full page's inline-affordance split.

    /// Presents DayflowLinkFlowSheet fresh each time — see that view's own
    /// header comment on why no manual reset is needed between uses. Only
    /// used when `externalActiveLinkFlow` is nil — see `activeLinkFlow` below.
    @State private var internalActiveLinkFlow: DayflowLinkKind? = nil
    /// Supplied by DayflowDailyNoteSection (the home card) so its header
    /// pencil icon can start a link flow that this editor still owns the
    /// sheet/persistence for. Left nil by DayflowNoteFullPageView and
    /// DayflowDailyNotePeekSheet, which don't need an external trigger.
    var externalActiveLinkFlow: Binding<DayflowLinkKind?>? = nil
    /// True (default, full page): DayflowRelatedNotesSection shows its own
    /// inline "Link a note" row even with nothing linked yet. False (home
    /// card): that row never renders — the section stays hidden until
    /// something's linked, same as Project Note's hidden-when-empty
    /// behavior, since the card supplies its own entry point instead (the
    /// header pencil icon).
    var showInlineLinkAffordance: Bool = true

    private var activeLinkFlow: Binding<DayflowLinkKind?> {
        externalActiveLinkFlow ?? Binding(
            get: { internalActiveLinkFlow },
            set: { internalActiveLinkFlow = $0 }
        )
    }

    /// Bug fix 2026-07-22 (Session 31). `.task(id: date)` below only reruns
    /// `load()` when `date` itself changes — it never refires just because
    /// the app came back to the foreground. David found real content (typed
    /// the previous evening) missing on the home screen's card this morning,
    /// while the exact same date's full-page editor (a fresh
    /// `DayflowDailyNoteEditor` instance, created new each time that sheet
    /// opens) showed it correctly. Root cause: the home screen's card is a
    /// long-lived instance — if it was already showing today's (empty, at
    /// the time) note before the content was written elsewhere, `date` never
    /// changed, so it never re-read the file and stayed stale. Reloading on
    /// scenePhase→active (same trigger `ContentView.swift` already uses to
    /// refresh `ThingsService`) fixes this the same way.
    @Environment(\.scenePhase) private var scenePhase

    private var relativePath: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return "Calendar/\(f.string(from: date)).md"
    }

    var body: some View {
        Group {
            if !NoteStore.shared.hasAccess {
                Text("Vault not linked yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // GeometryReader so DayflowRelatedNotesSection can size its
                // expanded state as a fraction of the actual available
                // height. Session 38 addendum 3 briefly removed this on the
                // theory it was causing a scroll/background bug David hit on
                // the full page — reverted in addendum 4 after removing it
                // didn't fix the full page and newly broke the home card
                // (which had been fine before). Root cause of the original
                // bug is still open; see the addendum 4 handoff entry.
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 0) {
                        MarkdownEditorView(
                            text: $content,
                            onSave: { newText in save(newText) },
                            placeholder: "Nothing here yet — start writing.",
                            onFocusChange: { focused in isFocused = focused },
                            relativePath: relativePath,
                            onWikiTap: { name in resolveWikiLink(name) },
                            wikiSuggestions: { query in wikiSuggestions(for: query) },
                            // Dayflow's Daily Note checkboxes are always local-only — no
                            // Send to Things/Tweek menu (that's a Trace-only concept).
                            // Fixed 2026-07-19 after David hit the menu in testing.
                            checklistSendEnabled: false,
                            // Must come after checklistSendEnabled — Swift call-site
                            // argument order has to match MarkdownEditorView's
                            // declaration order (onCaptureTap is declared after
                            // checklistSendEnabled/onPinSucceeded/onPinFailed).
                            onCaptureTap: { id in tappedCaptureID = id }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        DayflowRelatedNotesSection(
                            relatedNotes: relatedNotes,
                            expanded: $relatedNotesExpanded,
                            hidden: $relatedNotesHidden,
                            availableHeight: geo.size.height,
                            // See this file's header comment: full page gets
                            // the inline affordance, the card doesn't (its
                            // header pencil icon is the entry point there).
                            onStartLink: showInlineLinkAffordance ? { kind in activeLinkFlow.wrappedValue = kind } : nil,
                            onOpen: { kind in open(kind) },
                            onRemove: { row in removeRelatedNote(row) }
                        )
                    }
                }
            }
        }
        // Session 38 addendum 5 — id now includes `reloadToken` alongside
        // `date`, so an external bump (see this file's own `reloadToken`
        // comment) forces a fresh reload the same way a real date change
        // always has, without needing a second `.task`/`.onChange` pair.
        .task(id: "\(date.timeIntervalSince1970)_\(reloadToken)") { await load() }
        // Bug fix 2026-07-22 (Session 31) — see the `scenePhase` property's
        // own comment above. Safe to re-read on every foreground: edits are
        // written to disk via `save(_:)` as they happen (same real-time
        // onSave path Session 18's fix already established for this editor),
        // so by the time backgrounding can occur, disk already matches
        // memory — this can't clobber unsaved typing.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await load() }
            }
        }
        // Bug fix 2026-07-25 — the scenePhase reload above only fires on a
        // real foreground transition, and David hit two related failures
        // without one: (1) the home-screen card staying stale even without
        // backgrounding Dayflow, since nothing was actually re-reading the
        // file; (2) worse, typing anything into Dayflow's note after Jot
        // had already written to the same file caused `persistFullNote(prose:)`
        // to reconstruct the whole file from this editor's now-stale
        // in-memory `content`, silently overwriting (destroying) Jot's
        // addition on the very next save. `NoteStore.writeFile`/
        // `appendToDailyNote` both already post `.noteStoreCalendarDidChange`
        // on every write — this editor just wasn't listening for it (only
        // HomeView.swift/NotesView.swift did, elsewhere in the app).
        // Subscribing here closes both gaps: the card refreshes the moment
        // ANY writer touches this date's file, not just on scene
        // transitions, and by the time David's next keystroke triggers a
        // save, `content` already reflects Jot's addition instead of
        // predating it. Skipped while the editor currently has focus —
        // reloading mid-typing would clobber whatever's being actively
        // typed here, which just swaps which side's edit silently wins
        // rather than fixing anything. Doesn't solve true simultaneous
        // editing (typing in both apps at the exact same instant) — that's
        // a real collaborative-merge problem, out of scope for this fix.
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { note in
            guard !isFocused, (note.object as? String) == relativePath else { return }
            Task { await load() }
        }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                // sourceNoteText: content — Session 28 AI-prefill. The Daily Note is
                // one of the two note sources the locked design covers; passing the
                // live in-memory text lets the hand-off buttons on the presented
                // card search it without a re-read from disk.
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
            if let d = peekDate {
                DayflowDailyNotePeekSheet(date: d, onBack: { peekDate = nil })
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
            get: { activeLinkFlow.wrappedValue != nil },
            set: { if !$0 { activeLinkFlow.wrappedValue = nil } }
        )) {
            if let kind = activeLinkFlow.wrappedValue {
                DayflowLinkFlowSheet(
                    initialKind: kind,
                    excludeDailyDate: date,
                    onConfirm: { rowKind, description in
                        addRelatedNote(kind: rowKind, description: description)
                    },
                    onDismiss: { activeLinkFlow.wrappedValue = nil }
                )
            }
        }
        .sheet(item: $activeVisit) { visit in
            NavigationStack {
                DayflowVisitDetailView(visit: visit)
            }
        }
    }

    // MARK: Load / save
    //
    // Same pattern as Trace's NotesView.swift E15 daily-note load/save (strip
    // the "# YYYY-MM-DD" header for editing, re-add it on write) — minus the
    // calendar-panel-preview and clear-note extras that view also has, which
    // Dayflow doesn't need for this pass. Session 38: also splits the
    // "## Related Notes" section out via the shared DayflowRelatedNotesEngine,
    // same as Project Note.

    private func load() async {
        isLoading = true
        let raw = (try? NoteStore.shared.readDailyNote(date: date)) ?? ""
        let stripped = Self.stripDateHeader(raw)
        let (prose, notes) = DayflowRelatedNotesEngine.split(stripped)
        content = prose
        relatedNotes = notes
        isLoading = false
    }

    /// Widened from `private` 2026-07-22 (Session 36) — DayflowDailyNoteSection
    /// now reuses this to strip the header when it reads the note fresh from
    /// disk for the real Share implementation, instead of duplicating the
    /// same regex logic in two places.
    static func stripDateHeader(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.hasPrefix("# "),
              first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return text }
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

    /// Reassembles date header + prose + (if any) the serialized Related
    /// Notes table, and writes the whole thing back. Session 38 — was a
    /// direct `"# \(dateStr)\n\n\(text)"` write of exactly what
    /// MarkdownEditorView handed back; now composed from two pieces of
    /// SwiftUI state (same shape as Project Note's own `persistFullNote`),
    /// so a keystroke-triggered save can no longer wipe out an existing
    /// Related Notes table — `text` here is only ever the prose half.
    private func persistFullNote(prose: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        let dateStr = f.string(from: date)
        var body = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        let table = DayflowRelatedNotesEngine.serialize(relatedNotes)
        if !table.isEmpty {
            if !body.isEmpty { body += "\n\n" }
            body += table
        }
        let fileContent = body.isEmpty ? "" : "# \(dateStr)\n\n\(body)"
        try? NoteStore.shared.writeFile("Calendar/\(dateStr).md", content: fileContent)
    }

    // MARK: Wikilinks — Places + People from the shared NotionService.shared
    // singleton (already shared with Trace per the design plan). Same
    // matching logic as NotesView.swift's own wikiSuggestions/resolveWikiLink,
    // just resolving to DayflowWikiSummaryView instead of the real
    // PlaceDetailView/PersonDetailView sheets.

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
        // Session 38 addition — Daily Note prose previously only recognized
        // Person/Place wikilinks. A Related Notes row pointing at another
        // Daily Note reuses this same resolver when its embedded
        // DayflowWikiSummaryView-style flow needs it, and it costs nothing
        // to also let a hand-typed [[yyyy-MM-dd]] in the note body itself
        // peek the same way Project Note's prose already allows.
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
    // lists/rendering all live in DayflowRelatedNotes.swift).

    private func addRelatedNote(kind: RelatedNoteRow.Kind, description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        relatedNotes.insert(RelatedNoteRow(kind: kind, description: trimmed), at: 0)
        persistFullNote(prose: content)
    }

    private func removeRelatedNote(_ row: RelatedNoteRow) {
        relatedNotes.removeAll { $0.id == row.id }
        persistFullNote(prose: content)
    }

    private func open(_ kind: RelatedNoteRow.Kind) {
        switch kind {
        case .daily(let d):
            peekDate = d
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
