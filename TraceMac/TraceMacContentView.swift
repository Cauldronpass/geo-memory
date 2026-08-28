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
    /// One destination covering Daily, Weekly and Projects. The tab lives in
    /// `TraceMacNotesView`'s own `@State` — see the note there for why.
    case notes     = "Notes"
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
    case inbox     = "Inbox"
    case archive   = "Archive"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .notes:     return "book.pages"
        case .endeavors: return "flag"
        case .directory: return "person.2"
        case .activity:  return "figure.run"
        case .documents: return "doc.richtext"
        case .inbox:     return "tray"
        case .archive:   return "archivebox"
        }
    }

    var iconColor: Color {
        switch self {
        case .notes:     return .traceOrange
        case .endeavors: return .indigo
        case .directory: return .indigo
        // Session 64: these four were frozen hex while `.directory` and
        // `.inbox` two lines away used SwiftUI system colours and adapted
        // correctly. Two rows right, five wrong, in one switch. See
        // MacColor.swift.
        case .activity:  return MacPalette.green
        case .documents: return MacPalette.blue        // satchelBlue
        case .inbox:     return .gray
        case .archive:   return MacPalette.brown
        }
    }
}

// MARK: - Root view

struct TraceMacContentView: View {

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @Binding var selectedSection: MacSection?
    @State private var pendingHorizonsFile: String? = nil
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
    // Not a new idea: `pendingHorizonsFile` above has worked this way all along.
    // It was the one deep link with no timing hack in it, and it was the model
    // for these three.
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
    /// Bare filename into the Inbox list, same shape as `pendingHorizonsFile`.
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
                selectedSection = .notes
                pendingHorizonsFile = filename
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
                selectedSection = .notes
                pendingNotePath = note.relativePath
            }
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
            navigator.record(.section(new ?? .notes))
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
            // The floating panel needs these two, and this is where they live —
            // `TraceMacApp` builds its own `NotionService` rather than using the
            // shared one, so a panel that reached for `NotionService.shared`
            // would search a second, empty copy and report that nobody exists.
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

    private func openSearchResult(_ destination: MacSearchDestination, query: String) {
        // Recorded here because this is the single funnel every routed jump
        // already passes through — wikilinks, backlink rows, document chips,
        // search results and Ask citations all arrive at this function. One
        // insertion covers them all, and `.preview` is excluded because it opens
        // nothing to come back from.
        if destination != .preview { navigator.record(.record(destination)) }
        switch destination {
        case .dailyOrProjectNote(let path):
            selectedSection = .notes
            pendingNotePath = path
        case .weeklyNote(let filename):
            selectedSection = .notes
            pendingHorizonsFile = filename
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
    private var sidebar: some View {
        List(selection: $selectedSection) {
            // Session 64: `row(.home)` removed. See the detail switch below.
            row(.notes).tag(MacSection.notes)

            row(.endeavors).tag(MacSection.endeavors)

            row(.directory).tag(MacSection.directory)

            row(.activity).tag(MacSection.activity)

            // No group headers left: every group became a row of its own, which
            // is what made the column shorter rather than merely rearranged.
            Section {
                row(.documents).tag(MacSection.documents)
                row(.inbox).tag(MacSection.inbox)
                row(.archive).tag(MacSection.archive)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 200)
    }

    private func row(_ section: MacSection) -> some View {
        Label {
            Text(section.rawValue)
        } icon: {
            Image(systemName: section.icon)
                .foregroundStyle(section.iconColor)
        }
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
        case .notes, nil:
            TraceMacNotesView(deepLinkFile: $pendingHorizonsFile,
                              deepLinkNotePath: $pendingNotePath)
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
