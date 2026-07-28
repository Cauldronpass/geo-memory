import SwiftUI

// MARK: - SatchelLibraryView
//
// Build step 6 — the launch screen. Frame 1 of `satchel-mockup-v4.html`.
//
// Order on screen, top to bottom: header, search, Kit, Browse, Recent, and a
// permanent scan FAB. Scope doc §5 puts Scan as a primary action rather than
// buried in a FAB menu, so the button's TAP is always scan and the other three
// capture sources live behind a long press — the urgent path stays one tap.
//
// SIMULATOR NOTE: `NoteStore` falls back to the app's own local Documents
// folder when iCloud is unavailable, and the Simulator never has iCloud. Each
// app gets a separate sandbox there, so **Satchel shows an empty library on the
// Simulator by design.** Run on device to see real documents. This is not a bug
// and not a container misconfiguration.

struct SatchelLibraryView: View {

    /// Supplied by `SatchelApp` so `satchel://` URLs can drive this screen.
    /// Defaults to its own instance so previews and any future call site work
    /// without one.
    var router: SatchelRouter = SatchelRouter()

    @State private var path = NavigationPath()
    @State private var noteStore = NoteStore.shared
    @State private var store = iOSDocumentStore()
    @State private var endeavorStore = SatchelEndeavorStore()

    @State private var query: String = ""
    @State private var captureSource: SatchelCaptureSource?
    /// Only ever set by a `satchel://…?note=` hand-off, and cleared the moment
    /// the capture sheet closes. Held here rather than read off the router at
    /// sheet-build time because the router's copy is consumed immediately, and a
    /// sheet builds its content later than the observer that presented it.
    @State private var captureNoteLink: String?

    private var kit: KitMembership.Layout {
        KitMembership.assemble(
            documents: store.documents,
            endeavors: endeavorStore.endeavors
        )
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [TraceMacDocument] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return store.documents.filter { doc in
            if doc.title.lowercased().contains(q) { return true }
            if doc.description.lowercased().contains(q) { return true }
            if doc.category.lowercased().contains(q) { return true }
            if doc.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
            if let name = doc.endeavorName, name.lowercased().contains(q) { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        searchBar
                        content
                    }
                    .padding(.bottom, 110)
                }
                .refreshable { await store.reload() }

                scanButton
            }
            .satchelBackground()
            .toolbar(.hidden, for: .navigationBar)
            .task(id: noteStore.hasAccess) {
                guard noteStore.hasAccess else { return }
#if targetEnvironment(simulator)
                // The Simulator has no iCloud, so NoteStore points at this app's
                // own empty sandbox. Without this the library is empty forever.
                // Compiled out of device builds entirely.
                SatchelSimulatorSeed.seedIfNeeded(noteStore: noteStore)
#endif
                await endeavorStore.reload()
                await store.reload()
            }
            .sheet(item: $captureSource, onDismiss: { captureNoteLink = nil }) { source in
                SatchelCaptureView(source: source, store: store, prefilledNote: captureNoteLink)
            }
            .navigationDestination(for: SatchelDeepLink.self) { link in
                switch link {
                case .kit:
                    SatchelKitView(result: kit, store: store)
                case .allDocuments:
                    SatchelAllDocumentsView(documents: store.documents, store: store)
                case .document(let relativePath):
                    // Resolved at push time rather than carried in the link — a
                    // URL can arrive before the store has finished loading.
                    if let doc = store.documents.first(where: { $0.relativePath == relativePath }) {
                        SatchelViewerView(document: doc, store: store)
                    } else {
                        missingDocument(relativePath)
                    }
                }
            }
            .onChange(of: router.pendingCapture) { _, source in
                guard let source else { return }
                // Link first, source second: assigning `captureSource` is what
                // presents the sheet, and the sheet reads the link.
                captureNoteLink = router.pendingNoteLink
                captureSource = source
                router.pendingNoteLink = nil
                router.pendingCapture = nil
            }
            .onChange(of: router.pendingSearch) { _, text in
                guard let text else { return }
                query = text
                router.pendingSearch = nil
            }
            .onChange(of: router.pendingDestination) { _, destination in
                guard let destination else { return }
                path.append(destination)
                router.pendingDestination = nil
            }
        }
    }

    /// A `satchel://document?path=…` that points at nothing. Says so rather than
    /// dead-ending on a blank screen — the likeliest cause is a link written
    /// before the file moved or was deleted.
    private func missingDocument(_ relativePath: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.satchelTertiary)
            Text("Document not found")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.satchelInk)
            Text(relativePath)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.satchelSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .satchelBackground()
        .navigationTitle("Not found")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow)
                .font(.system(size: 12.5, weight: .medium))
                .kerning(0.5)
                .foregroundStyle(Color.satchelSecondary)
            Text("Satchel")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Color.satchelInk)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var eyebrow: String {
        if store.isLoading && store.documents.isEmpty { return "LOADING…" }
        let docs = store.documents.count
        let inKit = kit.all.count
        let docWord = docs == 1 ? "DOCUMENT" : "DOCUMENTS"
        if inKit > 0 { return "\(docs) \(docWord) · \(inKit) IN KIT" }
        return "\(docs) \(docWord)"
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.satchelSecondary)
            TextField("Search documents", text: $query)
                .font(.system(size: 13))
                .foregroundStyle(Color.satchelInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if isSearching {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.satchelTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.satchelFill, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 21)
        .padding(.bottom, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isSearching {
            searchSection
        } else if store.documents.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                kitSection
                browseSection
                recentSection
            }
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SatchelSectionTitle(searchResultsTitle)
            if !searchResults.isEmpty {
                DocumentCard(documents: searchResults, store: store)
            }
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 14)
    }

    private var searchResultsTitle: String {
        if searchResults.isEmpty { return "No matches" }
        return searchResults.count == 1 ? "1 result" : "\(searchResults.count) results"
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "bag")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.satchelTertiary)
            Text(noteStore.isLocalMode ? "No documents here yet" : "Nothing in the satchel")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.satchelInk)
            Text(emptyStateDetail)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.satchelSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 42)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyStateDetail: String {
        if noteStore.isLocalMode {
            return "This build has no iCloud, so it is reading a local folder. On device it reads the shared Trace container."
        }
        return "Scan something and it lands here."
    }

    // MARK: Kit

    @ViewBuilder
    private var kitSection: some View {
        if !kit.all.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SatchelSectionTitle(title: "Kit") {
                    if kit.showsSeeAll {
                        NavigationLink {
                            SatchelKitView(result: kit, store: store)
                        } label: {
                            HStack(spacing: 2) {
                                Text("Show all")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.satchelBlue)
                        }
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(kit.grid) { entry in
                        NavigationLink {
                            SatchelViewerView(document: entry.document, store: store)
                        } label: {
                            KitTile(entry: entry)
                        }
                        .buttonStyle(.plain)
                        // The grid is where you actually notice something does
                        // not belong in Kit, so the way out lives here too, not
                        // only two screens away behind a swipe.
                        .contextMenu {
                            if entry.isPinned {
                                Button(role: .destructive) {
                                    try? store.setPinned(false, for: entry.document)
                                } label: {
                                    Label("Remove from Kit", systemImage: "pin.slash")
                                }
                            } else {
                                // Auto-trip membership is computed from the
                                // Endeavor's dates, so there is no pin to
                                // remove. What IS available is making it
                                // permanent, which is the useful action here.
                                Button {
                                    try? store.setPinned(true, for: entry.document)
                                } label: {
                                    Label("Keep in Kit", systemImage: "pin")
                                }
                                Text("Otherwise leaves Kit when \(kit.activeTrip?.name ?? "the trip") ends")
                            }
                        }
                    }
                }

                kitFootnote
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var kitFootnote: some View {
        if let note = KitMembership.footnote(for: kit) {
            HStack(alignment: .top, spacing: 6) {
                if kit.tripCount > 0 {
                    Image(systemName: "airplane")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.satchelAuto)
                        .padding(.top, 2)
                }
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.satchelSecondary)
                    .lineSpacing(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 9)
        }
    }

    // MARK: Browse
    //
    // Browse leads with TYPE, because that is how David retrieves: *kind of thing
    // it is* first, then name, then date, tags last. The row used to lead with
    // Endeavors / Notes / Places / Tags — an arrangement from before the type
    // taxonomy existed, where a document with no tags, no linked note and no
    // Endeavor appeared under nothing at all.
    //
    // FIXED FOOTPRINT, SAME AS KIT. Six chips, two rows, never more, with
    // `All types` as the door to the rest. A horizontal scroller was built first
    // and thrown away: it hid its own contents behind a swipe, and it broke the
    // rule §5 states for Kit — sorting by count meant every chip moved position
    // whenever anything was captured, and a target that moves is worse than one
    // you have to tap twice.
    //
    // The five shown are the most-used types, but they are rendered
    // ALPHABETICALLY within that set. Which five changes slowly; the order among
    // them does not change at all. That is the muscle-memory half of §5's rule
    // without giving up on showing what you actually use.
    //
    // Endeavors take priority in the row when they exist, because "the Japan
    // trip" is the one case where the thing you reach for is not a type. They
    // render indigo so the two kinds of chip stay legible as different questions:
    // what IS it, versus what does it BELONG to.

    private static let browseChipLimit = 6

    @ViewBuilder
    private var browseSection: some View {
        if !typeCounts.isEmpty || !endeavorCounts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SatchelSectionTitle("Browse")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(endeavorCounts.prefix(2), id: \.0) { id, name, count in
                        NavigationLink {
                            SatchelAllDocumentsView(documents: store.documents,
                                                    store: store, endeavorID: id)
                        } label: {
                            SatchelBrowseChip(label: name, count: count, endeavor: true)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(shownTypes, id: \.0) { type, count in
                        NavigationLink {
                            SatchelAllDocumentsView(documents: store.documents,
                                                    store: store, type: type)
                        } label: {
                            SatchelBrowseChip(type: type, count: count)
                        }
                        .buttonStyle(.plain)
                    }

                    if typeCounts.count > shownTypes.count {
                        NavigationLink {
                            SatchelTypeIndexView(documents: store.documents, store: store)
                        } label: {
                            SatchelBrowseChip(label: "All types",
                                              count: typeCounts.count,
                                              showsChevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 14)
        }
    }

    /// The most-used types, capped, then sorted alphabetically so their positions
    /// hold still between captures.
    private var shownTypes: [(DocumentIcon, Int)] {
        let slots = max(0, Self.browseChipLimit
                        - min(endeavorCounts.count, 2)
                        - (typeCounts.count > Self.browseChipLimit ? 1 : 0))
        return typeCounts
            .prefix(slots)
            .sorted { $0.0.label < $1.0.label }
    }

    /// Types that actually have documents, commonest first. An empty drawer is
    /// not worth a chip — it only teaches you the row is unreliable.
    private var typeCounts: [(DocumentIcon, Int)] {
        var counts: [DocumentIcon: Int] = [:]
        for doc in store.documents {
            counts[doc.resolvedIcon, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key.label < $1.key.label : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    private var endeavorCounts: [(String, String, Int)] {
        var counts: [String: (String, Int)] = [:]
        for doc in store.documents {
            guard let id = doc.endeavor else { continue }
            let name = doc.endeavorName ?? "Endeavor"
            counts[id] = (name, (counts[id]?.1 ?? 0) + 1)
        }
        return counts
            .map { ($0.key, $0.value.0, $0.value.1) }
            .sorted { $0.1 < $1.1 }
    }

    // MARK: Recent

    /// Recent shows five. Everything else needs a door, and the Browse chips are
    /// not it: a document with no tags, no linked note and no Endeavor appears
    /// under none of them, so without this it was reachable only by search.
    /// David lost a document exactly this way — unpinning it dropped it out of
    /// Kit, it was not in the newest five, and it vanished from the app.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SatchelSectionTitle(title: "Recent") {
                if store.documents.count > 5 {
                    NavigationLink {
                        SatchelAllDocumentsView(documents: store.documents, store: store)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Show all \(store.documents.count)")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.satchelBlue)
                    }
                }
            }
            DocumentCard(documents: Array(store.documents.prefix(5)), store: store)
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 14)
    }

    // MARK: Scan FAB

    private var scanButton: some View {
        VStack(spacing: 4) {
            Button {
                captureSource = .scan
            } label: {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(
                        LinearGradient(
                            colors: [Color.satchelBlue, Color.satchelBlueDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Circle()
                    )
                    .shadow(color: Color.satchelBlue.opacity(0.45), radius: 9, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            // Long press, not tap: scope §5 keeps the one-tap scan and hides the
            // other three sources behind a hold, so nothing becomes a menu.
            .contextMenu {
                Button {
                    captureSource = .photo
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                Button {
                    captureSource = .library
                } label: {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
                Button {
                    captureSource = .file
                } label: {
                    Label("Import File", systemImage: "folder")
                }
            }

            Text("SCAN")
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.3)
                .foregroundStyle(Color.satchelSecondary)
        }
        .padding(.trailing, 18)
        .padding(.bottom, 10)
    }
}

// MARK: - Document card

/// A white card of document rows with hairline separators. Used by Recent,
/// search results and the browse screen, so the three cannot drift apart.
struct DocumentCard: View {
    let documents: [TraceMacDocument]
    let store: iOSDocumentStore

    @State private var pendingDelete: TraceMacDocument?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(documents.indices, id: \.self) { index in
                // Scope §5: "Viewer — full screen, direct tap from any row."
                // A row tap opens the document itself, never its metadata.
                NavigationLink {
                    SatchelViewerView(document: documents[index], store: store)
                } label: {
                    DocumentRow(document: documents[index])
                }
                .buttonStyle(.plain)
                // Long press, not swipe. These rows sit inside a plain VStack
                // rather than a List, so `.swipeActions` is unavailable, and a
                // context menu is the honest alternative — it also puts the
                // confirmation one step further from a stray thumb than a swipe
                // would, which suits an action that destroys a file.
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDelete = documents[index]
                    } label: {
                        Label("Delete document", systemImage: "trash")
                    }
                }

                if index < documents.count - 1 {
                    Divider()
                        .overlay(Color.satchelHairline)
                        .padding(.leading, 66)
                }
            }
        }
        .satchelCard()
        .confirmationDialog(
            "Delete \(pendingDelete?.title ?? "this document")?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let doc = pendingDelete { delete(doc) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The file and its sidecar are removed from the shared container. This cannot be undone from inside Satchel.")
        }
    }

    private func delete(_ doc: TraceMacDocument) {
        _ = try? store.deleteDocument(doc)
        Task { await store.reload() }
    }
}

// MARK: - Kit tile

struct KitTile: View {
    let entry: KitEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SatchelDocumentMark.kitTile(entry.document)
                .padding(.bottom, 8)
            Text(entry.document.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.satchelInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Color.satchelSecondary)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .satchelTile()
        .overlay(alignment: .topTrailing) { marker }
    }

    /// Orange pushpin for a manual pin, indigo plane for an active-trip
    /// document. Two kinds of Kit member, two markers — scope §5.
    private var marker: some View {
        Image(systemName: entry.isPinned ? "pin.fill" : "airplane")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(entry.isPinned ? Color.satchelPin : Color.satchelAuto)
            .padding(.top, 10)
            .padding(.trailing, 11)
    }

    private var subtitle: String {
        let kind = kindLabel(for: entry.document)
        if case .activeTrip(let name) = entry.kind { return "\(kind) · \(name)" }
        if let first = entry.document.tags.first { return "\(kind) · \(first)" }
        return kind
    }
}

// MARK: - Document row

struct DocumentRow: View {
    let document: TraceMacDocument

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SatchelDocumentMark.row(document)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.satchelInk)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    SatchelChip(filing: SatchelFiling.of(document))
                    Text(kindLabel(for: document))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.satchelSecondary)
                }
            }
            Spacer(minLength: 6)
            Text(relativeDateLabel(document.created))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.satchelTertiary)
                .padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Shared row helpers

func kindLabel(for document: TraceMacDocument) -> String {
    if document.isPDF { return "PDF" }
    if document.isImage { return "Image" }
    return document.fileExtension.uppercased()
}

func relativeDateLabel(_ date: Date?) -> String {
    guard let date else { return "" }
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    let fmt = DateFormatter()
    let sameYear = cal.isDate(date, equalTo: Date(), toGranularity: .year)
    fmt.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
    return fmt.string(from: date)
}

// MARK: - Browse chip

/// One Browse entry. A type chip carries its own mark and tint, so the row reads
/// as the same visual system as the tiles and rows it filters to. An Endeavor
/// chip is indigo, matching the auto-Kit marker, so the two kinds of chip are
/// answering visibly different questions.
struct SatchelBrowseChip: View {
    var type: DocumentIcon? = nil
    var label: String = ""
    let count: Int
    var endeavor: Bool = false
    /// The "All types" chip — swaps the mark for a grid glyph and adds a chevron,
    /// so the door to the full list does not look like just another type.
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if let type {
                SatchelDocumentMark(icon: type, tint: type.defaultTint,
                                    size: 26, cornerRadius: 8, glyphSize: 14)
            } else {
                Image(systemName: showsChevron ? "square.grid.2x2" : "briefcase.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(showsChevron ? Color.satchelSecondary : Color.satchelAuto)
                    .frame(width: 26, height: 26)
                    .background(showsChevron ? Color.satchelFill : DocumentTint.indigo.background,
                                in: RoundedRectangle(cornerRadius: 8))
            }

            Text(type?.label ?? label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(endeavor ? Color.satchelAuto : Color.satchelInk)
                .lineLimit(1)

            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.satchelTertiary)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.satchelTertiary)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 13)
        .padding(.vertical, 7)
        .satchelTile(cornerRadius: 12)
    }
}

// MARK: - Note picker
//
// Files a document against a note by writing `linked_note` into the sidecar.
//
// WHY THE SIDECAR OWNS THIS LINK. Trace currently writes a `📎 [title](path)`
// line into the note itself, which is a copy that goes stale the moment the
// document is renamed or moved. Scope §D4 settled the same argument for the
// Endeavor: the sidecar is the single source of truth and Notion holds no
// document references. A note-to-document link has the identical failure mode,
// so it lives here too, and Trace can render a chip for every document whose
// `linked_note` matches the note it is showing.
//
// This is the prerequisite for scope §7 — Trace cannot retire its Add Document
// flow until Satchel can create the link that flow currently creates.

struct SatchelNotePickerView: View {
    @Binding var linkedNote: String?
    @Environment(\.dismiss) private var dismiss

    @State private var noteStore = NoteStore.shared
    @State private var query = ""

    /// The note folders worth filing a document against. `Notes/Inbox` is
    /// deliberately absent — it is a staging area, and filing a permanent
    /// document to a place things are meant to leave is a trap.
    private static let folders = ["Projects", "Places", "People", "Horizons"]

    private var groups: [(String, [String])] {
        Self.folders.compactMap { folder in
            let names = ((try? noteStore.listFiles(in: "Notes/\(folder)")) ?? [])
                .filter { $0.hasSuffix(".md") }
                .map { ($0 as NSString).deletingPathExtension }
                .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                .sorted()
            return names.isEmpty ? nil : (folder, names)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    clearRow

                    ForEach(groups, id: \.0) { folder, names in
                        VStack(alignment: .leading, spacing: 0) {
                            SatchelSectionTitle(folder)
                            VStack(spacing: 0) {
                                ForEach(Array(names.indices), id: \.self) { index in
                                    noteRow(folder: folder, name: names[index],
                                            isLast: index == names.count - 1)
                                }
                            }
                            .satchelCard()
                        }
                        .padding(.horizontal, 15)
                        .padding(.bottom, 16)
                    }

                    if groups.isEmpty {
                        Text(query.isEmpty ? "No notes yet." : "No notes match.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.satchelSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 50)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
            .satchelBackground()
            .searchable(text: $query, prompt: "Search notes")
            .navigationTitle("File to a note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var clearRow: some View {
        Button {
            linkedNote = nil
            dismiss()
        } label: {
            HStack {
                Text("No note")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.satchelInk)
                Spacer()
                if linkedNote == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.satchelBlue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .satchelCard()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 15)
        .padding(.bottom, 18)
    }

    private func noteRow(folder: String, name: String, isLast: Bool) -> some View {
        let path = "Notes/\(folder)/\(name).md"
        return VStack(spacing: 0) {
            Button {
                linkedNote = path
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "note.text")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.satchelBlue)
                        .frame(width: 24)
                    Text(name)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.satchelInk)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if linkedNote == path {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.satchelBlue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider().overlay(Color.satchelHairline).padding(.leading, 50)
            }
        }
    }
}

/// Display name for a `linked_note` path. Shared so the capture form, the detail
/// screen and the filing chip render it identically rather than each stripping
/// the path their own way.
///
///   Notes/Projects/Home Bills.md   →  Home Bills
///   Notes/Journal/2026-07-26.md    →  Journal · Jul 26
///
/// The second case is why this exists. A journal note is named by its date, so
/// the naive version rendered a bare `2026-07-26` in the Filed-to chip, which
/// reads as a stray timestamp rather than as "the note for that day".
func noteDisplayName(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let base = (path.components(separatedBy: "/").last ?? path)
        .replacingOccurrences(of: ".md", with: "")

    let iso = DateFormatter()
    iso.locale = Locale(identifier: "en_US_POSIX")
    iso.dateFormat = "yyyy-MM-dd"
    if let date = iso.date(from: base) {
        let pretty = DateFormatter()
        pretty.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "MMM d" : "MMM d, yyyy"
        return "Journal · \(pretty.string(from: date))"
    }
    return base
}

// MARK: - Type index
//
// The door behind `All types`. Every type in use, alphabetical, with counts.
// Alphabetical rather than by count on purpose: this is the screen you come to
// when the chip you wanted was not on the Library, so it is scanned by name.

struct SatchelTypeIndexView: View {
    let documents: [TraceMacDocument]
    let store: iOSDocumentStore

    private var types: [(DocumentIcon, Int)] {
        var counts: [DocumentIcon: Int] = [:]
        for doc in documents { counts[doc.resolvedIcon, default: 0] += 1 }
        return counts.sorted { $0.key.label < $1.key.label }.map { ($0.key, $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(types.indices), id: \.self) { index in
                    NavigationLink {
                        SatchelAllDocumentsView(documents: documents, store: store,
                                                type: types[index].0)
                    } label: {
                        HStack(spacing: 12) {
                            SatchelDocumentMark(icon: types[index].0,
                                                tint: types[index].0.defaultTint,
                                                size: 34, cornerRadius: 10, glyphSize: 17)
                            Text(types[index].0.label)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Color.satchelInk)
                            Spacer(minLength: 8)
                            Text("\(types[index].1)")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.satchelSecondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.satchelTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < types.count - 1 {
                        Divider().overlay(Color.satchelHairline).padding(.leading, 62)
                    }
                }
            }
            .satchelCard()
            .padding(.horizontal, 15)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .satchelBackground()
        .navigationTitle("All types")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Full Kit
//
// Build step 7. Frame 2 of the mockup: two labelled groups, rows rather than
// tiles, Edit for reorder and unpin, and a note on the trip group stating it
// clears when the trip ends and the documents stay in the Endeavor.
//
// Reorder applies to the PINNED group only, and that is not an omission. Trip
// membership is computed from the Endeavor's date range at render time (scope
// §5), sorted by imminence — it is not a list David owns, so there is nothing
// there to drag. Making it draggable would imply a persistence that must not
// exist, since auto membership writes nothing to any sidecar.
//
// Built on `List` rather than the card-and-VStack the other screens use,
// because `.onMove` and `EditButton` are List behaviours and reimplementing
// drag-to-reorder by hand to preserve a rounded card would be a bad trade.
// `.listRowBackground` plus `.insetGrouped` gets close to the mockup's card.

struct SatchelKitView: View {
    let result: KitMembership.Layout
    let store: iOSDocumentStore

    /// Local working copies so a drag animates immediately; the store is written
    /// once the move settles, not on every frame of it.
    @State private var pinned: [KitEntry] = []
    @State private var tripEntries: [KitEntry] = []
    @State private var tripSlots: Int = SatchelKitPreferences.defaultTripSlots
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            if !pinned.isEmpty { pinnedSection }
            if !tripEntries.isEmpty { tripSection }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .satchelListBackground()
        .navigationTitle("Kit")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Edit") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .font(.system(size: 15, weight: .semibold))
            }
        }
        .onAppear { syncFromStore() }
        .onChange(of: result.all) { _, _ in
            // Do not stomp a drag in progress with a store refresh.
            guard !editMode.isEditing else { return }
            syncFromStore()
        }
    }

    // MARK: Pinned

    private var pinnedSection: some View {
        Section {
            ForEach(pinned) { entry in
                row(entry)
                    .swipeActions(edge: .trailing) {
                        Button {
                            unpin(entry)
                        } label: {
                            Label("Remove from Kit", systemImage: "pin.slash")
                        }
                        .tint(Color.satchelPin)
                    }
            }
            .onMove { source, destination in
                pinned.move(fromOffsets: source, toOffset: destination)
                _ = try? store.reorderKitGroup(pinned.map { $0.document })
            }
        } header: {
            sectionHeader("Pinned")
        } footer: {
            Text(pinnedFooter)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.satchelSecondary)
        }
    }

    private var pinnedFooter: String {
        let shown = max(0, KitMembership.gridCapacity - min(tripSlots, tripEntries.count))
        guard !pinned.isEmpty else { return "" }
        let count = min(shown, pinned.count)
        return "Drag to reorder. The top \(count) show on the Library."
    }

    // MARK: Active trip

    private var tripSection: some View {
        Section {
            ForEach(tripEntries) { entry in
                row(entry)
                    .swipeActions(edge: .trailing) {
                        Button {
                            keep(entry)
                        } label: {
                            Label("Keep in Kit", systemImage: "pin")
                        }
                        .tint(Color.satchelPin)
                    }
            }
            // Trip documents are now reorderable too. They were not, on the
            // reasoning that computed membership is not a list you own. That
            // was right about MEMBERSHIP and wrong about ORDER: which two of six
            // reach the grid is a judgement only David can make, and the sort it
            // was falling back on cannot express imminence anyway.
            .onMove { source, destination in
                tripEntries.move(fromOffsets: source, toOffset: destination)
                _ = try? store.reorderKitGroup(tripEntries.map { $0.document })
            }

            slotStepper
        } header: {
            sectionHeader(result.activeTrip?.name ?? "Active trip")
        } footer: {
            Text(tripFooter)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.satchelSecondary)
        }
    }

    /// The grid never grows past four tiles (§5). This moves the split inside
    /// those four rather than adding to them, so the glance stays a glance.
    private var slotStepper: some View {
        Stepper(value: $tripSlots, in: SatchelKitPreferences.range) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.satchelAuto)
                Text(slotLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.satchelInk)
            }
        }
        .listRowBackground(Color.satchelCard)
        .onChange(of: tripSlots) { _, value in
            guard let id = result.activeTrip?.id else { return }
            SatchelKitPreferences.setTripSlots(value, for: id)
        }
    }

    private var slotLabel: String {
        switch tripSlots {
        case 0:  return "No Library slots"
        case 1:  return "1 of 4 Library slots"
        default: return "\(tripSlots) of 4 Library slots"
        }
    }

    private var tripFooter: String {
        let name = result.activeTrip?.name ?? "the trip"
        var text = "Drag to choose which reach the Library grid. "
        if tripSlots == 0 {
            text += "Currently none do, so all four go to your pins. "
        }
        text += "Clears on its own when \(name) ends; the documents stay in the Endeavor."
        return text
    }

    // MARK: Pieces

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(Color.satchelSecondary)
    }

    private func row(_ entry: KitEntry) -> some View {
        NavigationLink {
            SatchelViewerView(document: entry.document, store: store)
        } label: {
            KitRow(entry: entry)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowBackground(Color.satchelCard)
    }

    // MARK: Mutations

    private func syncFromStore() {
        pinned = result.all.filter { $0.isPinned }
        tripEntries = result.all.filter { !$0.isPinned }
        tripSlots = SatchelKitPreferences.tripSlots(for: result.activeTrip?.id)
    }

    /// Removes a document from Kit. It stays in the library, in its folder,
    /// with everything else untouched — only the pin goes.
    private func unpin(_ entry: KitEntry) {
        withAnimation { pinned.removeAll { $0.id == entry.id } }
        try? store.setPinned(false, for: entry.document)
        _ = try? store.reorderKitGroup(pinned.map { $0.document })
    }

    /// Promotes a trip document to a permanent pin, so it survives the trip.
    private func keep(_ entry: KitEntry) {
        withAnimation { tripEntries.removeAll { $0.id == entry.id } }
        try? store.setPinned(true, for: entry.document)
    }
}

struct KitRow: View {
    let entry: KitEntry

    var body: some View {
        HStack(spacing: 12) {
            SatchelDocumentMark.compactRow(entry.document)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.document.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.satchelInk)
                    .lineLimit(1)
                Text(kindLabel(for: entry.document))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.satchelSecondary)
            }
            Spacer(minLength: 6)
            Image(systemName: entry.isPinned ? "pin.fill" : "airplane")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.isPinned ? Color.satchelPin : Color.satchelAuto)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Document detail
//
// Build step 10, first half: the metadata editor. Frame 8.
//
// Editable: title, description, tags, icon, tint, Endeavor, Kit pin. NOT the
// filename — that is the real file on disk with a sidecar pathed to match it,
// so renaming means moving two files and rewriting the link between them, for
// no gain the title does not already deliver everywhere it is displayed.
//
// FOLDER IS NOT A FILING CONTROL. It sits under FILE with the other facts about
// the bytes. Folders were retired as an organising axis 2026-07-28 (scope §6b
// and `Capture-Routing.md`) because they mixed three concepts — types
// (Receipts), Endeavors (Trip, Project) and workflow states (Inbox, Archive).
// Frame 8's "Move to another folder" is deliberately NOT built: it would put
// back the axis we just removed. Type answers what it is, Endeavor answers what
// it belongs to.
//
// STILL TO COME (step 10, second half): the user note and the on-demand AI
// summary, both in the sidecar BODY. `renderSidecar` must be taught to preserve
// the body FIRST — it currently rebuilds the file from frontmatter alone and
// would erase any note on the next save.

struct SatchelDocumentDetailView: View {
    let document: TraceMacDocument
    var store: iOSDocumentStore? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var noteStore = NoteStore.shared
    @State private var endeavorStore = SatchelEndeavorStore()

    @State private var title = ""
    @State private var descriptionText = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var icon: DocumentIcon = .document
    @State private var tint: DocumentTint = .gray
    @State private var endeavorID: String?
    @State private var endeavorName: String?
    @State private var linkedNote: String?
    @State private var showNotePicker = false
    @State private var pinned = false

    @State private var loaded = false
    @State private var dirty = false
    @State private var showIconPicker = false
    @State private var confirmingDelete = false
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var note = ""
    @State private var isSummarising = false
    @State private var summaryError: String?

    /// The live copy from the store, so a re-scan or a pin toggle is reflected
    /// without popping the screen.
    private var current: TraceMacDocument {
        store?.documents.first { $0.relativePath == document.relativePath } ?? document
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                rescanButton
                field("Title") {
                    TextField("Title", text: $title)
                        .font(.system(size: 14))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .satchelCard()
                        .onChange(of: title) { _, _ in dirty = true }
                }
                field("Description") {
                    TextEditor(text: $descriptionText)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(height: 92)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .satchelCard()
                        .onChange(of: descriptionText) { _, _ in dirty = true }
                }
                tagField
                noteField
                summaryField
                filedToField
                fileFacts
                deleteButton
            }
            .padding(.bottom, 34)
        }
        .satchelBackground()
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { save(); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showIconPicker) {
            SatchelIconPickerView(icon: $icon, tint: $tint)
        }
        .sheet(isPresented: $showNotePicker) {
            SatchelNotePickerView(linkedNote: $linkedNote)
        }
        .onChange(of: linkedNote) { _, _ in dirty = true }
        .onChange(of: icon) { _, _ in dirty = true }
        .onChange(of: tint) { _, _ in dirty = true }
        .task {
            await endeavorStore.reload()
            guard !loaded else { return }
            loadFromDocument()
            loaded = true
        }
        // Saves on the way out as well as on Done, so backing out with the
        // navigation chevron cannot silently discard an edit.
        .onDisappear { if dirty { save() } }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            Button {
                showIconPicker = true
            } label: {
                SatchelDocumentMark(icon: icon, tint: tint, size: 52, cornerRadius: 14, glyphSize: 24)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.satchelBlue, Color.satchelCard)
                            .offset(x: 4, y: 4)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(icon.label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.satchelInk)
                Text("\(kindLabel(for: current)) · \(relativeDateLabel(current.created)) · tap to change")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.satchelSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 21)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    // MARK: Tags

    private var tagField: some View {
        field("Tags") {
            VStack(alignment: .leading, spacing: 9) {
                if !tags.isEmpty {
                    SatchelFlowLayout {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                tags.removeAll { $0 == tag }
                                dirty = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(tag)
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.420, green: 0.420, blue: 0.439))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Color.satchelFill, in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a tag", text: $newTag)
                        .font(.system(size: 12.5))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { addTag() }
                    if !newTag.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add") { addTag() }
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .satchelCard()
        }
    }

    private func addTag() {
        let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !tags.contains(value) else { newTag = ""; return }
        tags.append(value)
        newTag = ""
        dirty = true
    }

    // MARK: Note

    /// David's own note. Lives in the sidecar BODY under `## Note`, and is never
    /// touched by anything AI — sharing a field with the summary would mean
    /// re-summarising deletes what he wrote.
    private var noteField: some View {
        field("Note") {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $note)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 104)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .onChange(of: note) { _, _ in dirty = true }

                if note.isEmpty {
                    Text("Anything you want to remember about this document.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.satchelTertiary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
            .satchelCard()
        }
    }

    // MARK: Summary

    /// The on-demand AI summary, in the body under `## Summary`. Separate from
    /// `description`, which stays the short capture-time line the list rows use —
    /// a three-paragraph summary in that field would wreck every row in the app.
    private var summaryField: some View {
        field("Summary") {
            VStack(alignment: .leading, spacing: 0) {
                if !current.summary.isEmpty {
                    Text(current.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.227, green: 0.227, blue: 0.235))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 13)
                        .padding(.bottom, 4)
                }

                Button {
                    guard let store else { return }
                    Task { await summarise(using: store) }
                } label: {
                    HStack(spacing: 7) {
                        if isSummarising {
                            ProgressView().controlSize(.small)
                            Text("Reading the whole document…")
                        } else {
                            Image(systemName: "text.append")
                                .font(.system(size: 12, weight: .semibold))
                            Text(current.summary.isEmpty ? "Summarise this document" : "Summarise again")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSummarising ? Color.satchelSecondary : Color.satchelAI)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSummarising || store == nil)

                if let summaryError {
                    Text(summaryError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 0.843, green: 0.0, blue: 0.082))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 11)
                }
            }
            .satchelCard()
        }
    }

    /// Reads far deeper than the capture scan — 12 pages rather than 4 — and
    /// only ever runs on a press. Saves in-flight edits first so nothing typed
    /// is lost behind the call.
    private func summarise(using store: iOSDocumentStore) async {
        isSummarising = true
        summaryError = nil
        defer { isSummarising = false }

        save()
        do {
            let text = try await iOSDocumentScanService.summarize(
                doc: current, noteStore: noteStore
            )
            _ = try store.setSummary(text, for: current)
            await store.reload()
        } catch {
            summaryError = error.localizedDescription
        }
    }

    // MARK: Filed to

    private var filedToField: some View {
        field("Filed to") {
            VStack(spacing: 0) {
                Menu {
                    Button("None") { endeavorID = nil; endeavorName = nil; dirty = true }
                    ForEach(endeavorStore.endeavors) { endeavor in
                        Button(endeavor.name) {
                            endeavorID = endeavor.id
                            endeavorName = endeavor.name
                            dirty = true
                        }
                    }
                } label: {
                    HStack {
                        Text("Endeavor")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.satchelInk)
                        Spacer(minLength: 10)
                        Text(endeavorName ?? "None")
                            .font(.system(size: 13))
                            .foregroundStyle(endeavorName != nil ? Color.satchelAuto : Color.satchelSecondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.satchelTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }

                Divider().overlay(Color.satchelHairline).padding(.leading, 14)

                Button {
                    showNotePicker = true
                } label: {
                    HStack {
                        Text("Note")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.satchelInk)
                        Spacer(minLength: 10)
                        Text(noteDisplayName(linkedNote) ?? "None")
                            .font(.system(size: 13))
                            .foregroundStyle(linkedNote != nil ? Color.satchelBlue : Color.satchelSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.satchelTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().overlay(Color.satchelHairline).padding(.leading, 14)

                Toggle(isOn: $pinned) {
                    Text("Pin to Kit")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.satchelInk)
                }
                .tint(Color.satchelPin)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .onChange(of: pinned) { _, _ in dirty = true }
            }
            .satchelCard()
        }
    }

    // MARK: File facts

    /// Everything here is about the bytes, not about how the document is filed.
    /// Folder lives here on purpose — see this file's header.
    private var fileFacts: some View {
        field("File") {
            VStack(spacing: 0) {
                factRow("Kind", kindLabel(for: current))
                factRow("Size", fileSize)
                factRow("Added", relativeDateLabel(current.created))
                factRow("Folder", current.category)
                factRow("Name", current.filename, isLast: true)
            }
            .satchelCard()
        }
    }

    private var fileSize: String {
        guard let url = noteStore.resolvedURL(for: current.relativePath),
              let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
        else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func factRow(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.satchelInk)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.satchelSecondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if !isLast {
                Divider().overlay(Color.satchelHairline).padding(.leading, 14)
            }
        }
    }

    // MARK: Ask AI

    @ViewBuilder
    private var rescanButton: some View {
        if let store {
            VStack(spacing: 6) {
                Button {
                    Task { await rescan(using: store) }
                } label: {
                    HStack(spacing: 7) {
                        if isScanning {
                            ProgressView().controlSize(.small)
                            Text("Reading the document…")
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                            Text("Ask AI to describe this")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isScanning ? Color.satchelSecondary : Color.satchelAI)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .satchelCard()
                }
                .buttonStyle(.plain)
                .disabled(isScanning)

                if let scanError {
                    Text(scanError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 0.843, green: 0.0, blue: 0.082))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 21)
            .padding(.bottom, 16)
        }
    }

    /// Writes straight through rather than into the fields, then reloads them —
    /// a re-scan is a decision to replace, and leaving the result sitting in
    /// unsaved state would mean it silently vanished if the screen was dismissed.
    private func rescan(using store: iOSDocumentStore) async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }

        save()          // don't lose in-flight edits behind the scan
        let doc = current
        let existing = Array(Set(store.documents.flatMap { $0.tags })).sorted()
        do {
            let result = try await iOSDocumentScanService.scan(
                doc: doc,
                noteStore: noteStore,
                existingTags: existing,
                filenameIsGenerated: doc.title.isEmpty
                    || doc.title.lowercased().hasPrefix("scan")
                    || doc.title.lowercased().hasPrefix("photo")
            )
            try store.saveSidecar(
                for: doc,
                title: result.title ?? doc.title,
                tags: result.tags.isEmpty ? doc.tags : result.tags,
                linkedNote: doc.linkedNote,
                people: doc.people,
                description: result.description.isEmpty ? doc.description : result.description,
                date: doc.created,
                icon: result.icon,
                tint: result.tint ?? result.icon?.defaultTint
            )
            await store.reload()
            loadFromDocument()
            dirty = false
        } catch {
            scanError = error.localizedDescription
        }
    }

    // MARK: Delete

    @ViewBuilder
    private var deleteButton: some View {
        if let store {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text("Delete document")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.843, green: 0.0, blue: 0.082))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .satchelCard()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 21)
            .padding(.top, 6)
            .confirmationDialog("Delete \(current.title)?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    dirty = false      // nothing to save into a file being removed
                    _ = try? store.deleteDocument(current)
                    Task { await store.reload() }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The file and its sidecar are removed from the shared container. This cannot be undone from inside Satchel.")
            }
        }
    }

    // MARK: Field wrapper

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11.5, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(Color.satchelSecondary)
                .padding(.horizontal, 6)
            content()
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 16)
    }

    // MARK: Load / save

    private func loadFromDocument() {
        let doc = current
        title = doc.title
        descriptionText = doc.description
        tags = doc.tags
        icon = doc.resolvedIcon
        tint = doc.resolvedTint
        endeavorID = doc.endeavor
        endeavorName = doc.endeavorName
        pinned = doc.pinned
        note = doc.note
        linkedNote = doc.linkedNote
    }

    private func save() {
        guard let store, dirty else { return }
        let doc = current
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        try? store.saveSidecar(
            for: doc,
            title: trimmed.isEmpty ? doc.title : trimmed,
            tags: tags,
            linkedNote: linkedNote,
            people: doc.people,
            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            date: doc.created,
            endeavor: endeavorID ?? "",
            endeavorName: endeavorName ?? "",
            pinned: pinned,
            icon: icon,
            tint: tint,
            // Same rule as `setPinned`: a document that was ALREADY pinned keeps
            // its position, a newly pinned one appends. `doc.kitOrder ?? next`
            // was wrong — it let a document that had been unpinned and re-pinned
            // silently reclaim its old slot, which is the one thing §5's "user
            // order" is supposed to make impossible without a drag.
            kitOrder: pinned ? (doc.pinned ? doc.kitOrder : nextKitOrder(in: store)) : nil,
            // The note is passed explicitly; the summary is left nil so it is
            // preserved. The two never write over each other — that separation
            // is the whole reason they are different sections.
            note: note
        )
        dirty = false
        Task { await store.reload() }
    }

    private func nextKitOrder(in store: iOSDocumentStore) -> Int {
        (store.documents.filter { $0.pinned }.compactMap { $0.kitOrder }.max() ?? -1) + 1
    }
}

// MARK: - All documents
//
// The full library, with the sort and filter Recent cannot offer. Reached from
// "Show all" in the Recent header.
//
// Sort and filter are held in view state rather than persisted: they are a way
// of looking at the list right now, not a preference about it. If a particular
// arrangement turns out to be the one David always wants, that is an argument
// for changing the DEFAULT, not for remembering the last thing he tapped.

struct SatchelAllDocumentsView: View {

    let documents: [TraceMacDocument]
    let store: iOSDocumentStore

    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest, title, folder
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: return "Newest first"
            case .oldest: return "Oldest first"
            case .title:  return "Title A–Z"
            case .folder: return "Folder"
            }
        }
        var symbol: String {
            switch self {
            case .newest: return "arrow.down"
            case .oldest: return "arrow.up"
            case .title:  return "textformat.abc"
            case .folder: return "folder"
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case all, pdf, image
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:   return "Any kind"
            case .pdf:   return "PDFs"
            case .image: return "Images"
            }
        }
    }

    @State private var sort: Sort = .newest
    @State private var kind: Kind = .all
    @State private var type: DocumentIcon? = nil
    @State private var endeavorID: String? = nil
    @State private var folder: String? = nil
    @State private var tag: String? = nil
    @State private var kitOnly = false
    @State private var query = ""

    /// Browse chips land here pre-filtered rather than opening a screen of their
    /// own. One browsing surface, entered from different angles — a separate
    /// per-facet screen would drift out of step with this one's sorting and
    /// filtering the first time either changed.
    init(documents: [TraceMacDocument],
         store: iOSDocumentStore,
         type: DocumentIcon? = nil,
         endeavorID: String? = nil) {
        self.documents = documents
        self.store = store
        _type = State(initialValue: type)
        _endeavorID = State(initialValue: endeavorID)
    }

    /// Only types present in the library. Offering all 23 as filters when six are
    /// in use makes the menu a wall of dead ends.
    private var availableTypes: [DocumentIcon] {
        Array(Set(documents.map { $0.resolvedIcon }))
            .sorted { $0.label < $1.label }
    }

    private var folders: [String] {
        Array(Set(documents.map { $0.category })).sorted()
    }

    private var tags: [String] {
        Array(Set(documents.flatMap { $0.tags })).sorted()
    }

    private var filtered: [TraceMacDocument] {
        var out = documents

        if let type { out = out.filter { $0.resolvedIcon == type } }
        if let endeavorID { out = out.filter { $0.endeavor == endeavorID } }
        if let folder { out = out.filter { $0.category == folder } }
        if let tag { out = out.filter { $0.tags.contains(tag) } }
        if kitOnly { out = out.filter { $0.pinned } }
        switch kind {
        case .all:   break
        case .pdf:   out = out.filter { $0.isPDF }
        case .image: out = out.filter { $0.isImage }
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            out = out.filter {
                $0.title.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
            }
        }

        switch sort {
        case .newest:
            out.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        case .oldest:
            out.sort { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        case .title:
            out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .folder:
            out.sort {
                $0.category == $1.category
                    ? ($0.created ?? .distantPast) > ($1.created ?? .distantPast)
                    : $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
            }
        }
        return out
    }

    private var isFiltered: Bool {
        type != nil || endeavorID != nil || folder != nil || tag != nil || kitOnly || kind != .all
    }

    private var endeavorLabel: String? {
        guard let endeavorID else { return nil }
        return documents.first { $0.endeavor == endeavorID }?.endeavorName ?? "Endeavor"
    }

    /// Named after what you asked for, not "17 of 42". Arriving from a Receipts
    /// chip should say Receipts.
    private var screenTitle: String {
        if let type { return "\(type.label) · \(filtered.count)" }
        if let endeavorLabel { return "\(endeavorLabel) · \(filtered.count)" }
        if filtered.count == documents.count { return "\(documents.count) documents" }
        return "\(filtered.count) of \(documents.count)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isFiltered { activeFilters }
                if filtered.isEmpty {
                    Text(query.isEmpty ? "Nothing matches those filters." : "No matches.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.satchelSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    DocumentCard(documents: filtered, store: store)
                        .padding(.horizontal, 15)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .satchelBackground()
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search documents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { option in
                            Label(option.label, systemImage: option.symbol).tag(option)
                        }
                    }

                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }

                    Menu("Type") {
                        Button("Any type") { type = nil }
                        ForEach(availableTypes, id: \.self) { candidate in
                            Button {
                                type = (type == candidate) ? nil : candidate
                            } label: {
                                if type == candidate {
                                    Label(candidate.label, systemImage: "checkmark")
                                } else {
                                    Text(candidate.label)
                                }
                            }
                        }
                    }

                    Menu("Folder") {
                        Button("Any folder") { folder = nil }
                        ForEach(folders, id: \.self) { name in
                            Button {
                                folder = (folder == name) ? nil : name
                            } label: {
                                if folder == name {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    }

                    if !tags.isEmpty {
                        Menu("Tag") {
                            Button("Any tag") { tag = nil }
                            ForEach(tags, id: \.self) { name in
                                Button {
                                    tag = (tag == name) ? nil : name
                                } label: {
                                    if tag == name {
                                        Label(name, systemImage: "checkmark")
                                    } else {
                                        Text(name)
                                    }
                                }
                            }
                        }
                    }

                    Toggle("In Kit only", isOn: $kitOnly)

                    if isFiltered {
                        Divider()
                        Button(role: .destructive) { clearFilters() } label: {
                            Label("Clear filters", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: isFiltered
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    /// Active filters are shown as removable chips, not just as a filled toolbar
    /// icon. A filter you cannot see is a filter you forget you set, and then the
    /// library looks like it has lost documents.
    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                if let type { filterChip(type.label, systemImage: type.sfSymbol) { self.type = nil } }
                if let endeavorLabel { filterChip(endeavorLabel, systemImage: "briefcase") { self.endeavorID = nil } }
                if let folder { filterChip(folder, systemImage: "folder") { self.folder = nil } }
                if let tag { filterChip(tag, systemImage: "tag") { self.tag = nil } }
                if kitOnly { filterChip("In Kit", systemImage: "pin.fill") { kitOnly = false } }
                if kind != .all { filterChip(kind.label, systemImage: "doc") { kind = .all } }
                Button("Clear") { clearFilters() }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.satchelBlue)
            }
            .padding(.horizontal, 21)
        }
        .padding(.bottom, 12)
    }

    private func filterChip(_ text: String, systemImage: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                Text(text).font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.satchelAuto)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(DocumentTint.indigo.background, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func clearFilters() {
        type = nil; endeavorID = nil; folder = nil; tag = nil; kitOnly = false; kind = .all
    }
}

// MARK: - Capture source
//
// Which of the four paths the FAB asked for. Tap is always scan; the other
// three sit behind a long press (scope §5). `SatchelCaptureView` reads this to
// decide which picker to open. The step-9 placeholder sheet that used to live
// here is gone, replaced by the real flow.

enum SatchelCaptureSource: String, Identifiable {
    case scan, photo, library, file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan:    return "Scan Document"
        case .photo:   return "Take Photo"
        case .library: return "Choose from Library"
        case .file:    return "Import File"
        }
    }

    var symbol: String {
        switch self {
        case .scan:    return "doc.viewfinder"
        case .photo:   return "camera"
        case .library: return "photo.on.rectangle"
        case .file:    return "folder"
        }
    }

}
