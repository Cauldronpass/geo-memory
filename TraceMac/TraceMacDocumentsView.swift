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

    @Environment(NoteStore.self) private var noteStore

    @State private var store: TraceMacDocumentStore? = nil
    @State private var selectedDoc: TraceMacDocument? = nil
    @State private var searchText = ""
    @State private var activeTag: String? = nil
    @State private var activeProject: String? = nil
    @State private var filterYear: Int? = nil
    @State private var filterMonth: Int? = nil
    @State private var categoryFilter = "All"
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

    /// Divider strip height. Thick enough to aim at without hunting.
    private let dividerThickness: CGFloat = 6

    // Row context menu. Session 63 (2026-08-02) — David: *"archive and delete of
    // a file isnt currently visible"*. Delete did exist, at the bottom of the
    // metadata disclosure group, which is both the last place you would look and
    // now behind a scroll. Right-click on the thing you want to act on is where
    // a Mac user reaches first, and the list had no context menu at all.
    @State private var deleteCandidate: TraceMacDocument? = nil

    // Standard tabs always shown; any non-standard subfolder (e.g. "Receipts",
    // or a year folder written by Satchel) gets its own tab.
    //
    // "Archive" left the exclusion set in Session 63 along with the tab and the
    // move-menu item that created the folder. If a `Documents/Archive/` folder
    // exists on someone's disk it now shows up as an ordinary category rather
    // than being filtered out of every list — which is the honest rendering:
    // the folder is just a folder, and hiding it was what made documents put
    // there disappear with no way back.
    private var categories: [String] {
        let standard = ["Inbox", "Project", "Place", "Trip"]
        let extras = Array(Set(store?.documents.map(\.category) ?? []).subtracting(Set(standard))).sorted()
        return ["All"] + standard + extras
    }

    private var filtered: [TraceMacDocument] {
        guard let store else { return [] }
        let cal = Calendar.current
        return store.documents.filter { doc in
            let matchesSearch = searchText.isEmpty
                || doc.title.localizedCaseInsensitiveContains(searchText)
                || doc.filename.localizedCaseInsensitiveContains(searchText)
                || doc.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            let matchesTag = activeTag == nil || doc.tags.contains(activeTag!)
            let matchesCategory = categoryFilter == "All"
                || doc.category.localizedCaseInsensitiveCompare(categoryFilter) == .orderedSame
            let matchesProject = activeProject == nil || doc.linkedNote == activeProject
            let matchesYear = filterYear == nil || {
                guard let d = doc.created else { return false }
                return cal.component(.year, from: d) == filterYear!
            }()
            let matchesMonth = filterMonth == nil || {
                guard let d = doc.created else { return false }
                return cal.component(.month, from: d) == filterMonth!
            }()
            return matchesSearch && matchesTag && matchesCategory && matchesProject
                && matchesYear && matchesMonth
        }
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
            MacSectionHeader("Satchel",
                             action: MacHeaderButton(icon: "plus",
                                                     help: "Add a document") { importDocument() })
            columns
        }
    }

    /// The screen itself. Split out only so `body` can put a header above it
    /// without re-indenting five hundred lines; nothing here changed.
    private var columns: some View {
        HStack(spacing: 0) {
            if !listCollapsed { leftColumn }
            CollapseHandle(isCollapsed: $listCollapsed, collapsesRight: false, showLine: true, panelColor: .clear)
            rightColumn.frame(maxWidth: .infinity)
        }
        .task {
            if store == nil {
                store = TraceMacDocumentStore(noteStore: noteStore)
            }
            await store?.reload()
        }
        .task(id: deepLinkPath?.wrappedValue) {
            guard let path = deepLinkPath?.wrappedValue else { return }
            // The store may not have scanned yet on a cold jump into this
            // section. Build and load it here rather than hoping the `.task`
            // above won the race — that hope is exactly what the old 0.4s delay
            // was standing in for.
            if store == nil { store = TraceMacDocumentStore(noteStore: noteStore) }
            if store?.documents.isEmpty ?? true { await store?.reload() }
            selectedDoc = store?.documents.first { $0.relativePath == path }
            deepLinkPath?.wrappedValue = nil
        }
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

            // Category filter — scrollable so labels never wrap
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(categories, id: \.self) { cat in
                        Button(cat) { categoryFilter = cat; if cat != "Project" { activeProject = nil } }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .fixedSize()                          // never truncate or wrap
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                categoryFilter == cat
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .foregroundStyle(
                                categoryFilter == cat ? Color.accentColor : Color.secondary
                            )
                            .overlay(
                                // Underline indicator for selected tab
                                Rectangle()
                                    .frame(height: 2)
                                    .foregroundStyle(categoryFilter == cat ? Color.accentColor : Color.clear)
                                    .padding(.horizontal, 6),
                                alignment: .bottom
                            )
                    }
                }
                .padding(.horizontal, 8)
            }
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
        .frame(width: 240)
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
                            categoryFilter = "All"
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
                // Tag filter pill
                filterPill(
                    icon: "tag",
                    label: activeTag ?? "Tags",
                    isActive: activeTag != nil,
                    onClear: { activeTag = nil }
                ) {
                    showingTagFilter = true
                }
                .popover(isPresented: $showingTagFilter, arrowEdge: .bottom) {
                    DocFilterPickerPopover(
                        title: "Filter by Tag",
                        items: allTags,
                        selected: activeTag,
                        onSelect: { activeTag = $0; showingTagFilter = false }
                    )
                }

                // Project filter pill — only when in Project category
                if categoryFilter == "Project" {
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
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
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
                                DocMetadataPanel(doc: doc, store: store!) { movedDoc in
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

    @ViewBuilder
    private func docViewer(for doc: TraceMacDocument) -> some View {
        if doc.isPDF, let url = noteStore.resolvedURL(for: doc.relativePath) {
            PDFViewRepresentable(url: url, zoom: zoom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Image(systemName: doc.isPDF ? "doc.fill" : doc.isImage ? "photo" : "doc.text")
                    .foregroundStyle(doc.isPDF ? .red : doc.isImage ? .blue : .secondary)
                    .font(.caption)
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
                    ForEach(doc.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
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

    private func noteName(from path: String) -> String {
        path.components(separatedBy: "/").last?.replacingOccurrences(of: ".md", with: "") ?? path
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
    let onSave: (TraceMacDocument) -> Void

    @Environment(NotionService.self) private var notion
    @Environment(NoteStore.self) private var noteStore

    @State private var title: String = ""
    @State private var tags: [String] = []
    @State private var linkedNote: String = ""
    @State private var people: [String] = []
    @State private var description: String = ""
    @State private var docDate: Date = Date()
    @State private var showingDatePicker = false
    @State private var isSaving = false
    @State private var isMoving = false
    @State private var isScanning = false
    @State private var scanError: String? = nil
    @State private var userContext: String = ""
    @State private var isExpanded = true
    @State private var showingTagPopover = false
    @State private var newTagText = ""
    @State private var showingPeoplePicker = false
    @State private var showingProjectMover = false
    @State private var showingPlaceMover = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        DisclosureGroup("Metadata", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                categoryRow
                titleRow
                dateRow
                tagsRow
                peopleRow
                descriptionRow
                if let err = scanError {
                    Text(err).font(.caption).foregroundStyle(.red)
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

    // MARK: - Category + Move

    private var categoryRow: some View {
        HStack(spacing: 8) {
            fieldLabel("Category")
            Text(doc.category)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            Spacer()
            Menu {
                if doc.category != "Inbox"   { Button("Move to Inbox")      { move(to: "Inbox") } }
                if doc.category != "Project" { Button("Move to Project…")   { showingProjectMover = true } }
                if doc.category != "Place"   { Button("Move to Place…")     { showingPlaceMover  = true } }
                if doc.category != "Trip"    { Button("Move to Trip")       { move(to: "Trip") } }
                if doc.category != "Other"   { Button("Move to Other")      { move(to: "Other") } }
                // "Archive" removed in Session 63 with the Archive tab that read
                // it back. It was the only writer of `Documents/Archive/`, and
                // with no reader it was a one-way door: the document vanished
                // from every list on the Mac and stayed in the flat library on
                // iOS, which knows nothing about the folder.
            } label: {
                HStack(spacing: 4) {
                    if isMoving { ProgressView().controlSize(.mini) }
                    Text("Move to…").font(.caption)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.1))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isMoving)
        }
        .sheet(isPresented: $showingProjectMover) {
            LinkedNotePickerSheet(current: linkedNote, filterFolders: ["Notes/Projects"]) { picked in
                linkedNote = picked
                move(to: "Project")
            }
            .environment(noteStore)
        }
        .sheet(isPresented: $showingPlaceMover) {
            LinkedNotePickerSheet(current: linkedNote, filterFolders: ["Notes/Places"]) { picked in
                linkedNote = picked
                move(to: "Place")
            }
            .environment(noteStore)
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
                color: .accentColor
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
                onAddTap: { showingPeoplePicker = true }
            )
        }
    }

    // MARK: - Description + AI scan

    private var descriptionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Context hint field — user types optional context before hitting sparkle
            HStack(alignment: .center, spacing: 0) {
                fieldLabel("Context")
                ZStack(alignment: .leading) {
                    TextField("", text: $userContext)
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if userContext.isEmpty {
                        Text("Optional hint for AI (who, what, when…)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                    }
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
                    // AI sparkle button — top-right corner of the text editor
                    Button {
                        runScan()
                    } label: {
                        Group {
                            if isScanning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Circle())
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .padding(4)
                    .help("Auto-fill tags and description using AI")
                }
            }
        }
    }

    private func runScan() {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        let currentTags = existingTags
        let context = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let result = try await DocumentScanService.scan(
                    doc: doc,
                    noteStore: noteStore,
                    existingTags: currentTags,
                    userContext: context
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
        tags = doc.tags
        linkedNote = doc.linkedNote ?? ""
        people = doc.people
        description = doc.description
        docDate = doc.created ?? Date()

        // Auto-scan if this looks like a freshly imported doc with no metadata yet
        let noMetadata = doc.tags.isEmpty && doc.description.isEmpty
        let scannable = doc.isPDF || doc.isImage
        if noMetadata && scannable && !isScanning {
            runScan()
        }
    }

    private func move(to category: String) {
        isMoving = true
        Task {
            do { try store.moveDocument(doc, to: category) }
            catch {
                await MainActor.run { isMoving = false }
                return
            }
            // Build a synthetic doc at the new path so we can write the sidecar there
            let newPath = "Documents/\(category)/\(doc.filename)"
            let newSidecarBase = newPath.hasSuffix(".\(doc.fileExtension)")
                ? String(newPath.dropLast(doc.fileExtension.count + 1))
                : newPath
            let movedDoc = TraceMacDocument(
                relativePath: newPath,
                filename: doc.filename,
                category: category,
                fileExtension: doc.fileExtension,
                title: title.trimmingCharacters(in: .whitespaces),
                tags: tags,
                created: docDate,
                linkedNote: linkedNote.isEmpty ? nil : linkedNote,
                people: people,
                description: description
            )
            try? store.saveSidecar(
                for: movedDoc,
                title: movedDoc.title,
                tags: movedDoc.tags,
                linkedNote: movedDoc.linkedNote,
                people: movedDoc.people,
                description: movedDoc.description,
                date: docDate
            )
            // Delete old sidecar if it was at a different path
            let oldSidecar = doc.sidecarPath
            let newSidecar = "\(newSidecarBase).md"
            if oldSidecar != newSidecar {
                try? noteStore.deleteFile(oldSidecar)
            }
            await MainActor.run { isMoving = false; onSave(movedDoc) }
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
            date: docDate
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
// Reusable tag/people chip list with inline add-by-typing or custom add action.

struct DocChipsEditor: View {
    @Binding var chips: [String]
    let allSuggestions: [String]
    let placeholder: String
    let color: Color
    var onAddTap: (() -> Void)? = nil   // if set, "+" opens this instead of the text popover

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

    private func chipView(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text).font(.caption)
            Button { chips.removeAll { $0 == text } } label: {
                Image(systemName: "xmark").font(MacGlyph.smallBold)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
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

    var body: some View {
        // Stacked sections, not tabs. David: *"right now it lists them but not
        // the same way as endeavors."* The Endeavor rail shows everything at
        // once; three tabs meant hunting for a list that was usually empty.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
                        Button(String(year)) {
                            if selectedYear == year { selectedYear = nil }
                            else { selectedYear = year; selectedMonth = nil }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selectedYear == year ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.09))
                        .foregroundStyle(selectedYear == year ? Color.accentColor : Color.secondary)
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
                        Button(monthNames[month - 1]) {
                            selectedMonth = selectedMonth == month ? nil : month
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selectedMonth == month ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.09))
                        .foregroundStyle(selectedMonth == month ? Color.accentColor : Color.secondary)
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

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        Self.relaxSizing(view)
        Self.load(url, into: view)
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
            Self.load(url, into: nsView)
        }
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
    private static func load(_ url: URL, into view: PDFView) {
        if let doc = PDFDocument(url: url) {
            view.document = doc
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
