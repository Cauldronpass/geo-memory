import SwiftUI

// MARK: - DayflowNotesView
//
// Reached via Daily Note's third header icon (DayflowDailyNoteSection.swift,
// Session 11, 2026-07-20). One screen doing double duty, per David's own
// framing during the design conversation that preceded this build: a
// keyword/#tag search over NoteStore's Daily/Projects/Places files (ported
// from Trace's own GlobalSearchView in NotesView.swift — same folder scan,
// same token-matching rules, restyled to Dayflow's minimal look), and —
// since a Projects-scope search with nothing typed is really just "browse
// your project notes" — the same screen is also where a new project note
// gets created and where an existing one is opened for view/append
// (DayflowProjectNoteView).
//
// Deliberately does NOT reuse Trace's real GlobalSearchView/NotesView.swift
// UI — same precedent as DayflowWikiSummaryView.swift (Session 5): read the
// same NoteStore data, build a small Dayflow-specific view around it, so
// Trace's own Notes-tab machinery (tag filter chips, promote/move blocks,
// Horizons, document attachments) never has to enter Dayflow's target.
// "Horizons" scope is intentionally left out — it's a Trace weekly/monthly-
// review concept never part of Dayflow's design, no reason to surface it
// here just because the underlying folder scan could technically include it.
//
// Agenda/task search (Things tasks + calendar events) is a separate screen,
// DayflowAgendaSearchView, reached from the top-bar Browse menu instead —
// see that file's header comment and Dayflow-Design-Plan.md "Notes & Agenda
// search" for why these stayed two screens rather than one.
//
// **Daily/Places result rows made tappable — Session 19, 2026-07-20.** David
// found a Daily Note via search ("test wed") and reported it wasn't
// clickable — the original build deliberately left Daily/Places as no-ops
// per this file's own comment ("no dedicated Dayflow detail view exists for
// those yet"), flagged in Session 11's "not done" list. That's no longer
// true: Session 17 built out DayflowWikiSummaryView's Place Notes tab, and
// the full-page Daily Note editor has existed since Session 4/5 — both
// destinations already exist, this was just never wired up. Daily results
// now jump straight to DayflowNoteFullPageView for that exact date (parsed
// from the filename, `Calendar/YYYY-MM-DD.md`); Places results resolve the
// matching `Place` (via `NoteStore.placeNoteFilename` reverse-match against
// `NotionService.shared.places`) and open it in DayflowWikiSummaryView,
// same as tapping a [[Place]] wikilink anywhere else. Project rows were
// already tappable and are unchanged. `selectedDate` is now threaded in from
// ContentView (`$selectedDate`) rather than being its own separate value —
// same "share the one real date, don't seed a copy" fix as
// DayflowNoteFullPageView.swift's own Session 18 header comment — so jumping
// to a Daily search result also moves Agenda/the main Daily Note card to
// that date, consistent with every other date-jump in the app.
//
// **Result metadata + sorting + backlinks — Session 22, 2026-07-21.** Each
// result now shows its modified date (via new `NoteStore.fileModifiedDate(_:)`
// — not created date; Daily Notes only really have one meaningful date
// anyway, and "last edited" is the more useful recency signal for Project/
// Place notes too, per the same precedent the Mentioned In section already
// used). Results are sortable Newest/Oldest/Name (`DayflowNoteSortOrder`,
// DayflowModels.swift — shared with the new DayflowBacklinksView.swift so
// both screens sort identically, per David's explicit ask). A new "link"
// icon per row lazily opens DayflowBacklinksView for just that one note —
// deliberately NOT an eagerly-computed inbound-mention count on every row,
// since that would mean a whole-vault scan per result on every keystroke.
// See DayflowBacklinksView.swift's own header comment for the full reasoning
// and the tap-through dispatch it generalizes from `openResult` below.
//
// **Places/People redesign — Session 25, 2026-07-21.** David's observation:
// the old Places scope only ever found notes living at `Notes/Places/<name>.md`
// — but he writes far more notes that just *mention* a place in passing than
// notes dedicated to a place, so searching "arlington" while looking for a
// place he'd mentioned elsewhere came up empty even though the place (and
// mentions of it) existed. Confirmed direction: stop scanning a folder for
// Places/People entirely — instead search the entity's real **name** against
// `NotionService.shared.places`/`.people` (cheap, already in memory, same
// precedent DayflowWikiSummaryView's own edit fields already read from), and
// tapping a match opens the exact same `DayflowWikiSummaryView` card a
// [[wikilink]] tap opens anywhere else — reusing the Mentioned-In/Backlinks
// machinery Sessions 20-22 already built rather than building a second,
// content-scanning search path for these two scopes.
//
// This also answered a question that came up mid-conversation: what happens
// when you find a place this way that doesn't have a note file yet? David's
// call, after walking through it — he didn't want a "start a note" prompt
// bolted onto the search result itself, because writing a note blind (with
// no address/phone/category in view) isn't what he wants. His answer was
// simpler than anything proposed: just open the place's card like normal.
// Turns out zero new code was needed for this — `placeNotesTab`/
// `personNotesTab` already read a missing note file as empty text and hand it
// straight to an editable `MarkdownEditorView` with a placeholder ("Notes
// about \(place.name)…"), exactly the same as a place that already has a
// note. The redesign's job was only ever to get you TO that card by name —
// the card itself already did the rest.
//
// Added a People scope (didn't exist before — the old design only ever
// covered Places among entities). New Scope also drives a scope-conditional
// action row: "New project note" now only renders on the Projects tab
// (previously rendered unconditionally on every tab — a real bug David
// flagged directly, visible on the Places tab in his screenshot), and Places/
// People each get their own "Add a [Place/Person] in Trace" hand-off button
// (`trace://addplace` / `trace://addperson`, same Session 25 hand-off pattern
// as DayflowWikiSummaryView's "Log a Visit in Trace") — CRM-light boundary
// held, this view still never creates a Notion place/person itself.
//
// **Pinned Days section, added 2026-07-23 (Session 38 addendum 9).**
// Companion to Session 37's flagged-first Project Notes ordering, for Daily
// Notes' own pin toggle (Session 38 addendum 7, DayflowFlagStore reused
// unchanged). Deliberately NOT the same "flagged-first" treatment as Project
// Notes, since there's no existing browsable list of every Daily Note to
// float pinned ones to the top of — Daily scope has only ever offered search,
// never a full browse (there could be hundreds of Calendar files; nobody
// wants to scroll all of them). So this is a new, separate "PINNED DAYS"
// section instead, showing only the (presumably short) list of days David
// has actually pinned — same idea as Project Notes' pin, adapted to the fact
// Daily has no base list to sort. Shows on both `.all` and `.daily` scopes,
// same as Project Notes shows on both `.all` and `.projects`; renders nothing
// when no days are pinned yet, so a fresh install / nobody's used the pin
// feature yet looks identical to before this existed.

struct DayflowNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Binding var selectedDate: Date
    /// Set by `dayflow://note?path=Notes/Projects/…` so the screen opens straight
    /// into a project instead of its browse list (E35, 2026-07-29). Defaulted, so
    /// every existing `DayflowNotesView(selectedDate:)` call still compiles.
    var initialProjectTitle: String? = nil
    @State private var showDailyNote = false
    @State private var wikiLinkTarget: WikiLinkTarget? = nil

    private enum Scope: String, CaseIterable, Identifiable {
        case all = "All", daily = "Daily", projects = "Projects", places = "Places", people = "People"
        /// Added 2026-07-29. Endeavors are notes in the shared pool like any
        /// other, but they carry frontmatter and are browsed by imminence
        /// rather than searched by name — so this scope renders its own list
        /// (`DayflowEndeavorListSection`) instead of search results.
        case endeavors = "Endeavors"
        var id: String { rawValue }

        /// Daily/Project folders scanned by file content — unchanged mechanism,
        /// see this file's original header comment. Places/People are NOT here
        /// any more — see `includesPlaces`/`includesPeople` below and this
        /// file's Session 25 header addendum for why.
        var noteFolders: [(label: String, path: String)] {
            switch self {
            // Endeavors added to `.all` on 2026-07-30. David: *"on the all
            // screen i only see the project notes even though i have a japan
            // endeavor note."* Correct — the scope was written before Endeavors
            // existed and never revisited, so "All" quietly meant "days and
            // projects". A scope called All that omits a whole note type is worse
            // than no All at all, because it answers "not there" convincingly.
            case .all:      return [("Daily", "Calendar"),
                                    ("Projects", "Notes/Projects"),
                                    ("Endeavors", "Notes/Endeavors")]
            case .daily:    return [("Daily", "Calendar")]
            case .projects: return [("Projects", "Notes/Projects")]
            case .places, .people, .endeavors: return []
            }
        }
        var includesPlaces: Bool { self == .all || self == .places }
        var includesPeople: Bool { self == .all || self == .people }
    }

    private struct SearchResult: Identifiable {
        let id = UUID()
        let subfolder: String
        let displayName: String
        let scopeLabel: String
        let snippet: String
        /// Full vault-relative path, e.g. "Notes/Projects/P018-Title.md" — added
        /// Session 22 (search result metadata + sorting) for two things: the
        /// modified-date sort/display below, and as the `excludePath` a tapped
        /// result's own DayflowBacklinksView passes to findWikilinkMentions so a
        /// note never lists itself as "mentioning itself." For a Place/Person
        /// result (Session 25) this is the note file's path whether or not that
        /// file actually exists yet — fine for both uses: a missing file just
        /// means `modified` below is nil and `excludePath` never matches a real
        /// backlink (nothing links to a file that isn't there).
        let relativePath: String
        /// Added Session 22 — `NoteStore.fileModifiedDate(_:)`, same
        /// `.contentModificationDateKey` call `findWikilinkMentions` already uses
        /// elsewhere. Shown on the row and drives the Newest/Oldest sort options.
        let modified: Date?
        /// Added Session 25 — set only for Place/People results, found by
        /// entity name rather than by scanning a note file. Tapping the row
        /// opens this directly (the exact same card a [[wikilink]] tap opens
        /// anywhere else in the app), no file needs to exist for that to work —
        /// see this file's Session 25 header addendum for the full reasoning.
        let wikiTarget: WikiLinkTarget?
    }

    /// Identifies which search result's backlinks to show — drives
    /// `.sheet(item:)` below. Added Session 22 alongside DayflowBacklinksView.swift.
    private struct BacklinksTarget: Identifiable {
        let id = UUID()
        let noteTitle: String
        let lookupName: String
        let excludePath: String
    }

    /// One pinned Calendar day — Session 38 addendum 9, see this file's
    /// header comment. `relativePath` is the same "Calendar/yyyy-MM-dd.md"
    /// key `DayflowFlagStore` is keyed on everywhere else in this app.
    private struct PinnedDay: Identifiable {
        let id: String
        let date: Date
        let relativePath: String
    }

    @State private var searchText = ""
    @State private var scope: Scope = .all
    @State private var results: [SearchResult] = []
    @State private var sortOrder: DayflowNoteSortOrder = .newest
    @State private var backlinksTarget: BacklinksTarget? = nil
    @State private var projectNames: [String] = []
    @State private var selectedProjectTitle: String? = nil
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""
    /// Sort for the Projects browse list (separate from `sortOrder`, which is
    /// search-results-only) — David asked for a sort option here too. Default
    /// `.name` matches what the list already looked like before this existed
    /// (`listFiles` returns alphabetical), so turning this on doesn't silently
    /// reorder anyone's list on first launch.
    @State private var projectSortOrder: DayflowNoteSortOrder = .name
    /// Projects moved to `Notes/Projects/Archive/`.
    @State private var archivedProjectNames: [String] = []
    /// Starts closed. It is history, not a second list.
    @State private var showArchivedProjects = false
    /// One-shot. Without it, `onAppear` re-firing after the project view's
    /// `onBack` set `selectedProjectTitle = nil` would bounce straight back in,
    /// and the Back button would appear broken.
    /// Which routed title has already been applied.
    ///
    /// **Was a `Bool` one-shot, and that was the bug.** `DayflowNotesView` keeps
    /// its identity across presentations of the cover, so the flag stayed `true`
    /// after the first routed open and every later
    /// `dayflow://note?path=Notes/Projects/…` was ignored — the screen appeared,
    /// on the all-notes list, which is exactly what David saw twice.
    ///
    /// Keyed on the value instead: a *different* title is a different route and
    /// gets consumed, the same title twice does not re-apply. Same class as the
    /// 2026-07-30 regression noted in `ContentView.onOpenNotes` — a one-shot
    /// route has to be consumed, and "consumed" means "this one", not "any".
    @State private var consumedInitialProject: String? = nil
    /// Tags found on the notes in the current scope, most-used first. Rebuilt when
    /// the scope changes and when the screen appears; see `loadTagCounts`.
    @State private var tagCounts: [(tag: String, count: Int)] = []

    private var sortedResults: [SearchResult] {
        switch sortOrder {
        case .newest: return results.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .oldest: return results.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        case .name:   return results.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    private let noteStore = NoteStore.shared

    var body: some View {
        Group {
            if let title = selectedProjectTitle {
                DayflowProjectNoteView(title: title, onBack: {
                    selectedProjectTitle = nil
                    loadProjectNames()
                })
            } else {
                mainBody
            }
        }
        .alert("New Project Note", isPresented: $showNewProjectAlert) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") { createProject() }
        }
        .onChange(of: searchText) { _, _ in runSearch() }
        .onChange(of: scope) { _, _ in
            runSearch()
            loadTagCounts()
        }
        // Recount when ANY note is written, wherever from.
        //
        // `onAppear` alone was not enough: an Endeavor opens as a sheet ON TOP of
        // this screen, and dismissing a sheet does not re-fire the parent's
        // `onAppear`. So a tag removed there left its chip sitting in this row
        // until the whole screen was rebuilt — which is what David saw, and why
        // leaving Dayflow's notes screen entirely and coming back "fixed" it.
        //
        // Cheap enough to do on every write: ~40 small files today, and the editor
        // debounces its saves, so this is not per-keystroke.
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreFileDidChange)) { _ in
            loadTagCounts()
        }
        .onAppear {
            loadProjectNames()
            // Also on every appearance, not only on scope change: a tag added on
            // the note screen and then backed out of would otherwise not show up
            // until the scope was toggled.
            loadTagCounts()
            applyRoutedProject()
        }
        // **`.onAppear` alone was the whole bug, and the screenshot named it.**
        //
        // The Endeavor screen is reached *through* this one, so when a note
        // wikilink there routes to `dayflow://note?path=Notes/Projects/…`, this
        // view is **already presented**. `showNotes = true` is then a no-op, no
        // appearance happens, and `initialProjectTitle` changes with nothing
        // watching it. The Endeavor cover drops away and reveals the notes list
        // that was underneath all along — which reads exactly like "it brought me
        // to the all notes page" and is why two fixes aimed at *navigation* both
        // missed. Nothing navigated. Nothing needed to.
        //
        // The value is the event. Watch the value.
        .onChange(of: initialProjectTitle) { _, _ in applyRoutedProject() }
        .fullScreenCover(isPresented: $showDailyNote) {
            DayflowNoteFullPageView(selectedDate: $selectedDate)
        }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target)
            }
        }
        .sheet(item: $backlinksTarget) { target in
            NavigationStack {
                DayflowBacklinksView(
                    noteTitle: target.noteTitle,
                    lookupName: target.lookupName,
                    excludePath: target.excludePath,
                    selectedDate: $selectedDate
                )
            }
        }
    }

    private var mainBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            scopeRow
            scopeActionRow
            tagFilterRow
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        browseContent
                    } else if results.isEmpty {
                        Text("No notes match \"\(searchText)\".")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    } else {
                        resultsHeader
                        ForEach(sortedResults) { r in resultRow(r) }
                    }
                }
                // Card-width fix 2026-07-24 — `.dayflowCard()` below just
                // backgrounds whatever size this ScrollView reports; it never
                // forces full width itself. Projects/All/actual search results
                // always looked full-width because some row in them (e.g.
                // `projectNotesSection`'s header HStack Spacer) happened to push
                // the VStack out to the full proposed width. Places, People, and
                // Daily-with-no-pinned-days only ever show one short line of hint
                // text with nothing pushing outward, so the VStack (and the card
                // wrapped around it) shrank to hug just that text — the "half the
                // screen" card David flagged, comparing a Places screenshot
                // against a Projects one. This `.frame` makes the VStack always
                // claim full width regardless of what's inside it; no visible
                // change for the cases that were already full width.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            // Skin fix 2026-07-22 (Session 31) — wraps the scrollable list
            // in the same card treatment Agenda/Daily Note use on the main
            // screen, so it doesn't sit as a bare list directly on the warm
            // background below. See DayflowSkin.swift.
            .dayflowCard()
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        // Skin fix 2026-07-22 (Session 31) — same warm gradient as the main
        // screen. David flagged this whole screen (reached via Daily Note's
        // Notes & Projects icon) as visually inconsistent with the home
        // screen — this, the pill colors below, and the header font were
        // the three concrete causes. See DayflowSkin.swift.
        .dayflowSkinBackground()
    }

    // MARK: Header — matches DayflowAnytimeView's Browse-destination header

    private var header: some View {
        // Back by reversing the gesture that got you here: Home swipes LEFT to
        // reach Notes, so Notes swipes RIGHT to go back. See the matching
        // comment in `DayflowNotesInboxView`. Header-confined for the same
        // reason, and kept identical here even though this screen has no
        // `.swipeActions` of its own — two screens whose back-swipe works in
        // different places would read as flakiness rather than as two rules.

        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Spacer()
            // Skin fix 2026-07-22 (Session 31) — was .custom("Georgia", ...),
            // the same capital-J mismatch already fixed on the home screen's
            // date headline (Session 29/30) but never carried over here. See
            // DayflowSkin.swift.
            Text("Notes").font(.dayflowSerif(20))
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let h = value.translation.width
                    guard h > 50,
                          h > abs(value.translation.height) * 1.5 else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dismiss()
                }
        )
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notes, #tags…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// Applies a routed project title, at most once per distinct title.
    ///
    /// Called from both `.onAppear` and `.onChange(of: initialProjectTitle)`:
    /// a route can arrive either before this screen exists or while it is already
    /// on screen, and only one of those produces an appearance.
    private func applyRoutedProject() {
        guard let initialProjectTitle, initialProjectTitle != consumedInitialProject else { return }
        consumedInitialProject = initialProjectTitle
        selectedProjectTitle = initialProjectTitle
    }

    private var scopeRow: some View {
        // Horizontal scroller since 2026-07-29. Five pills fitted a phone
        // width; Endeavors made six and the labels started truncating
        // mid-word. `.scrollClipDisabled` so the active pill's shadow is not
        // sheared off at the edges.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
            ForEach(Scope.allCases) { s in
                Button { scope = s } label: {
                    Text(s.rawValue)
                        // Skin fix 2026-07-22 (Session 31) — was a solid blue
                        // capsule + white text, the same pre-skin pattern
                        // fixed on the home screen's Yesterday/Today/Tomorrow
                        // pill (Session 30 addendum), never carried over
                        // here. Now matches that same white/near-black active
                        // + muted inactive language. See DayflowSkin.swift.
                        .font(.system(size: 11.5, weight: scope == s ? .bold : .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(scope == s ? Color.white : Color.dayflowInk.opacity(0.055), in: Capsule())
                        .foregroundStyle(scope == s ? Color.dayflowInk : Color.dayflowPillInactiveText)
                        .shadow(color: .black.opacity(scope == s ? 0.10 : 0), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .padding(.bottom, 12)
    }

    // MARK: Scope action row — Session 25
    //
    // Was a single unconditional `newProjectRow` (rendered on every tab,
    // including Places — the exact bug David flagged from a screenshot).
    // Now scope-conditional: Projects keeps "New project note" (unchanged,
    // still the only in-app entity creation this view does — CRM-light
    // boundary, Places/People never get an in-app creation button, only a
    // hand-off to Trace, which is the only place actually allowed to create
    // a Notion place/person record).

    @ViewBuilder
    private var scopeActionRow: some View {
        switch scope {
        case .projects: newProjectRow
        case .places:   traceHandoffRow(title: "Add a Place in Trace", urlHost: "addplace")
        case .people:   traceHandoffRow(title: "Add a Person in Trace", urlHost: "addperson")
        // 2026-07-27 — the All tab renders `projectNotesSection` too (see
        // `browseContent` below), so it needs the create button that belongs
        // with that list. Session 25's scope-conditional rewrite correctly
        // stopped this row from rendering on Places/People, but it also
        // dropped it from All, where the project list still shows. David hit
        // exactly that: full project list on the default tab, no way to add
        // one, and no reason to guess the button was hiding behind the
        // Projects pill. Daily stays empty (no browse list, nothing to
        // create there).
        case .all:      newProjectRow
        case .daily:    EmptyView()
        // The Endeavors list carries its own New button, inside the section, so
        // it does not need one out here as well.
        case .endeavors: EmptyView()
        }
    }

    private var newProjectRow: some View {
        Button {
            newProjectName = ""
            showNewProjectAlert = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                Text("New project note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.blue.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// Trace hand-off button — Session 25, same visual language as
    /// `newProjectRow` (so Places/People don't look like a lesser tab) but a
    /// distinct icon (`arrow.up.forward.app`) signaling this leaves Dayflow,
    /// same convention DayflowWikiSummaryView's/DayflowVisitDetailView's own
    /// Trace hand-off buttons use.
    private func traceHandoffRow(title: String, urlHost: String) -> some View {
        Button {
            var comps = URLComponents()
            comps.scheme = "trace"
            comps.host = urlHost
            if let url = comps.url { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.blue)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.blue.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: Browse (no search text). Projects (and the All tab) keep the
    // existing project browse list. Daily/Places/People show a short hint
    // instead — Session 25: this used to show the Projects browse list
    // unconditionally regardless of scope too (same class of bug as
    // `newProjectRow`'s old unconditional rendering), just less visible since
    // it only showed up with an empty search box.
    //
    // **Flagged-first ordering, added 2026-07-22 (Session 37).** David flagged
    // that this list may grow long and wanted a way to pin important notes to
    // the top — see DayflowFlagStore.swift for the storage design. `listFiles`
    // already returns `projectNames` alphabetically; `sortedProjectNames`
    // layers "flagged first" on top of that without touching the underlying
    // order otherwise.
    //
    // **Sort option, added 2026-07-22 (Session 37 addendum 3).** David asked
    // for a sort control on this list too, same as search results already
    // have. Reuses the existing `DayflowNoteSortOrder` (Newest/Oldest/Name) —
    // same enum, same Menu pattern as `resultsHeader` below — rather than a
    // second, differently-shaped sort type. Pinned notes still float to the
    // top regardless of sort choice; the chosen order only decides ranking
    // within the pinned group and within the unpinned group.

    private var sortedProjectNames: [String] {
        let store = DayflowFlagStore.shared
        let flagged = projectNames.filter { store.isFlagged(projectNotePath($0)) }
        let unflagged = projectNames.filter { !store.isFlagged(projectNotePath($0)) }
        return applyProjectSort(flagged) + applyProjectSort(unflagged)
    }

    private func applyProjectSort(_ names: [String]) -> [String] {
        switch projectSortOrder {
        case .name:
            return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case .newest:
            return names.sorted { projectModifiedDate($0) > projectModifiedDate($1) }
        case .oldest:
            return names.sorted { projectModifiedDate($0) < projectModifiedDate($1) }
        }
    }

    private func projectModifiedDate(_ name: String) -> Date {
        noteStore.fileModifiedDate(projectNotePath(name)) ?? .distantPast
    }

    private func projectNotePath(_ name: String) -> String { "Notes/Projects/\(name).md" }

    /// Live-computed, same pattern as DayflowCalendarBrowseView's own
    /// `pinnedDates` (Session 38 addendum 8) — reads straight off
    /// `DayflowFlagStore.shared` rather than caching in `@State`, so pinning/
    /// unpinning from the card, full page, or right here all show up
    /// immediately without a manual reload. Filtered to "Calendar/"-prefixed
    /// paths only, so a Project Note's own flagged path never leaks in here.
    /// Sorted newest day first — unlike Project Notes' name-default sort, a
    /// pinned-days list reads more usefully as "most recent pin at the top."
    private var pinnedDays: [PinnedDay] {
        let calendarPrefix = "Calendar/"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let days = DayflowFlagStore.shared.flaggedAt.keys.compactMap { path -> PinnedDay? in
            guard path.hasPrefix(calendarPrefix), path.hasSuffix(".md") else { return nil }
            let stem = String(path.dropFirst(calendarPrefix.count).dropLast(3))
            guard let parsed = formatter.date(from: stem) else { return nil }
            return PinnedDay(id: path, date: parsed, relativePath: path)
        }
        return days.sorted { $0.date > $1.date }
    }

    /// Same "yyyy-MM-dd · Weekday" format `resultTitle(for:)` already uses
    /// for Calendar search results, kept as its own helper here since this
    /// section has no `SearchResult` to hand that function.
    private func pinnedDayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        let stem = f.string(from: date)
        let weekday = DateFormatter()
        weekday.dateFormat = "EEEE"
        return "\(stem) · \(weekday.string(from: date))"
    }

    @ViewBuilder
    private var pinnedDaysSection: some View {
        if !pinnedDays.isEmpty {
            Text("PINNED DAYS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ForEach(pinnedDays) { day in
                pinnedDayRow(day)
            }
        }
    }

    /// Two independent tap targets, same reasoning as `projectRow` below —
    /// the pin toggle can't nest inside the row's own navigation Button.
    /// Every row here is, by definition, already pinned, so the pin icon is
    /// always the filled state and tapping it only ever unpins.
    @ViewBuilder
    private func pinnedDayRow(_ day: PinnedDay) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedDate = day.date
                showDailyNote = true
            } label: {
                HStack {
                    Text(pinnedDayLabel(day.date)).font(.system(size: 13.5)).foregroundStyle(.primary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Button {
                DayflowFlagStore.shared.toggleFlag(day.relativePath)
            } label: {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dayflowInk)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unpin \(pinnedDayLabel(day.date))")
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        Divider()
    }

    @ViewBuilder
    private var projectNotesSection: some View {
        if !projectNames.isEmpty {
            HStack {
                Text("PROJECT NOTES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(DayflowNoteSortOrder.allCases) { order in
                        Button {
                            projectSortOrder = order
                        } label: {
                            if projectSortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(projectSortOrder.rawValue)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
            ForEach(sortedProjectNames, id: \.self) { name in
                projectRow(name)
            }
            archivedProjectsSection
        } else {
            Text("No project notes yet — tap \"New project note\" above to start one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
            // Also here: archiving the LAST project would otherwise take the only
            // route to the archive away with it.
            archivedProjectsSection
        }
    }

    // MARK: Tag filter
    //
    // David's choice over showing tags on every row: *"yes lets filter tags
    // only."* The reasoning behind that choice is worth keeping — a tag column on
    // every row repeats itself (every trip note tagged `#travel`) so it costs
    // attention on every row while telling you nothing. A chip row answers "what
    // is in here" once, at the top.
    //
    // **Tapping a chip runs the search that already exists.** `runSearch` has
    // understood `#tag` tokens since Session 25, so this sets `searchText` rather
    // than adding a second filtering path — one list, one predicate, no chance of
    // the chip row and the search box disagreeing.
    //
    // Asymmetry worth knowing, in the generous direction: **chips come from the
    // canonical tag line** (the same tags the pills show), while **tapping matches
    // `#tag` anywhere in a note**. So a tag typed mid-prose can appear in results
    // without ever producing a chip. Deliberate — the chips reflect what you
    // assigned on purpose; the search finds everything that mentions it.
    //
    // Shown during search as well as browse, so the active chip is the way back
    // out. Hidden entirely when the scope has no tags, rather than sitting there
    // as an empty band.

    @ViewBuilder
    private var tagFilterRow: some View {
        if !tagCounts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tagCounts, id: \.tag) { entry in
                        let active = searchText.trimmingCharacters(in: .whitespaces)
                            .caseInsensitiveCompare("#\(entry.tag)") == .orderedSame
                        Button {
                            // Tapping the active chip clears it. Without this the
                            // only way out of a tag filter would be to empty the
                            // search box, which is not where the eye is.
                            searchText = active ? "" : "#\(entry.tag)"
                        } label: {
                            HStack(spacing: 4) {
                                Text("#\(entry.tag)")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(entry.count)")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .opacity(0.65)
                            }
                            .foregroundStyle(active ? .white : Color(uiColor: .systemPurple))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(active ? Color(uiColor: .systemPurple)
                                               : Color(uiColor: .systemPurple).opacity(0.12),
                                        in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            // So the active chip's fill is not sheared at the edge of the scroll
            // view — same fix the six scope pills needed on 2026-07-29.
            .scrollClipDisabled()
        }
    }

    /// Counts the canonical tags across the scope's folders.
    ///
    /// A full read of every file in scope, deliberately: 31 day notes, 4 projects
    /// and 1 Endeavor is 164KB today, and an index cached on anything other than a
    /// fresh read is how four stale-read bugs happened in two days. Revisit if the
    /// vault ever grows enough for this to be felt — the honest trigger is a
    /// visible pause on opening this screen, not a guess now.
    ///
    /// **Project notes need their Related Notes table stripped first.** The table
    /// is appended after the prose when the file is composed, so the last line of
    /// the FILE is a table row rather than the tag line, and parsing the raw file
    /// would find no tags at all on exactly the notes most likely to have them.
    /// Endeavor notes need their frontmatter stripped for the mirror-image reason.
    private func loadTagCounts() {
        var counts: [String: Int] = [:]

        for (_, path) in scope.noteFolders {
            for filename in (try? noteStore.listFiles(in: path)) ?? [] {
                guard filename.hasSuffix(".md"),
                      let raw = try? noteStore.readFile("\(path)/\(filename)")
                else { continue }

                let prose: String
                switch path {
                case "Notes/Endeavors":
                    prose = EndeavorStore.splitFrontmatter(raw).1
                case "Notes/Projects":
                    prose = DayflowRelatedNotesEngine.split(raw).prose
                default:
                    prose = raw
                }

                for tag in NoteTagLine.parse(prose) {
                    counts[tag.lowercased(), default: 0] += 1
                }
            }
        }

        tagCounts = counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.tag < $1.tag : $0.count > $1.count }
    }

    // `@ViewBuilder` below is REQUIRED: this body is a `switch` whose cases produce
    // different view types, and several produce more than one view. Without it the
    // compiler says "no return statements in its body from which to infer an
    // underlying type", then a cascade of "expression of type 'some View' is
    // unused" — which is exactly what happened on 2026-07-30, when inserting a new
    // property above this one stranded the attribute on the wrong declaration and
    // gave it two result builders at once.
    //
    // The comment sits ABOVE the attribute on purpose. Comments between an
    // attribute and its declaration compile fine, but they look like the mistake
    // this comment exists to prevent.
    @ViewBuilder
    private var browseContent: some View {
        switch scope {
        case .all:
            pinnedDaysSection
            // Same omission as `noteFolders` above: browsing All showed days and
            // projects only. Endeavors go ABOVE projects because they are sorted
            // by imminence — what is running or about to — where the project list
            // is alphabetical and answers a different question.
            Text("ENDEAVORS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .padding(.top, pinnedDays.isEmpty ? 4 : 14)
                .padding(.bottom, 6)
            DayflowEndeavorListSection()
            projectNotesSection
        case .projects:
            projectNotesSection
        case .daily:
            pinnedDaysSection
            Text("Search for a date, or open a day from the main Agenda.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, pinnedDays.isEmpty ? 24 : 12)
        case .places:
            Text("Search for a place by name.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        case .people:
            Text("Search for a person by name.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        case .endeavors:
            DayflowEndeavorListSection()
        }
    }

    @ViewBuilder
    private func projectRow(_ name: String) -> some View {
        // Pin toggle is a separate tap target from the row's own navigation
        // button, not nested inside it — nesting two Buttons is the class of
        // bug DayflowAgendaSection's row already worked around (separate
        // checkbox Button beside a `.onTapGesture` title, not one Button
        // wrapping another) — same pattern here.
        let path = projectNotePath(name)
        let flagged = DayflowFlagStore.shared.isFlagged(path)
        HStack(spacing: 8) {
            Button { selectedProjectTitle = name } label: {
                HStack {
                    Text(name).font(.system(size: 13.5)).foregroundStyle(.primary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Button {
                DayflowFlagStore.shared.toggleFlag(path)
            } label: {
                Image(systemName: flagged ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(flagged ? Color.dayflowInk : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(flagged ? "Unpin \(name)" : "Pin \(name)")
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        // LONG PRESS, NOT SWIPE. This list is a VStack inside a ScrollView, not a
        // `List`, so `.swipeActions` does not apply — the same situation that made
        // Trace's people list need a hand-rolled gesture. That one is justified
        // there: deleting a person from a long list is frequent and sweeping.
        // Archiving a project is rare and deliberate, and `.contextMenu` is native,
        // needs no gesture arbitration, and cannot swallow the row's own tap.
        .contextMenu {
            Button {
                if noteStore.archiveProject(name: name) { loadProjectNames() }
            } label: {
                Label("Archive Project", systemImage: "archivebox")
            }
        }
        Divider()
    }

    // MARK: Archived projects
    //
    // In the app on David's explicit call — *"yes id like to be able to reach it in
    // the app"* — rather than only as a folder in Obsidian. Collapsed by default,
    // under the live list, with a count so it is honest about being non-empty
    // without spending space on what is in it.

    @ViewBuilder
    private var archivedProjectsSection: some View {
        if !archivedProjectNames.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showArchivedProjects.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showArchivedProjects ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Archived").font(.system(size: 11, weight: .medium))
                    Text("\(archivedProjectNames.count)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showArchivedProjects {
                ForEach(archivedProjectNames, id: \.self) { name in
                    HStack(spacing: 8) {
                        Text(name).font(.system(size: 13.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            if noteStore.unarchiveProject(name: name) { loadProjectNames() }
                        } label: {
                            Text("Restore").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
            }
        }
    }

    // MARK: Results header (count + sort — Session 22, search result metadata + sorting)

    private var resultsHeader: some View {
        HStack {
            Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(DayflowNoteSortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        if sortOrder == order {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(sortOrder.rawValue)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: Result row (search mode)
    //
    // Two independent tap targets, not a single wrapping Button — SwiftUI
    // doesn't handle a Button nested inside another Button's label well (the
    // inner tap can fire the outer too), so the row content uses
    // .onTapGesture and the trailing "Links" icon is its own sibling Button.
    // Added Session 22: modified-date caption, and the Links button that
    // lazily opens DayflowBacklinksView for just this one result (see that
    // file's header comment for why this stays lazy/per-row rather than an
    // eagerly-computed inbound count on every row).

    @ViewBuilder
    private func resultRow(_ r: SearchResult) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(resultTitle(for: r)).font(.system(size: 13.5)).foregroundStyle(.primary)
                    Spacer()
                    Text(r.scopeLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.75)))
                }
                if !r.snippet.isEmpty {
                    Text(r.snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                if let modified = r.modified {
                    Text(modified.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { openResult(r) }

            Button {
                openBacklinks(for: r)
            } label: {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        Divider()
    }

    /// Daily results show as a bare `yyyy-MM-dd` (`r.displayName`, still the
    /// raw filename stem `openResult` below parses back into a `Date`) —
    /// David asked for the day of week alongside it so a search result reads
    /// at a glance instead of needing the date worked out. Display-only: does
    /// NOT touch `r.displayName` itself, since `openResult`'s date-jump and
    /// `openBacklinks`' lookup both still depend on that exact "yyyy-MM-dd"
    /// string.
    private func resultTitle(for r: SearchResult) -> String {
        guard r.subfolder == "Calendar" else { return r.displayName }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: r.displayName) else { return r.displayName }
        let weekday = DateFormatter()
        weekday.dateFormat = "EEEE"
        return "\(r.displayName) · \(weekday.string(from: date))"
    }

    /// Dispatches a tapped search result to whichever detail view already
    /// exists for its subfolder — see this file's Session 19 header comment.
    /// Projects: unchanged, sets `selectedProjectTitle` (handled by `body`'s
    /// own `Group` switch). Calendar (Daily): parses the filename back into a
    /// `Date` (same "yyyy-MM-dd" / en_US_POSIX / TimeZone.current pattern
    /// `DayflowDailyNoteEditor` uses to go the other direction) and opens
    /// `DayflowNoteFullPageView` on that date via the shared `selectedDate`
    /// binding. Places/People (Session 25): `r.wikiTarget` is already the real
    /// `Place`/`Person` — set directly by `runSearch` from the entity-name
    /// match, no filename round-trip needed any more. If a Calendar date
    /// fails to parse (shouldn't happen — a round-trip of a value this view
    /// itself produced), this silently no-ops rather than crashing; nothing
    /// else in the row implies a destination exists in that case.
    private func openResult(_ r: SearchResult) {
        if let target = r.wikiTarget {
            wikiLinkTarget = target
            return
        }
        switch r.subfolder {
        case "Notes/Projects":
            selectedProjectTitle = r.displayName
        case "Calendar":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: r.displayName) {
                selectedDate = parsed
                showDailyNote = true
            }
        default:
            break
        }
    }

    /// Opens DayflowBacklinksView for one result — Session 22. Simplified in
    /// Session 25: `r.displayName` is now always the entity's/note's real
    /// title for every scope (Places/People results are built straight from
    /// `place.name`/`person.name`, not a filesystem-sanitized filename any
    /// more — see `runSearch`), so `lookupName` no longer needs a per-scope
    /// special case to recover the real name.
    private func openBacklinks(for r: SearchResult) {
        backlinksTarget = BacklinksTarget(noteTitle: r.displayName, lookupName: r.displayName, excludePath: r.relativePath)
    }

    // MARK: Data

    private func loadProjectNames() {
        let files = (try? noteStore.listFiles(in: "Notes/Projects")) ?? []
        projectNames = files.map { $0.replacingOccurrences(of: ".md", with: "") }
        archivedProjectNames = noteStore.listArchivedProjects()
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = "Notes/Projects/\(name).md"
        let existing = (try? noteStore.readFile(path)) ?? ""
        if existing.isEmpty {
            try? noteStore.writeFile(path, content: "# \(name)\n\n")
        }
        loadProjectNames()
        newProjectName = ""
        selectedProjectTitle = name
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { results = []; return }
        let tokens = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let tagTokens = tokens.filter { $0.hasPrefix("#") }.map { String($0.dropFirst()).lowercased() }
        let plainTokens = tokens.filter { !$0.hasPrefix("#") }.map { $0.lowercased() }

        var found: [SearchResult] = []

        // Daily + Projects — unchanged folder-content scan.
        for (label, path) in scope.noteFolders {
            let files = (try? noteStore.listFiles(in: path)) ?? []
            for filename in files {
                guard filename.hasSuffix(".md") else { continue }
                let content = (try? noteStore.readFile("\(path)/\(filename)")) ?? ""
                let contentLower = content.lowercased()
                let nameLower = filename.replacingOccurrences(of: ".md", with: "").lowercased()

                let tagsMatch = tagTokens.allSatisfy { contentLower.contains("#\($0)") }
                let plainMatch = plainTokens.allSatisfy { nameLower.contains($0) || contentLower.contains($0) }
                guard tagsMatch && plainMatch else { continue }

                let relativePath = "\(path)/\(filename)"
                // MATCH on the whole file, SNIPPET from the body only.
                //
                // Endeavor notes carry frontmatter, so a snippet taken from the
                // raw file reads "id: japan-2026 name: Japan type: Travel" — true,
                // and useless as a search result. Matching still uses the whole
                // file on purpose: `destination: Kyoto` and `type: Travel` are
                // genuinely worth finding.
                let body = path == "Notes/Endeavors"
                    ? EndeavorStore.splitFrontmatter(content).1
                    : content
                found.append(SearchResult(
                    subfolder: path,
                    displayName: filename.replacingOccurrences(of: ".md", with: ""),
                    scopeLabel: label,
                    snippet: snippet(from: body, tokens: plainTokens + tagTokens.map { "#\($0)" }),
                    relativePath: relativePath,
                    modified: noteStore.fileModifiedDate(relativePath),
                    wikiTarget: nil
                ))
            }
        }

        // Places + People — Session 25: entity-name search, in memory, no
        // folder scan. Tag tokens don't apply to an entity's name, so a
        // query that's tags-only (no plain tokens) matches nothing here,
        // same as it would against a folder with no matching content.
        if scope.includesPlaces, !plainTokens.isEmpty {
            for place in NotionService.shared.places {
                let nameLower = place.name.lowercased()
                guard plainTokens.allSatisfy({ nameLower.contains($0) }) else { continue }
                let relativePath = "Notes/Places/\(noteStore.placeNoteFilename(for: place.name)).md"
                found.append(SearchResult(
                    subfolder: "Notes/Places",
                    displayName: place.name,
                    scopeLabel: "Places",
                    snippet: [place.category, place.city].filter { !$0.isEmpty }.joined(separator: " · "),
                    relativePath: relativePath,
                    modified: noteStore.fileModifiedDate(relativePath),
                    wikiTarget: .place(place)
                ))
            }
        }
        if scope.includesPeople, !plainTokens.isEmpty {
            for person in NotionService.shared.people {
                let nameLower = person.name.lowercased()
                guard plainTokens.allSatisfy({ nameLower.contains($0) }) else { continue }
                let relativePath = "Notes/People/\(person.name).md"
                found.append(SearchResult(
                    subfolder: "Notes/People",
                    displayName: person.name,
                    scopeLabel: "People",
                    snippet: person.relationship ?? "",
                    relativePath: relativePath,
                    modified: noteStore.fileModifiedDate(relativePath),
                    wikiTarget: .person(person)
                ))
            }
        }

        results = found
    }

    private func snippet(from content: String, tokens: [String]) -> String {
        let lines = content.components(separatedBy: "\n")
        for token in tokens where !token.isEmpty {
            if let line = lines.first(where: { $0.lowercased().contains(token) }) {
                return String(line.trimmingCharacters(in: .whitespaces).prefix(120))
            }
        }
        return String((lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "").prefix(120))
    }
}
