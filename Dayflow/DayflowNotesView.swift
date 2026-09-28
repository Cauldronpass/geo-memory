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
//
// **The search mode is gone - D513, 2026-09-27 (Session 112).** Nothing ever
// set `searchActive` true after the Session 77 redesign moved search behind a
// header icon and D159 retired the icon, so the whole branch - search field,
// scope pills, tag chips, results, sort, backlinks - had been unreachable for
// months (D471). Removed with everything that only it reached: `browseContent`
// and the pinned-days list (never called; pinned days live on Today's day
// list, the month unfold and In Play), the Trace hand-off row, and
// `loadTagCounts`, which still read every note on each appearance and each
// write to fill chips nobody could see. Search now lives in Quick Find.
// Most of the history above describes that removed machinery.

/// Where Quick Find sends a Records destination (D480).
///
/// Quick Find's browse list gained People, Places, Endeavors and Notes, and a
/// row there has to land on this screen at the right segment. One value, set
/// by the card and drained here; `DayflowRootView` watches it to select the
/// tab. The same shape as `DayflowQuickFindRouter.pendingDestination`, which
/// does this job for the Today screen's destinations.
///
/// **Drained, not read twice.** The lesson is written out on
/// `DayflowRootView.tab(for:)`: two views observing one pending value and both
/// firing is how a route gets consumed out from under the thing deciding where
/// to send it. The root only ever LOOKS at this; this screen clears it.
@MainActor
@Observable
final class DayflowRecordsRouter {
    static let shared = DayflowRecordsRouter()
    /// A `NotesSegment` raw value: NOTES, PLACES, PEOPLE, ENDEAVORS, TO FILE.
    var pendingSegment: String? = nil
    /// A whole screen that is not a Records segment (D486). Presented by
    /// `DayflowRootView` as a sheet over whatever tab is up.
    var pendingRoom: DayflowRecordsRoom? = nil
    private init() {}
}

/// Three of Trace's rooms that came into this target as dependencies and have
/// never been reachable (D486).
///
/// David, asked which Trace-only screens he still uses: *"Trace home screen i
/// use for accessing orange theory classes and billiards sessions (its my only
/// door there). also recent visits are there and i use that as well."* The
/// other four - the captures drawer, the quick-pin sheet, Nearby, Flagged - he
/// did not recognise, so they go with the old app.
///
/// **Nothing was built for this.** `FitnessView`, `BilliardsView` and
/// `VisitsView` have been compiled into this target since D469, carried in by
/// `VisitDetailView`, which links a gym visit to its workout and a pool-hall
/// visit to its session. They only ever lacked a door.
enum DayflowRecordsRoom: String, Identifiable, CaseIterable {
    case visits    = "Visits"
    case fitness   = "Workouts"
    case billiards = "Billiards"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .visits:    return "clock.arrow.circlepath"
        case .fitness:   return "figure.run"
        case .billiards: return "circle.circle"
        }
    }
}

struct DayflowNotesView: View {
    @Environment(\.dismiss) private var dismiss
    /// Unread since D513 removed the search results and pinned days that
    /// opened a day from here. Kept so every caller still compiles; drop it
    /// together with the call sites if it is ever wanted again.
    @Binding var selectedDate: Date
    /// Set by `dayflow://note?path=Notes/Projects/…` so the screen opens straight
    /// into a project instead of its browse list (E35, 2026-07-29). Defaulted, so
    /// every existing `DayflowNotesView(selectedDate:)` call still compiles.
    var initialProjectTitle: String? = nil
    /// Session 77: true when hosted as the Notes tab in DayflowRootView —
    /// hides the chevron and disables the header's swipe-right-to-dismiss
    /// (there is no presentation to dismiss there).
    var isTabRoot: Bool = false

    @State private var projectNames: [String] = []
    @State private var selectedProjectTitle: String? = nil
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""
    /// Sort for the Projects browse list (separate from `sortOrder`, which is
    /// search-results-only) — David asked for a sort option here too. Default
    /// `.name` matches what the list already looked like before this existed
    /// (`listFiles` returns alphabetical), so turning this on doesn't silently
    /// reorder anyone's list on first launch.
    /// Redesign default: RECENT is by last touch (Name still in the menu).
    @State private var projectSortOrder: DayflowNoteSortOrder = .newest
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

    // Session 77 step (d) — the tab's segments (Dayflow-Tasks-Design.md,
    // Notes tab): opens on Days; To file is the renamed notes-staging inbox
    // and wears a dot while it has items. (The search mode that once sat
    // behind the header icon, with its scope pills, was removed in D513.)
    private enum NotesSegment: String, CaseIterable, Identifiable {
        // Session 89 (D298). Two changes, one each of the two kinds of drift
        // David found when he asked whether this tab had come adrift from the
        // Mac.
        //
        // **PROJECTS is NOTES**, finishing D271. The Mac's room went back to
        // being called Notes in Session 87 and that entry said the phone
        // carried the same label off the same folder and that a Dayflow
        // session would fix it. This is that session.
        //
        // **DAYS is gone**, because D297 gave it a better home: the day nav on
        // Today, where the Mac has always kept it. Removed only AFTER David
        // confirmed the replacement on a build — a way in must never come out
        // before its replacement is proven, which is the shape half this
        // session has been about.
        //
        // **PEOPLE added (D470, merge pass (a)).** D454 put People into
        // Records as a scope rather than a tab. The approved mockup drew the
        // row as the six rounded pills, but those are `Scope`, the SEARCH
        // vocabulary, which is a different control living inside search mode
        // and carries two values — All and Daily — that have no browse list to
        // show here at all (D297 moved Daily to Today). Drawn from memory
        // rather than from the file, the same miss as mockup v1.1's day strip.
        // The browse row is this one, and People joins it.
        //
        // **PLACES added (D472).** Sits before PEOPLE, the order the mockup
        // and the `Scope` enum both use. List mode only in this build; the
        // Discover map behind a MAP / LIST toggle is pass (b).
        case notes = "NOTES", places = "PLACES", people = "PEOPLE",
             endeavors = "ENDEAVORS", toFile = "TO FILE"
        var id: String { rawValue }
    }
    @State private var segment: NotesSegment = .notes
    @State private var recordsRouter = DayflowRecordsRouter.shared

    /// MAP or LIST inside the PLACES segment (D484). Discover becomes the map
    /// behind Places rather than a screen of its own, which is D454.
    private enum PlacesMode: String, CaseIterable { case list = "LIST", map = "MAP" }
    @State private var placesMode: PlacesMode = .list
    /// A coordinate handed to the map by `trace://discover?lat&lon&label`, or
    /// by "Show on My Map" on a pin card. `DiscoverView` owns it from there
    /// and clears it itself.
    @State private var discoverPin: DiscoverDroppedPin? = nil
    @State private var router = TraceRouter.shared

    /// Takes the routed segment as an ARGUMENT rather than re-reading the
    /// router, for the reason `DayflowRootView.tab(for:)` spells out at
    /// length: a value that two views watch must be handed to the handler
    /// that acts on it, never looked up again inside it.
    private func applyRoutedSegment(_ wanted: String?) {
        guard let wanted,
              let match = NotesSegment.allCases.first(where: { $0.rawValue == wanted })
        else { return }
        segment = match
        recordsRouter.pendingSegment = nil
    }
    /// Session 78 evening — the project-delete confirmation's subject.
    @State private var projectPendingDelete: String? = nil
    @State private var toFileCount = 0
    /// Session 78, Notes redesign — routed PROJECT notes land on this tab
    /// (in place, tab bar visible) instead of ContentView's cover.
    @State private var quickFindRouter = DayflowQuickFindRouter.shared

    private let noteStore = NoteStore.shared

    /// Takes a held `trace://discover` and opens the map on its pin (D484).
    ///
    /// **Called on appear as well as on `router.version` (D519).** The root
    /// switches to this tab when a discover route is held, but a `TabView` tab
    /// that has not been shown this launch is not built yet, so the version
    /// change that announced the route happened before this view existed and
    /// was never heard. D484's own note said this screen must "still find the
    /// route waiting for it when it appears"; nothing on appear ever looked.
    /// Show on My Map on the pin card, on Dayflow 95: *"does nothing."*
    private func takeDiscoverRoute() {
        guard let route = router.take(where: {
            if case .discover = $0 { return true } else { return false }
        }) else { return }
        guard case .discover(let lat, let lon, let label) = route else { return }
        segment = .places
        placesMode = .map
        discoverPin = DiscoverDroppedPin(latitude: lat, longitude: lon,
                                         label: label ?? "Dropped pin")
    }

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
        .alert("New Note", isPresented: $showNewProjectAlert) {
            TextField("Note name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") { createProject() }
        }
        // **The first screen to take a route from `TraceRouter`** (D484).
        //
        // `trace://discover?lat=&lon=&label=` used to cross a process boundary
        // into the old Trace app. It lands here now. The router held it until
        // places reported ready (D468), which is the whole point of D466: no
        // pending ID on this screen, no retry watcher, no guessing whether
        // Notion has answered yet.
        .onChange(of: router.version) { _, _ in takeDiscoverRoute() }
        // The Records destination from Quick Find (D480). Cleared here, and
        // only here.
        .onChange(of: recordsRouter.pendingSegment) { _, wanted in
            applyRoutedSegment(wanted)
        }
        .onAppear {
            // D519: a route delivered before this tab was ever built fired
            // `router.version` with nothing here to hear it. Look on arrival.
            takeDiscoverRoute()
            loadProjectNames()
            applyRoutedProject()
            refreshToFileCount()
            drainRoutedProjectNote()
        }
        .onChange(of: quickFindRouter.pendingDestination != nil) { _, hasPending in
            if hasPending { drainRoutedProjectNote() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreInboxDidChange)) { _ in
            refreshToFileCount()
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
    }

    private var mainBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            segmentRow
            if segment == .toFile {
                // Owns its own List (swipe actions need it) — not nested
                // in the segment ScrollView.
                DayflowNotesInboxView(embedded: true)
            } else if segment == .places && placesMode == .map {
                // Discover, whole, as the map behind Places (D454, D484).
                // It is a `ZStack` of a full-bleed `Map` with its own
                // search field and filter chips laid over it, so it needs
                // no stack and no chrome from here — and its one reach
                // outside the merged target, `DrawerButtons()`, is already
                // answered as nothing by `TraceMergeShims` (D469).
                DiscoverView(droppedPin: $discoverPin)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            } else if segment == .places {
                // Trace's Places screen (D472), in a `NavigationStack` of
                // its own. Unlike People, this one needs the stack: it
                // pushes a place with a `NavigationLink` and hangs Add a
                // place, Visits, Sort and Refresh off a navigation bar.
                // Without a stack the row does nothing and the four
                // buttons never appear at all.
                //
                // `embedded: true` only empties the large title, so the
                // bar is a thin strip carrying those four buttons instead
                // of a second big heading under Records.
                //
                // `LocationManager` is injected here because the app root
                // supplies only `NotionService`, and this screen sorts by
                // distance.
                NavigationStack {
                    PlacesView(embedded: true)
                        .environment(LocationManager.shared)
                }
            } else if segment == .people {
                // Trace's People screen, whole (D470) — Recent
                // interactions first, the everyone list behind its second
                // segment, search, filters, Add a person, and a tap opens
                // `PersonDetailView` as a sheet. That is frame 2 of the
                // approved mockup, already built.
                //
                // Outside the segment ScrollView for the same reason TO
                // FILE is: it brings its own scroller and its own swipe
                // rows, and a vertical scroller inside a vertical scroller
                // scrolls neither well.
                //
                // **Not one line of it edited.** Its `.navigationTitle`
                // and `.navigationBarTitleDisplayMode` are inert with no
                // NavigationStack around this body, `.drawerToolbar()` is
                // answered as nothing by `TraceMergeShims` (D469), and its
                // ten `TraceSkin` names are answered by `TraceSkinBridge`
                // (D467), so it draws Editorial in both appearances as it
                // stands. It is still the old app's file, byte for byte,
                // while the old app is still installed.
                PeopleView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        switch segment {
                        case .notes:
                            newProjectRow
                            projectNotesSection
                        case .endeavors:
                            DayflowEndeavorListSection()
                        case .places, .people, .toFile:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .dayflowSkinBackground()
    }

    /// The figure on the masthead, for the segment actually being shown.
    ///
    /// Was `"\(projectNames.count) NOTES"` unconditionally, so the screen read
    /// "12 NOTES" while ENDEAVORS was up. One segment made that easy to miss;
    /// D470 adds a second and the next build a third, at which point three of
    /// five screens would be stating a number about something they are not
    /// showing. Nil where there is no honest figure: TO FILE already wears its
    /// own dot, and the endeavor list carries its own headings.
    ///
    /// **Nil, not zero, for People before the fetch lands.** An empty
    /// `people` array is a store that has not loaded and a store that loaded
    /// and found nobody, and nothing here can tell them apart. "0 PEOPLE"
    /// would pick one and be wrong half the time.
    private var segmentCountLabel: String? {
        switch segment {
        case .notes:
            return "\(projectNames.count) NOTES"
        case .places:
            let n = NotionService.shared.places.count
            return n == 0 ? nil : "\(n) PLACES"
        case .people:
            let n = NotionService.shared.people.count
            return n == 0 ? nil : "\(n) PEOPLE"
        case .endeavors, .toFile:
            return nil
        }
    }

    private var segmentRow: some View {
        // **A horizontal scroller from D470**, while it still makes no visible
        // difference: four labels fit a phone, five will not. This file has
        // already recorded that failure twice — the old scope pills' comment
        // ("five pills fitted a phone width; Endeavors made six and the labels
        // started truncating mid-word") and the `fixedSize()` note below,
        // written after "PROJECT S" wrapped mid-word on David's first device
        // build. PLACES makes five here in the next build; the fix goes in
        // ahead of the label rather than after the screenshot.
        //
        // `.scrollClipDisabled` so the active segment's accent underline is
        // not sheared at the edges (the scope pills that did the same went in D513).
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
            ForEach(NotesSegment.allCases) { seg in
                Button { segment = seg } label: {
                    // Redesign: the active section wears a short accent
                    // underline, newspaper-section style, not color alone.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(seg.rawValue)
                                .font(.system(size: 11, weight: segment == seg ? .bold : .medium))
                                .tracking(1.2)
                                .lineLimit(1)
                            if seg == .toFile && toFileCount > 0 {
                                Circle().fill(Color.dayflowAccent).frame(width: 5, height: 5)
                            }
                        }
                        Rectangle()
                            .fill(segment == seg ? Color.dayflowAccent : Color.clear)
                            .frame(height: 2)
                    }
                    // fixedSize: the underline Rectangle otherwise accepts
                    // every width offered, widening the stack until the
                    // LABELS wrap mid-word ("PROJECT S" — David's screenshot,
                    // first device build). Sized to the text, the rule hugs
                    // the word it belongs to.
                    .fixedSize()
                    .foregroundStyle(segment == seg ? Color.dayflowAccent : Color.dayflowFaint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        }
        .scrollClipDisabled()
    }






    private func refreshToFileCount() {
        toFileCount = (try? NoteStore.shared.listFiles(in: "Notes/Inbox").count) ?? 0
    }

    // MARK: Header

    private var header: some View {
        // Session 78, Notes redesign — the Today masthead family: triple
        // rule (3pt over, 1pt under), serif title, a quiet count on the
        // right. The magnifier stayed retired (D159, Quick Find reaches
        // notes from anywhere). The dormant search mode it once opened was
        // removed in D513.
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.dayflowInk).frame(height: 3)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !isTabRoot {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
                // **Records, not Notes** (Session 89, D298). The tab holds
                // notes, endeavors and the filing queue, and an endeavor is
                // not a note — it is a record with dates, bookings, places and
                // its own tasks, with a note attached. Naming the container
                // after one of the things inside it is what made this screen
                // read wrong, and the Mac already had the right word: its
                // sidebar groups exactly these under RECORDS.
                Text("Records")
                    .font(.dayflowSerif(30, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                if segment == .places {
                    // **The toggle sits where the count sits** (D484). The
                    // masthead already has one small right-hand slot and the
                    // count is the least useful thing that could be in it
                    // while you are looking at a map. A row of its own would
                    // put four bands of chrome above Discover's own search
                    // field, which is the shape that made Trace's Home screen
                    // feel busy.
                    Picker("", selection: $placesMode) {
                        ForEach(PlacesMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.dayflowAccent)
                    .fixedSize()
                } else if let label = segmentCountLabel {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.4)
                        .foregroundStyle(Color.dayflowFaint)
                }
            }
            .padding(.vertical, 10)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, isTabRoot ? 22 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dayflowQuickFindPull(enabled: isTabRoot)
    }

    /// Applies a routed project title, at most once per distinct title.
    ///
    /// Called from both `.onAppear` and `.onChange(of: initialProjectTitle)`:
    /// a route can arrive either before this screen exists or while it is already
    /// on screen, and only one of those produces an appearance.
    /// Session 78, Notes redesign: project-note destinations are drained
    /// HERE, on the tab root, so the note opens in place with the tab bar
    /// still standing — Today is one tap from any note (David's ask).
    /// ContentView deliberately leaves these values alone; RootView has
    /// already switched to this tab. The in-place swap is not a
    /// presentation, so no dismiss-hop is needed.
    private func drainRoutedProjectNote() {
        guard isTabRoot,
              case .dailyOrProjectNote(let path)? = quickFindRouter.pendingDestination,
              path.hasPrefix("Notes/Projects/") else { return }
        quickFindRouter.pendingDestination = nil
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !title.isEmpty else { return }
        segment = .notes
        selectedProjectTitle = title
    }

    private func applyRoutedProject() {
        guard let initialProjectTitle, initialProjectTitle != consumedInitialProject else { return }
        consumedInitialProject = initialProjectTitle
        selectedProjectTitle = initialProjectTitle
    }

    private var newProjectRow: some View {
        Button {
            newProjectName = ""
            showNewProjectAlert = true
        } label: {
            // Redesign (Session 78): the quiet caps row from the approved
            // mockup — an add affordance that never shouts.
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("NEW NOTE")
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(1.6)
                Spacer()
            }
            .foregroundStyle(Color.dayflowFaint)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
    }

    // MARK: Project list ordering
    //
    // **Pinned first (Session 37, 2026-07-22).** David wanted important notes
    // held at the top as the list grows - see DayflowFlagStore.swift for the
    // storage. `projectNotesSection` splits pinned from the rest and sorts each
    // group with `applyProjectSort`, so pinning never fights the chosen order.
    //
    // **Sort (Session 37 addendum 3).** `DayflowNoteSortOrder` (Newest/Oldest/
    // Name) lives in DayflowModels.swift and is SHARED - `DayflowBacklinksView`
    // sorts with it too. The search results that first used it here were
    // removed in D513; the enum was never this file's to remove.

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

    @ViewBuilder
    private var projectNotesSection: some View {
        // Redesign (Session 78, approved mockup): PINNED first with the
        // accent square, then RECENT by last touch, each group under its own
        // caps header + ink rule. The sort menu rides the RECENT header.
        if !projectNames.isEmpty {
            let store = DayflowFlagStore.shared
            let pinned = applyProjectSort(projectNames.filter { store.isFlagged(projectNotePath($0)) })
            let recent = applyProjectSort(projectNames.filter { !store.isFlagged(projectNotePath($0)) })
            if !pinned.isEmpty {
                Text("PINNED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Color.dayflowFaint)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                ForEach(pinned, id: \.self) { name in
                    projectRow(name, pinned: true)
                }
            }
            if !recent.isEmpty {
                HStack {
                    Text("RECENT")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(Color.dayflowFaint)
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
                        .foregroundStyle(Color.dayflowFaint)
                    }
                }
                .padding(.top, pinned.isEmpty ? 10 : 16)
                .padding(.bottom, 4)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                ForEach(recent, id: \.self) { name in
                    projectRow(name, pinned: false)
                }
            }
            archivedProjectsSection
        } else {
            Text("Nothing here yet — tap \"New note\" above to start one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
            // Also here: archiving the LAST project would otherwise take the only
            // route to the archive away with it.
            archivedProjectsSection
        }
    }

    @ViewBuilder
    private func projectRow(_ name: String, pinned: Bool = false) -> some View {
        // Redesign (Session 78): serif title over a meta line of real data —
        // open linked tasks (the OPEN TASKS machinery) and last touch. The
        // pin toggle moved into the context menu; the chevron died with the
        // rest of them. The accent square marks the pinned group.
        let path = projectNotePath(name)
        let flagged = DayflowFlagStore.shared.isFlagged(path)
        let meta = projectMetaLabel(name)
        HStack(spacing: 10) {
            if pinned {
                Rectangle().fill(Color.dayflowAccent).frame(width: 6, height: 6)
            }
            Button { selectedProjectTitle = name } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.dayflowSerif(16, weight: .semibold))
                        .foregroundStyle(Color.dayflowInk)
                        .lineLimit(1)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 10.5, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(Color.dayflowFaint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        // LONG PRESS, NOT SWIPE. This list is a VStack inside a ScrollView, not a
        // `List`, so `.swipeActions` does not apply — the same situation that made
        // Trace's people list need a hand-rolled gesture. That one is justified
        // there: deleting a person from a long list is frequent and sweeping.
        // Archiving a project is rare and deliberate, and `.contextMenu` is native,
        // needs no gesture arbitration, and cannot swallow the row's own tap.
        .contextMenu {
            Button {
                DayflowFlagStore.shared.toggleFlag(path)
            } label: {
                Label(flagged ? "Unpin" : "Pin", systemImage: flagged ? "pin.slash" : "pin")
            }
            Button {
                if noteStore.archiveProject(name: name) { loadProjectNames() }
            } label: {
                Label("Archive Note", systemImage: "archivebox")
            }
            // Session 78 evening — David: "i have no way of deleting project
            // notes." Destructive + confirmed (file removal is permanent;
            // archive above is the recoverable path and stays first).
            Button(role: .destructive) {
                projectPendingDelete = name
            } label: {
                Label("Delete Note", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete \u{201C}\(projectPendingDelete ?? name)\u{201D}? The note file is removed permanently — Archive is the recoverable option.",
            isPresented: Binding(
                get: { projectPendingDelete == name },
                set: { if !$0 { projectPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                try? NoteStore.shared.deleteFile(projectNotePath(name))
                projectPendingDelete = nil
                loadProjectNames()
            }
            Button("Cancel", role: .cancel) { projectPendingDelete = nil }
        }
        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
    }

    /// The row's meta line, from real data: open tasks linked to this
    /// note's agenda anchor (the same set its OPEN TASKS section and the
    /// meeting AGENDA line show) and the file's last touch. "TODAY" in
    /// accent context comes free from RECENT sorting; empty when a project
    /// has neither.
    private func projectMetaLabel(_ name: String) -> String {
        let anchor = DayflowAgendaMatch.agendaAnchor(forTitle: name)
        let open = ReminderTaskStore.shared.allTasks.filter {
            ($0.notes ?? "").contains("[[\(anchor)]]")
        }.count
        let touched = projectModifiedDate(name)
        let cal = Calendar.current
        var parts: [String] = []
        if open == 1 { parts.append("1 OPEN TASK") }
        else if open > 1 { parts.append("\(open) OPEN TASKS") }
        if touched != .distantPast {
            if cal.isDateInToday(touched) { parts.append("TODAY") }
            else if cal.isDateInYesterday(touched) { parts.append("YESTERDAY") }
            else {
                let f = DateFormatter(); f.dateFormat = "MMM d"
                parts.append(f.string(from: touched).uppercased())
            }
        }
        return parts.joined(separator: " \u{00B7} ")
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
                    Text("ARCHIVED \u{00B7} \(archivedProjectNames.count)")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.6)
                    Image(systemName: showArchivedProjects ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Color.dayflowFaint)
                .padding(.top, 18)
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
}
