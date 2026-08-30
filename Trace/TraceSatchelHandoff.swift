// TraceSatchelHandoff.swift
// Trace
//
// The Trace half of the `satchel://…?note=` hand-off. Scope doc §7b; the
// Satchel half was built in Session 50 and this is the other end of it.
//
// WHY IT EXISTS. Satchel is the documents app now. A document captured while
// David is looking at a Place or Person note should already know which note it
// belongs to — otherwise he pays a trip through Satchel's note picker to
// re-find the note he was reading a second earlier. All four Satchel capture
// routes accept `?note=<container-relative path>` for exactly this.
//
// WHAT TRACE DOES AND DOES NOT DO. Trace hands across INTENT, never data. It
// opens a URL naming a capture source and a note path, and stops there. Satchel
// writes the sidecar, owns `linked_note`, and decides title, type, tint and
// everything else about the document. That is the property which keeps scope §7
// clean when Trace's own document handling is finally retired: Trace must not
// become a second writer again. Nothing in this file touches a document store,
// and it must stay that way.
//
// SHARED BY TRACE AND DAYFLOW as of 2026-07-28 (E-CHIP). It began as a
// Trace-only file, on the reasoning that Dayflow should not get the button until
// it could also render the chips. Once that became the next piece of work the
// duplication stopped being justified: nothing in here is Trace-specific — it
// needs `NoteStore`, `IOSDocumentStore`, `TraceDocumentModels` and SwiftUI, and
// Dayflow now has all four.
//
// The alternative, a `DayflowSatchelHandoff.swift` copy, was rejected. Two files
// with the same behaviour drift, and the thing they would drift on is the exact
// spelling of a `linked_note` path — the one value where a near-miss produces a
// chip that silently never appears.
//
// It lives in `Trace/` and is opted into Dayflow through that target's exception
// set on the `Trace` group, the same mechanism `NoteStore` and `MarkdownEditorView`
// already use. **Satchel is deliberately NOT a member** — it has its own capture
// source enum and plainly never needs to hand off to itself.
//
// The name keeps its `Trace` prefix because the vault mirror is a flat folder in
// which a `Satchel`-prefixed filename reads as one of Satchel's own sources.
// `NoteStore.swift` sits in `Trace/` and is shared with three targets on exactly
// the same footing.

import SwiftUI

// MARK: - Capture routes

/// The four `satchel://` capture hosts.
///
/// Deliberately a SEPARATE declaration from Satchel's own `SatchelCaptureSource`
/// rather than one shared file ticked into both targets. The URL scheme is the
/// contract between the two apps and it is a public one — anything on the phone
/// can send it. Sharing the type would quietly turn a rename inside Satchel into
/// a breaking change here. Keeping them apart means the only thing that has to
/// hold still is the four strings below, which is the promise a URL scheme makes
/// anyway.
enum SatchelCaptureRoute: String, CaseIterable, Identifiable {

    case scan, photo, library, file

    var id: String { rawValue }

    /// The URL host. `file` is the single case where the case name and the route
    /// name differ: Satchel's own enum calls it `file`, the scheme calls it
    /// `import`. Do not "tidy" this by renaming the case — `import` is a Swift
    /// keyword and would need backticks at every use site.
    var host: String {
        switch self {
        case .scan:    return "scan"
        case .photo:   return "photo"
        case .library: return "library"
        case .file:    return "import"
        }
    }

    /// Wording matched to Satchel's own capture menu, so the long-press here and
    /// the long-press on Satchel's FAB read as the same four choices rather than
    /// as two different features.
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

// MARK: - URL construction

enum TraceSatchelHandoff {

    /// Builds `satchel://<route>?note=<path>`.
    ///
    /// `URLComponents` rather than string interpolation, because a note path can
    /// hold spaces and ampersands — "Notes/Places/Ruth's Chris.md" is an
    /// ordinary place name — and an unescaped one yields a URL that either fails
    /// to parse or silently truncates the note at the first space.
    ///
    /// The path goes over exactly as Trace holds it: container-relative, with
    /// the `.md` extension. `SatchelRouter.normalizedNote(_:)` forgives a
    /// leading slash or a missing extension, but leaning on that would be
    /// sloppy. A near-miss is worse than a miss here — the sidecar gets written
    /// with a path that renders fine inside Satchel and matches nothing on the
    /// reverse lookup, so the chip never appears and nothing on screen explains
    /// why.
    static func captureURL(_ route: SatchelCaptureRoute, note: String?) -> URL? {
        var comps = URLComponents()
        comps.scheme = "satchel"
        comps.host = route.host
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            comps.queryItems = [URLQueryItem(name: "note", value: note)]
        }
        return comps.url
    }

    /// Builds `satchel://document?path=…` — the READ direction of §7. A chip taps
    /// through to the document in Satchel's viewer.
    ///
    /// Takes a container-relative path rather than an opaque ID on purpose: the
    /// path is what every app in the family already holds, and it is what the
    /// sidecar reverse lookup matched on to draw the chip in the first place.
    static func documentURL(path: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "satchel"
        comps.host = "document"
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        return comps.url
    }
}

// MARK: - Chip store

/// The reverse lookup behind the chips, loaded once per app session.
///
/// SCOPE §7a: a chip is a render-time query, NOT stored data. The link lives on
/// the document, in its sidecar's `linked_note`, pointing at the note. The note
/// file contains nothing about the document and does not know it exists. So
/// drawing a note means asking "which sidecars name this note?" — nothing
/// cached, nothing embedded, nothing that can go stale. That is the whole reason
/// it replaces the old `📎 [title](path)` lines written into note bodies: those
/// are copies, so renaming a document in Satchel silently falsified every note
/// that referenced it.
///
/// TRACE NEVER WRITES HERE. The sidecar stays Satchel's to own. This type reads
/// and filters, and that is all it will ever do.
///
/// Shared and load-once because every Place and Person note asks for chips, and
/// a full sidecar sweep on each screen open is real file I/O that would be felt.
@Observable
final class TraceSatchelChipStore {

    static let shared = TraceSatchelChipStore()

    private let store = iOSDocumentStore()
    private var hasLoaded = false
    /// The sweep currently running, if any. A second caller awaits it rather
    /// than being turned away — see `loadIfNeeded`.
    private var inFlight: Task<Void, Never>?

    private init() { }

    /// Documents carrying a `remind:` date, soonest first.
    ///
    /// Read here rather than by a second store instance: this one is already
    /// shared and load-once precisely because a full sidecar sweep is real file
    /// I/O, and Home would otherwise do its own on every appearance.
    var dated: [TraceMacDocument] {
        store.documents
            .filter { $0.remindOn != nil }
            .sorted { ($0.remindOn ?? .distantFuture) < ($1.remindOn ?? .distantFuture) }
    }

    /// Every document the store knows about.
    ///
    /// Added Session 71 for iOS search, which needs the whole set rather than
    /// one note's. Read off this shared store rather than a second
    /// `iOSDocumentStore`, because a sidecar sweep is real file I/O and this one
    /// is already loaded and already refreshed on foreground.
    var all: [TraceMacDocument] { store.documents }

    /// Documents whose sidecar names this note. Newest first.
    ///
    /// Exact string match, deliberately. `SatchelRouter.normalizedNote(_:)` does
    /// the tidying on the way in precisely so both sides settle on one spelling;
    /// a fuzzy match here would paper over a hand-off that is writing the wrong
    /// path and make the real bug much harder to see.
    ///
    /// **`endeavor` is a second, equally normal association.** Satchel's own
    /// capture writes `endeavor:` into the sidecar; the Add Document button on
    /// the phone's Endeavor screen writes `linked_note:`. Filtering on one key
    /// meant a document attached the other way was invisible, on that screen,
    /// with nothing anywhere saying so. The Mac unions both in
    /// `TraceMacEndeavorsView.documents(for:)` for exactly this reason and left
    /// the phone half-fixed. One filter over one array, so nothing appears twice.
    func documents(linkedTo notePath: String, endeavor endeavorID: String? = nil) -> [TraceMacDocument] {
        store.documents
            .filter { $0.linkedNote == notePath || ($0.endeavor != nil && $0.endeavor == endeavorID) }
            .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    func loadIfNeeded() async {
        // THE `hasAccess` GUARD IS THE WHOLE POINT OF THIS METHOD'S SHAPE.
        //
        // `iOSDocumentStore.reload()` begins `guard noteStore.hasAccess else
        // { return }` — if the iCloud container has not resolved yet it does
        // nothing at all, silently and successfully. The first version of this
        // set `hasLoaded = true` straight afterwards, which cached that empty
        // result for the rest of the app's life.
        //
        // Trace got away with it because its note screens are several taps in,
        // by which time iCloud has resolved. Dayflow does not: the day note is
        // on the HOME screen and draws immediately at launch, so the chips ran
        // before the container was ready, marked themselves loaded, and never
        // showed anything. Found in device testing 2026-07-28, test 7.
        //
        // Callers pair this with `.task(id: noteStore.hasAccess)` so it re-runs
        // the moment access arrives.
        //
        // A CALLER THAT ARRIVES MID-SWEEP WAITS FOR IT; IT IS NOT TURNED AWAY.
        // The first version had an `isLoading` flag and returned at once if it
        // was set. Home starts the sweep on appearance and the Spotlight
        // reindex (`ContentView`, 2026-08-25) called `refresh()` in the same
        // instant, was refused, read an empty `all`, and wrote an index with
        // no documents in it. The receipt was on the phone and unfindable.
        guard NoteStore.shared.hasAccess else { return }
        if let inFlight {
            await inFlight.value
            if hasLoaded { return }
        }
        guard !hasLoaded else { return }
        let task = Task { await store.reload() }
        inFlight = task
        await task.value
        hasLoaded = true
        inFlight = nil
    }

    /// Marks the cache stale so the next `loadIfNeeded()` actually reloads.
    func markStale() { hasLoaded = false }

    /// Unconditional reload. Use on returning to the foreground.
    ///
    /// WHY THIS IS NOT `loadIfNeeded`. The first version loaded once per app
    /// session and refreshed only when `SatchelAddDocumentButton` called
    /// `markStale()` — that is, only when the document was added through *this*
    /// app's own button. A document linked from inside Satchel was therefore
    /// invisible here until the app was killed and relaunched.
    ///
    /// That is not an edge case, it is the normal path: Satchel is where
    /// documents are captured and where the note picker lives, so most new links
    /// are made there. David hit it in device testing 2026-07-28 (test 7) — the
    /// day-note chip did not appear, then appeared after a relaunch, and test 8
    /// passed only because the relaunch had refreshed the cache in between.
    ///
    /// The cost is one directory sweep per foreground, which is what Satchel
    /// itself already does on every launch.
    func refresh() async {
        hasLoaded = false
        await loadIfNeeded()
    }
}

// MARK: - Chips

/// The documents filed against one note, as tappable chips.
struct SatchelDocumentChips: View {

    let notePath: String
    /// When the host note is an Endeavor, its id — so documents filed against
    /// the endeavor in Satchel appear alongside those linked to the note.
    /// Defaulted, so the four non-Endeavor hosts are unchanged.
    var endeavorID: String? = nil
    /// Group the documents into `DocumentBucket` rows, collapsed, under a
    /// header of their own. Session 72, and **defaulted off so the four
    /// non-Endeavor hosts are untouched** — a person's note with one receipt
    /// filed against it does not need a taxonomy laid over it.
    ///
    /// David, on the endeavor screen: *"the various notes and documents are
    /// great but they start to crowd out the note at the bottom."* Collapsing is
    /// the fix for that as much as the organisation is: an unbounded grid
    /// becomes a handful of one-line rows and the editor beneath it gets its
    /// space back.
    var grouped: Bool = false
    /// When the host is a day note, its date: documents whose `remind:` falls
    /// on that day appear here too, with a bell, so a receipt scanned on the
    /// 14th with "Ready On 8/15" is on the 15th's page. 2026-08-27, David:
    /// *"a way to surface this on my daily note."* Defaulted nil so the
    /// other hosts are untouched.
    var dueOn: Date? = nil
    /// When the host is a person's page, their name: documents whose sidecar
    /// `people:` names them appear alongside the linked ones, as on the Mac.
    /// 2026-08-27 — David: *"I realize that people are not currently
    /// associated with documents."* They were, in the sidecar; the phone never
    /// read it.
    var personName: String? = nil

    @State private var chipStore = TraceSatchelChipStore.shared
    @State private var noteStore = NoteStore.shared
    @State private var showingUnavailable = false
    /// Which buckets are open. **Empty by default, so everything starts
    /// collapsed** — the whole point is to give the page its height back, and a
    /// panel that opens itself has not.
    @State private var expanded: Set<DocumentBucket> = []
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private var documents: [TraceMacDocument] {
        var linked = chipStore.documents(linkedTo: notePath, endeavor: endeavorID)
        if let personName {
            let named = chipStore.all.filter { doc in
                doc.people.contains { $0.caseInsensitiveCompare(personName) == .orderedSame }
                    && !linked.contains(where: { $0.relativePath == doc.relativePath })
            }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
            linked += named
        }
        guard let dueOn else { return linked }
        let cal = Calendar.current
        let due = chipStore.dated.filter { doc in
            guard let d = doc.remindOn else { return false }
            return cal.isDate(d, inSameDayAs: dueOn)
                && !linked.contains(where: { $0.relativePath == doc.relativePath })
        }
        return linked + due
    }

    private func isDue(_ doc: TraceMacDocument) -> Bool {
        guard let dueOn, let d = doc.remindOn else { return false }
        return Calendar.current.isDate(d, inSameDayAs: dueOn)
    }

    var body: some View {
        Group {
            if !documents.isEmpty {
                if grouped { groupedBody } else { plainGrid }
            }
        }
        // REFRESH ON EVERY APPEARANCE, not `loadIfNeeded`.
        //
        // Caching here has now produced three separate bugs in two days: an
        // empty store cached before iCloud resolved, a list that never noticed
        // documents added in Satchel, and — this one — a chip missing on one
        // person's note while another person's showed, because the store had
        // been loaded while viewing the first and nothing invalidated it before
        // the second.
        //
        // The premise of the app is a SMALL curated set you carry, not an
        // archive (scope §D2), so a folder sweep is cheap and certainty is worth
        // more than the saving. If the library ever grows enough for this to be
        // felt, reintroduce caching keyed on the directory's modification date
        // rather than on a bool.
        //
        // Still keyed on `hasAccess`: on a cold launch the container has not
        // resolved when this first draws, and `refresh` deliberately does
        // nothing in that state, so this re-fires when access arrives.
        .task(id: noteStore.hasAccess) { await chipStore.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Returning from Satchel is the case that matters, and it is where
            // the link was most likely made — so this reloads rather than
            // asking politely. See `refresh()`.
            guard phase == .active else { return }
            Task { await chipStore.refresh() }
        }
        .alert("Satchel isn't installed", isPresented: $showingUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This document lives in Satchel, the documents app. Install it on this device to open it.")
        }
    }

    /// The original ungrouped grid, unchanged, for the four hosts that never
    /// asked for buckets.
    private var plainGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 136), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            // Keyed on `relativePath`, not `id`. `TraceMacDocument.id` is a
            // fresh UUID minted at parse time, so every reload would look
            // to SwiftUI like a completely different set of rows.
            ForEach(documents, id: \.relativePath) { doc in
                Button { open(doc) } label: { chip(doc) }
                    .buttonStyle(.plain)
            }
        }
        // Supplied here rather than by the caller, because the Person host
        // is a `Form` row with its insets zeroed out.
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Header, then one collapsed line per bucket.
    ///
    /// **The header is the other half of David's report:** *"it says Notes but
    /// the pills include notes as well as documents from satchel."* The list was
    /// never mixed — `attachedChips` draws a titled Notes row and this view drew
    /// its grid directly underneath with no title of its own, so the documents
    /// read as more Notes. One word fixes it, and it only appears in grouped
    /// mode because the other four hosts sit inside sections that are already
    /// titled.
    private var groupedBody: some View {
        let groups = DocumentBucket.group(documents)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("DOCUMENTS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(documents.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            ForEach(groups, id: \.bucket) { group in
                let isOpen = expanded.contains(group.bucket)
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        if isOpen { expanded.remove(group.bucket) }
                        else { expanded.insert(group.bucket) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: group.bucket.sfSymbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(group.bucket.label)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                        Text("\(group.documents.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 136), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(group.documents, id: \.relativePath) { doc in
                            Button { open(doc) } label: { chip(doc) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func chip(_ doc: TraceMacDocument) -> some View {
        let tint = doc.resolvedTint
        return HStack(spacing: 7) {
            Image(systemName: doc.resolvedIcon.sfSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.glyph(tint))
                .frame(width: 22, height: 22)
                .background(Self.tile(tint), in: RoundedRectangle(cornerRadius: 6))
            Text(doc.title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if isDue(doc) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .contentShape(Capsule())
    }

    private func open(_ doc: TraceMacDocument) {
        guard let url = TraceSatchelHandoff.documentURL(path: doc.relativePath) else { return }
        openURL(url) { accepted in
            if !accepted { showingUnavailable = true }
        }
    }

    // MARK: Tint palette
    //
    // A second copy of the eight tints, matching `SatchelSkin.swift`'s extension
    // on `DocumentTint`. Neither is the source of truth — `satchel-mockup-v2.html`
    // is, and both were read off it.
    //
    // The obvious fix, hoisting the extension into `TraceDocumentModels.swift`
    // where `DocumentTint` itself lives, is deliberately NOT taken: that file
    // states at the top that it is Foundation-only by design because it is shared
    // with TraceMac, and `Color` would drag SwiftUI into it. Kept as plain static
    // functions rather than an extension with the same member names as Satchel's,
    // so nobody reads one as the other.

    private static func tile(_ tint: DocumentTint) -> Color {
        switch tint {
        case .teal:   return Color(red: 0.859, green: 0.941, blue: 0.945)
        case .blue:   return Color(red: 0.898, green: 0.941, blue: 1.000)
        case .green:  return Color(red: 0.894, green: 0.969, blue: 0.918)
        case .rose:   return Color(red: 0.992, green: 0.918, blue: 0.953)
        case .indigo: return Color(red: 0.925, green: 0.933, blue: 1.000)
        case .amber:  return Color(red: 1.000, green: 0.949, blue: 0.878)
        case .red:    return Color(red: 1.000, green: 0.902, blue: 0.914)
        case .gray:   return Color(red: 0.925, green: 0.933, blue: 0.941)
        }
    }

    private static func glyph(_ tint: DocumentTint) -> Color {
        switch tint {
        case .teal:   return Color(red: 0.055, green: 0.486, blue: 0.525)
        case .blue:   return Color(red: 0.039, green: 0.518, blue: 1.000)
        case .green:  return Color(red: 0.141, green: 0.541, blue: 0.239)
        case .rose:   return Color(red: 0.812, green: 0.184, blue: 0.467)
        case .indigo: return Color(red: 0.345, green: 0.337, blue: 0.839)
        case .amber:  return Color(red: 0.788, green: 0.463, blue: 0.039)
        case .red:    return Color(red: 0.843, green: 0.000, blue: 0.082)
        case .gray:   return Color(red: 0.420, green: 0.420, blue: 0.439)
        }
    }
}

// MARK: - Button

/// "Add Document", filed to a specific note.
///
/// Tap opens Satchel's scanner; long-press offers the other three sources. That
/// is Satchel's own FAB rule (scope §5, Photos) applied unchanged: the urgent
/// path stays one tap and nothing becomes a menu. Scanning a receipt at the
/// place whose note is on screen is the case that motivated the hand-off.
struct SatchelAddDocumentButton: View {

    /// How the control renders. Two presentations because the two hosts are
    /// different containers, not because the button does two different things:
    /// a Person's note tab is a `Form`, where a `Label` row is the native shape,
    /// while a Place's note tab is a bare editor inside a paged `TabView`, where
    /// a row would have nothing to be a row of.
    enum Style {
        case row
        case bar
        /// Session 78, Dayflow's Notes redesign: a bare small-caps word for
        /// the project note's unified bottom band — same hand-off menu, no
        /// bar of its own.
        case caps
    }

    /// Container-relative path of the note the new document should be filed to.
    let notePath: String
    var style: Style = .row

    @Environment(\.openURL) private var openURL
    @State private var showingUnavailable = false

    var body: some View {
        content
            .alert("Satchel isn't installed", isPresented: $showingUnavailable) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Add Document hands this note over to Satchel, the documents app, so whatever you capture is filed against it automatically.")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .row:
            handoffMenu {
                Label("Add Document in Satchel", systemImage: "arrow.up.forward.app")
            }
        case .caps:
            handoffMenu {
                // Color(.systemGray2), not Color.dayflowFaint: this file is
                // shared beyond the Dayflow target, where the skin tokens
                // don't exist.
                Text("DOCUMENT")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.4)
                    .foregroundStyle(Color(.systemGray2))
                    .contentShape(Rectangle())
            }
        case .bar:
            HStack(spacing: 0) {
                handoffMenu {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Add Document")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    private func handoffMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            // `.scan` is excluded on purpose: a plain tap already scans, so
            // listing it again is a menu item for something the user just did
            // not do. Satchel's own FAB made this call first — its `contextMenu`
            // offers exactly these three — and two buttons that do the same job
            // should not disagree about their own menu. David caught the
            // mismatch on device, 2026-07-28.
            ForEach(SatchelCaptureRoute.allCases.filter { $0 != .scan }) { route in
                Button {
                    open(route)
                } label: {
                    Label(route.title, systemImage: route.symbol)
                }
            }
        } label: {
            label()
        } primaryAction: {
            open(.scan)
        }
    }

    private func open(_ route: SatchelCaptureRoute) {
        ensureNoteExists()
        // A document is about to be added to this note. Coming back to a note
        // that does not show what you just captured reads as the link having
        // failed, which is the confusion the chips exist to remove.
        TraceSatchelChipStore.shared.markStale()
        guard let url = TraceSatchelHandoff.captureURL(route, note: notePath) else { return }
        // The completion form, not the bare call. With no Satchel on the device
        // the bare call does nothing whatsoever and leaves a button that simply
        // looks broken. This also deliberately avoids `canOpenURL`, which would
        // require `satchel` in Trace's `LSApplicationQueriesSchemes` — a plist
        // edit to learn something the open attempt already reports.
        openURL(url) { accepted in
            if !accepted { showingUnavailable = true }
        }
    }

    /// Creates the note file if it is not there yet. David's call, 2026-07-28,
    /// after the first device test.
    ///
    /// Person and place notes in Trace are created LAZILY: `PersonDetailView`
    /// and `PlaceDetailView` write the file only when their editor saves
    /// non-empty text. So a person nothing has ever been written about has no
    /// note file at all, and a document filed against them points at nothing.
    ///
    /// Two consequences, both bad. Satchel's note picker lists real files, so if
    /// the hand-off ever misses, the link cannot be repaired by hand — the
    /// person simply is not in the list. And the reverse lookup that will draw
    /// the chip has nothing to anchor to. The path is deterministic, so the link
    /// would start resolving the moment the note was first written by hand, but
    /// "works later, if you happen to type something" is not a property worth
    /// shipping.
    ///
    /// TRACE CREATES IT, NOT SATCHEL, and that is not a violation of §7b. The
    /// rule is that Trace hands across intent rather than DOCUMENT data. A
    /// Person or Place note is Trace's own data, which Trace already creates on
    /// first save; this only moves the moment of creation earlier. Satchel still
    /// writes the sidecar and still owns `linked_note`.
    ///
    /// Seeded with a `# Title` heading rather than left empty, so the file is
    /// self-describing when the vault is browsed outside the app. Failure is
    /// deliberately silent: a hand-off that still works beats an alert about a
    /// file the user never asked for.
    private func ensureNoteExists() {
        guard let url = NoteStore.shared.resolvedURL(for: notePath),
              !FileManager.default.fileExists(atPath: url.path) else { return }
        let heading = (notePath.components(separatedBy: "/").last ?? notePath)
            .replacingOccurrences(of: ".md", with: "")
        try? NoteStore.shared.writeFile(notePath, content: "# \(heading)\n\n")
    }
}
