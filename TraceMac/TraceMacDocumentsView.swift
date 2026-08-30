// TraceMacDocumentsView.swift
// Browse, search, filter, and view documents stored in Trace's iCloud container.
// PDFs render inline via PDFKit. Images display inline. Tags via sidecar .md files.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - Main view

struct TraceMacDocumentsView: View {

    /// Set by `TraceMacContentView` when something asks to open a specific
    /// document. Consumed in `.task(id:)` below and cleared. Unlike the person
    /// and place links this one has to wait for the store, since a relative path
    /// means nothing until the folder scan has run. See the deep link note in
    /// `TraceMacContentView`.
    var deepLinkPath: Binding<String?>? = nil

    /// The search text that produced `deepLinkPath`, so the PDF viewer can
    /// paint it on the page. Consumed and cleared alongside the path.
    var deepLinkQuery: Binding<String?>? = nil

    /// Open a record elsewhere in the app.
    ///
    /// Supplied by `TraceMacContentView` and wired straight to
    /// `openSearchResult`, which is the one funnel every routed jump already
    /// uses. Typed as `MacSearchDestination` for the reason D105 records: a
    /// second enum of places, with its own switch over the same folders, is
    /// drift this project has already paid for three times.
    var onOpen: ((MacSearchDestination) -> Void)? = nil

    @Environment(NoteStore.self) private var noteStore

    @State private var store: TraceMacDocumentStore? = nil
    /// **One per section, not one per document.** It lived on
    /// `DocMetadataPanel`, which is rebuilt on every selection, so choosing a
    /// document walked the Endeavors folder again — main-actor file reads over
    /// iCloud, and David got a spinning wheel for it. The panel now receives a
    /// store that is loaded once.
    @State private var endeavorStore: TraceMacEndeavorStore? = nil
    @State private var selectedDoc: TraceMacDocument? = nil
    @State private var searchText = ""
    /// Multi-select since Session 73, and the reason the Tags pill changed
    /// shape. It was `activeTag: String?`, owned outright by that pill; the
    /// filter pane needs a set so tags can narrow by AND, and two controls
    /// cannot hold two versions of one filter. The pill is now a view onto
    /// this — see `filterBar`.
    @State private var selectedTags: Set<String> = []
    /// OR within the axis, because a document has exactly one icon. See the
    /// semantics note in `TraceMacDocumentFacets.swift`.
    @State private var selectedIcons: Set<DocumentIcon> = []
    /// OR within the axis, for the same reason.
    @State private var selectedTints: Set<DocumentTint> = []
    @State private var activeProject: String? = nil
    @State private var filterYear: Int? = nil
    @State private var filterMonth: Int? = nil
    @State private var listCollapsed = false
    @State private var isDropTargeted = false

    // Filter popover visibility
    @State private var showingTagFilter = false
    @State private var showingProjectFilter = false
    @State private var showingDateFilter = false

    // Preview / metadata split. Session 63 (2026-08-02).
    //
    // Stored as a *fraction* of the available height rather than an absolute
    // one, so resizing the window keeps the proportion the user chose instead
    // of pinning the preview and eating the metadata. Live drag is kept
    // separate in `@GestureState` so it unwinds on its own if the gesture is
    // cancelled. See the note at the split in `rightColumn` for why both panes
    // are sized explicitly.
    @State private var previewFraction: CGFloat = 0.58
    @GestureState private var previewDrag: CGFloat = 0
    @State private var zoom = PreviewZoomController()
    /// Find-in-PDF for whatever is on screen. Owned here rather than by the
    /// representable so the match chip can live outside the `PDFView` and
    /// survive its rebuilds, exactly as `zoom` does.
    @State private var find = MacPDFFind()
    @State private var navigator = MacNavigator.shared
    /// Remembered across launches. The two inline copies of this strip in
    /// People and Places used plain `@State`, so a widened column was narrow
    /// again on the next launch.
    @AppStorage("tracemac.column.satchel") private var listWidth: Double = 240

    /// The filter pane. Remembered across launches like the column opposite it
    /// — a pane you have to reopen every morning is one you stop opening.
    @AppStorage(SatchelFilterPane.visibleKey) private var showFacets = false
    @AppStorage(SatchelFilterPane.widthKey) private var facetWidth: Double = SatchelFilterPane.defaultWidth
    /// Only so the header button's tooltip can name the current combination.
    /// The key itself is caught in `TraceMacContentView` — see the note there.
    @State private var filterShortcut = MacSatchelFilterShortcut.shared

    /// Divider strip height. Thick enough to aim at without hunting.
    private let dividerThickness: CGFloat = 6

    // Row context menu. Session 63 (2026-08-02) — David: *"archive and delete of
    // a file isnt currently visible"*. Delete did exist, at the bottom of the
    // metadata disclosure group, which is both the last place you would look and
    // now behind a scroll. Right-click on the thing you want to act on is where
    // a Mac user reaches first, and the list had no context menu at all.
    @State private var deleteCandidate: TraceMacDocument? = nil

    // The category tab row lived here until Session 69 (2026-08-10). It listed
    // `["Inbox", "Project", "Place", "Trip"]` plus any other subfolder found on
    // disk, and it was the last surviving piece of an axis `Documents-App-Scope.md`
    // removed on 2026-07-28 — "the folder is now the year", with retrieval by
    // type, `endeavor`, `linked_note`, tags and Kit. That doc also says the
    // move-to-another-folder command "was never built, deliberately — it would
    // have put back the axis being removed." TraceMac had it anyway, because
    // only Satchel was migrated.
    //
    // David, arriving at it from the other end: *"i have to continually organize
    // things to either places or trips... we decided on tags instead of folders
    // so i am not sure why this is like this."* Those four words were these four
    // tabs. Nothing decided it; the change simply never reached this file.
    //
    // Year is still filterable — `filterYear` below reads the sidecar's
    // `created` date, which is a fact about the document rather than a folder
    // somebody had to choose.

    private var filtered: [TraceMacDocument] {
        guard let store else { return [] }
        let tokens = searchTokens
        return store.documents.filter { matches($0, tokens: tokens) }
    }

    /// The one predicate, with each facet axis switchable off.
    ///
    /// Split out in Session 73 so the filter pane can count a facet against
    /// every filter EXCEPT its own axis, which is what stops every unselected
    /// icon reading zero the moment one icon is picked. A second copy of this
    /// logic written for the counts is exactly the drift
    /// [[feedback_trace_renderer_drift]] records, one level down.
    /// **Read once by each caller and passed down**, which is why `matches`
    /// takes tokens rather than reaching for this itself: it is a computed
    /// property, so touching it inside the predicate would re-split the query
    /// once per document across four separate filters over the whole store.
    private var searchTokens: [String] { DocumentSearch.tokens(from: searchText) }

    private func matches(_ doc: TraceMacDocument,
                         tokens: [String],
                         applyIcons: Bool = true,
                         applyTints: Bool = true,
                         applyTags: Bool = true) -> Bool {
        let cal = Calendar.current

        // ── Text ──────────────────────────────────────────────────────────
        //
        // **One predicate, in `Trace/DocumentSearchPredicate.swift`, shared with
        // Satchel through `membershipExceptions`.** Eleven clauses lived here
        // and eleven near-identical ones lived on the phone, kept in step by
        // hand and by a comment asking the next reader to diff them by eye.
        // D134 is what that cost: this predicate was missing five fields the
        // phone had matched for months, and nothing failed — a search that
        // returns too little still returns something.
        //
        // The shared version also closes the two gaps D134 could only log
        // (`filename` on iOS, `note` and `summary` on both) and matches by
        // token rather than by whole string, so "Arlington Animal" finds
        // "Arlington Heights Animal Hospital".
        let matchesSearch = DocumentSearch.matches(doc, tokens: tokens)

        // ── Facets ────────────────────────────────────────────────────────
        //
        // OR within icon and within tint (a document has one of each, so AND
        // would always be empty); AND within tags (a document has many, and
        // narrowing is the point); AND across all three.
        let matchesIcon = !applyIcons || selectedIcons.isEmpty
            || selectedIcons.contains(doc.resolvedIcon)
        let matchesTint = !applyTints || selectedTints.isEmpty
            || selectedTints.contains(doc.resolvedTint)
        let matchesTag = !applyTags || selectedTags.isSubset(of: Set(doc.tags))

        let matchesProject = activeProject == nil || doc.linkedNote == activeProject
        let matchesYear = filterYear == nil || {
            guard let d = doc.created else { return false }
            return cal.component(.year, from: d) == filterYear!
        }()
        let matchesMonth = filterMonth == nil || {
            guard let d = doc.created else { return false }
            return cal.component(.month, from: d) == filterMonth!
        }()
        return matchesSearch && matchesIcon && matchesTint && matchesTag
            && matchesProject && matchesYear && matchesMonth
    }

    // `noteDisplayName` lived here, existing only to serve the search predicate
    // above — its own doc comment said it returned "" rather than an optional
    // "so the caller stays one flat `||` chain like the iOS one it is being kept
    // in step with." That chain is gone, and so is the reason for the shape.
    // `DocumentSearch.noteDisplayName` is the one that matters now.
    //
    // Removed rather than left: a private helper with no callers is a thing the
    // next reader has to prove is dead before they can touch anything near it.

    /// Everything the filter pane draws. Rebuilt when anything it depends on
    /// moves, which on a library this size is far cheaper than caching it.
    private var facetModel: DocFacetModel {
        guard let store else { return DocFacetModel() }
        let tokens = searchTokens
        return DocFacetModel.build(
            all: store.documents,
            matchingWithoutIcons: { matches($0, tokens: tokens, applyIcons: false) },
            matchingWithoutTints: { matches($0, tokens: tokens, applyTints: false) },
            matchingAll:          { matches($0, tokens: tokens) }
        )
    }

    /// Unique (year, month) pairs across all docs, newest first.
    private var availableDates: [(year: Int, month: Int)] {
        guard let store else { return [] }
        let cal = Calendar.current
        var seen = Set<String>()
        var result: [(year: Int, month: Int)] = []
        for doc in store.documents {
            guard let d = doc.created else { continue }
            let y = cal.component(.year, from: d)
            let m = cal.component(.month, from: d)
            let key = "\(y)-\(m)"
            if !seen.contains(key) { seen.insert(key); result.append((y, m)) }
        }
        return result.sorted { $0.year != $1.year ? $0.year > $1.year : $0.month > $1.month }
    }

    private var availableYears: [Int] {
        Array(Set(availableDates.map(\.year))).sorted(by: >)
    }

    /// All unique project note paths used by docs in the Project category.
    private var projectList: [(path: String, name: String)] {
        guard let store else { return [] }
        var seen = Set<String>()
        var result: [(path: String, name: String)] = []
        for doc in store.documents where doc.category == "Project" {
            if let note = doc.linkedNote, !note.isEmpty, !seen.contains(note) {
                seen.insert(note)
                let name = note.components(separatedBy: "/").last?
                    .replacingOccurrences(of: ".md", with: "") ?? note
                result.append((path: note, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private var allTags: [String] {
        guard let store else { return [] }
        return Array(Set(store.documents.flatMap { $0.tags })).sorted()
    }

    /// What the Tags pill says. One tag by name; several by count, since the
    /// names would not fit and a truncated list is worse than an honest number.
    private var tagPillLabel: String {
        switch selectedTags.count {
        case 0:  return "Tags"
        case 1:  return selectedTags.first ?? "Tags"
        default: return "\(selectedTags.count) tags"
        }
    }

    // Human-readable label for the active date filter
    private var dateFilterLabel: String? {
        guard filterYear != nil || filterMonth != nil else { return nil }
        let monthName = filterMonth.map {
            DateFormatter().monthSymbols[$0 - 1]
        }
        switch (filterYear, monthName) {
        case (let y?, let m?): return "\(m) \(y)"
        case (let y?, nil):    return "\(y)"
        case (nil, let m?):    return m
        default:               return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session 63 (2026-08-02). This screen used to begin at y = 0 with
            // a search field, while Notes, Directory and Archive began below a
            // tab strip — so moving between them moved the whole content down
            // and back up. It has no tabs to put in the header, which is the
            // point: the header is there anyway, so the origin does not move.
            //
            // "Satchel", not "Documents". The sidebar row already says Satchel
            // (the folder on disk stays `Documents/` — see `MacSection`), and a
            // header that disagreed with the row you clicked would be worse than
            // no header.
            // Two buttons now. David: *"a right hand pane that appears or
            // disappears with a keyboard stroke or an icon on the top right
            // next to the plus."*
            //
            // The tooltip names the **current** combination rather than a
            // literal, because Session 73 made it settable and a tooltip that
            // says ⇧⌘F after he has changed it is worse than one that says
            // nothing: it is a confident wrong answer about his own settings.
            MacSectionHeader("Satchel",
                             leadingAction: MacHeaderButton(
                                icon: showFacets
                                    ? "line.3.horizontal.decrease.circle.fill"
                                    : "line.3.horizontal.decrease.circle",
                                help: (showFacets ? "Hide filters (" : "Show filters (")
                                      + filterShortcut.combo.label + ")") {
                                    showFacets.toggle()
                                },
                             action: MacHeaderButton(icon: "plus",
                                                     help: "Add a document") { importDocument() })
            columns
        }
    }

    /// The screen itself. Split out only so `body` can put a header above it
    /// without re-indenting five hundred lines; nothing here changed.
    private var columns: some View {
        HStack(spacing: 0) {
            if !listCollapsed {
                leftColumn
                MacColumnResizer(width: $listWidth)
            }
            CollapseHandle(isCollapsed: $listCollapsed, collapsesRight: false, showLine: true, panelColor: .clear)
            rightColumn.frame(maxWidth: .infinity)
            if showFacets {
                // `.trailing`, and this is the only site that needs it: the
                // pane is to the RIGHT of the strip, so it grows as you drag
                // left. `showsLine` because there is no column beyond it to
                // draw the seam for free.
                MacColumnResizer(width: $facetWidth,
                                 minWidth: SatchelFilterPane.minWidth,
                                 maxWidth: SatchelFilterPane.maxWidth,
                                 edge: .trailing,
                                 showsLine: true)
                DocFacetPanel(model: facetModel,
                              selectedIcons: $selectedIcons,
                              selectedTints: $selectedTints,
                              selectedTags: $selectedTags,
                              width: CGFloat(facetWidth),
                              resultCount: filtered.count)
            }
        }
        .task {
            if store == nil {
                store = TraceMacDocumentStore(noteStore: noteStore)
            }
            await store?.reload()
        }
        // A file arrived under `Documents/` from outside this process — the
        // Dropzone action, Satchel on the phone, or the iPad. Session 69: until
        // `NoteStore`'s metadata query learned to watch that folder there was no
        // signal at all, and David had to leave the tab and come back to see a
        // file he had just dropped.
        //
        // Debounced by a beat because a single drop lands as two events, the
        // binary and then its sidecar, and reloading twice makes the list jump.
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreDocumentsDidChange)) { _ in
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                await store?.reload()
                // Before the AI scan, not after. This is local and free, and
                // running it first means a document dropped a second ago is
                // searchable by its contents whether or not the scan that
                // follows ever completes.
                await store?.extractTextForNewArrivals()
                await store?.autoScanNewArrivals()
            }
        }
        .task(id: deepLinkPath?.wrappedValue) {
            guard let path = deepLinkPath?.wrappedValue else { return }
            // The store may not have scanned yet on a cold jump into this
            // section. Build and load it here rather than hoping the `.task`
            // above won the race — that hope is exactly what the old 0.4s delay
            // was standing in for.
            if store == nil { store = TraceMacDocumentStore(noteStore: noteStore) }
            if endeavorStore == nil {
                endeavorStore = TraceMacEndeavorStore(noteStore: noteStore)
                await endeavorStore?.reload()
            }
            if store?.documents.isEmpty ?? true { await store?.reload() }
            // Query before selection. Setting `selectedDoc` builds the
            // viewer, and the viewer reads `find.query` as it loads; assigning
            // it afterwards would mean the first load searched for nothing.
            find.query = deepLinkQuery?.wrappedValue ?? ""
            find.targetPath = path
            deepLinkQuery?.wrappedValue = nil
            selectedDoc = store?.documents.first { $0.relativePath == path }
            deepLinkPath?.wrappedValue = nil
        }
        // Picking a different document by hand is not a search result, so the
        // highlight goes with the document that was searched for. Without this
        // the chip would follow you around the list claiming hits from a query
        // you had moved on from.
        .onChange(of: selectedDoc) { old, new in
            guard old?.relativePath != new?.relativePath else { return }
            if new?.relativePath != find.targetPath { find.clear() }
            // Which document, so back from here returns to it rather than to a
            // Satchel list scrolled somewhere else.
            if let path = new?.relativePath { navigator.record(.record(.document(path))) }
        }
        // Escape clears the highlight. David: *"how do i remove the highlights
        // with a keystroke easily other than exiting the document and
        // returning"* — and clicking the chip's × was the only way.
        //
        // **`nil` when there is nothing to clear, and that is the whole point of
        // writing it this way.** `onExitCommand` takes an optional action, so
        // passing nil leaves Escape to whatever else wants it rather than
        // silently swallowing every Escape in the Satchel section for a
        // highlight that is not showing. A key that is consumed and does nothing
        // is the same defect as a menu item that is.
        //
        // **Not a menu command with `.keyboardShortcut(.escape)`.** Menu key
        // equivalents are matched before the responder chain, so an app-wide
        // Escape item would outrank the Escape that dismisses a sheet or a
        // confirmation dialog — including the delete confirmation attached a few
        // lines above this. `onExitCommand` rides `cancelOperation:` up the
        // responder chain instead, which is the chain those dialogs already own.
        //
        // Attached to the whole split rather than to the viewer, because focus
        // may be on the document list rather than inside the `PDFView`, and both
        // are below this.
        .onExitCommand(perform: find.isShowing ? { find.clear() } : nil)
        .onReceive(NotificationCenter.default.publisher(for: .reloadDocuments)) { _ in
            Task { await store?.reload() }
        }
        // Attached here rather than to the row: the row is destroyed the moment
        // the delete lands, and a confirmation owned by a view that no longer
        // exists never gets to dismiss itself.
        .confirmationDialog(
            deleteCandidate.map { "Delete \"\($0.title)\"?" } ?? "Delete this document?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let doc = deleteCandidate { deleteDocument(doc) }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("This removes the file and its sidecar from iCloud on every device.")
        }
        // The window toolbar keeps only the two commands that act on the
        // SELECTED DOCUMENT. Import moved to the section header's `+` in
        // Session 65 rather than being duplicated there: it is the section's
        // own verb, not the selection's, and sitting between Open and Reveal
        // it read as a third thing you could do to the document in front of
        // you. `square.and.arrow.down` was also the download glyph, which says
        // the file comes from somewhere — true, and not the point.
        .toolbar {
            if let doc = selectedDoc, let url = noteStore.resolvedURL(for: doc.relativePath) {
                ToolbarItem {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Open", systemImage: "arrow.up.forward.square")
                    }
                }
                ToolbarItem {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
            }
        }
    }

    // MARK: - Row context menu

    /// Deliberately no "Archive". `Documents/Archive/` was removed in Session 63
    /// as a relic — David: *"I don't use it. It's a relic."* — and iOS has no
    /// archive concept for documents at all. A document you are done with simply
    /// falls down the list. Filing is `endeavor`, `linked_note`, `tags` and
    /// `pinned`, none of which move the file anywhere.
    @ViewBuilder
    private func rowMenu(for doc: TraceMacDocument) -> some View {
        if let url = noteStore.resolvedURL(for: doc.relativePath) {
            Button("Open in Default App") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            ShareLink(item: url) { Text("Share…") }
            Divider()
        }
        Button("Delete…", role: .destructive) { deleteCandidate = doc }
    }

    private func deleteDocument(_ doc: TraceMacDocument) {
        Task {
            // Both halves, and the sidecar second: if the binary delete throws,
            // an orphaned sidecar is a stray note, whereas an orphaned document
            // with no sidecar loses every piece of metadata attached to it.
            try? noteStore.deleteFile(doc.relativePath)
            try? noteStore.deleteFile(doc.sidecarPath)
            await store?.reload()
            await MainActor.run {
                if selectedDoc?.relativePath == doc.relativePath { selectedDoc = nil }
            }
        }
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(spacing: 0) {
            // Search
            TextField("Search documents", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            .padding(.bottom, 2)

            Divider()

            // Filter bar — Tag, Project (when in Project tab), Date
            filterBar
            Divider()

            // Document list + drop zone
            ZStack {
                if let store, store.isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Loading…")
                        Spacer()
                    }
                } else if filtered.isEmpty {
                    VStack {
                        Spacer()
                        MacEmptyState.list("doc.richtext",
                                           store?.documents.isEmpty == true
                                           ? "No documents yet.\nDrag files here or use Import."
                                           : "No matches.")
                        Spacer()
                    }
                } else {
                    List(filtered, selection: $selectedDoc) { doc in
                        DocListRow(doc: doc)
                            .tag(doc)
                            .contextMenu { rowMenu(for: doc) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .windowBackgroundColor))
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                Group {
                    if isDropTargeted {
                        ZStack {
                            Color.accentColor.opacity(0.08)
                            VStack(spacing: 10) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 36, weight: .thin))
                                    .foregroundStyle(Color.accentColor)
                                Text("Drop to import")
                                    .font(.subheadline).fontWeight(.medium)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(3)
                        )
                        .allowsHitTesting(false)
                    }
                }
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
        .frame(width: listWidth)
    }

    // MARK: - Drop handler

    @discardableResult
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard error == nil,
                      let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue,
                      !url.lastPathComponent.hasPrefix(".") else { return }
                let ext = url.pathExtension.lowercased()
                if ["txt", "md", "markdown", "text"].contains(ext) {
                    // Markdown/text drops become a real note in Notes/Inbox
                    // rather than an opaque Document — importDocument() below
                    // has no concept of note content, it just files whatever's
                    // dropped as a binary blob, which is why this case used to
                    // be skipped entirely (silent no-op) rather than mis-filed.
                    // No destination choice here — always Inbox, matching what
                    // iOS's AddDocumentView did before E31. Full Inbox/Today/
                    // Project/Place parity would need a small confirmation UI
                    // this drop handler doesn't have; minimal fix for now
                    // (2026-07-06) just stops the silent failure.
                    importAsNote(from: url)
                } else {
                    do {
                        try store?.importDocument(from: url)
                        Task { @MainActor in
                            await store?.reload()
                        }
                    } catch { }
                }
            }
            handled = true
        }
        return handled
    }

    private func importAsNote(from url: URL) {
        guard let rawText = try? String(contentsOf: url, encoding: .utf8) else { return }
        let title = url.deletingPathExtension().lastPathComponent
        let noteContent = rawText.hasPrefix("# ") ? rawText : "# \(title)\n\n\(rawText)"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = fmt.string(from: Date())
        let safeName = title
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: "-")
            .replacingOccurrences(of: "/", with: "-")
        try? noteStore.writeFile("Notes/Inbox/\(timestamp)-\(safeName).md", content: noteContent)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Tag filter pill. A view onto `selectedTags` since Session 73,
                // not a second store of the same filter. It still picks ONE tag
                // — the popover is a single-select list — but it reports the
                // truth when the pane has set more than one, because a pill
                // reading "Tags" while three are active is a filter you cannot
                // see, and an invisible filter is the shape Session 72 was spent
                // on.
                filterPill(
                    icon: "tag",
                    label: tagPillLabel,
                    isActive: !selectedTags.isEmpty,
                    onClear: { selectedTags.removeAll() }
                ) {
                    showingTagFilter = true
                }
                .popover(isPresented: $showingTagFilter, arrowEdge: .bottom) {
                    DocFilterPickerPopover(
                        title: "Filter by Tag",
                        items: allTags,
                        selected: selectedTags.count == 1 ? selectedTags.first : nil,
                        onSelect: { selectedTags = [$0]; showingTagFilter = false }
                    )
                }

                // Project filter pill. Was gated on `categoryFilter == "Project"`
                // — i.e. only reachable from inside a folder that no longer
                // exists. Filing to a project is `linked_note`, so the filter
                // belongs beside the tag filter, always available.
                if true {
                    filterPill(
                        icon: "folder",
                        label: activeProject.flatMap { p in
                            projectList.first { $0.path == p }?.name
                        } ?? "Project",
                        isActive: activeProject != nil,
                        onClear: { activeProject = nil }
                    ) {
                        showingProjectFilter = true
                    }
                    .popover(isPresented: $showingProjectFilter, arrowEdge: .bottom) {
                        DocFilterPickerPopover(
                            title: "Filter by Project",
                            items: projectList.map(\.name),
                            selected: activeProject.flatMap { p in projectList.first { $0.path == p }?.name },
                            onSelect: { name in
                                activeProject = projectList.first { $0.name == name }?.path
                                showingProjectFilter = false
                            }
                        )
                    }
                }

                // Date filter pill
                filterPill(
                    icon: "calendar",
                    label: dateFilterLabel ?? "Date",
                    isActive: filterYear != nil || filterMonth != nil,
                    onClear: { filterYear = nil; filterMonth = nil }
                ) {
                    showingDateFilter = true
                }
                .popover(isPresented: $showingDateFilter, arrowEdge: .bottom) {
                    DocDateFilterPopover(
                        availableYears: availableYears,
                        availableDates: availableDates,
                        selectedYear: $filterYear,
                        selectedMonth: $filterMonth
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    /// A compact pill button with optional clear (×) badge.
    private func filterPill(
        icon: String,
        label: String,
        isActive: Bool,
        onClear: @escaping () -> Void,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 3) {
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(MacGlyph.small)
                    Text(label).font(.caption).lineLimit(1)
                    if !isActive {
                        Image(systemName: "chevron.down").font(MacGlyph.small)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.09))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if isActive {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(MacGlyph.control)
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tagChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        // Same rule as the metadata chips, through the same function.
        let accent = DocChipsEditor.tint(for: label, base: .accentColor)
        return Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? accent.opacity(0.2) : accent.opacity(0.1))
                .foregroundStyle(isActive ? accent : accent.opacity(0.75))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right column

    @State private var docDetailTab: DocDetailTab = .preview

    @ViewBuilder
    private var rightColumn: some View {
        if let doc = selectedDoc {
            VStack(spacing: 0) {
                // Tab bar
                HStack(spacing: 0) {
                    ForEach(DocDetailTab.allCases, id: \.self) { tab in
                        Button {
                            docDetailTab = tab
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.icon).font(.caption)
                                Text(tab.label).font(.caption)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(docDetailTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.gray.opacity(0.0001))
                            .foregroundStyle(docDetailTab == tab
                                ? Color.accentColor
                                : Color.secondary)
                            // Same fix as the section tabs: a `.plain` button
                            // hit-tests its rendered content, so an unselected
                            // tab over a clear background was only clickable on
                            // the glyphs. These are short words with icons so it
                            // was easy to hit by accident, which is how it went
                            // unnoticed.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()

                // Tab content
                switch docDetailTab {
                case .preview:
                    // Both panes get an EXPLICIT height. That is the whole fix.
                    //
                    // Session 63 (2026-08-02). Three attempts, one bug. Twice I
                    // gave one pane a height and let the other "take the rest":
                    // first a `.frame(height:)` plus drag gesture, then a
                    // `VSplitView` with min/ideal heights. David both times:
                    // *"only one direction"* — down worked, up did not.
                    //
                    // A pane sized implicitly is not neutral. It negotiates, and
                    // it can refuse. A `PDFView` zoomed past the frame reports a
                    // large fitting size; a `ScrollView` over short content
                    // declines to give space back. Whichever one is holding the
                    // slack decides how far the divider may travel, and it only
                    // ever pushed one way.
                    //
                    // So neither pane holds the slack now. A `GeometryReader`
                    // owns the total, the divider position is a stored fraction
                    // of it, and both children are handed an exact height
                    // computed from that fraction and clamped to the minimums.
                    // Nothing is left to negotiate, so both directions work by
                    // construction rather than by cooperation.
                    GeometryReader { geo in
                        let total     = max(geo.size.height, 300)
                        // Note what is NOT in here: `previewDrag`. The panes do
                        // not move during the drag at all.
                        //
                        // Session 63 (2026-08-02), fourth attempt. David:
                        // *"it really still flickers… Can we just make this
                        // simpler to do if it is causing such a problem"*.
                        //
                        // Live resizing meant re-laying out a `PDFView` holding
                        // a document larger than its pane, sixty times a second,
                        // while a zoom controller published state back into the
                        // same layout. Every fix I added was another moving part
                        // in a loop that should not have existed.
                        //
                        // So the drag moves a line, not the layout. One commit
                        // on release, one layout pass. Nothing to flicker,
                        // because nothing is being re-laid out mid-gesture.
                        let previewH  = max(160, min(previewFraction * total, total - 140))
                        let metadataH = max(0, total - previewH - dividerThickness)
                        let ghostY    = max(160, min(previewH + previewDrag, total - 140))

                        VStack(spacing: 0) {
                            docViewer(for: doc)
                                .frame(height: previewH)
                                // The viewer draws a document that may be far
                                // larger than its slot. Without this it paints
                                // over the divider and the metadata below it.
                                .clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    if zoom.isActive {
                                        PreviewZoomBar(zoom: zoom).padding(10)
                                    }
                                }

                            // A real strip, not a hairline. David: *"Getting the
                            // mouse over the divide is also difficult."* It was
                            // 1pt of layout with a 9pt invisible target, which
                            // is still a guess about where to aim. This one is
                            // 6pt, visible, with a grip.
                            ZStack {
                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                                Capsule()
                                    .fill(Color.secondary.opacity(0.45))
                                    .frame(width: 34, height: 2)
                            }
                            .frame(height: dividerThickness)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .updating($previewDrag) { value, state, _ in
                                        state = value.translation.height
                                    }
                                    .onEnded { value in
                                        let settled = max(160, min(
                                            previewH + value.translation.height,
                                            total - 140
                                        ))
                                        previewFraction = settled / total
                                    }
                            )
                            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }

                            ScrollView {
                                DocMetadataPanel(doc: doc,
                                                 store: store!,
                                                 // Replaces rather than adds:
                                                 // *"see a list of all the
                                                 // documents… with that same
                                                 // tag"* is a jump, not a
                                                 // refinement of wherever you
                                                 // happened to be.
                                                 onTagTap: { selectedTags = [$0] },
                                                 onOpen: onOpen,
                                                 endeavorStore: endeavorStore) { movedDoc in
                                    Task {
                                        await store?.reload()
                                        selectedDoc = store?.documents.first { $0.filename == movedDoc.filename }
                                    }
                                }
                            }
                            .frame(height: metadataH)
                        }
                        // Where the divider will land, drawn over everything and
                        // hit-testing nothing. This is the only thing that moves
                        // while dragging.
                        .overlay(alignment: .top) {
                            if previewDrag != 0 {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .offset(y: ghostY)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                case .note:
                    DocNotePanel(doc: doc, store: store!)
                        .id(doc.id)
                }
            }
            .onChange(of: selectedDoc) { _, _ in docDetailTab = .preview }
        } else {
            MacEmptyState.placeholder("doc.richtext", "Select a document")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    enum DocDetailTab: CaseIterable {
        case preview, note
        var label: String { switch self { case .preview: "Preview"; case .note: "Note" } }
        var icon: String  { switch self { case .preview: "doc.fill"; case .note: "note.text" } }
    }

    /// The match counter over the top-right of the page.
    ///
    /// It shows **zero as a number with a reason**, not as nothing. A PDF opened
    /// from a search that clearly matched it, showing no highlight and no chip,
    /// reads as a broken highlighter — and a phone-scanned page has no text
    /// layer for `findString` to search, which is a fact about the file that the
    /// user has no other way to learn. `MacPDFFind.emptyReason` supplies the
    /// words.
    @ViewBuilder
    private var findChip: some View {
        if find.isShowing {
            HStack(spacing: 6) {
                if find.count > 0 {
                    Button { find.previous() } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain)
                    Text("\(find.current + 1) of \(find.count)")
                        .font(MacType.meta)
                        .monospacedDigit()
                    Button { find.next() } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain)
                } else {
                    Text("No highlight — \(find.emptyReason ?? "no match")")
                        .font(MacType.meta)
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 12)
                Button { find.clear() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Clear highlight (esc)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(12)
        }
    }

    @ViewBuilder
    private func docViewer(for doc: TraceMacDocument) -> some View {
        if doc.isPDF, let url = noteStore.resolvedURL(for: doc.relativePath) {
            PDFViewRepresentable(url: url, zoom: zoom, find: find)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { findChip }
                .id(doc.relativePath)
        } else if doc.isImage, let url = noteStore.resolvedURL(for: doc.relativePath) {
            // Note the shape of this condition: it branches on `doc.isImage`
            // alone. It used to also bind `NSImage(contentsOf: url)`, which
            // meant an image iCloud had not downloaded failed the `else if`
            // entirely and fell through to the "unsupported file" branch below.
            // Whether a file is an image is a fact about the file; whether its
            // bytes are local yet is not, and the two do not belong in one test.
            MacImagePreview(url: url, zoom: zoom)
                .id(doc.relativePath)
        } else if let url = noteStore.resolvedURL(for: doc.relativePath) {
            VStack(spacing: 16) {
                Image(systemName: "doc")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text(doc.filename)
                    .font(.headline)
                if let size = fileSize(at: url) {
                    Text(size)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Button("Open in Default App") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
            // Nothing zoomable here, so the bar hides rather than offering
            // controls that would do nothing.
            .onAppear { zoom.detach() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Import

    /// Multi-select, matching the Endeavor rail's `+`. Two doors to the same
    /// verb disagreeing about whether you may pick two files is the kind of
    /// difference nobody decides and everybody trips over.
    private func importDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                _ = try? store?.importDocument(from: url)
            }
            Task { await store?.reload() }
        }
    }

    private func fileSize(at url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - List row

struct DocListRow: View {
    let doc: TraceMacDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // **The document's own icon and colour, not its file kind.**
                //
                // This row drew a red `doc.fill` for every PDF and a blue
                // `photo` for every image, which is renderer drift of the exact
                // kind [[feedback_trace_renderer_drift]] records: Satchel's list
                // on the phone has drawn `SatchelDocumentMark` — the real icon
                // and tint — since it shipped, and the Mac never learned.
                //
                // It went unnoticed while the icon was decoration. Session 72
                // made it the subject and gave colour a meaning, retyped the
                // whole corpus, and David looked at this list and said *"i dont
                // see any change in the icons for mac"* — correctly, because
                // this row could not show one. A file kind is the least
                // interesting true thing about a document, and it is already
                // legible from the preview beside it.
                MacIconBadge(icon: doc.resolvedIcon.sfSymbol,
                             tint: MacPalette.documentTint(doc.resolvedTint),
                             size: .compact)
                Text(doc.title)
                    .font(.body)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(doc.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // For Project/Place/Trip, show the linked note name as a subtitle
                if let note = doc.linkedNote, !note.isEmpty {
                    let noteName = note.components(separatedBy: "/").last?
                        .replacingOccurrences(of: ".md", with: "") ?? note
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(noteName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let date = doc.created {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(date, format: .dateTime.month(.abbreviated).year())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !doc.tags.isEmpty {
                HStack(spacing: 4) {
                    // THE THIRD PLACE TAGS ARE DRAWN, and it was missed when
                    // `private` went orange. David: *"the private tag is orange
                    // in the file itself but the tag on the column is still
                    // blue."* Three renderers, one rule — the tint function is
                    // shared precisely so the next one cannot drift either.
                    ForEach(doc.tags.prefix(3), id: \.self) { tag in
                        let tint = DocChipsEditor.tint(for: tag, base: .accentColor)
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.14))
                            .foregroundStyle(tint)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A note path's display name. File-scope since Session 69: `DocNotePanel` had
/// it privately and `DocMetadataPanel`'s new Filed-to row needs the same answer.
/// Two copies of "how do we name a note" is how two screens start disagreeing
/// about the same document.
private func noteName(from path: String) -> String {
    path.components(separatedBy: "/").last?.replacingOccurrences(of: ".md", with: "") ?? path
}

// MARK: - Note tab panel

struct DocNotePanel: View {
    let doc: TraceMacDocument
    let store: TraceMacDocumentStore

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notion

    @State private var linkedNote: String = ""
    @State private var showingNotePicker = false
    @State private var showingHub = false

    var body: some View {
        Group {
            noteContent
        }
        .onAppear { load() }
        .onChange(of: doc.id) { _, _ in load() }
    }

    @ViewBuilder
    private var noteContent: some View {
        if linkedNote.isEmpty {
            // Empty state — no project note linked yet
            VStack(spacing: 16) {
                Image(systemName: "note.text.badge.plus")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("No project note linked")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Link this document to a project to start writing notes that are shared across all documents in that project.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                HStack(spacing: 12) {
                    Button("Link to project…") {
                        showingNotePicker = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showingNotePicker) {
                LinkedNotePickerSheet(
                    current: linkedNote,
                    filterFolders: ["Notes/Projects"],
                    allowCreate: true
                ) { picked in
                    linkedNote = picked
                    saveLinkedNote(picked)
                }
                .environment(noteStore)
            }
        } else {
            // Note is linked — show editor + project header
            VStack(spacing: 0) {
                // Project name header bar
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    // Tappable project name → opens hub view
                    Button {
                        showingHub = true
                    } label: {
                        Text(noteName(from: linkedNote))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // Hub button — "see everything in this project"
                    Button {
                        showingHub = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open project hub")
                    Button {
                        showingNotePicker = true
                    } label: {
                        Text("Change")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.06))

                Divider()

                TraceMacNoteEditor(relativePath: linkedNote)
            }
            .sheet(isPresented: $showingHub) {
                MacProjectNoteDetailView(notePath: linkedNote, store: store)
                    .environment(noteStore)
                    .environment(notion)
            }
            .sheet(isPresented: $showingNotePicker) {
                LinkedNotePickerSheet(
                    current: linkedNote,
                    filterFolders: ["Notes/Projects"],
                    allowCreate: true
                ) { picked in
                    linkedNote = picked
                    saveLinkedNote(picked)
                }
                .environment(noteStore)
            }
        }
    }

    private func saveLinkedNote(_ path: String) {
        try? store.saveSidecar(
            for: doc,
            title: doc.title,
            tags: doc.tags,
            linkedNote: path.isEmpty ? nil : path,
            people: doc.people,
            description: doc.description
        )
    }

    private func load() {
        linkedNote = doc.linkedNote ?? ""
    }
}

// MARK: - Metadata panel

struct DocMetadataPanel: View {
    let doc: TraceMacDocument
    let store: TraceMacDocumentStore
    /// Filter the library to a tag. David: *"when i click on any tag in satchel
    /// is it possible to have that be the search and see a list of all the
    /// documents… with that same tag?"* The filter already existed behind a
    /// dropdown in the toolbar; the tag sitting under his cursor did nothing,
    /// which is the more discoverable of the two doing less.
    var onTagTap: ((String) -> Void)? = nil
    /// Open a record elsewhere. See `TraceMacDocumentsView.onOpen`.
    var onOpen: ((MacSearchDestination) -> Void)? = nil
    /// Supplied by the section, already loaded. See its declaration there.
    var endeavorStore: TraceMacEndeavorStore? = nil
    let onSave: (TraceMacDocument) -> Void

    @Environment(NotionService.self) private var notion
    @Environment(NoteStore.self) private var noteStore
    /// For the Links row. A URL read off a scan opens in the default browser.
    @Environment(\.openURL) private var openURL

    @State private var title: String = ""
    /// Web addresses found in the extracted text. **Derived, not stored** --
    /// see `MacTextExtraction.links(in:)` for why there is no `links:`
    /// frontmatter key. Recomputed in `load()`, which is once per selection.
    @State private var links: [URL] = []
    @State private var tags: [String] = []
    @State private var linkedNote: String = ""
    @State private var people: [String] = []
    @State private var description: String = ""
    @State private var docDate: Date = Date()
    @State private var showingDatePicker = false
    @State private var isSaving = false
    @State private var isScanning = false
    @State private var scanError: String? = nil
    /// Neutral feedback from the local fill. Separate from `scanError` because
    /// it is not an error and must not be red — "no matches" is a fact about
    /// his vocabulary, not a failure.
    @State private var localNote: String? = nil
    @State private var userContext: String = ""
    /// Sidecar `remind:`, as the panel holds it. Filled by the scan when the
    /// document states a date (2026-08-27); no Mac row edits it yet — the
    /// phone's Satchel has the picker and the Reminders button. Backlog.
    @State private var remindOn: Date? = nil
    /// Which document `userContext` was typed for.
    ///
    /// `load()` used to clear the hint unconditionally, for a good reason
    /// recorded there — a hint left behind followed the next document. But
    /// `save()` reloads the same document, so pressing the button also threw
    /// away what he had just typed. David: *"the context itself is gone after
    /// it processed. is that right?"* No. Clearing on a change of SELECTION is
    /// what that lesson actually needed; clearing on every load was the blunt
    /// version of it.
    @State private var contextOwner: String = ""
    /// The on-device pass is running. Separate from `isScanning`, which gates
    /// the network path and must stay gated for private documents.
    @State private var isThinkingLocally = false
    /// The document's icon, as chosen here. `nil` means "let the app pick",
    /// which is what `resolvedIcon` does from category, tags and extension.
    /// Session 72.
    @State private var docIcon: DocumentIcon? = nil
    /// The document's type, as colour. `nil` is Unclassified, which renders
    /// gray. Session 72.
    @State private var docTint: DocumentTint? = nil
    @State private var endeavorID: String? = nil
    @State private var endeavorName: String? = nil
    /// Loaded lazily so a panel that never opens the menu never walks the
    /// Endeavors folder. Same shape the Endeavors and Journal views already use.
    @State private var showingEndeavorPicker = false


    /// Above this many, the menu offers a search field instead of more rows.
    /// David, looking at two Endeavors and thinking ahead: *"probably should
    /// allow me to search if the endeavor list gets long."*
    private static let inlineEndeavorLimit = 8

    /// **Soonest-first, future before past.** His words: *"it should sort from
    /// the most forward dated endeavor to the oldest."* An Endeavor is a thing
    /// you are about to do or have just done, so recency by start date is the
    /// order the list is actually used in — the trip next week is what a
    /// document is being filed against, not the lunch in July.
    ///
    /// Undated ones sort last rather than first: no date means no claim on the
    /// top of the list.
    private var sortedEndeavors: [Endeavor] {
        (endeavorStore?.endeavors ?? []).sorted {
            ($0.starts ?? $0.ends ?? .distantPast) > ($1.starts ?? $1.ends ?? .distantPast)
        }
    }

    private func assign(_ endeavor: Endeavor) {
        endeavorID = endeavor.id
        endeavorName = endeavor.name
        save()
    }
    @State private var isExpanded = true
    @State private var showingTagPopover = false
    @State private var newTagText = ""
    @State private var showingPeoplePicker = false
    @State private var showingFilePicker = false
    /// Raised when Run AI is pressed on a document tagged `private`.
    @State private var showPrivatePrompt = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        DisclosureGroup("Metadata", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                filedToRow
                endeavorRow
                iconRow
                typeRow
                yearRow
                titleRow
                dateRow
                tagsRow
                peopleRow
                linksRow
                descriptionRow
                if let err = scanError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if let localNote {
                    Text(localNote).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Delete", role: .destructive) { showingDeleteConfirm = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .controlSize(.small)
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isSaving)
                }
                .confirmationDialog("Delete \"\(doc.title)\"?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { delete() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This permanently removes the file from iCloud.")
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { load() }
        .onChange(of: doc.id) { _, _ in load() }
        .sheet(isPresented: $showingPeoplePicker) {
            DocPersonPickerSheet(current: people) { picked in
                if !people.contains(picked) { people.append(picked) }
            }
            .environment(notion)
        }
    }

    // MARK: - Filed to + Year
    //
    // **This replaced the Category chip and the "Move to…" menu, Session 69.**
    // That menu offered Inbox / Project / Place / Trip / Other and each entry
    // physically moved the file, because the Mac derives `category` from the
    // folder name at scan time (`TraceMacDocumentStore.reload`). It was not
    // metadata that looked like filing, it was filing.
    //
    // Two of its entries were doing something real underneath: "Move to
    // Project…" and "Move to Place…" also set `linked_note`, and that was the
    // ONLY way to link a document to a Place note anywhere on the Mac —
    // `DocNotePanel` filters to `Notes/Projects`. So the menu could not just be
    // deleted. The association it was carrying is now edited directly, in one
    // picker over both folders, and no file moves.
    //
    // Year is shown, not chosen. Same treatment Satchel gives it: a fact about
    // the bytes, under FILE, rather than a control.

    private var filedToRow: some View {
        HStack {
            fieldLabel("Filed to")
            Button {
                showingFilePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: linkedNote.isEmpty ? "tray" : "folder.fill")
                        .font(.caption2)
                    Text(linkedNote.isEmpty ? "Nothing" : noteName(from: linkedNote))
                        .font(.caption)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.1))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            if !linkedNote.isEmpty {
                Button {
                    linkedNote = ""
                    save()
                } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Unfile")
            }
            Spacer()
        }
        .sheet(isPresented: $showingFilePicker) {
            // Both folders in one list, because "is this a project or a place"
            // is a question the picker can answer from the path and the person
            // filing should not have to answer twice.
            LinkedNotePickerSheet(current: linkedNote,
                                  filterFolders: ["Notes/Projects", "Notes/Places"]) { picked in
                linkedNote = picked
                save()
            }
            .environment(noteStore)
        }
    }

    /// Which Endeavor this document belongs to.
    ///
    /// **It was visible from one end only.** The Endeavor screen has listed its
    /// documents since it was built; the document said nothing about the
    /// Endeavor. David: *"the document called vacation rental amenities is
    /// linked to the Megan Wedding Endeavor but there is no indication of that
    /// on the satchel document but it is showing in the endeavor. it should be
    /// both ways."*
    ///
    /// The confusion is compounded by `filedToRow` directly above, which reads
    /// "Filed to" and shows the linked NOTE — so a document filed to an
    /// Endeavor reads as "Filed to: Nothing". Two different associations, one
    /// of them displayed, and the undisplayed one owning the word "filed".
    ///
    /// Satchel on iOS has shown this as a suitcase chip all along, which is
    /// where the icon comes from: same idea, same glyph, two apps.
    ///
    /// **Read-only for now, deliberately.** Tapping through wants the router on
    /// `TraceMacContentView`, which has no path down to this panel;
    /// `MacNavigator` records history but does not route. Inventing a second
    /// routing vocabulary to save one click is the drift D105 and D112 both
    /// warn about. Parked in the backlog with the reciprocal views for Notes
    /// and Places, which are the same idea at larger scale.
    /// Which Endeavor this document belongs to — **now settable, not just shown.**
    ///
    /// A Menu rather than a chip plus a chevron, because the row has two jobs
    /// and one of them is rare. Opening the Endeavor is the common act and sits
    /// at the top; reassigning is a list underneath it. Two separate controls
    /// three points apart would be a smaller target for both.
    ///
    /// **Always visible, even when unset.** The row used to appear only when a
    /// document already had an Endeavor, which meant the control for setting one
    /// was hidden from exactly the documents that needed it.
    @ViewBuilder
    private var endeavorRow: some View {
        HStack {
            fieldLabel("Endeavor")
            Menu {
                Button("None") {
                    endeavorID = nil
                    endeavorName = nil
                    save()
                }
                let list = sortedEndeavors
                if !list.isEmpty {
                    Divider()
                    // Only the first handful inline. A menu you scroll is a menu
                    // you read one item at a time.
                    ForEach(list.prefix(Self.inlineEndeavorLimit)) { endeavor in
                        Button(endeavor.name) { assign(endeavor) }
                    }
                    if list.count > Self.inlineEndeavorLimit {
                        Divider()
                        Button("Search all \(list.count)…") { showingEndeavorPicker = true }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: endeavorName == nil ? "suitcase" : "suitcase.fill")
                        .font(.caption2)
                    Text(endeavorName ?? "Nothing").font(.caption)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.indigo.opacity(endeavorName == nil ? 0.08 : 0.14))
                .foregroundStyle(endeavorName == nil ? Color.secondary : Color.indigo)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .popover(isPresented: $showingEndeavorPicker, arrowEdge: .bottom) {
                DocEndeavorPicker(endeavors: sortedEndeavors) { picked in
                    showingEndeavorPicker = false
                    assign(picked)
                }
            }

            // GO IS ITS OWN TARGET, next to the one that CHANGES.
            //
            // The menu had an "Open …" item and that was two clicks for the
            // common act and one for the rare one. David: *"can we somehow also
            // make the Endeavor i chose clickable or if that doesnt work since i
            // might want to change the item, a little button next to that."*
            // He named the tension himself — a pill cannot both navigate and
            // open a picker on one click — and chose the right resolution.
            //
            // Only when there is somewhere to go. A document with no Endeavor
            // gets no arrow, rather than a disabled one nobody can interpret.
            if let id = endeavorID, let onOpen {
                Button { onOpen(.endeavor(id)) } label: {
                    Image(systemName: "arrow.up.forward.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.indigo)
                .help("Open \(endeavorName ?? "this endeavor")")
            }
            Spacer()
        }
    }

    // MARK: - Icon

    /// Which glyph the document wears, and — since Session 72 — which bucket it
    /// files into on the endeavor screens.
    ///
    /// **There was no way to change this on the Mac at all.** Satchel has had
    /// one since it shipped (tap the 52pt mark in `SatchelDocumentDetailView`'s
    /// header, pencil badge and all) and TraceMac had nothing, which only
    /// started to matter when `DocumentBucket` made the icon load-bearing.
    /// David: *"where can i change the type of icon for documents? i dont see
    /// that as an option in ios or mac… Nicks for example i want to change it
    /// from the receipt to something else."*
    ///
    /// **Auto is a real choice and sits first.** `resolvedIcon` already types an
    /// unset document from its category, tags and extension, and that answer is
    /// often right — so "no icon" has to be reachable, not merely the state a
    /// document starts in. A picker that can only ever add is a one-way door.
    ///
    /// A Menu rather than the grid Satchel uses: twenty-three items with their
    /// own glyphs is exactly what a Mac menu is for, and the panel is a column
    /// of labelled rows, not a canvas.
    private var iconRow: some View {
        HStack {
            fieldLabel("Icon")
            Menu {
                Button {
                    docIcon = nil
                    save()
                } label: {
                    Label("Auto (\(doc.resolvedIcon.label))", systemImage: doc.resolvedIcon.sfSymbol)
                }
                Divider()
                ForEach(DocumentIcon.allCases, id: \.self) { candidate in
                    Button {
                        docIcon = candidate
                        save()
                    } label: {
                        Label(candidate.label, systemImage: candidate.sfSymbol)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: (docIcon ?? doc.resolvedIcon).sfSymbol)
                        .foregroundStyle(Color.indigo)
                    Text(docIcon?.label ?? "Auto (\(doc.resolvedIcon.label))")
                        .font(.caption)
                    // The bucket, said out loud next to the thing that decides
                    // it. Naming the consequence is what makes a wrong icon
                    // visible as a wrong FILE, which is the whole reason the
                    // control exists.
                    Text("· \(DocumentBucket.of(docIcon ?? doc.resolvedIcon).label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    // MARK: - Type

    /// The document's TYPE, carried as colour. Session 72.
    ///
    /// **The second of two axes, and the row exists because they are two.** The
    /// icon above says what the document is about; this says what kind of thing
    /// it is. David: *"i think the type is a secondary thing that yes i will
    /// look for but only occasionally. What does color signify? can we use that
    /// in the rule?"*
    ///
    /// Six choices, not eight. `amber` is out because orange with a lock means
    /// private app-wide since Session 71, and `red` is held for "needs action" —
    /// a colour that means two things is the problem this row was built to fix.
    private var typeRow: some View {
        HStack {
            fieldLabel("Kind")
            Menu {
                ForEach(DocumentTint.typeCases, id: \.self) { candidate in
                    Button {
                        docTint = candidate == .gray ? nil : candidate
                        save()
                    } label: {
                        Text(candidate.typeMeaning ?? candidate.label)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(MacPalette.documentTint(docTint ?? .gray))
                        .frame(width: 9, height: 9)
                    Text((docTint ?? .gray).typeMeaning ?? "Unclassified")
                        .font(.caption)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private var yearRow: some View {
        HStack {
            fieldLabel("Year")
            Text(doc.category)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack {
            fieldLabel("Title")
            TextField("Document title", text: $title)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Date

    private var dateRow: some View {
        HStack(spacing: 0) {
            fieldLabel("Date")
            Button {
                showingDatePicker = true
            } label: {
                Text(docDate, format: .dateTime.month(.abbreviated).year())
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .foregroundStyle(.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
                MonthYearPickerPopover(selected: $docDate) {
                    showingDatePicker = false
                }
            }
            Spacer()
        }
    }

    // MARK: - Tags

    private var tagsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            fieldLabel("Tags").padding(.top, 4)
            DocChipsEditor(
                chips: $tags,
                allSuggestions: existingTags,
                placeholder: "Add tag…",
                color: .accentColor,
                // Not on People: a person chip filtering the document list by
                // person is a different feature with no filter behind it yet,
                // and a chip that looks tappable and is not is worse than one
                // that plainly is not.
                onChipTap: onTagTap
            )
        }
    }

    private var existingTags: [String] {
        let all = store.documents.flatMap { $0.tags }
        return Array(Set(all)).sorted()
    }

    // MARK: - People

    private var peopleRow: some View {
        HStack(alignment: .top, spacing: 0) {
            fieldLabel("People").padding(.top, 4)
            DocChipsEditor(
                chips: $people,
                allSuggestions: [],
                placeholder: "Add person…",
                color: .purple,
                onAddTap: { showingPeoplePicker = true },
                // David: *"clicking Hannah in people should open her record."*
                // Resolved by name against the live Notion list, and silently
                // inert when the name is not in it — a person typed by hand who
                // has no record cannot be opened, and pretending otherwise is
                // the dead-control defect D114 was written about.
                //
                // LAST in the argument list, because a memberwise initialiser
                // takes its parameters in declaration order and `onChipTap` is
                // declared after `onAddTap`.
                onChipTap: onOpen.map { open in
                    { name in
                        guard let match = notion.people.first(where: {
                            $0.name.caseInsensitiveCompare(name) == .orderedSame
                        }) else { return }
                        open(.person(match.id))
                    }
                }
            )
        }
    }

    // MARK: - Links

    /// Web addresses read off the document.
    ///
    /// David: *"I have a lot of urls that are part of scans... Id like the url
    /// if it is something picked up in the scan it would show up as a field in
    /// the document like the other fields like a person or an endeavor."*
    ///
    /// **Nothing is written.** The addresses are recomputed from `## Text` on
    /// selection, so they cannot disagree with the document, they need no
    /// parser or store change on either platform, and they work on a `private`
    /// document because `NSDataDetector` never leaves the machine.
    ///
    /// The label is the host, not the URL. A full payment link is sixty
    /// characters of query string and `tuxedo.menswearhouse.com` is the part he
    /// is scanning for. The whole thing is in the tooltip and in the click.
    ///
    /// Absent, not empty, when there are none: a Links row reading "Nothing" on
    /// every receipt would cost a line on every document to say so.
    @ViewBuilder
    private var linksRow: some View {
        if !links.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                fieldLabel("Links").padding(.top, 4)
                FlowLayout(spacing: 6) {
                    ForEach(links, id: \.absoluteString) { url in
                        Button { openURL(url) } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "link").font(.caption2)
                                Text(linkLabel(url)).font(.caption).lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.teal.opacity(0.12))
                            .foregroundStyle(Color.teal)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(url.absoluteString)
                    }
                }
            }
        }
    }

    /// Host without `www.`, plus the last path component when it says something.
    private func linkLabel(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let last = url.pathComponents.last ?? ""
        if last.count > 1, last != "/", host.count + last.count < 44 {
            return "\(host)/\(last)"
        }
        return host
    }

    // MARK: - Description + AI scan

    private var descriptionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Context hint, with the button that uses it sitting beside it.
            //
            // **The trigger used to live somewhere else, and that was the whole
            // problem.** It was an unlabelled `sparkles` glyph in the top-right
            // corner of the About box, a row below — so the field that says
            // "Optional hint for AI" had no control next to it, and the control
            // that consumed the hint gave no sign of what it read. David, having
            // typed a hint: *"i just added context to the wildflower document and
            // i cant rerun AI."* He could not find it, and looking in the wrong
            // place was the correct instinct.
            //
            // Same lesson as D82's pin: the affordance belongs where the person
            // is already looking, and an icon alone does not say what it does.
            // Words, next to the input.
            HStack(alignment: .center, spacing: 6) {
                fieldLabel("Context")
                ZStack(alignment: .leading) {
                    TextField("", text: $userContext)
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        // Typing a hint and pressing Return is the gesture the
                        // field's own placeholder implies.
                        .onSubmit { requestScan() }
                    if userContext.isEmpty {
                        Text("Hint: who, what, when. Use #tag to force a tag")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                    }
                }
                Button {
                    requestScan()
                } label: {
                    HStack(spacing: 4) {
                        if isScanning || isThinkingLocally {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles").font(.caption2)
                        }
                        // Reads what it will do. A document that already has
                        // tags and a description is being re-run, and saying so
                        // is the difference between a button you trust and one
                        // you wonder about.
                        Text(hasScanResults ? "Re-run" : "Run AI")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isScanning || isThinkingLocally)
                .help(isPrivate
                      ? "This document is private and has never been sent. You will be offered a local option that sends nothing."
                      : hasScanResults
                        ? "Run the AI again, using the context above"
                        : "Fill in title, tags and description using AI")
                .confirmationDialog("Send this private document to the AI?",
                                    isPresented: $showPrivatePrompt,
                                    titleVisibility: .visible) {
                    // **The safe option first, and it is a real option rather
                    // than a consolation.** Vision has already read this file on
                    // this machine — the `private` tag is deliberately not
                    // consulted by `extractTextForNewArrivals`, because nothing
                    // there leaves the Mac — so a title and a description can be
                    // taken off text that is already sitting in the sidecar,
                    // with no network at all. Before this the choice was an
                    // untitled screenshot forever or sending a bank statement to
                    // an API, and that is not a choice.
                    Button("Fill in from text already on this Mac") { fillLocally() }
                    // Marked destructive because it is: the tag comes off, is
                    // saved before the request goes out, and does not come back.
                    Button("Send and remove private tag", role: .destructive) {
                        promoteFromPrivate()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("It arrived through the private drop and has never left this Mac. "
                         + "Running the AI sends its contents to Anthropic and makes it "
                         + "readable by Ask, permanently. Filling in from local text sends "
                         + "nothing and keeps the private tag.")
                }
            }

            // Description + sparkle button
            HStack(alignment: .top, spacing: 0) {
                fieldLabel("About").padding(.top, 6)
                ZStack(alignment: .topTrailing) {
                    TextEditor(text: $description)
                        .font(.caption)
                        .frame(minHeight: 50, maxHeight: 90)
                        .scrollContentBackground(.hidden)
                        .background(Color.secondary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            Group {
                                if description.isEmpty {
                                    Text("AI will fill this in, or type a note…")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(6)
                                        .allowsHitTesting(false)
                                }
                            },
                            alignment: .topLeading
                        )
                    // The sparkle that used to sit here moved up to the Context
                    // row. Two buttons doing one job is how they drift; one
                    // button in the wrong place is how it goes unfound.
                }
            }
        }
    }

    /// Whether this document has already been through a scan. Drives the button
    /// label, so "Re-run" only ever appears when there is something to re-run.
    private var hasScanResults: Bool { !tags.isEmpty || !description.isEmpty }

    /// Carries the `private` tag, meaning it arrived through Dropzone's private
    /// action and has never been sent anywhere.
    private var isPrivate: Bool {
        tags.contains { $0.caseInsensitiveCompare("private") == .orderedSame }
    }

    /// The single entry point for every scan trigger.
    ///
    /// **`runScan` used to be wired straight to the button, and that was a hole.**
    /// The `private` tag stops `autoScanNewArrivals`, because that tests for "no
    /// tags and no description" — but nothing stopped the manual button. Worse,
    /// `runScan` MERGES tags rather than replacing them, so a private document
    /// could be sent to the API and **keep its private label**, which is the one
    /// outcome worse than not having the label at all.
    ///
    /// David, asking the question that found it: *"if i take the private tag off
    /// in the future of a document and hit AI re run will it then process
    /// normally and be available to ask."*
    private func requestScan() {
        if isPrivate { showPrivatePrompt = true } else { runScan() }
    }

    /// Confirmed promotion: drop the tag, persist that, then scan.
    ///
    /// The tag is removed and **saved before the request goes out**, so the file
    /// on disk can never claim to be private while its contents are in flight.
    /// Title and description from text Vision already read on this Mac.
    ///
    /// Nothing is sent. The `private` tag is untouched, so the document stays
    /// withheld from Ask exactly as before.
    private func fillLocally() {
        let context = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = doc.extractedText
        guard !text.isEmpty || !context.isEmpty else {
            scanError = doc.textExtracted
                ? "No readable text was found in this document. Type a title, or add a hint in Context and press this again."
                : "This document has not been read yet. That happens automatically a few seconds after it arrives — try again shortly."
            return
        }
        scanError = nil
        isThinkingLocally = true
        Task {
            // **The on-device model first, the heuristic underneath it.**
            //
            // David asked whether a local pass could read intention rather than
            // words: *"It should look at the meaning of what i was trying to get
            // across and use a few and only a few (say 3 at most) tags."* A
            // keyword pass cannot. Apple's on-device model can, and it runs on
            // this machine with nothing sent anywhere, which is the only reason
            // it is allowed near a document tagged `private`.
            //
            // `suggest` returns nil for every failure including an unavailable
            // model, so this reads as "did the good path work" with no error
            // handling to get wrong.
            let suggestion = await MacLocalIntelligence.suggest(text: text, hint: context)
            await MainActor.run {
                isThinkingLocally = false
                applyLocal(suggestion: suggestion, context: context, text: text)
            }
        }
    }

    private func applyLocal(suggestion: MacLocalIntelligence.Suggestion?,
                            context: String,
                            text: String) {
        let headline = MacTextExtraction.localHeadline(from: text)

        // Title stays with the document's own words. The model writes a
        // sentence, and a sentence is a description, not a name.
        if let headline { title = headline.title }

        if let suggestion, !suggestion.summary.isEmpty {
            description = suggestion.summary
        } else if description.trimmingCharacters(in: .whitespaces).isEmpty, let headline {
            description = headline.description
        }

        func addTag(_ name: String) {
            let t = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !t.isEmpty,
                  !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame })
            else { return }
            // **A person is not a tag.** The first run produced `hannah`
            // alongside `Hannah Weiss` in People — the same fact recorded twice,
            // in two places, one of which cannot be filtered on properly.
            if people.contains(where: { person in
                person.lowercased().split(separator: " ").contains(Substring(t))
            }) { return }
            // **No tag that contains another tag.** It produced `loan` and
            // `loan statement`, which is one idea and two chips. The shorter one
            // wins: it is the one that will still match next year.
            if tags.contains(where: { existing in
                let e = existing.lowercased()
                return t.split(separator: " ").contains(Substring(e))
            }) { return }
            tags.append(t)
        }
        func addPerson(_ name: String) {
            guard !people.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { return }
            people.append(name)
        }

        let before = (tags.count, people.count)

        // ── People ───────────────────────────────────────────────────────
        // Unchanged, because it worked: Hannah Weiss came out right first time.
        let activePeople = notion.people.filter { !$0.isArchived }
        for name in MacTextExtraction.vocabularyMatches(in: context + " " + text,
                                                        vocabulary: activePeople.map { $0.name }) {
            addPerson(name)
        }
        let hints = MacTextExtraction.hintTerms(in: context)
        let byFirstName = Dictionary(grouping: activePeople) {
            ($0.name.split(separator: " ").first.map(String.init) ?? "").lowercased()
        }
        for hint in hints {
            guard let bucket = byFirstName[hint.lowercased()], bucket.count == 1 else { continue }
            addPerson(bucket[0].name)
        }

        // ── Tags ─────────────────────────────────────────────────────────
        //
        // **Bare words from Context are no longer tags.** That is what produced
        // `this`, `the`, `for`, `her` and `aidvantage.` from one ordinary
        // sentence. Three sources now, all of them deliberate:
        //
        //   1. `#tag` in the hint. Explicit, always honoured, model or no model.
        //   2. The model's three, when it ran.
        //   3. Tags already in the library that appear in the document's text.
        //
        // Prose stays prose and is handed to the model as the owner's statement
        // of intent, which is the one place it is genuinely useful.
        for marked in MacTextExtraction.hashTags(in: context) { addTag(marked) }

        if let suggestion {
            for tag in suggestion.tags { addTag(tag) }
        }

        let knownTags = Array(Set(store.documents.flatMap { $0.tags }))
        for tag in MacTextExtraction.vocabularyMatches(in: text, vocabulary: knownTags) {
            addTag(tag)
        }

        let addedTags = tags.count - before.0
        let addedPeople = people.count - before.1

        // Says which path ran, because the two have very different ceilings and
        // he should not have to guess which one he is looking at.
        switch MacLocalIntelligence.availability {
        case .ready where suggestion != nil:
            localNote = nil
        case .ready:
            localNote = "The on-device model did not answer, so this was filled from the text alone."
        case .notBuilt:
            localNote = "Filled from the text alone. The on-device model is not part of this build."
        case .unavailable(let why):
            localNote = "Filled from the text alone. \(why)"
        }
        if localNote == nil, addedTags == 0, addedPeople == 0 {
            localNote = "Nothing was added to Tags or People. Add #tag to the Context hint to force one."
        }

        save()
    }

    private func promoteFromPrivate() {
        tags.removeAll { $0.caseInsensitiveCompare("private") == .orderedSame }
        save()
        runScan()
    }

    private func runScan() {
        // A hard gate, not a courtesy. `promoteFromPrivate` is the only way past
        // it, and it clears the tag first — so no future caller can reintroduce
        // the hole by wiring itself to `runScan` directly.
        guard !isPrivate else { return }
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        localNote = nil
        let currentTags = existingTags
        let context = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let knownPeople = notion.people.filter { !$0.isArchived }.map(\.name)
                let result = try await DocumentScanService.scan(
                    doc: doc,
                    noteStore: noteStore,
                    existingTags: currentTags,
                    userContext: context,
                    knownPeople: knownPeople
                )
                await MainActor.run {
                    // Merge new tags — preserve what's already selected, append new
                    let merged = Array(Set(tags + result.tags)).sorted()
                    tags = merged
                    if !result.description.isEmpty {
                        description = result.description
                    }
                    // Apply suggested title only if Claude flagged the filename as nonsensical
                    if let suggestedTitle = result.title {
                        title = suggestedTitle
                    }
                    // A stated date is the document's, so it is written; the
                    // phone shows and edits it. See `remindOn`.
                    if let date = result.remindOn { remindOn = date }
                    if let dated = result.datedOn { docDate = dated }
                    // List-only, spelled the list's way, same rule as the phone.
                    for name in result.people
                    where knownPeople.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
                        && !people.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        people.append(knownPeople.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name)
                    }
                    isScanning = false
                    // Auto-save so the list reflects the AI-generated title immediately
                    save()
                }
            } catch {
                await MainActor.run {
                    scanError = error.localizedDescription
                    isScanning = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .frame(width: 60, alignment: .trailing)
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(.trailing, 8)
    }

    private func load() {
        title = doc.title
        endeavorID = doc.endeavor
        endeavorName = doc.endeavorName
        tags = doc.tags
        linkedNote = doc.linkedNote ?? ""
        people = doc.people
        description = doc.description
        docDate = doc.created ?? Date()
        docIcon = doc.icon
        docTint = doc.tint
        remindOn = doc.remindOn
        links = MacTextExtraction.links(in: doc.extractedText)
        // Cleared on every load, and it was not before Session 69. `userContext`
        // is a hint typed for ONE document; leaving it behind meant the next
        // document inherited it. David selected a Peloton screenshot and found
        // *"I suggested this song to Megan for the father daughter dance"*
        // sitting in its Context field, ready to be sent to the model as though
        // it described a treadmill class.
        //
        // Every other field here is reassigned from `doc`, which is why they
        // could not go stale. This one had no `doc` to read from, so it was
        // simply forgotten — the failure mode of state that belongs to a
        // selection but is not derived from it.
        if contextOwner != doc.relativePath {
            userContext = ""
            contextOwner = doc.relativePath
        }

        // Auto-scan if this looks like a freshly imported doc with no metadata yet
        let noMetadata = doc.tags.isEmpty && doc.description.isEmpty
        let scannable = doc.isPDF || doc.isImage
        if noMetadata && scannable && !isScanning {
            runScan()
        }
    }

    private func save() {
        isSaving = true
        try? store.saveSidecar(
            for: doc,
            title: title.trimmingCharacters(in: .whitespaces),
            tags: tags,
            linkedNote: linkedNote.trimmingCharacters(in: .whitespaces).isEmpty ? nil : linkedNote,
            people: people,
            description: description,
            date: docDate,
            // Explicit on every save, because the panel now owns this value.
            // Passing `nil` would mean "leave whatever is on disk", and the
            // whole point is that he can now change it.
            endeavor: {
                guard let id = endeavorID, let name = endeavorName else { return .clear }
                return .set(id: id, name: name)
            }(),
            // Double-wrapped on purpose: `.some(docIcon)` says "this panel owns
            // the value now", and `docIcon` being nil inside it means Auto
            // rather than "leave it alone". Passing a bare `nil` would make
            // clearing an icon impossible.
            icon: .some(docIcon),
            tint: .some(docTint),
            remindOn: .some(remindOn)
        )
        isSaving = false
        onSave(doc)
    }

    private func delete() {
        Task {
            try? noteStore.deleteFile(doc.relativePath)
            try? noteStore.deleteFile(doc.sidecarPath)
            await MainActor.run {
                // The comment here used to claim this passed "a sentinel with
                // empty filename"; it passed `doc` unchanged, and the parent
                // clears the selection because a reload no longer finds that
                // filename. The `var` was never mutated — a leftover from the
                // sentinel that was described but never written.
                onSave(doc)
            }
        }
    }
}

// MARK: - Chips editor
/// A searchable Endeavor list, for when the menu is no longer the right shape.
///
/// Same pattern as `DocPersonPickerSheet`, deliberately: a project with two
/// spellings of "pick one thing from a list" ends up with two sets of keyboard
/// behaviour and one of them is always the worse one.
struct DocEndeavorPicker: View {
    let endeavors: [Endeavor]
    let onPick: (Endeavor) -> Void

    @State private var searchText = ""

    private var filtered: [Endeavor] {
        guard !searchText.isEmpty else { return endeavors }
        return endeavors.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search endeavors", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { endeavor in
                        Button {
                            onPick(endeavor)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "suitcase.fill").font(.caption2)
                                Text(endeavor.name).font(.caption)
                                Spacer()
                                if let starts = endeavor.starts {
                                    Text(starts, format: .dateTime.month(.abbreviated).year())
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty {
                        Text("No endeavor matches that.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 240, height: 220)
        }
        .padding(10)
    }
}

// Reusable tag/people chip list with inline add-by-typing or custom add action.

struct DocChipsEditor: View {
    @Binding var chips: [String]
    let allSuggestions: [String]
    let placeholder: String
    let color: Color
    var onAddTap: (() -> Void)? = nil   // if set, "+" opens this instead of the text popover
    /// Tapping the chip's LABEL, as distinct from its `x`. Optional, so a list
    /// with nothing to do on tap renders exactly as it did before.
    var onChipTap: ((String) -> Void)? = nil

    @State private var showingPopover = false
    @State private var newText = ""

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(chips, id: \.self) { chip in
                chipView(chip)
            }
            Button {
                if let tap = onAddTap { tap() }
                else { showingPopover.toggle() }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption).foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                suggestionsPopover
            }
        }
    }

    /// `private` is not a topic, it is a warning, and it now reads as one.
    ///
    /// David: *"I was wondering if we should make the private tag a different
    /// colour always so that it stands out."* Yes. It sat in the same blue as
    /// `loan` and `csu` while being the only tag that changes what the app is
    /// allowed to do with the document — the one chip on the screen that
    /// decides whether contents can be sent anywhere. Uniform styling made the
    /// most consequential piece of state the least visible.
    ///
    /// One function so the list and the filter bar cannot drift apart.
    static func tint(for text: String, base: Color) -> Color {
        text.caseInsensitiveCompare("private") == .orderedSame ? .orange : base
    }

    private func chipView(_ text: String) -> some View {
        let chipColor = Self.tint(for: text, base: color)
        return HStack(spacing: 3) {
            if text.caseInsensitiveCompare("private") == .orderedSame {
                Image(systemName: "lock.fill").font(MacGlyph.smallBold)
            }
            // The label filters, the `x` removes. Two targets in one chip, and
            // the pointer cursor is what tells them apart.
            Group {
                if let onChipTap {
                    Button { onChipTap(text) } label: { Text(text).font(.caption) }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help("Show everything tagged \(text)")
                } else {
                    Text(text).font(.caption)
                }
            }
            Button { chips.removeAll { $0 == text } } label: {
                Image(systemName: "xmark").font(MacGlyph.smallBold)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(chipColor.opacity(0.16))
        .foregroundStyle(chipColor)
        .clipShape(Capsule())
    }

    private var suggestionsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(placeholder, text: $newText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit { commit() }
                Button("Add") { commit() }
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let available = allSuggestions.filter { !chips.contains($0) }
            if !available.isEmpty {
                Divider()
                Text("Existing").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 4) {
                    ForEach(available, id: \.self) { s in
                        Button(s) { chips.append(s); showingPopover = false }
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(color.opacity(0.1))
                            .foregroundStyle(color)
                            .clipShape(Capsule())
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 190)
    }

    private func commit() {
        let t = newText.trimmingCharacters(in: .whitespaces).lowercased()
        if !t.isEmpty && !chips.contains(t) { chips.append(t) }
        newText = ""
        showingPopover = false
    }
}

// MARK: - Linked note picker

struct LinkedNotePickerSheet: View {
    let current: String
    var filterFolders: [String]? = nil   // nil = show all; set to restrict to specific subfolders
    var allowCreate: Bool = false         // when true, show "New project…" creation row
    let onSelect: (String) -> Void

    @Environment(NoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [(folder: String, path: String, name: String)] = []
    @State private var searchText = ""
    @State private var newProjectName = ""
    @State private var isCreating = false
    @State private var createError: String? = nil

    private let allFolders = ["Notes/Projects", "Notes/Places", "Notes/Horizons"]
    private var folders: [String] { filterFolders ?? allFolders }

    // Folder shown in the "New project…" row — first filtered folder, or "Notes/Projects"
    private var createFolder: String { folders.first ?? "Notes/Projects" }

    private var filtered: [(folder: String, path: String, name: String)] {
        searchText.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Create new row — shown at top when allowCreate and showing a single folder (Projects)
                if allowCreate && folders.count == 1 {
                    Section("New project") {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(.body)
                            TextField("Project name…", text: $newProjectName)
                                .textFieldStyle(.plain)
                                .onSubmit { createAndSelect() }
                            if isCreating {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button("Create") { createAndSelect() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        if let err = createError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                // Existing notes
                ForEach(folders, id: \.self) { folder in
                    let group = filtered.filter { $0.folder == folder }
                    if !group.isEmpty {
                        Section(folder.components(separatedBy: "/").last ?? folder) {
                            ForEach(group, id: \.path) { item in
                                Button {
                                    onSelect(item.path)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(item.name).foregroundStyle(.primary)
                                        Spacer()
                                        if item.path == current {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search notes")
            .navigationTitle("Link to Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .frame(minWidth: 320, minHeight: 400)
        .task { loadItems() }
    }

    private func createAndSelect() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        createError = nil
        let filename = name.replacingOccurrences(of: "/", with: "-") + ".md"
        let path = "\(createFolder)/\(filename)"
        // **A title line, not frontmatter.** Every project note already in the
        // vault starts `# Name` and nothing else, and the seven-key block this
        // replaced had two writers and zero readers: nothing in either app parses
        // `title:`, `type:`, `created:` or `linked_notes:` on a project note.
        // Tags come from `#tag` in the body (see `loadFiles`' regex), linked notes
        // from `[[wikilinks]]` in the body (D64), documents from Satchel sidecars.
        //
        // It also could not be hidden. `EndeavorFile.parse` splits frontmatter off
        // before an Endeavor note reaches the editor; a project note goes to the
        // generic editor whole, so the block rendered as seven lines of raw text
        // at the top of every new note. David, on the first one he made:
        // *"i added a project note in TraceMac and this came up."*
        let content = """
        # \(name)

        """
        do {
            try noteStore.writeFile(path, content: content)
            onSelect(path)
            dismiss()
        } catch {
            createError = "Could not create note: \(error.localizedDescription)"
            isCreating = false
        }
    }

    private func loadItems() {
        var result: [(folder: String, path: String, name: String)] = []
        for folder in folders {
            let files = (try? noteStore.listFiles(in: folder)) ?? []
            for file in files {
                let path = "\(folder)/\(file)"
                let name = file.replacingOccurrences(of: ".md", with: "")
                result.append((folder: folder, path: path, name: name))
            }
        }
        items = result
    }
}

// MARK: - Person picker (documents)

struct DocPersonPickerSheet: View {
    let current: [String]
    let onSelect: (String) -> Void

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [Person] {
        let sorted = notion.people.sorted { $0.name < $1.name }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.id) { person in
                Button {
                    onSelect(person.name)
                    dismiss()
                } label: {
                    HStack {
                        Text(person.name).foregroundStyle(.primary)
                        Spacer()
                        if current.contains(person.name) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Search people")
            .navigationTitle("Add Person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .frame(minWidth: 280, minHeight: 380)
    }
}

// MARK: - Project hub entity panel (reusable right-side tab column)

/// The Documents / People / Places tab column used in both the inline Projects view
/// and the MacProjectNoteDetailView sheet.
struct MacProjectHubSidebar: View {
    let notePath: String
    let store: TraceMacDocumentStore
    /// Bumped by the owner after the editor's debounced save lands.
    ///
    /// **This panel derives everything from the note body, so it has to be told
    /// when the body changes.** It reads the file on appear; typing next to it
    /// changed nothing until you left the note and came back, which is exactly
    /// what David hit: *"i added megan to the note as a link and nothing happened
    /// in the rail."*
    ///
    /// A token rather than the body text itself, because the editor owns its own
    /// `content` and lifting that into the host to share it would put every
    /// keystroke through the parent view.
    var reloadToken: Int = 0

    @Environment(NoteStore.self) private var noteStore
    /// **The environment instance, NOT `NotionService.shared`.**
    ///
    /// `TraceMacApp` does `@State private var notionService = NotionService()` and
    /// injects that. `.shared` is a second, separate object on this target that
    /// nothing ever fetches into, so reading `.shared.people` returns an empty
    /// array forever — which is exactly what happened: `[[Megan Weiss]]` was in
    /// the note, Megan Weiss was in Notion, and the People section stayed empty
    /// because it was asking the wrong object.
    ///
    /// `.shared` was chosen to dodge a guessed-at injection risk. Both hosts turn
    /// out to have the environment (the sheet already declares its own
    /// `@Environment(NotionService.self)`), so the risk was imaginary and the
    /// workaround was the bug. **Check which instance the app actually uses.**
    @Environment(NotionService.self) private var notionService

    @State private var linkedDocs: [TraceMacDocument] = []
    /// Every endeavor note, so the Endeavors section can ask which of them link
    /// this one. Session 72. Re-read on the same `reloadToken` as everything
    /// else here, because an endeavor edited elsewhere changes this answer.
    @State private var allEndeavors: [Endeavor] = []
    /// `[[names]]` found in the note body, in the order they are written.
    @State private var mentioned: [String] = []
    @State private var linkableNotes: [LinkableNote] = []

    // MARK: Sources
    //
    // **People and Places are derived from the body, not from frontmatter.**
    //
    // This panel used to read `people:` and `places:` arrays out of the note's
    // frontmatter. Nothing ever wrote anything into them: the project-note
    // skeleton emitted `people: []` and there was no UI to add to it, so both
    // tabs were empty on every note in the vault since the day they were built.
    // The skeleton itself came out on 2026-08-09 (D75) for being metadata nobody
    // read that the generic editor could not hide.
    //
    // Deriving from `[[wikilinks]]` is not a fallback, it is the better source
    // for this kind of note. An Endeavor's `places:` is *prospective* — Lakemore
    // is attached weeks before anyone goes (D59) — so it has to be stored. A
    // project note is a document, and the people in "Final Wedding Speech" are
    // Megan, Ryan and Mitch because it says so. Nobody would curate that list
    // twice.
    //
    // Same forward parser the Endeavor rail's Notes section uses, so the two
    // cannot disagree about what a note links to.
    private var people: [String] {
        let names = Set(notionService.people.filter { !$0.isArchived }.map { $0.name.lowercased() })
        return mentioned.filter { names.contains($0.lowercased()) }
    }
    private var places: [String] {
        let names = Set(notionService.places.map { $0.name.lowercased() })
        return mentioned.filter { names.contains($0.lowercased()) }
    }
    private var notes: [LinkableNote] {
        mentioned.compactMap { target in
            linkableNotes.first { $0.title.localizedCaseInsensitiveCompare(target) == .orderedSame }
        }
        .filter { $0.relativePath != notePath }   // a note does not link to itself
    }

    /// This note's title, as a wikilink would write it.
    private var noteTitle: String {
        ((notePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The endeavors whose body links this note. Session 72.
    private var endeavors: [Endeavor] {
        allEndeavors.filter { $0.linksNote(titled: noteTitle) }
    }

    var body: some View {
        // Stacked sections, not tabs. David: *"right now it lists them but not
        // the same way as endeavors."* The Endeavor rail shows everything at
        // once; three tabs meant hunting for a list that was usually empty.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // FIRST, and only when there is one.
                //
                // Every other section here answers "what does this note
                // mention". This one answers "what is this note part of", which
                // is the frame you read the rest inside — and unlike the others
                // it is usually empty, so an empty-state line for it would be
                // four words of furniture on most notes in the vault.
                if !endeavors.isEmpty {
                    hubSection("Endeavors", count: endeavors.count, empty: "") {
                        ForEach(endeavors) { e in hubEndeavorRow(e) }
                    }
                    Divider().padding(.vertical, 6)
                }

                hubSection("Documents", count: linkedDocs.count,
                           empty: "Nothing filed yet.") {
                    ForEach(linkedDocs) { doc in hubDocRow(doc) }
                }
                Divider().padding(.vertical, 6)

                hubSection("Notes", count: notes.count,
                           empty: "Type [[ in the note to link one.") {
                    ForEach(notes) { note in hubNoteRow(note) }
                }
                Divider().padding(.vertical, 6)

                hubSection("People", count: people.count,
                           empty: "Nobody named yet.") {
                    ForEach(people, id: \.self) { name in hubPersonRow(name) }
                }
                Divider().padding(.vertical, 6)

                hubSection("Places", count: places.count,
                           empty: "Nowhere named yet.") {
                    ForEach(places, id: \.self) { name in hubPlaceRow(name) }
                }

                // **No Visits section, deliberately.** The Endeavor rail derives
                // visits from its start and end dates; a project note has none,
                // so the section would be empty by construction on every note
                // forever. An always-empty section is worse than no section — it
                // reads as a feature that is broken rather than one that does not
                // apply.
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { load() }
        // People and Places match against Notion, and this panel can be the first
        // screen opened in a session — Directory is where those fetches otherwise
        // happen. Guarded, so returning here does not re-hit Notion.
        .task {
            if notionService.people.isEmpty { await notionService.fetchPeople() }
            if notionService.places.isEmpty { await notionService.fetchPlaces() }
        }
        .onChange(of: notePath) { _, _ in load() }
        // Fires a beat after typing stops, on the editor's own save debounce.
        // `.noteStoreCalendarDidChange` was the first attempt and was simply the
        // wrong notification — it is posted for day notes, never for a project.
        .onChange(of: reloadToken) { _, _ in load() }
    }

    @ViewBuilder
    private func hubSection<Content: View>(_ title: String, count: Int, empty: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if count == 0 {
                Text(empty)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            } else {
                content()
            }
        }
    }

    // MARK: - Row helpers

    private func hubDocRow(_ doc: TraceMacDocument) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .selectDocument, object: nil,
                userInfo: ["relativePath": doc.relativePath]
            )
        } label: {
            HStack(spacing: 9) {
                Image(systemName: doc.isPDF ? "doc.fill" : doc.isImage ? "photo" : "doc.text")
                    .foregroundStyle(doc.isPDF ? .red : doc.isImage ? .blue : .secondary)
                    .font(.callout).frame(width: 18)
                Text(doc.title).font(.callout).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Same shape as `hubNoteRow`, and the same routing funnel — the
    /// notification `TraceMacContentView` now maps onto `openSearchResult`, so
    /// this jump records into `navigator` and Back works from it (D121).
    private func hubEndeavorRow(_ e: Endeavor) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .navigateToRecord, object: nil,
                userInfo: ["type": "endeavor", "id": e.id]
            )
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "suitcase.fill")
                    .foregroundStyle(Color.indigo)
                    .font(.callout).frame(width: 18)
                Text(e.name).font(.callout).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(e.name)")
    }

    private func hubNoteRow(_ note: LinkableNote) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .openWikilink, object: nil, userInfo: ["name": note.title]
            )
        } label: {
            HStack(spacing: 9) {
                Image(systemName: note.isDaily ? "calendar" : "doc.text")
                    // The same purple the editor paints a note wikilink with
                    // (D64), read off the storage rather than picked again.
                    .foregroundStyle(Color(nsColor: MacMarkdownTextStorage.noteLinkColor))
                    .font(.callout).frame(width: 18)
                Text(note.title).font(.callout).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hubPersonRow(_ name: String) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .openWikilink, object: nil, userInfo: ["name": name]
            )
        } label: {
            HStack(spacing: 9) {
                MacAvatar(name: name, size: .row, tint: .purple)
                Text(name).font(.callout).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hubPlaceRow(_ name: String) -> some View {
        let place = notionService.places.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        return Button {
            NotificationCenter.default.post(
                name: .openWikilink, object: nil, userInfo: ["name": name]
            )
        } label: {
            HStack(spacing: 9) {
                MacIconBadge(icon: placeIcon(for: place?.category ?? ""),
                             tint: placeColor(for: place?.category ?? ""),
                             size: .compact)
                Text(name).font(.callout).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Load

    private func load() {
        linkedDocs = store.documents.filter { $0.linkedNote == notePath }
        linkableNotes = noteStore.linkableNotes()
        let body = (try? noteStore.readFile(notePath)) ?? ""
        mentioned = NoteStore.wikilinkTargets(in: body)
        // Read here rather than held by the owner: this is the only consumer,
        // and `reloadToken` already brings us back after every save — including
        // a save made in the endeavor whose body decides the answer.
        allEndeavors = EndeavorFile.loadAll(from: noteStore)
    }
}

// MARK: - Project note hub sheet

/// Sheet wrapper — opened from DocNotePanel header. Fixed size, has dismiss button.
struct MacProjectNoteDetailView: View {
    let notePath: String
    let store: TraceMacDocumentStore

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss)          private var dismiss

    /// Bumped when the editor saves, so the hub re-derives from the new body.
    @State private var hubReload = 0

    private var projectName: String {
        notePath.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".md", with: "") ?? notePath
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left — editor
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text(projectName).font(.headline)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary).font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.accentColor.opacity(0.06))
                Divider()
                TraceMacNoteEditor(relativePath: notePath,
                                   onSaved: { hubReload += 1 })
            }
            .frame(minWidth: 420)

            Divider()

            // Right — hub sidebar
            MacProjectHubSidebar(notePath: notePath, store: store, reloadToken: hubReload)
                .frame(width: 280)
        }
        .frame(width: 760, height: 560)
    }
}

// MARK: - Month/year picker

struct MonthYearPickerPopover: View {
    @Binding var selected: Date
    let onPick: () -> Void

    @State private var displayYear: Int = Calendar.current.component(.year, from: Date())

    private let months = Calendar.current.shortMonthSymbols   // Jan–Dec

    var body: some View {
        VStack(spacing: 12) {
            // Year navigation
            HStack {
                Button { displayYear -= 1 } label: {
                    Image(systemName: "chevron.left").font(.caption)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(String(displayYear))
                    .font(.caption).fontWeight(.semibold)
                Spacer()
                Button { displayYear += 1 } label: {
                    Image(systemName: "chevron.right").font(.caption)
                }
                .buttonStyle(.plain)
            }

            // Month grid — 3 columns × 4 rows
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(0..<12, id: \.self) { idx in
                    let isSelected = selectedMonth == idx + 1 && selectedYear == displayYear
                    Button(months[idx]) {
                        // Set to 1st of chosen month/year, preserve day if in same month
                        var comps = DateComponents()
                        comps.year = displayYear
                        comps.month = idx + 1
                        comps.day = 1
                        if let d = Calendar.current.date(from: comps) {
                            selected = d
                        }
                        onPick()
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 200)
        .onAppear {
            displayYear = Calendar.current.component(.year, from: selected)
        }
    }

    private var selectedMonth: Int { Calendar.current.component(.month, from: selected) }
    private var selectedYear:  Int { Calendar.current.component(.year,  from: selected) }
}

// MARK: - Filter popovers

/// Generic searchable single-select list popover used for Tag and Project filters.
struct DocFilterPickerPopover: View {
    let title: String
    let items: [String]
    let selected: String?
    let onSelect: (String) -> Void

    @State private var search = ""

    private var filtered: [String] {
        search.isEmpty ? items : items.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack {
                                Text(item)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if item == selected {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 220)
    }
}

/// Date filter popover — pick a year, a month, or both.
struct DocDateFilterPopover: View {
    let availableYears: [Int]
    let availableDates: [(year: Int, month: Int)]
    @Binding var selectedYear: Int?
    @Binding var selectedMonth: Int?

    private let monthNames = Calendar.current.shortMonthSymbols   // Jan–Dec

    /// Months available given the selected year (or all months if no year selected).
    private var availableMonths: [Int] {
        let filtered = selectedYear == nil
            ? availableDates
            : availableDates.filter { $0.year == selectedYear }
        return Array(Set(filtered.map(\.month))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Date Filter")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                if selectedYear != nil || selectedMonth != nil {
                    Button("Clear") { selectedYear = nil; selectedMonth = nil }
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                }
            }

            // Year picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Year").font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    ForEach(availableYears, id: \.self) { year in
                        // Same hoist as the month grid below, applied to its twin
                        // before it tips over too — identical construct, and it was
                        // sitting on the same headroom.
                        let isOn: Bool = (selectedYear == year)
                        let fill: Color = isOn ? Color.accentColor.opacity(0.15)
                                               : Color.secondary.opacity(0.09)
                        let tint: Color = isOn ? Color.accentColor : Color.secondary
                        Button(String(year)) {
                            if isOn { selectedYear = nil }
                            else { selectedYear = year; selectedMonth = nil }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(fill)
                        .foregroundStyle(tint)
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                    }
                }
            }

            // Month picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Month").font(.caption2).foregroundStyle(.tertiary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                    ForEach(availableMonths, id: \.self) { month in
                        // Session 79: the two inline colour ternaries below used to
                        // live in `.background(...)` / `.foregroundStyle(...)`, and
                        // this expression type-checked only just inside the budget.
                        // Hoisting them to typed lets is what the compiler asks for
                        // when it says "break the expression into distinct
                        // sub-expressions" — nothing about the rendering changes.
                        let isOn: Bool = (selectedMonth == month)
                        let fill: Color = isOn ? Color.accentColor.opacity(0.15)
                                               : Color.secondary.opacity(0.09)
                        let tint: Color = isOn ? Color.accentColor : Color.secondary
                        Button(monthNames[month - 1]) {
                            selectedMonth = isOn ? nil : month
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(fill)
                        .foregroundStyle(tint)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 230)
    }
}

// MARK: - PDF viewer (Mac)

struct PDFViewRepresentable: NSViewRepresentable {
    let url: URL
    var zoom: PreviewZoomController? = nil
    var find: MacPDFFind? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        Self.relaxSizing(view)
        // Bound before the load, so the highlight lands whether the bytes were
        // already here or arrive from iCloud a moment later. `bind` writes no
        // observed property; the search itself is deferred a runloop turn for
        // the same reason the zoom attach is.
        find?.bind(view)
        Self.load(url, into: view, find: find)
        if let zoom {
            // Registered on the next runloop turn: attaching writes observed
            // properties, and doing that inside `makeNSView` mutates state
            // during a SwiftUI update pass, which is the "Modifying state
            // during view update" runtime warning.
            DispatchQueue.main.async { zoom.attach(pdf: view) }
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // Only rebuild when the file actually changed — reassigning `document`
        // on every SwiftUI update resets scroll position mid-read.
        if nsView.document?.documentURL != url {
            Self.load(url, into: nsView, find: find)
        }
        // Cheap: returns immediately unless the query changed since the last
        // run. Deferred anyway, because `updateNSView` is an update pass and
        // the search writes observed state.
        DispatchQueue.main.async { find?.applyIfNeeded() }
    }

    /// Accept whatever height the split offers.
    ///
    /// Session 63 (2026-08-02). David: *"the divider bar does in fact move up
    /// but only when the pdf is entirely within the frame. if the pdf is
    /// expanded and extends beyond the frame then the split only moves to make
    /// it bigger"* — an exact description of a size floor.
    ///
    /// A zoomed `PDFView` reports a large fitting size, and `NSSplitView` will
    /// not shrink a pane below what its content says it needs. So the divider
    /// travelled down freely and stopped dead going up, and *how far* it
    /// stopped short depended on the zoom level, which is why it looked like
    /// the divider was broken rather than the sizing.
    ///
    /// A scrolling viewer has no natural size — it scrolls precisely so it does
    /// not need one. Returning the proposal says so, and the compression
    /// resistance in `relaxSizing` says the same thing to AppKit's own layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 240)
    }

    static func relaxSizing(_ view: NSView) {
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    /// Loads the PDF, waiting for iCloud if the bytes are not here yet.
    ///
    /// THE BLANK-PAGE BUG, Mac edition (Session 63, 2026-08-01). Satchel fixed
    /// this on iOS in `SatchelPDFView.load`; the Mac was never touched and had
    /// the identical defect. `PDFDocument(url:)` on a file iCloud has not
    /// downloaded returns nil, and `PDFView` with a nil document draws nothing
    /// — no error, no spinner, just an empty pane. Opening the document again
    /// works, because the download completed in between, which makes it look
    /// like a random glitch rather than a missing code path.
    ///
    /// This matters more on the Mac than on the phone: the Mac is where old
    /// documents get browsed, and old documents are exactly the ones iCloud has
    /// evicted to save disk.
    ///
    /// Ask for the download, then read under a file coordinator, which waits.
    /// Off the main thread, because a coordinated read on a file that has not
    /// arrived blocks until it does.
    @MainActor
    private static func load(_ url: URL, into view: PDFView, find: MacPDFFind? = nil) {
        if let doc = PDFDocument(url: url) {
            view.document = doc
            // Next runloop turn: this path runs inside `makeNSView`, and the
            // search writes observed state.
            DispatchQueue.main.async { find?.applyIfNeeded() }
            return
        }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        // The `PDFView` stays on the MainActor throughout — only the URL goes
        // into the detached read, and only `Data` comes back. Handing an AppKit
        // object to a detached task is the kind of thing that compiles today and
        // becomes an error under stricter concurrency later.
        Task { @MainActor in
            let data: Data? = await Task.detached(priority: .userInitiated) {
                var bytes: Data?
                var coordinatorError: NSError?
                NSFileCoordinator().coordinate(
                    readingItemAt: url, options: [], error: &coordinatorError
                ) { readURL in
                    bytes = try? Data(contentsOf: readURL)
                }
                return bytes
            }.value

            // The view may have been handed a document while this was in
            // flight — do not stamp a stale one over it.
            guard view.document == nil else { return }
            view.document = data.flatMap { PDFDocument(data: $0) }
            // The other moment a document first exists. Without this a PDF that
            // iCloud was still fetching when the search result opened it would
            // render unpainted and never recover — the same shape as the
            // blank-page bug this method was written for.
            find?.applyIfNeeded()
        }
    }
}

// MARK: - Image preview

/// Image preview with the same iCloud handling as the PDF path above.
///
/// The image case was worse than the PDF case, not better. `NSImage(contentsOf:)`
/// was called inside an `else if` binding, so an undownloaded photo failed the
/// condition and fell through to the *next* branch — the generic "Open in
/// Default App" placeholder. A photo that iCloud simply had not fetched yet
/// presented as an unsupported file type.
struct MacImagePreview: View {
    let url: URL
    var zoom: PreviewZoomController? = nil

    @State private var image: NSImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let image {
                MacZoomableImage(image: image, zoom: zoom)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 38, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("Image not available")
                        .font(.headline)
                    Text("It may still be downloading from iCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .onAppear { zoom?.detach() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { await load() }
    }

    private func load() async {
        isLoading = true

        // Nudge iCloud if this is still a placeholder rather than real bytes.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let target = url
        let loaded: NSImage? = await Task.detached(priority: .userInitiated) {
            var bytes: Data?
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(
                readingItemAt: target, options: [], error: &coordinatorError
            ) { readURL in
                bytes = try? Data(contentsOf: readURL)
            }
            return bytes.flatMap { NSImage(data: $0) }
        }.value

        image = loaded
        isLoading = false
    }
}

// MARK: - Preview zoom
//
// Session 63 (2026-08-02). David, looking at a scanned receipt filling the whole
// pane with its top third: *"the preview of the document is very big. there
// should be a way to shrink it and zoom, etc"*
//
// He was looking at a bug, not a preference. `Image(nsImage:).resizable()
// .scaledToFit()` fits only when its parent proposes a bounded size; inside a
// greedy `maxHeight: .infinity` frame stacked above a metadata panel, the
// proposal came back larger than the visible area and the image was laid out at
// that size and clipped. So the whole image was never on screen and there was
// no zoom, no scroll and no fit control to get to the rest of it.
//
// This is the same class of bug Satchel hit on iOS, where the comment on
// `ZoomableImageScrollView` reads: *"A 12-megapixel photo has no business being
// laid out at its intrinsic size, which is exactly what `ScrollView { Image
// .resizable().scaledToFit() }` does."* The answer is the same on both
// platforms: let the scroll view own the zoom. It already knows how to fit,
// magnify, scroll and centre, and reimplementing that on SwiftUI gestures buys
// nothing.

/// Drives whichever preview is on screen. One controller serves both the image
/// and the PDF path so the zoom bar does not have to know which it is talking
/// to; exactly one of the two references is non-nil at a time.
///
/// `@Observable`, not `ObservableObject`. This project uses Observation
/// everywhere — `NoteStore`, `NotionService`, `IOSDocumentStore` and seven
/// others — and imports Combine in exactly one file. Reaching for
/// `ObservableObject` here cost a build: both `@Published` and the protocol
/// need `import Combine`, which TraceMac has never had, and the failure reads
/// as "does not conform to protocol 'ObservableObject'" rather than naming the
/// missing import.
///
/// Deliberately not `@MainActor` either. Every caller is already on the main
/// thread — SwiftUI bodies, `onAppear`, and the two `DispatchQueue.main.async`
/// attach hops — so the annotation would buy nothing.
@Observable
final class PreviewZoomController {

    var percent: Int = 100
    var isFitted: Bool = true
    /// False when no preview is showing (an unsupported file type), so the bar
    /// can hide rather than offer controls that do nothing.
    var isActive: Bool = false

    /// Ignored by Observation: plumbing to AppKit views, never read from a view
    /// body, and a weak reference has no business waking a redraw.
    @ObservationIgnored private weak var imageView: MacZoomableImageView?
    @ObservationIgnored private weak var pdfView: PDFView?

    private static let step: CGFloat = 1.25

    func attach(image view: MacZoomableImageView) {
        imageView = view
        pdfView = nil
        isActive = true
        view.onZoomChange = { [weak self] mag, fit in
            guard let self else { return }
            self.percent = Int((mag * 100).rounded())
            self.isFitted = abs(mag - fit) < 0.005
        }
    }

    func attach(pdf view: PDFView) {
        pdfView = view
        imageView = nil
        isActive = true
        percent = Int((view.scaleFactor * 100).rounded())
        isFitted = view.autoScales
    }

    func detach() {
        imageView = nil
        pdfView = nil
        isActive = false
    }

    func zoomIn()  { zoom(by: Self.step) }
    func zoomOut() { zoom(by: 1 / Self.step) }

    func fit() {
        if let imageView {
            imageView.zoomToFit()
        } else if let pdfView {
            pdfView.autoScales = true
            percent = Int((pdfView.scaleFactor * 100).rounded())
            isFitted = true
        }
    }

    func actualSize() {
        if let imageView {
            imageView.zoomToActualSize()
        } else if let pdfView {
            pdfView.autoScales = false
            pdfView.scaleFactor = 1
            percent = 100
            isFitted = false
        }
    }

    private func zoom(by factor: CGFloat) {
        if let imageView {
            imageView.zoom(by: factor)
        } else if let pdfView {
            // `autoScales` has to go off first: it re-fits on every layout pass
            // and would undo the zoom on the next one.
            pdfView.autoScales = false
            let target = pdfView.scaleFactor * factor
            pdfView.scaleFactor = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, target))
            percent = Int((pdfView.scaleFactor * 100).rounded())
            isFitted = false
        }
    }
}

/// `NSScrollView` with magnification, holding the image at its true pixel size
/// as the document view. Starts fitted, and stays fitted across window resizes
/// until the user picks a zoom of their own.
final class MacZoomableImageView: NSScrollView {

    private let imageContainer = NSImageView()
    private var lastReported: CGFloat = -1

    /// Clip-view origin when the current drag began. Nil when not dragging.
    private var panStart: NSPoint?

    /// True once the view has been laid out at a real size and fitted once.
    private var hasSizedOnce = false

    /// True while showing the whole image. Tracked so a window resize re-fits
    /// rather than stranding the image at a magnification that suited the old
    /// size, while leaving a deliberate zoom alone.
    private(set) var isFitted = true

    /// There is somewhere to pan to only when the document is bigger than the
    /// viewport. Below that the drag does nothing and the cursor should not
    /// promise otherwise.
    var canPan: Bool {
        guard let doc = documentView else { return false }
        return doc.frame.width  > contentView.bounds.width  + 0.5
            || doc.frame.height > contentView.bounds.height + 0.5
    }

    var onZoomChange: ((CGFloat, CGFloat) -> Void)?
    var currentImage: NSImage? { imageContainer.image }

    init(image: NSImage) {
        super.init(frame: .zero)

        borderType          = .noBorder
        drawsBackground     = true
        backgroundColor     = NSColor(calibratedWhite: 0.17, alpha: 1)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers  = true
        allowsMagnification = true
        minMagnification    = 0.02
        maxMagnification    = 8

        imageContainer.imageScaling = .scaleAxesIndependently
        imageContainer.animates     = false
        documentView = imageContainer

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        imageContainer.addGestureRecognizer(doubleClick)

        // Click-and-drag to pan. Scrollers and the wheel cover vertical, but a
        // mouse has no horizontal axis, and a receipt zoomed past fit needs
        // both. Added on the image only: a PDF's drag already means "select
        // text", which is what you want when copying an order number off one.
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        imageContainer.addGestureRecognizer(pan)

        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification, object: self)

        // Catches trackpad pinch-zoom, which changes `magnification` without
        // going through any method here.
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification, object: contentView)

        setImage(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setImage(_ image: NSImage) {
        imageContainer.image = image
        // `image.size` is in points and can be zero for a malformed file; a zero
        // document view makes magnification arithmetic divide by zero.
        let size = (image.size.width > 0 && image.size.height > 0)
            ? image.size
            : NSSize(width: 1, height: 1)
        imageContainer.frame = NSRect(origin: .zero, size: size)
        zoomToFit()
    }

    /// The magnification at which the whole image is visible.
    var fitMagnification: CGFloat {
        guard let image = imageContainer.image,
              image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / image.size.width, bounds.height / image.size.height)
    }

    func zoomToFit() {
        let target = fitMagnification
        // Guard the assignment too, not just the publish. Re-assigning the same
        // magnification during a live resize still churns the clip view, and
        // this runs on every frame of a divider drag.
        if abs(magnification - target) > 0.0005 {
            magnification = target
            centreDocument()
        }
        isFitted = true
        report(force: false)
    }

    func zoomToActualSize() {
        setMagnification(1, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
        isFitted = abs(1 - fitMagnification) < 0.005
        report(force: true)
    }

    func zoom(by factor: CGFloat) {
        let target = max(minMagnification, min(maxMagnification, magnification * factor))
        setMagnification(target, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
        isFitted = abs(target - fitMagnification) < 0.005
        report(force: true)
    }

    @objc private func handleDoubleClick() {
        isFitted ? zoomToActualSize() : zoomToFit()
    }

    /// Drag the document itself.
    ///
    /// Translation comes from `self`, not from the image, because the image is
    /// what moves: measuring in a view that is being scrolled makes the
    /// translation feed back on itself and the pan accelerates away.
    ///
    /// `origin = start - translation` on both axes. It looks like it should be
    /// minus-then-plus, but the clip view is unflipped, so both signs work out
    /// the same way: drag right and the visible rect moves left; drag down and
    /// it moves up. Divided by `magnification` to convert screen points into
    /// document points.
    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        guard canPan else { return }

        switch gesture.state {
        case .began:
            panStart = contentView.bounds.origin
            NSCursor.closedHand.push()

        case .changed:
            guard let start = panStart, let doc = documentView else { return }
            let t = gesture.translation(in: self)
            let scale = max(magnification, 0.0001)
            let visible = contentView.bounds.size
            let maxX = max(0, doc.frame.width  - visible.width)
            let maxY = max(0, doc.frame.height - visible.height)
            contentView.scroll(to: NSPoint(
                x: min(maxX, max(0, start.x - t.x / scale)),
                y: min(maxY, max(0, start.y - t.y / scale))
            ))
            reflectScrolledClipView(contentView)

        case .ended, .cancelled, .failed:
            if panStart != nil { NSCursor.pop() }
            panStart = nil

        default:
            break
        }
    }

    /// Open hand while there is somewhere to go, the normal arrow otherwise.
    override func resetCursorRects() {
        super.resetCursorRects()
        if canPan { addCursorRect(bounds, cursor: .openHand) }
    }

    /// Fits **once**, when the view first receives a real size.
    ///
    /// It used to re-fit on every frame change so long as the image was still
    /// fitted. That sounds helpful and was the engine of the flicker: dragging
    /// the divider changes the frame continuously, so this re-fitted
    /// continuously, publishing zoom state back into the layout that was
    /// causing it.
    ///
    /// Resizing the pane no longer touches the zoom, which is also what Preview
    /// does — making a window bigger shows you more of the page, it does not
    /// re-scale it. `Fit` is one click away when it is wanted.
    ///
    /// The first fit still has to happen here: at `init` the view has no bounds
    /// yet, so `fitMagnification` has nothing to divide by and returns 1.
    @objc private func frameDidChange() {
        guard !hasSizedOnce, bounds.width > 1, bounds.height > 1 else { return }
        hasSizedOnce = true
        zoomToFit()
    }

    @objc private func boundsDidChange() {
        // Fires on every scroll as well as every zoom, so only a real
        // magnification change is worth publishing.
        report(force: false)
    }

    /// Publishes the current zoom, **on the next runloop turn**.
    ///
    /// Session 63 (2026-08-02). David, dragging the new divider: *"the screen
    /// flickers a lot"*. A feedback loop, and I built it:
    ///
    ///   drag → pane height changes → `frameDidChange` → `zoomToFit` →
    ///   `onZoomChange` → writes an `@Observable` → SwiftUI re-lays out →
    ///   pane height changes → …
    ///
    /// Each hop is reasonable; together they run every frame of the drag. The
    /// callback writes observed state, so doing it *synchronously inside a
    /// layout pass* invites SwiftUI straight back in. Hopping to the next turn
    /// breaks the cycle: layout finishes first, and the publish lands after.
    private func report(force: Bool) {
        if !force, abs(magnification - lastReported) < 0.0005 { return }
        lastReported = magnification
        // `canPan` changes with the zoom, so the cursor has to be recomputed or
        // it stays an arrow after zooming in and a hand after zooming back out.
        window?.invalidateCursorRects(for: self)

        let publishedMagnification = magnification
        let publishedFit = fitMagnification
        DispatchQueue.main.async { [weak self] in
            self?.onZoomChange?(publishedMagnification, publishedFit)
        }
    }

    private func centreDocument() {
        guard let doc = documentView else { return }
        let visible = contentView.bounds.size
        let docSize = doc.frame.size
        contentView.scroll(to: NSPoint(
            x: max(0, (docSize.width  - visible.width)  / 2),
            y: max(0, (docSize.height - visible.height) / 2)
        ))
        reflectScrolledClipView(contentView)
    }
}

struct MacZoomableImage: NSViewRepresentable {
    let image: NSImage
    var zoom: PreviewZoomController? = nil

    func makeNSView(context: Context) -> MacZoomableImageView {
        let view = MacZoomableImageView(image: image)
        PDFViewRepresentable.relaxSizing(view)
        if let zoom {
            // Deferred for the same reason as the PDF path: attaching writes
            // observed properties, which must not happen inside a SwiftUI
            // update pass.
            DispatchQueue.main.async { zoom.attach(image: view) }
        }
        return view
    }

    func updateNSView(_ nsView: MacZoomableImageView, context: Context) {
        if nsView.currentImage !== image {
            nsView.setImage(image)
        }
    }

    /// Same size floor as the PDF path, for the same reason — a zoomed image is
    /// a document view far larger than the pane, and without this the split
    /// refuses to travel back up past it. See the note on
    /// `PDFViewRepresentable.sizeThatFits`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacZoomableImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 240)
    }
}

/// Zoom controls, overlaid on the preview. Deliberately shows the percentage:
/// without it "did that do anything?" is unanswerable at small steps.
struct PreviewZoomBar: View {
    /// A plain `let` is correct for an `@Observable` type — Observation tracks
    /// whatever the body reads, so no property wrapper is needed here.
    let zoom: PreviewZoomController

    var body: some View {
        HStack(spacing: 3) {
            button("minus.magnifyingglass", help: "Zoom out") { zoom.zoomOut() }
            Text("\(zoom.percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44)
            button("plus.magnifyingglass", help: "Zoom in") { zoom.zoomIn() }

            Divider().frame(height: 13).padding(.horizontal, 2)

            Button("Fit") { zoom.fit() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(zoom.isFitted ? Color.accentColor : Color.secondary)
                .help("Fit the whole document in the pane")
            Button("100%") { zoom.actualSize() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Actual size")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(MacGlyph.control)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
