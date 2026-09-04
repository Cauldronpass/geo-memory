// TraceMacContentView.swift
// The app shell, Home, and the interaction sheets.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 63 (2026-08-02), Phase 1. This file was 3607 lines: the shell, the
// whole Places section, Home, and six sheets. Places moved out verbatim to
// `TraceMacPlacesView.swift` — same declarations, same order, same bodies,
// nothing rewritten. Verified by hashing the sorted non-blank lines of the
// original against the two halves; they match exactly.
//
// What deliberately stayed: `DocumentBacklinkRow`, `MentionedInSection`,
// `NotePreviewTarget`, `MacNotePreviewSheet` and `MacNoteStorePhotoView`, all
// of which `TraceMacPeopleView` also uses. Putting them in a Places file would
// have made People depend on Places for no reason.
//
// `import MapKit` went with Places: the only map in the file was the one in
// `MacVisitDetailView`.

import SwiftUI
import CoreSpotlight
import AppKit
import UniformTypeIdentifiers

// MARK: - Sidebar sections

enum MacSection: String, CaseIterable, Identifiable {
    // Session 79, D186. THE DAY group: the Mac mimics the iOS app's shape
    // rather than inventing one, so Today and Upcoming are destinations of
    // their own and Tasks is a third, all above the RECORDS sections that
    // were here before.
    case today     = "Today"
    case upcoming  = "Upcoming"
    case tasks     = "Tasks"
    /// Was "Notes", covering Daily, Weekly and Projects. Session 83 (D254,
    /// D255): Daily folded into Today's DAYS list, Weekly into that list's
    /// week rules, so the one thing left is Projects and the row says so. The
    /// CASE stays `notes` for the reason `inbox` gives below: nothing persists
    /// a `MacSection` by rawValue, and renaming the case would churn every
    /// call site for a label change.
    case notes     = "Projects"
    /// D1 listed this row when the design was written; it never existed in
    /// code. Added Session 64, once there was something for it to open.
    case endeavors = "Endeavors"
    /// One destination covering People, Places, Visits and Discover. The tab
    /// lives in `TraceMacDirectoryView`'s own `@State`.
    case directory = "Directory"
    /// One destination covering Billiards, Fitness and Photos. The tab lives in
    /// `TraceMacActivityView`'s own `@State`.
    case activity  = "Activity"
    /// Labelled "Satchel" — the app name, matching iOS. The **folder** on disk
    /// stays `Documents/`: three apps and a share extension read that path, and
    /// this is a label, not a storage decision. Per-record tabs (a person's
    /// documents, a place's documents) also stay "Documents", because there they
    /// describe the contents rather than name the app.
    case documents = "Satchel"
    /// Session 79, D186. Was "Inbox". This row is NOTE captures from the menu
    /// bar and the phone (`Notes/Inbox/`) — the identical folder the iOS Notes
    /// tab's TO FILE segment reads, so the word is not new, only newly
    /// consistent. The rename frees "Inbox" for the Reminders task pool inside
    /// TASKS: two piles, two doors, no collision. The CASE stays `inbox`
    /// because nothing persists or reconstructs a `MacSection` from its
    /// rawValue (checked) and renaming it would churn every call site for a
    /// label change.
    case inbox     = "To File"
    case archive   = "Archive"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .today:     return "sun.max"
        case .upcoming:  return "calendar"
        case .tasks:     return "list.bullet"
        case .notes:     return "folder"
        case .endeavors: return "flag"
        case .directory: return "person.2"
        case .activity:  return "figure.run"
        case .documents: return "doc.richtext"
        case .inbox:     return "tray"
        case .archive:   return "archivebox"
        }
    }

    // `iconColor` retired, Session 79 (D186). It painted seven sidebar rows in
    // six different colours — orange, indigo, indigo, green, blue, gray,
    // brown — against a design language with exactly ONE accent, which is why
    // the Editorial sidebar could not use it and why nothing else ever did
    // (its only caller was `row(_:)`, retired in the same change). The Session
    // 64 audit that fixed two of those seven for contrast is preserved in
    // MacColor.swift's header; this is the rest of that finding, applied.
}

// MARK: - Root view

struct TraceMacContentView: View {

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @Binding var selectedSection: MacSection?
    /// A week (or day) for Today's DAYS list, set by the routes that used to
    /// land on the Weekly tab. Consumed by `TraceMacTodayView`.
    @State private var pendingDaysPick: MacDaysPick? = nil
    /// Bare filename into the Projects list. Consumed by `TraceMacProjectsView`.
    @State private var pendingProjectFile: String? = nil
    @State private var isDropTargeted = false

    // Deep-link handoffs. Session 63 (2026-08-02), Phase 1.
    //
    // Switching section and then *posting a notification the new view is
    // supposed to catch* only works if the view is already listening, and it is
    // not — it mounts a beat later. The workaround was
    // `DispatchQueue.main.asyncAfter` with a hand-tuned delay: 0.1 for a
    // wikilink, 0.15 from Home, 0.35 for a record, 0.4 for a document. Four
    // different guesses at the same unknown, each of them a race that happened
    // to be winnable on the machine it was written on.
    //
    // These replace all of it. The target view takes the value as a `Binding`
    // and consumes it in `.task(id:)`, which fires when the view appears *and*
    // whenever the value changes — so it does not matter whether the view is
    // already up or arrives later. The view clears the binding when done.
    //
    // Not a new idea: the Weekly tab's `pendingHorizonsFile` worked this way
    // all along (retired in Session 83, its route now lands on Today's DAYS).
    // It was the one deep link with no timing hack in it, and it was the model
    // for these three.
    /// The day Today is showing. Held HERE rather than inside
    /// `TraceMacTodayView` so the arrow-key monitor installed by this view can
    /// move it, and so the day survives a trip to Satchel and back.
    @State private var dayInView: Date = Calendar.current.startOfDay(for: Date())
    /// A task chosen in search. `TraceMacTasksView` works out which pool holds
    /// it, switches there and opens the card — see its deep link.
    @State private var pendingTaskID: String? = nil
    @State private var composing = false
    /// A `+` rail choice waiting to be performed (D249).
    @State private var newRequest: MacNewRequest? = nil
    /// Built on demand for the rail's Endeavor door. Every other Mac surface
    /// that needs endeavors builds its own the same way; a shared instance for
    /// one sheet would be a new lifetime to reason about.
    @State private var endeavorStore: TraceMacEndeavorStore? = nil
    /// A context list chosen in the panel's GO TO section, handed to the Tasks
    /// screen the same way a task id is.
    @State private var pendingTaskList: String? = nil
    /// Read only for the search glyph's tooltip, so the rail can say which key
    /// does the same thing. Observed rather than copied: he can change the
    /// combination in Settings and the tooltip has to follow it.
    @State private var hotKeys = MacHotKeyCenter.shared
    @State private var composeTrigger = MacComposeTrigger.shared
    /// **The supported way to open the Settings scene**, and the reason the
    /// gear did nothing on first build.
    ///
    /// I reached for `NSApp.sendAction(Selector(("showSettingsWindow:")), …)`,
    /// which is the widely-copied workaround from before this environment
    /// action existed. It is a PRIVATE selector, Apple has already renamed it
    /// once (`showPreferencesWindow:` became `showSettingsWindow:` in Ventura),
    /// and a string selector that no longer matches fails silently — no crash,
    /// no log, nothing. Exactly the failure David saw.
    ///
    /// `openSettings` is public, typed, and breaks at compile time if it ever
    /// goes away. The lesson generalises: a stringly-typed call into AppKit is
    /// a call that can stop working without telling anyone.
    @Environment(\.openSettings) private var openSettings
    /// Both default false — see `MacInboxCountSetting` for why an unrequested
    /// count is the app deciding on his behalf that an un-triaged Inbox is a
    /// problem.
    @AppStorage(MacInboxCountSetting.sidebarKey) private var showInboxCount = false
    @AppStorage(MacInboxCountSetting.dockKey) private var showDockBadge = false

    @State private var pendingPersonID: String? = nil
    @State private var pendingPlaceID: String? = nil
    @State private var pendingDocumentPath: String? = nil
    /// The search text that produced `pendingDocumentPath`, so the PDF viewer
    /// can highlight it on the page. Cleared by the viewer, like every other
    /// pending value here.
    @State private var pendingDocumentQuery: String? = nil
    /// A **container-relative path**, not a bare filename, unlike the three
    /// above. `TraceMacNotesView` reads the folder off the front to decide which
    /// tab to switch to, because "Speech.md" alone cannot say whether it is a
    /// project note or a day. See D64.
    @State private var pendingNotePath: String? = nil
    /// Endeavor slug (frontmatter `id:`), added Session 70 for global search.
    /// The Endeavors rail already keys its selection on that id; it just had no
    /// way to be told one from outside.
    @State private var pendingEndeavorID: String? = nil
    /// Bare filename into the Inbox list, same shape as `pendingProjectFile`.
    @State private var pendingInboxFile: String? = nil
    /// Set by the system-wide hot key on the one path that still needs the
    /// window (see `MacHotKeyCenter.fire`), consumed below.
    @State private var searchTrigger = MacSearchTrigger.shared
    /// A destination chosen in the floating panel, which lives outside this
    /// view's hierarchy and so cannot write the pending-link state directly.
    @State private var searchRoute = MacSearchRoute.shared
    /// Back/forward history. Sections report where they are; the header
    /// arrows ask to move; this view performs the move.
    @State private var navigator = MacNavigator.shared

    var body: some View {
        // Plain HStack instead of NavigationSplitView — eliminates NSSplitView resize
        // arrows entirely. Sidebar is fixed at 200px; detail fills the rest.
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Global drop target overlay — only visible when dragging a file
            if isDropTargeted {
                Color.accentColor.opacity(0.06)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(6)
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleGlobalDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHorizonsFile)) { note in
            if let filename = note.userInfo?["filename"] as? String {
                routeWeekFile(filename)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectDocument)) { note in
            guard let path = note.userInfo?["relativePath"] as? String else { return }
            selectedSection = .documents
            pendingDocumentPath = path
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWikilink)) { note in
            guard let name = note.userInfo?["name"] as? String else { return }
            if let person = notionService.people.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                selectedSection = .directory
                pendingPersonID = person.id
            } else if let place = notionService.places.first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                selectedSection = .directory
                pendingPlaceID = place.id
            } else if let note = noteStore.linkableNotes().first(where: {
                $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                // D64. Third and last branch. Records first, notes last, because
                // a Place note and a Place record can share a name and the record
                // is what you want when you click one.
                //
                // Before this, an unmatched name fell out of the `if` and **did
                // nothing at all** — the link still rendered, so it looked live
                // and went nowhere, which is worse than no link.
                routeNote(note.relativePath)
            } else if MacDaysList.dayFormatter.date(from: name) != nil {
                // A date-shaped name is a DAY whether or not its file exists
                // yet: `linkableNotes()` lists only days that have a file, and
                // Today creates the file on the first keystroke. Session 83,
                // found alongside the week case below.
                routeNote(NoteStore.dailyFolder + "/" + name + ".md")
            } else if routeWeekFile(name + ".md") {
                // `[[2026-W35]]`. Week notes are not in `linkableNotes()` (that
                // list is Projects + Daily, per D49, and is shared with the
                // phone), so before Session 83 this name fell out of the `if`
                // and the link went nowhere — David: "once it looked like a
                // link it never went anywhere." `routeWeekFile` is its own
                // shape test; a name that is not `YYYY-Www` returns false
                // and falls through as before.
            }
        }
        // `pendingNotePath` is still WRITTEN by the Endeavors rail's linked-note
        // rows (`deepLinkNotePath`), which used to hand it to the Notes tab
        // container. Nothing consumes it there any more, so it is consumed
        // here, the same way, and routed by folder.
        .onChange(of: pendingNotePath) { _, path in
            guard let path else { return }
            pendingNotePath = nil
            routeNote(path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToRecord)) { note in
            guard let type = note.userInfo?["type"] as? String,
                  let id   = note.userInfo?["id"]   as? String else { return }
            // Routed through `openSearchResult` rather than setting the section
            // and the pending id here.
            //
            // **These two cases were a hand copy of two cases in that function**,
            // and Session 72 needed a third for the visit sheet's Endeavor row.
            // Adding it here would have made the copy three deep and left the
            // same gap the copy already had: `openSearchResult` records into
            // `navigator`, and this did not, so Back did nothing after a "Go to
            // Place" from a visit while it worked after the identical jump from
            // a search result. One funnel, per D112.
            //
            // Empty query: nothing here is a search, and the argument only
            // reaches the documents case.
            let destination: MacSearchDestination?
            switch type {
            case "person":   destination = .person(id)
            case "place":    destination = .place(id)
            case "endeavor": destination = .endeavor(id)
            // A task's document chip (D227). `id` is the document's
            // relativePath — the same string `MacSearchDestination.document`
            // already carries, so this arm adds a poster, not a new route.
            case "document": destination = .document(id)
            default:         destination = nil
            }
            if let destination { openSearchResult(destination, query: "") }
        }
        // Consume-and-clear, not a notification. The hot key can fire while
        // this window is being restored, and a notification posted then lands
        // before anything is listening. `.task(id:)` fires on appear as well as
        // on change, so a request made a beat too early is still honoured.
        .task(id: searchTrigger.pending) {
            guard searchTrigger.pending else { return }
            searchTrigger.pending = false
            MacQuickPanelController.shared.show()
        }
        // Same consume-and-clear, for results chosen in the floating panel. It
        // fires on appear as well as on change, so a request made while this
        // window was still being restored is still honoured.
        // **Both hooks, on purpose.** `.task(id:)` covers the window that is
        // being created right now — it fires on appear with whatever is already
        // pending. `.onChange` covers the window that is already up and merely
        // being brought forward. Either alone leaves one of those two cases
        // depending on a body re-evaluation landing at the right moment, and
        // "the app doesn't jump to the record" is what that looks like from
        // outside. Consuming clears the value, so whichever fires second sees
        // nothing and returns.
        .task(id: searchRoute.pending) { consumeSearchRoute() }
        .onChange(of: searchRoute.pending) { consumeSearchRoute() }
        // The sidebar. A section clicked by hand is a place; a section arrived
        // at by replay is not, and `MacNavigator.record` drops the second by
        // equality rather than by a flag.
        .onChange(of: selectedSection) { _, new in
            navigator.record(.section(new ?? .today))
        }
        // Session 73. Satchel's filter-pane shortcut, user-settable in Settings.
        //
        // **Installed here, not in the Satchel view**, so it means something
        // from every section: pressed from Notes it switches to Satchel and
        // opens the pane; pressed while already there it toggles. A shortcut
        // that silently does nothing on five of seven tabs is a shortcut you
        // stop trusting, and "nothing happened" is indistinguishable from
        // "it is broken".
        //
        // Capturing `selectedSection` in an escaping closure is safe **here and
        // only here**: this is the root view, the binding's storage outlives
        // every closure it could hand out, and `install` reassigns its handler
        // on each call rather than stacking monitors. Do not copy the pattern
        // into a view that comes and goes.
        .onAppear {
            MacSatchelFilterShortcut.shared.install {
                if selectedSection == .documents {
                    SatchelFilterPane.toggle()
                } else {
                    // Open, not toggle. You asked for the filters; arriving with
                    // them shut would be the shortcut answering a different
                    // question.
                    SatchelFilterPane.show()
                    selectedSection = .documents
                }
            }
        }
        .onDisappear { MacSatchelFilterShortcut.shared.uninstall() }
        // Session 79. Arrow keys, restoring what `List(selection:)` gave for
        // free before the Editorial sidebar replaced it — and giving the day a
        // keyboard it never had. Capturing `self` in an escaping closure is
        // safe for the same reason the block above says it is: this is the root
        // view, its `@State`/`@Binding` storage outlives any closure it hands
        // out, and `install` replaces its handler rather than stacking
        // monitors. Do not copy the pattern into a view that comes and goes.
        // Three triggers, because the badge is wrong if any one is missed: the
        // count changed, the switch changed, or the app just launched and the
        // tile is showing whatever it showed last time.
        // Consume-and-clear, same shape as every other cross-window request
        // here: the panel lives outside this view's hierarchy and the window may
        // be reopening at the moment the request is made.
        .task(id: composeTrigger.requests) {
            // Not on the first fire: `.task(id:)` runs on appear as well as on
            // change, and a composer that opens itself every time the window
            // appears would be a sheet nobody asked for.
            guard composeTrigger.requests > 0 else { return }
            composing = true
        }
        .task(id: searchRoute.pendingGoTo) {
            guard let go = searchRoute.pendingGoTo else { return }
            searchRoute.pendingGoTo = nil
            selectedSection = go.section
            pendingTaskList = go.list
        }
        .sheet(isPresented: $composing) {
            // The day in view when Today is showing, nothing otherwise — the
            // same rule the per-screen buttons used, kept when they were
            // replaced so the behaviour did not quietly change with the
            // button's address.
            MacTaskComposer(defaultDate: (selectedSection ?? .today) == .today
                            ? dayInView : nil,
                            onAdded: { },
                            onSwitch: { kind, seed in
                                performNew(kind, seed: seed)
                            })
        }
        // The rail's other three doors (D249). `item:` rather than
        // `isPresented:` so a second Person in a row presents a second time.
        .sheet(item: $newRequest) { request in
            switch request.kind {
            case .person:
                AddPersonSheet(notionService: notionService,
                               onSaved: { person in
                                   openSearchResult(.person(person.id), query: "")
                               },
                               seedName: request.seed)
            case .endeavor:
                MacEndeavorSheet(existing: nil,
                                 onSave: { _, name, type, starts, ends, destination, _, _ in
                                     await createEndeavor(name: name, type: type, starts: starts,
                                                          ends: ends, destination: destination)
                                 },
                                 seedName: request.seed)
            case .task, .projectNote:
                // Unreachable. `.task` never leaves the composer, and a project
                // note needs no sheet — `makeProjectNote` writes and opens it.
                // `EmptyView` rather than a `fatalError`: a sheet body is a bad
                // place to die, and this arm exists only because the enum is
                // exhaustive.
                EmptyView()
            }
        }
        .onAppear { syncDockBadge() }
        .onChange(of: ReminderTaskStore.shared.inboxCount) { _, _ in syncDockBadge() }
        .onChange(of: showDockBadge) { _, _ in syncDockBadge() }
        .onChange(of: showInboxCount) { _, _ in syncDockBadge() }
        .onAppear {
            MacEditorialArrowKeys.shared.install { direction in
                switch direction {
                case .up:    moveSection(-1)
                case .down:  moveSection(1)
                case .left:  stepDay(-1)
                case .right: stepDay(1)
                }
            }
        }
        .onDisappear { MacEditorialArrowKeys.shared.uninstall() }
        // The header arrows, consumed here because this is the view that holds
        // the pending-link state a move is made of.
        .onChange(of: navigator.pendingReplay) { _, place in
            guard let place else { return }
            navigator.pendingReplay = nil
            switch place {
            case .section(let value):
                selectedSection = value
            case .record(let destination):
                openSearchResult(destination, query: "")
            }
        }
        // TraceMac came to the front. Refetch whatever another device may have
        // written while this window was not looking.
        //
        // **`NSApplication.didBecomeActiveNotification`, not `scenePhase`.** On
        // macOS `scenePhase` tracks the *window*, so it also fires for things
        // that are not "the user came back" — and this app is single-window with
        // a `MenuBarExtra` and a Settings scene beside it. The AppKit
        // notification means exactly one thing.
        //
        // The staleness windows live on `NotionCollection`, so this call site
        // does not decide what is worth refetching — it only says when to ask.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notionService.refreshStale() }
        }
        .task {
            // App-wide and idempotent. Registered from here rather than from the
            // `App`'s `init` only to keep the isolation plain; the registration
            // itself is not tied to this view's lifetime, so closing the window
            // leaves the shortcut that reopens it working.
            MacHotKeyCenter.shared.start()
            // The floating panel needs these two, and this is where they live.
            // (Until D248 there was a second reason: `TraceMacApp` built its own
            // `NotionService`, so the panel could not reach for `.shared`. That
            // divergence is gone — the Mac now uses the same singleton as both
            // iOS apps — and this call is simply the tidiest place to hand the
            // panel its stores.)
            MacQuickPanelController.shared.configure(noteStore: noteStore,
                                                     notionService: notionService)
            async let p: ()  = notionService.fetchPlaces()
            async let pe: () = notionService.fetchPeople()
            async let b: ()  = notionService.fetchBilliardsSessions()
            async let w: ()  = notionService.fetchWorkouts()
            _ = await (p, pe, b, w)

            // A place with visits that still says "Want to Visit" is provably
            // wrong, and David asked for it fixed rather than reported. Runs
            // after `fetchPlaces` because it reads the rollup that call brings.
            await notionService.reconcileVisitedStatuses()

            // Text extraction (spec §8 step 2) at launch rather than only when
            // the Satchel section is visited. Search reads every document
            // whether or not that screen has ever been opened, so hanging the
            // backfill off a section David might not visit for a week would
            // mean search quietly missing the contents of files it lists.
            //
            // Its own store instance, and a short-lived one. Vision and PDFKit
            // only, no network, and it writes nothing for a document it has
            // already read.
            let documentStore = TraceMacDocumentStore(noteStore: noteStore)
            await documentStore.reload()
            await documentStore.extractTextForNewArrivals()

            // Spotlight (2026-08-25). After extraction, so a new PDF's text is
            // in the index the same launch it was read. Same corpus walk the
            // search panel does; the Mac can open every kind but `.preview`.
            // A store reload after extraction picks up the sidecars it wrote.
            guard let url = noteStore.containerURL else { return }
            let corpus = await Task.detached(priority: .utility) {
                MacSearchCorpus.build(containerURL: url)
            }.value
            await documentStore.reload()
            await TraceSpotlightIndex.reindex(corpus: corpus,
                                              documents: documentStore.documents,
                                              people: notionService.people,
                                              places: notionService.places,
                                              canOpen: { $0 != .preview })
        }
    }

    // MARK: - Search routing

    /// The one place a search result becomes a screen.
    ///
    /// It reuses the pending-link bindings rather than posting notifications,
    /// which is the pattern that replaced four hand-tuned `asyncAfter` delays in
    /// Session 63. Section first, then the value: the target view consumes it in
    /// `.task(id:)`, so it does not matter whether the view is already mounted.
    ///
    /// **Every case lands somewhere that shows the thing.** `.preview` never
    /// reaches here — the panel handles it in place, precisely so that this
    /// function never has to have a branch that switches a section and then
    /// shrugs.
    private func consumeSearchRoute() {
        guard let request = searchRoute.pending else { return }
        searchRoute.pending = nil
        openSearchResult(request.destination, query: request.query)
    }

    /// Where a note by container-relative path lives now that the Notes tab
    /// container is gone (Session 83). A day note is a DAY, so it opens on
    /// Today; a project note opens in Projects; a week note opens in Today's
    /// DAYS list with its rule picked. Anything else is ignored rather than
    /// guessed at — `linkableNotes()` only ever produces these folders.
    private func routeNote(_ path: String) {
        let filename = (path as NSString).lastPathComponent
        if path.hasPrefix(NoteStore.dailyFolder + "/") {
            let key = filename.replacingOccurrences(of: ".md", with: "")
            if let day = MacDaysList.dayFormatter.date(from: key) {
                dayInView = Calendar.current.startOfDay(for: day)
                selectedSection = .today
            }
        } else if path.hasPrefix(NoteStore.projectsFolder + "/") {
            selectedSection = .notes
            pendingProjectFile = filename
        } else if path.hasPrefix("Notes/Horizons/") {
            routeWeekFile(filename)
        }
    }

    /// "2026-W35.md" → Today, DAYS, Week 35 picked. A filename that is not an
    /// ISO week (the old Horizons folder also held month notes) opens nothing,
    /// which is what the Weekly tab did with its calendar header for those.
    @discardableResult
    private func routeWeekFile(_ filename: String) -> Bool {
        let stem = filename.replacingOccurrences(of: ".md", with: "")
        let parts = stem.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]),
              parts[1].hasPrefix("W"), let week = Int(parts[1].dropFirst()),
              (1...53).contains(week) else { return false }
        pendingDaysPick = .week(year: year, week: week)
        selectedSection = .today
        return true
    }

    private func openSearchResult(_ destination: MacSearchDestination, query: String) {
        // Recorded here because this is the single funnel every routed jump
        // already passes through — wikilinks, backlink rows, document chips,
        // search results and Ask citations all arrive at this function. One
        // insertion covers them all, and `.preview` is excluded because it opens
        // nothing to come back from.
        if destination != .preview { navigator.record(.record(destination)) }
        switch destination {
        case .dailyOrProjectNote(let path):
            routeNote(path)
        case .weeklyNote(let filename):
            routeWeekFile(filename)
        case .inboxNote(let filename):
            selectedSection = .inbox
            pendingInboxFile = filename
        case .person(let id):
            selectedSection = .directory
            pendingPersonID = id
        case .place(let id):
            selectedSection = .directory
            pendingPlaceID = id
        case .endeavor(let id):
            selectedSection = .endeavors
            pendingEndeavorID = id
        case .task(let id):
            selectedSection = .tasks
            pendingTaskID = id
        case .document(let path):
            selectedSection = .documents
            // Query first. `TraceMacDocumentsView` consumes the path in a
            // `.task(id:)`, so a value set after it would arrive to a consumer
            // that has already run.
            pendingDocumentQuery = query
            pendingDocumentPath = path
        case .preview:
            break
        }
    }

    // MARK: - Global file drop

    @discardableResult
    private func handleGlobalDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard error == nil,
                      let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue,
                      !url.lastPathComponent.hasPrefix(".") else { return }
                let ext = url.pathExtension.lowercased()
                guard !["txt", "md", "markdown", "text"].contains(ext) else { return }
                let store = TraceMacDocumentStore(noteStore: noteStore)
                do {
                    try store.importDocument(from: url)
                    Task { @MainActor in
                        // Switch to Documents section and reload
                        selectedSection = .documents
                        NotificationCenter.default.post(name: .reloadDocuments, object: nil)
                    }
                } catch { }
            }
            handled = true
        }
        return handled
    }

    // MARK: - Sidebar

    /// Sections as rows under group headers — the pattern this app already had,
    /// with the new grouping and names.
    ///
    /// Session 63 (2026-08-02). I built this as a sidebar of *groups* plus a tab
    /// bar in the detail. David: *"the tabs are not clickable"*, then after a
    /// hit-testing fix, *"still does not work"*, then after rebuilding them as a
    /// segmented `Picker`, *"still does not work"*.
    ///
    /// Three attempts, and the cost was not cosmetic: with the tabs dead,
    /// Billiards, Fitness, Photos, Weekly, Projects, Visits and Discover were
    /// **unreachable**. David noticed the way anyone would — *"removing
    /// billiards is not great...where is that"*. A navigation change that hides
    /// seven sections is not a partial success, it is a broken app.
    ///
    /// So this drops the tabs entirely and puts the sections back in the sidebar
    /// under `Section` headers, which is exactly what worked here before. The
    /// reorganisation survives: thirteen flat rows became four named groups plus
    /// three singles, Horizons is Weekly, Documents is Satchel, Visits is a peer
    /// of Places rather than a sheet inside it, and Photos moved to Activity.
    ///
    /// `selectedSection` is bound **directly**. The derived group binding went
    /// with the tabs — it was the newest and least proven thing in the change,
    /// and none of this needs it.
    /// Session 79, D186. The system `List(selection:)` sidebar is retired for
    /// the same reason the iOS tab bar was (D181): a floating system control
    /// speaking macOS's visual language, at the edge of a page speaking
    /// Editorial's. This is that tab bar stood on its end — paper panel, one
    /// hairline, small-caps wordmarks, monochrome glyphs, and the ONE accent
    /// used for exactly one thing: where you are.
    ///
    /// **What this costs.** `List(selection:)` gave arrow-key navigation and
    /// system focus rings for free, and a hand-built column does not. Clicking
    /// works, the hot key still works, and the Go menu still works — but if
    /// keyboard traversal of the sidebar turns out to matter, the answer is to
    /// add a focusable/`onMoveCommand` layer here, not to go back to `List`.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trace")
                .font(.system(size: 21, weight: .heavy, design: .serif))
                .foregroundStyle(MacEditorialColor.ink)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 11)
            MacEditorialRule.ink
                .padding(.horizontal, 20)

            groupLabel("The day")
            navRow(.today)
            navRow(.upcoming)
            navRow(.tasks)

            groupLabel("Records")
            navRow(.notes)
            navRow(.endeavors)
            navRow(.directory)
            navRow(.activity)
            navRow(.documents)
            navRow(.inbox)
            navRow(.archive)

            Spacer(minLength: 0)
            bottomRail
        }
        .frame(width: MacEditorialLayout.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(MacEditorialColor.panel)
    }

    /// **Settings, search, add** — the three things that belong to the app
    /// rather than to whichever screen is showing.
    ///
    /// Session 80, David, with a Things screenshot: "i want a visual element to
    /// the mac app as well where i can type. Im thinking of a magnifying glass
    /// on the bottom rail (which doesnt exist at the moment). It could include a
    /// settings button, and a magnifying glass and the plus symbol."
    ///
    /// **Why the sidebar and not the content pane.** Things puts its bar under
    /// the content because its sidebar is a list of projects. Here the sidebar
    /// is the app's own navigation, and these three controls are the app's too:
    /// none of them changes meaning when the section changes. Putting them under
    /// the content would imply they act on what is above them, which is exactly
    /// what they do not do.
    ///
    /// **The search glyph is not a second search.** It opens the same panel the
    /// hot key opens — David's rule from Session 79, "Id want in app to be the
    /// same as out of app", and a magnifying glass that opened a DIFFERENT
    /// search would be the two-shortcuts mistake wearing a picture.
    ///
    /// It replaces the floating `MacEditorialPlus` that Today, Upcoming and
    /// Tasks each carried. Three screens with a button in the same corner doing
    /// the same thing is one button in the wrong place.
    private var bottomRail: some View {
        VStack(spacing: 0) {
            MacEditorialRule.hair
            HStack(spacing: 0) {
                railButton("gearshape", "Settings") { openSettings() }
                Spacer(minLength: 0)
                railButton("magnifyingglass", "Search  \(hotKeys.combo.label)") {
                    MacQuickPanelController.shared.show()
                }
                Spacer(minLength: 0)
                railButton("plus", "New task") { composing = true }
            }
            .padding(.horizontal, 22)
            .frame(height: 42)
        }
    }

    private func railButton(_ icon: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MacEditorialColor.muted)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Up/down through the sidebar in the order it is drawn, which is
    /// `MacSection.allCases` — the enum's case order IS the sidebar's order, and
    /// keeping it that way is cheaper than a second list to fall out of step.
    /// Clamped rather than wrapped: arriving back at Today by pressing down
    /// eleven times is a surprise, and nothing else in this app wraps.
    /// One writer for the Dock badge, driven from the root view so it tracks
    /// the count and both switches without any screen having to remember to
    /// call it. Clearing on `false` is as important as setting on `true`: a
    /// badge nobody updates is a badge that lies for a week.

    // MARK: - The + rail's three other doors (D249)

    /// Perform a rail choice made in the composer.
    ///
    /// **The delay is not superstition.** The composer calls `dismiss()` and
    /// then this, in the same run loop. Presenting a second sheet while the
    /// first is still tearing down is how AppKit drops one of them, and the
    /// symptom is the worst kind — it works most of the time. A beat is the
    /// standard remedy and the only one that does not require the composer to
    /// stay on screen while its replacement arrives.
    private func performNew(_ kind: MacNewKind, seed: String) {
        switch kind {
        case .task:
            break
        case .projectNote:
            // **Synchronously, and that is the fix.** The first version put this
            // inside the same 0.2s delay the sheets need, which meant it ran off
            // a captured copy of this view long after its update had finished —
            // and an `@Environment` value read from a stale copy is not
            // guaranteed to be anything. The note was never written and nothing
            // said so. A no-sheet door has no teardown to wait for, so it does
            // its work now, while the view is still live.
            makeProjectNote(named: seed)
        case .person, .endeavor:
            if kind == .endeavor, endeavorStore == nil {
                endeavorStore = TraceMacEndeavorStore(noteStore: NoteStore.shared)
            }
            // Only the SHEET needs the beat: the composer is still tearing down,
            // and presenting into that is how AppKit drops one of the two. This
            // closure now writes nothing but `@State`, which is a stable box and
            // survives the view copy that the environment does not.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                newRequest = MacNewRequest(kind: kind, seed: seed)
            }
        }
    }

    /// Make — or simply open — `Notes/Projects/<name>.md`, and go there.
    ///
    /// **No sheet, because the name is the only thing a project note needs and
    /// the composer already collected it.** A confirmation step here would be a
    /// dialog whose one field is already filled in.
    ///
    /// The stem comes from `DayflowAgendaMatch.noteStem`, which is the same
    /// function a meeting uses to find its running note. That is deliberate and
    /// it is the payoff from D244 moving that type into `Trace/`: a project note
    /// made here for "Sarah <> David Catch up" lands on exactly the path that
    /// meeting's AGENDA line looks for, so the note shows up on the day without
    /// anybody linking anything.
    ///
    /// An existing note is opened rather than overwritten. Typing a name you
    /// already use should take you there; the alternative is a + that can
    /// silently destroy a note.
    private func makeProjectNote(named raw: String) {
        let stem = DayflowAgendaMatch.noteStem(raw)
        guard !stem.isEmpty else { return }
        // **`NoteStore.shared`, not the environment copy.** `TraceMacApp` injects
        // `NoteStore.shared` (unlike `NotionService`, which diverged until D248),
        // so these are provably the same object — and naming the store directly
        // means this cannot depend on when it is called relative to a view
        // update. Checked against the app's own declaration, not assumed.
        let store = NoteStore.shared
        // The folder name comes from `NoteStore.projectsFolder` rather than a
        // second copy of the string, because `TraceMacNotesView` decides which
        // TAB to open by testing that exact prefix. A literal here that drifted
        // by one character would write the file correctly and then route
        // nowhere, which is the least debuggable pair of behaviours available.
        let path = "\(NoteStore.projectsFolder)/\(stem).md"
        // **`fileExists`, because `(try? readFile(path)) == nil` never fires.**
        // `readFile` returns "" for a missing file rather than throwing, so that
        // test was false every single time and the write below was dead code.
        // The note was never created and the app navigated to it anyway. See the
        // note on `readFile` itself.
        if !store.fileExists(path) {
            do {
                try store.writeFile(path, content: "# \(stem)\n\n")
            } catch {
                // **Not `try?`.** A creation path that can fail silently is the
                // thing this evening kept finding. There is no banner on this
                // screen to raise, so the honest minimum is: say so where it can
                // be read, and do NOT navigate to a note that does not exist.
                NSLog("[NewProjectNote] write failed for %@: %@",
                      path, String(describing: error))
                return
            }
        }
        // **Confirmed on disk before routing, not assumed from a successful
        // write.** Routing to a note that is not there is not a harmless
        // no-op: `TraceMacProjectsView`'s deep-link arm appends the filename to
        // its list whether or not the file exists, and the editor then opens a
        // phantom and can save an empty buffer over it. A zero-byte
        // `project3.md` in David's vault is what that looks like from outside.
        guard store.fileExists(path) else {
            NSLog("[NewProjectNote] %@ still not on disk after write", path)
            return
        }
        openSearchResult(.dailyOrProjectNote(path), query: "")
    }

    /// **`reload()` before `create`, not after.** `TraceMacEndeavorStore.create`
    /// derives the new id from `endeavors.map(\.id)`, so a store that has never
    /// loaded thinks nothing exists and can mint an id that is already on disk.
    /// The Endeavors screen never hits this because it loads on appear; a door
    /// opened from the sidebar has no such screen behind it.
    private func createEndeavor(name: String, type: String,
                                starts: Date?, ends: Date?, destination: String) async {
        guard let store = endeavorStore else { return }
        if !store.hasLoaded { await store.reload() }
        guard let made = try? await store.create(name: name, type: type, starts: starts,
                                                 ends: ends, destination: destination)
        else { return }
        openSearchResult(.endeavor(made.id), query: "")
    }

    private func syncDockBadge() {
        // BOTH switches. The Dock toggle is only disabled in Settings when the
        // sidebar count is off — its stored value survives, so turning the
        // sidebar count off has to clear the badge here or the louder half
        // outlives the quieter one it was supposed to depend on.
        MacDockBadge.set(ReminderTaskStore.shared.inboxCount,
                         enabled: showDockBadge && showInboxCount)
    }

    private func moveSection(_ delta: Int) {
        let all = MacSection.allCases
        let current: MacSection = selectedSection ?? .today
        guard let index = all.firstIndex(of: current) else { return }
        let next: Int = min(max(index + delta, 0), all.count - 1)
        guard next != index else { return }
        selectedSection = all[next]
    }

    /// Left/right step the day, but only while Today is the section showing —
    /// on Satchel or Directory an arrow should do nothing rather than silently
    /// move a day you cannot see.
    private func stepDay(_ delta: Int) {
        guard (selectedSection ?? .today) == .today else { return }
        let cal = Calendar.current
        guard let moved = cal.date(byAdding: .day, value: delta, to: dayInView) else { return }
        dayInView = cal.startOfDay(for: moved)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .editorialGroupLabel()
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    private func navRow(_ section: MacSection) -> some View {
        // Every conditional resolved to a typed `let` before it reaches a
        // modifier — see the header note in TraceMacTodayView.swift for the
        // build this rule was bought with.
        let active: Bool = (selectedSection ?? .today) == section
        let tint: Color = active ? MacEditorialColor.accent : MacEditorialColor.faint
        return HStack(spacing: 10) {
            Image(systemName: section.icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(section.rawValue)
                .editorialNavLabel(active: active)
            Spacer(minLength: 0)
            // Only on TASKS, and only for the Inbox. The other pools are things
            // you go and look at; the Inbox is the only one that accumulates
            // whether you look or not, which is the difference between a count
            // that informs and a count that nags.
            if section == .tasks, showInboxCount {
                MacEditorialCount(count: ReminderTaskStore.shared.inboxCount)
            }
        }
        // Session 79: the accent left bar is retired at David's call. The
        // accent on the label is already the whole signal, and a second mark
        // saying the same thing is the kind of belt-and-braces this design
        // spent D181 removing.
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture { selectedSection = section }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        // Home removed, Session 64 (D2, and D21 for why it was never blocked).
        //
        // The stated blocker was that "Coming Up" had nowhere to land. **There
        // was no Coming Up on the Mac.** Every reference to it in the codebase
        // is in `Trace/` or `Satchel/` — it is an iOS Home concept, and the
        // Mac's Home never had it. The blocker was an iOS fact carried into a
        // Mac plan.
        //
        // What Mac Home actually held was three cards — Daily note, Recent
        // visits, Recent people — and each one's button set `selectedSection`
        // to a destination that already exists. It was a screen of shortcuts
        // to the sidebar sitting in the sidebar. `TraceMacApp` has defaulted
        // to `.notes` all along, so D2's "land on the day note" was already
        // true and Home was a row you could visit, not the landing screen.
        //
        // `nil` (deselecting in the sidebar List) now lands on Notes, which is
        // the same place launching lands.
        // Session 79, D186. `nil` (and launch) lands on Today, not Notes — the
        // day is what the app is opened for. Notes keeps its own case below.
        case .today, nil:
            TraceMacTodayView(date: $dayInView,
                              onOpenPlace: { openSearchResult(.place($0), query: "") },
                              onOpenNote: { openSearchResult(.dailyOrProjectNote($0), query: "") },
                              deepLinkDaysPick: $pendingDaysPick)
                .environment(noteStore)
                .environment(notionService)
        case .upcoming:
            TraceMacUpcomingView(dayInView: $dayInView,
                                 selectedSection: $selectedSection,
                                 onOpenPlace: { openSearchResult(.place($0), query: "") },
                                 onOpenNote: { openSearchResult(.dailyOrProjectNote($0), query: "") })
                .environment(noteStore)
                .environment(notionService)
        case .tasks:
            TraceMacTasksView(selectedSection: $selectedSection,
                              deepLinkTaskID: $pendingTaskID,
                              deepLinkList: $pendingTaskList,
                              onGoToDay: { day in
                                  dayInView = Calendar.current.startOfDay(for: day)
                                  selectedSection = .today
                              })
                // `MacTaskRow` resolves its document chips through NoteStore
                // (D227). Today, Upcoming and the quick panel already pass it;
                // this was the only host that did not, and a non-optional
                // `@Environment` traps when read, not when built — so the gap
                // would have shipped as a crash on opening a linked task here.
                .environment(noteStore)
        case .notes:
            TraceMacProjectsView(deepLinkFile: $pendingProjectFile)
                .environment(noteStore)
                .environment(notionService)
        case .endeavors:
            TraceMacEndeavorsView(deepLinkPersonID: $pendingPersonID,
                                  deepLinkDocumentPath: $pendingDocumentPath,
                                  deepLinkPlaceID: $pendingPlaceID,
                                  deepLinkNotePath: $pendingNotePath,
                                  deepLinkEndeavorID: $pendingEndeavorID,
                                  selectedSection: $selectedSection)
                .environment(noteStore)
                .environment(notionService)
        case .directory:
            TraceMacDirectoryView(deepLinkPersonID: $pendingPersonID,
                                  deepLinkPlaceID:  $pendingPlaceID)
                .environment(noteStore)
                .environment(notionService)
        case .activity:
            TraceMacActivityView()
                .environment(noteStore)
                .environment(notionService)
        case .documents:
            // **The router goes in, rather than a new one coming out.**
            // Three separate asks in one session — a tappable Endeavor row,
            // tappable People chips, a tag that filters — all needed the same
            // thing: somewhere for this screen to say "open that". Handing it
            // `openSearchResult` reuses the single funnel every routed jump in
            // the app already passes through, so back/forward (D112) records
            // these for free and no second vocabulary of places appears (D105).
            TraceMacDocumentsView(deepLinkPath: $pendingDocumentPath,
                                  deepLinkQuery: $pendingDocumentQuery,
                                  onOpen: { openSearchResult($0, query: "") })
                .environment(noteStore)
        case .inbox:
            TraceMacInboxView(deepLinkFile: $pendingInboxFile)
                .environment(noteStore)
        case .archive:
            TraceMacArchiveView()
                .environment(noteStore)
                .environment(notionService)
        }
    }
}

// MARK: - Shared document backlink row (People Phase 4 + Places Phase 5)

/// Row: doc icon, title, category pill, linked note name. Tap navigates to the
/// document in Documents via the same `.selectDocument` notification pattern
/// used elsewhere (see `.onReceive(.selectDocument)` in this file).
struct DocumentBacklinkRow: View {
    let doc: TraceMacDocument

    private var linkedNoteName: String? {
        guard let linked = doc.linkedNote, !linked.isEmpty else { return nil }
        return linked.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".md", with: "")
    }

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: .selectDocument, object: nil,
                userInfo: ["relativePath": doc.relativePath]
            )
        } label: {
            HStack(spacing: 10) {
                Image(systemName: doc.isPDF ? "doc.fill" : doc.isImage ? "photo" : "doc.text")
                    .foregroundStyle(doc.isPDF ? .red : doc.isImage ? .blue : .secondary)
                    .font(.body).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.title).font(.body).lineLimit(1).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(doc.category)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                        if let linkedNoteName {
                            Text(linkedNoteName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mentioned In section (content-based backlinks — shared by People + Place Notes tabs)

/// Collapsible, sortable list of notes whose body contains a `[[Name]]` wikilink pointing at
/// this person/place. Sort is a growable enum by design — add a case + a branch in
/// `sortedMentions(_:)` to offer another sort later (alphabetical, oldest-first, etc.).
/// Hidden entirely (returns EmptyView) when there are no mentions.
struct MentionedInSection: View {
    let mentions: [NoteMention]
    let onSelect: (NoteMention) -> Void

    @State private var isExpanded = true
    @State private var sort: MentionSort = .newestFirst

    enum MentionSort: String, CaseIterable, Identifiable {
        case newestFirst = "Latest first"
        var id: String { rawValue }
    }

    private func sortedMentions(_ items: [NoteMention]) -> [NoteMention] {
        switch sort {
        case .newestFirst:
            return items.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }

    var body: some View {
        if !mentions.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("Mentioned in (\(mentions.count))")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Sort menu is a sibling of the collapse button (not part of its label),
                    // so tapping it doesn't also toggle isExpanded.
                    Menu {
                        ForEach(MentionSort.allCases) { option in
                            Button {
                                sort = option
                            } label: {
                                if sort == option {
                                    Label(option.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(option.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                if isExpanded {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(sortedMentions(mentions)) { mention in
                                mentionRow(mention)
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    private func mentionRow(_ mention: NoteMention) -> some View {
        Button { onSelect(mention) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary).font(.body).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mention.title).font(.body).lineLimit(1).foregroundStyle(.primary)
                    if let modified = mention.modified {
                        Text(modified, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Identifiable wrapper so a plain note path can drive `.sheet(item:)`.
struct NotePreviewTarget: Identifiable, Hashable {
    let path: String
    var id: String { path }
}

/// Minimal read/write preview for an arbitrary note path — used when a "Mentioned in" row
/// might point at a daily note, project note, or any other note type, not just a person/place
/// canonical note. Deliberately lighter than `MacProjectNoteDetailView` (which assumes
/// project-style frontmatter + pulls associated Documents/People/Places).
struct MacNotePreviewSheet: View {
    let relativePath: String

    @Environment(\.dismiss) private var dismiss
    @Environment(NoteStore.self) private var noteStore

    private var title: String {
        (relativePath as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            TraceMacNoteEditor(relativePath: relativePath)
                .environment(noteStore)
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

// MARK: - Mac supporting views

/// Displays a photo from either a NoteStore relative path ("Photos/...") or a remote HTTPS URL.
struct MacNoteStorePhotoView: View {
    let urlString: String
    let size: CGFloat

    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: urlString) { nsImage = await loadImage() }
    }

    private func loadImage() async -> NSImage? {
        if urlString.hasPrefix("Photos/") {
            guard let fileURL = NoteStore.shared.resolvedURL(for: urlString) else { return nil }
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            let delays: [UInt64] = [300, 500, 1_000, 1_500, 2_000, 3_000]
            for delay in delays {
                if let img = NSImage(contentsOf: fileURL) { return img }
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            return NSImage(contentsOf: fileURL)
        } else if let url = URL(string: urlString) {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        return nil
    }
}

// MARK: - MacLogInteractionSheet

struct MacLogInteractionSheet: View {
    var preselectedPerson: Person?
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var personSearch   = ""
    @State private var selectedPerson: Person? = nil
    @State private var date           = Date()
    @State private var type           = "other"
    @State private var summary        = ""
    @State private var notes          = ""
    @State private var isSaving       = false
    @State private var saveError: String?
    @State private var pendingPhotos: [NSImage] = []
    @State private var showingPhotoPicker = false
    @State private var isDropTargeted    = false

    private let types = [
        "visit", "dinner", "lunch", "coffee", "call", "video call",
        "text", "email", "meeting", "event", "workout", "other"
    ]

    private var filteredPeople: [Person] {
        guard selectedPerson == nil, !personSearch.isEmpty else { return [] }
        return notionService.people
            .filter { $0.name.localizedCaseInsensitiveContains(personSearch) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log Interaction")
                .font(.headline)

            // Person
            VStack(alignment: .leading, spacing: 4) {
                Text("Person").font(.caption).foregroundStyle(.secondary)
                if let p = selectedPerson ?? preselectedPerson {
                    HStack {
                        Text(p.name).font(.body)
                        Spacer()
                        if preselectedPerson == nil {
                            Button { selectedPerson = nil; personSearch = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    TextField("Search people…", text: $personSearch)
                        .textFieldStyle(.roundedBorder)
                    if !filteredPeople.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredPeople) { person in
                                Button { selectedPerson = person; personSearch = "" } label: {
                                    Text(person.name)
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                if person.id != filteredPeople.last?.id { Divider() }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            // Date + Type
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Date").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(types, id: \.self) { t in
                            Button(t.capitalized) { type = t }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(type.capitalized)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(MacGlyph.small)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Summary
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").font(.caption).foregroundStyle(.secondary)
                TextField("Brief summary…", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }

            // Notes
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }

            // Photos
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Photos").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.purple)
                }

                if pendingPhotos.isEmpty {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDropTargeted ? Color.purple.opacity(0.1) : Color.secondary.opacity(0.06))
                        .frame(height: 56)
                        .overlay(
                            VStack(spacing: 3) {
                                Image(systemName: "photo.badge.plus")
                                    .foregroundStyle(isDropTargeted ? .purple : .secondary)
                                Text("Drop photos here or click Add")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isDropTargeted ? Color.purple.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers)
                        }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingPhotos.indices, id: \.self) { i in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: pendingPhotos[i])
                                        .resizable().scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Button {
                                        pendingPhotos.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                                            .font(MacGlyph.control)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                }
                            }
                            Button {
                                showingPhotoPicker = true
                            } label: {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(width: 72, height: 72)
                                    .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingPhotoPicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        let _ = url.startAccessingSecurityScopedResource()
                        if let img = NSImage(contentsOf: url) { pendingPhotos.append(img) }
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled((selectedPerson == nil && preselectedPerson == nil) || isSaving)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage {
                        DispatchQueue.main.async { pendingPhotos.append(img) }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func save() {
        guard let person = selectedPerson ?? preselectedPerson else { return }
        isSaving = true
        Task {
            do {
                let interaction = try await notionService.createInteraction(
                    personID: person.id, summary: summary, date: date, type: type, notes: notes)
                // Upload photos after the page exists
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                for (i, photo) in pendingPhotos.enumerated() {
                    if let tiff = photo.tiffRepresentation,
                       let bmp = NSBitmapImageRep(data: tiff),
                       let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        let filename = "interaction-\(formatter.string(from: date))-\(i).jpg"
                        let path = try NoteStore.shared.writePhoto(jpeg, category: "Interactions", filename: filename)
                        try await notionService.addPhotoToPage(interaction.id, photoURL: path)
                    }
                }
                await notionService.fetchRecentInteractions()
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - MacEditInteractionSheet

struct MacEditInteractionSheet: View {
    let interaction: Interaction
    let person: Person?
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var date           = Date()
    @State private var type           = "other"
    @State private var summary        = ""
    @State private var notes          = ""
    @State private var isSaving       = false
    @State private var saveError: String?
    @State private var pendingPhotos: [NSImage] = []
    @State private var showingPhotoPicker = false
    @State private var isDropTargeted    = false

    private let types = [
        "visit", "dinner", "lunch", "coffee", "call", "video call",
        "text", "email", "meeting", "event", "workout", "other"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Edit Interaction")
                    .font(.headline)
                if let p = person {
                    Text("— \(p.name)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            // Date + Type
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Date").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(types, id: \.self) { t in
                            Button(t.capitalized) { type = t }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(type.capitalized)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(MacGlyph.small)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").font(.caption).foregroundStyle(.secondary)
                TextField("Brief summary…", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }

            // Photos
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Photos").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Add", systemImage: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.purple)
                }

                let existingURLs = interaction.photoURLs
                let hasAny = !existingURLs.isEmpty || !pendingPhotos.isEmpty

                if !hasAny {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDropTargeted ? Color.purple.opacity(0.1) : Color.secondary.opacity(0.06))
                        .frame(height: 56)
                        .overlay(
                            VStack(spacing: 3) {
                                Image(systemName: "photo.badge.plus")
                                    .foregroundStyle(isDropTargeted ? .purple : .secondary)
                                Text("Drop photos here or click Add")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isDropTargeted ? Color.purple.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers)
                        }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // Existing photos (read display only)
                            ForEach(existingURLs, id: \.self) { urlString in
                                MacNoteStorePhotoView(urlString: urlString, size: 72)
                            }
                            // Pending new photos (removable)
                            ForEach(pendingPhotos.indices, id: \.self) { i in
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: pendingPhotos[i])
                                        .resizable().scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Button {
                                        pendingPhotos.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                                            .font(MacGlyph.control)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                }
                            }
                            // Add more button
                            Button {
                                showingPhotoPicker = true
                            } label: {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(width: 72, height: 72)
                                    .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingPhotoPicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        let _ = url.startAccessingSecurityScopedResource()
                        if let img = NSImage(contentsOf: url) { pendingPhotos.append(img) }
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }

            if let err = saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            date    = interaction.date
            type    = interaction.type
            summary = interaction.summary
            notes   = interaction.notes ?? ""
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    if let img = obj as? NSImage {
                        DispatchQueue.main.async { pendingPhotos.append(img) }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await notionService.updateInteraction(
                    id: interaction.id, summary: summary, type: type, date: date, notes: notes)
                // Upload any new photos
                if !pendingPhotos.isEmpty {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                    for (i, photo) in pendingPhotos.enumerated() {
                        if let tiff = photo.tiffRepresentation,
                           let bmp = NSBitmapImageRep(data: tiff),
                           let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                            let filename = "interaction-\(formatter.string(from: date))-\(i).jpg"
                            let path = try NoteStore.shared.writePhoto(jpeg, category: "Interactions", filename: filename)
                            try await notionService.addPhotoToPage(interaction.id, photoURL: path)
                        }
                    }
                }
                await notionService.fetchRecentInteractions()
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - MacAgendaSheet

struct MacAgendaSheet: View {
    // nil = home-screen entry point; presents a search picker first.
    // Row-level entry points (peopleCard hover/context-menu) still pass a fixed person.
    var preselectedPerson: Person? = nil
    @Environment(NotionService.self) private var notionService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPerson: Person?
    @State private var personSearch = ""
    @State private var agenda    = ""
    @State private var isSaving  = false
    @State private var saveError: String?

    init(preselectedPerson: Person? = nil) {
        self.preselectedPerson = preselectedPerson
        _selectedPerson = State(initialValue: preselectedPerson)
        _agenda         = State(initialValue: preselectedPerson?.agenda ?? "")
    }

    private var filteredPeople: [Person] {
        let q = personSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let all = notionService.people
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let person = selectedPerson {
                HStack {
                    Text("Agenda — \(person.name)").font(.headline)
                    // Only offer to change the person when we got here via the
                    // open-ended entry point — row-level entry points are locked.
                    if preselectedPerson == nil {
                        Spacer()
                        Button {
                            selectedPerson = nil
                            agenda = ""
                            personSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("One item per line. Shows as talking points in 1:1 meetings.")
                    .font(.caption).foregroundStyle(.secondary)

                TextEditor(text: $agenda)
                    .font(.body)
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                if let err = saveError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                }
            } else {
                Text("Edit Agenda").font(.headline)
                TextField("Search people…", text: $personSearch)
                    .textFieldStyle(.roundedBorder)
                if filteredPeople.isEmpty {
                    Text("No matches.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredPeople.prefix(8)) { p in
                                Button {
                                    selectedPerson = p
                                    agenda = p.agenda ?? ""
                                } label: {
                                    Text(p.name)
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                }
                                .buttonStyle(.plain)
                                if p.id != filteredPeople.prefix(8).last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func save() {
        guard let person = selectedPerson else { return }
        isSaving = true
        Task {
            do {
                try await notionService.updatePersonAgenda(id: person.id, agenda: agenda)
                if let idx = notionService.people.firstIndex(where: { $0.id == person.id }) {
                    notionService.people[idx].agenda = agenda.isEmpty ? nil : agenda
                }
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - Custom billiards rack icon (triangle of circles)
//
// Restored in Session 63 after the tab experiment briefly removed it. It went
// unreferenced only because the segmented tab bar was text-only; the sidebar
// rows use icons, so it is live again.

struct BilliardsRackIcon: View {
    var color: Color = .purple

    var body: some View {
        Canvas { ctx, size in
            let d: CGFloat = 3.6          // ball diameter
            let hStep: CGFloat = 4.8      // horizontal center-to-center
            let vStep: CGFloat = hStep * 0.866  // equilateral triangle row height

            // Rack: 3 rows — 1 ball (top), 2 balls, 3 balls (bottom)
            let rows: [(count: Int, indent: CGFloat)] = [
                (1, hStep),        // top
                (2, hStep / 2),    // middle
                (3, 0),            // bottom
            ]

            let rackWidth  = 2 * hStep + d
            let rackHeight = 2 * vStep + d
            let ox = (size.width  - rackWidth)  / 2
            let oy = (size.height - rackHeight) / 2

            for (rowIdx, row) in rows.enumerated() {
                let y = oy + CGFloat(rowIdx) * vStep
                for col in 0..<row.count {
                    let x = ox + row.indent + CGFloat(col) * hStep
                    let rect = CGRect(x: x, y: y, width: d, height: d)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .frame(width: 18, height: 18)
    }
}
