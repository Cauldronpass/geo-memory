import SwiftUI
import UIKit

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
    /// **Owned by `SatchelRootView` since D417, not by this screen.** Three tabs
    /// read the same library; three stores scanning the same folder would be
    /// three answers to one question, and the first thing they would do after a
    /// swipe on the Shelf is disagree.
    let store: iOSDocumentStore
    let endeavorStore: SatchelEndeavorStore
    /// D407 Build 3. Satchel's only setting so far.
    @State private var showingSignedInSites = false

    @Environment(\.scenePhase) private var scenePhase
    /// For the Save to Satchel toast's return action (D390).
    @Environment(\.openURL) private var openURL

    @State private var query: String = ""
    /// Which Browse chip is showing its full name. One at a time.
    @State private var revealedChip: String? = nil
    /// The Paste action found an empty clipboard (D386). An alert rather than
    /// silence: a long press that does nothing reads as a broken button.
    @State private var showPasteEmpty = false

    /// The result of a `satchel://savelink` hand-off (D390), shown as a toast.
    /// Nil while nothing has been filed.
    @State private var saveLinkResult: SatchelSaveLinkOutcome?
    /// Where the sender asked to be sent back to, held alongside the result so
    /// the toast can offer it. Satchel opens it only on a deliberate tap.
    @State private var saveLinkReturn: URL?
    /// A save in flight. The toast shows a spinner rather than appearing from
    /// nowhere a second after the app opens: the page fetch can take a moment,
    /// and an app that came forward and then did nothing visible reads as a
    /// hand-off that failed.
    @State private var saveLinkWorking = false

    /// Reads the clipboard and starts a capture with what it holds (D386).
    ///
    /// Order matters and mirrors the share extension's: a copied link is on
    /// the pasteboard as a URL AND as its own text, so the URL is asked for
    /// first or every link would arrive as a `.txt`. A bare `kearney.com`
    /// copied as text still counts as a link, by the same `openableURL` test
    /// the URL row uses, but only when it is one word: a sentence with a dot
    /// in it is a sentence.
    private func pasteFromClipboard() {
        let board = UIPasteboard.general
        let stamp: String = {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd-HHmmss"
            return fmt.string(from: Date())
        }()

        var webURL: URL? = nil
        if let url = board.url, !url.isFileURL { webURL = url }
        if webURL == nil, let text = board.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            webURL = TraceMacDocument.openableURL(text)
        }
        if let webURL, ["http", "https"].contains(webURL.scheme?.lowercased() ?? ""),
           let data = TraceMacDocument.weblocData(for: webURL.absoluteString) {
            var host = webURL.host ?? "link"
            if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
            captureRequest = SatchelCaptureRequest(
                source: .paste,
                incoming: IncomingDocument(data: data,
                                           filename: "\(stamp)-\(host).webloc",
                                           originalName: "\(host).webloc",
                                           contentType: "link"))
            return
        }
        if let text = board.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           let data = text.data(using: .utf8) {
            // The first line names the file, so the sheet opens with something
            // readable rather than "pasted text"; the scan may rename it.
            let firstLine = text.components(separatedBy: .newlines).first ?? "text"
            let base = String(firstLine.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
            captureRequest = SatchelCaptureRequest(
                source: .paste,
                incoming: IncomingDocument(data: data,
                                           filename: "\(stamp)-pasted.txt",
                                           originalName: "\(base.isEmpty ? "text" : base).txt",
                                           contentType: "txt"))
            return
        }
        if let image = board.image, let data = image.pngData() {
            captureRequest = SatchelCaptureRequest(
                source: .paste,
                incoming: IncomingDocument(data: data,
                                           filename: "\(stamp)-pasted.png",
                                           originalName: "pasted image.png",
                                           contentType: "image"))
            return
        }
        showPasteEmpty = true
    }

    /// Where a tapped Browse chip goes.
    ///
    /// The chips were `NavigationLink`s until 2026-08-01. They had to stop being
    /// links: a `NavigationLink` owns its own tap, so the only way to add a long
    /// press was `.simultaneousGesture`, and *simultaneous* is exactly what it
    /// says — the push fired on release as well. David: *"the long press shows the
    /// full name but when i release I am brought to that filter… The way it is now
    /// defeats the purpose."*
    ///
    /// Driving the push from state instead means `.onTapGesture` and
    /// `.onLongPressGesture` can arbitrate properly: one or the other, never both.
    @State private var chipRoute: ChipRoute? = nil

    /// Kept local rather than added to `SatchelDeepLink`. That enum is the URL
    /// router's vocabulary; these are four screens reachable only by thumb.
    enum ChipRoute: Hashable, Identifiable {
        case endeavor(String)
        case type(DocumentIcon)
        case tint(DocumentTint)
        case allTrips
        case allTypes
        /// Show all with Format set to Links (D386). A door, not a room.
        case links
        var id: Self { self }
    }
    /// THE WHOLE CAPTURE REQUEST, IN ONE VALUE.
    ///
    /// This was three separate `@State` properties: the source (which presented
    /// the sheet) plus a note link and a staged incoming file that the sheet
    /// read as it built. The comments on them recorded the ordering rule that
    /// was supposed to make it safe — assign the payload first, the source
    /// second, because assigning the source is what presents.
    ///
    /// **It was not safe.** `.sheet(item:)` builds its content from a snapshot
    /// of the view, and a sibling `@State` written in the same tick is not
    /// guaranteed to be in that snapshot. On 2026-07-31 David shared a PDF from
    /// Mail, the extension staged it correctly and reported success, and Satchel
    /// opened the Files picker over a spinner — which is exactly what
    /// `SatchelCaptureView` does when `incoming` arrives **nil**: it falls past
    /// the incoming branch and calls `launchSource()`. The bytes were gone by
    /// then, because `AppGroup.consumeIncoming()` deletes as it reads.
    ///
    /// A payload carried BY the item cannot be missing when the item is present.
    /// The ordering rule stops being something to remember, which is the only
    /// kind of fix worth making to a bug whose comments already described the
    /// hazard correctly.
    @State private var captureRequest: SatchelCaptureRequest?
    /// David: *"when i click in the search box there is no way to exit that view
    /// and dismiss the keyboard to see the main screen."* The field had no
    /// focus binding at all, so nothing could put the keyboard away — the `x`
    /// cleared the text and left it up, and it only appeared once there was
    /// text to clear.
    @FocusState private var searchFocused: Bool

    // Session 73. Both default to open, so nothing moves under him until he
    // folds one — and then it stays folded, which is the entire point. A
    // collapse that resets on launch is a control you use once and stop
    // trusting, the same defect `MacColumnResizer` was built to fix on the Mac
    // side (`@State private var sidebarWidth` resetting every morning).
    //
    // Plain `UserDefaults` via `@AppStorage`, not the App Group suite: this is
    // one app's view state and nothing else reads it.
    /// Home's two drawers and its tail, folded independently and remembered
    /// (D418). Same mechanism as Browse and Kind below, and the same reason: a
    /// fold you redo on every launch is worse than no fold.
    @AppStorage("satchel.kit.expanded") private var kitExpanded = true
    @AppStorage("satchel.recent.expanded") private var recentExpanded = true
    @AppStorage("satchel.browse.expanded") private var browseExpanded = true
    @AppStorage("satchel.kinds.expanded") private var kindsExpanded = true
    /// Persisted for the same reason the two above are: a fold that springs open
    /// every launch is a control you stop using.
    @AppStorage("satchel.due.laterExpanded") private var laterExpanded = false

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
        // Tokenised once per search, not once per document — see
        // `DocumentSearch.tokens(from:)`.
        let tokens = DocumentSearch.tokens(from: query)
        guard !tokens.isEmpty else { return [] }
        return store.documents.filter { DocumentSearch.matches($0, tokens: tokens) }
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
                .refreshable {
                await store.reload()
                await store.extractTextForNewArrivals()
                await SatchelArticleSweep.run(store: store, noteStore: noteStore)
            }
                // Third way out: drag the list. The one people try first.
                .scrollDismissesKeyboard(.interactively)

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
                // Read the words off anything captured since the last sweep.
                // **After `reload()`, and it reloads again itself if it wrote**
                // — the pass reads `store.documents` to decide what is pending,
                // so running it first would find nothing on a cold launch.
                // Satchel is the documents app and the app the phone's captures
                // go through, which makes it the right and only place for this;
                // Dayflow running Vision would be the wrong app doing it.
                await store.extractTextForNewArrivals()
                // **And the same pass for saved links** (D407 Build 2). Its own
                // sweep rather than a case inside the one above: that one runs
                // Vision on the device and never touches the network, this one
                // loads someone else's page in a web view, and folding them
                // together would put a hidden web view in Dayflow and Trace,
                // which compile the file it lives in.
                await SatchelArticleSweep.run(store: store, noteStore: noteStore)
                // Deep-link destinations drain HERE, after the store is loaded,
                // not on appear: `satchel://document?path=…` resolves against
                // `store.documents`, and on a cold launch that is still empty
                // when the view first appears. Draining early would dead-end the
                // §7 chip hand-off on "missing document".
                drainRouter()
            }
            // Cold-launch drain for capture and search. `onChange` alone is NOT
            // enough — see `drainRouter()`. The brief sleep is the same lesson
            // `SatchelCaptureView` already learned: a sheet presented while the
            // window is still coming up gets swallowed silently.
            .task {
                try? await Task.sleep(for: .milliseconds(50))
                drainRouter(includingDestination: false)
                consumeSharedFile()
            }
            // **Extraction after a capture, not only at launch.**
            //
            // `extractTextForNewArrivals` was called from `.task(id:
            // noteStore.hasAccess)`, which fires when access arrives and never
            // again — so a document captured during a session was not read until
            // the next cold launch. Invisible for an ordinary capture, which
            // gets an AI title and tags to search on. **Fatal for a private
            // one**, whose only searchable content is the words on the page.
            .sheet(isPresented: $showingSignedInSites) {
            SatchelSignedInSitesView()
        }
        .sheet(item: $captureRequest, onDismiss: {
                Task {
                    await store.reload()
                    await store.extractTextForNewArrivals()
                    // A link saved through the capture sheet is read on the way
                    // out of it, not at the next cold launch. Same reason the
                    // line above it exists.
                    await SatchelArticleSweep.run(store: store, noteStore: noteStore)
                }
            }) { request in
                SatchelCaptureView(source: request.source, store: store,
                                   prefilledNote: request.noteLink,
                                   incoming: request.incoming,
                                   isPrivate: request.isPrivate)
                    // **A NEW VIEW FOR EVERY REQUEST, NOT A REUSED ONE.**
                    //
                    // David's hypothesis, after a private scan followed by an
                    // ordinary one came back with nothing filled in: *"do you
                    // think that it might have been the sequence?"* SwiftUI will
                    // sometimes reuse a sheet's content across presentations
                    // rather than rebuild it, and a reused capture sheet would
                    // inherit the previous one's `@State` — including `tags`
                    // still holding `private`, which makes the guard inside
                    // `runScan` fire and return in silence. That is precisely
                    // the symptom.
                    //
                    // It does not fully fit — carried-over tags would have shown
                    // a visible `private` chip on the ordinary document and he
                    // saw none — so this is not a confirmed diagnosis. **It is
                    // the elimination of a whole class for one line**, which is
                    // worth more than another round of reasoning about which
                    // half of the theory holds. If it recurs after this, the
                    // cause is elsewhere and the next step is instrumentation,
                    // not a fourth guess.
                    .id(request.id)
            }
            .navigationDestination(item: $chipRoute) { route in
                switch route {
                case .endeavor(let id):
                    SatchelAllDocumentsView(documents: store.documents,
                                            store: store, endeavorID: id)
                case .type(let type):
                    SatchelAllDocumentsView(documents: store.documents,
                                            store: store, type: type)
                case .tint(let tint):
                    SatchelAllDocumentsView(documents: store.documents,
                                            store: store, tint: tint)
                case .allTrips:
                    SatchelEndeavorIndexView(documents: store.documents,
                                             store: store, endeavorStore: endeavorStore)
                case .allTypes:
                    SatchelTypeIndexView(documents: store.documents, store: store)
                case .links:
                    SatchelAllDocumentsView(documents: store.documents,
                                            store: store, kind: .link)
                }
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
                        SatchelOpenView(document: doc, store: store)
                    } else {
                        missingDocument(relativePath)
                    }
                }
            }
            // Warm-app path: Satchel is already running when the URL arrives,
            // so there is a real transition for `onChange` to see.
            // Reload on returning to the foreground. Satchel had the same bug
            // its own chip reader did in Trace and Dayflow: the library loaded
            // once per session and never noticed a change made elsewhere. Edit a
            // document through Trace's own browser, come back, and Satchel still
            // showed the old title — which reads as the edit having failed.
            // Found in device testing 2026-07-28, test 10. Third instance of
            // this family in one day; if a fourth surfaces, the reload belongs
            // in the store rather than at each call site.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await store.reload() }
                // The share extension stages a file and dismisses without
                // opening anything, so the hand-off is picked up whenever
                // Satchel next comes forward — which is usually the user
                // switching to it deliberately, right after sharing.
                consumeSharedFile()
            }
            .onChange(of: router.pendingCapture) { _, _ in drainRouter() }
            .onChange(of: router.pendingSearch) { _, _ in drainRouter() }
            .onChange(of: router.pendingDestination) { _, _ in drainRouter() }
            .onChange(of: router.pendingSaveLink) { _, _ in drainRouter() }
            // Above the Library rather than inside it: the hand-off can land on
            // any screen this stack is showing, and the confirmation belongs to
            // the app, not to whichever list happens to be up.
            .overlay(alignment: .bottom) { saveLinkToast }
            .animation(.easeInOut(duration: 0.2), value: saveLinkWorking)
        }
    }

    /// Picks up a file shared in from another app via the iOS share sheet.
    ///
    /// `TraceShareExtension` writes the bytes plus a `pending.json` into the
    /// shared app group and dismisses — it opens no app and names none, so
    /// whichever app calls `consumeIncoming()` first gets it. **Trace stopped
    /// calling it on 2026-07-29**, so there is no race: the file waits in the
    /// container until Satchel is opened.
    ///
    /// This is what settles scope §10's open question. Satchel does not need its
    /// own share extension — the existing one is app-agnostic, and only the
    /// consumer had to move.
    private func consumeSharedFile() {
        guard captureRequest == nil,
              let doc = AppGroup.consumeIncoming() else { return }
        captureRequest = SatchelCaptureRequest(source: .file, incoming: doc)
    }

    /// Consumes whatever the router is holding, and is safe to call when it is
    /// holding nothing.
    ///
    /// WHY THIS IS NOT JUST `onChange`. Found in device testing on 2026-07-28,
    /// the first real run of the Trace-side "Add document" button. On a COLD
    /// launch, `onOpenURL` delivers before this view establishes its `onChange`
    /// baseline, so `router.pendingCapture` is ALREADY set the first time the
    /// body runs and there is never a *change* to observe. Nothing fires.
    ///
    /// The symptom is quiet and thoroughly misleading: Satchel opens on the
    /// Library instead of the scanner, so the user starts a capture by hand,
    /// the note the other app handed across is gone, and the document saves
    /// unlinked. Every part of that looks like the hand-off simply not being
    /// implemented, which is why it survived a code read — the write path, the
    /// picker and the sidecar were all correct.
    ///
    /// It applied to all four capture routes, to `satchel://search` and to
    /// `satchel://document?path=…`. That last one matters most: the §7 chip is
    /// a hand-off from another app, so it is a cold launch nearly every time.
    private func drainRouter(includingDestination: Bool = true) {
        // **Paste is drained differently, because it is not a sheet.** It reads
        // the pasteboard, builds an `IncomingDocument` and then opens the sheet
        // on the result (D386). Handing `.paste` to the branch below would
        // present a capture sheet with nothing in it.
        if router.pendingCapture == .paste {
            router.pendingCapture = nil
            router.pendingCaptureIsPrivate = false
            pasteFromClipboard()
        }
        if let source = router.pendingCapture {
            captureRequest = SatchelCaptureRequest(source: source,
                                                   noteLink: router.pendingNoteLink,
                                                   isPrivate: router.pendingCaptureIsPrivate)
            router.pendingNoteLink = nil
            router.pendingCaptureIsPrivate = false
            router.pendingCapture = nil
        }
        if let text = router.pendingSearch {
            query = text
            router.pendingSearch = nil
        }
        if includingDestination, let destination = router.pendingDestination {
            path.append(destination)
            router.pendingDestination = nil
        }
        // **Cleared before the work starts, not after.** The same cold-launch
        // shape as the capture routes above, plus one of its own: the save is
        // asynchronous, so a request left on the router while the page is being
        // fetched would be drained a second time by the next `onChange` and
        // file the address twice.
        if let request = router.pendingSaveLink {
            router.pendingSaveLink = nil
            saveLinkReturn = request.returnURL
            saveLinkWorking = true
            saveLinkResult = nil
            Task {
                let outcome = await SatchelSaveLink.perform(request, store: store)
                saveLinkWorking = false
                saveLinkResult = outcome
            }
        }
    }

    /// The Save to Satchel confirmation (D390).
    ///
    /// A toast, not a sheet: D385's rule is that filing is one motion, and a
    /// screen that asks a question after the fact is the same interruption
    /// arriving late. It carries one action — back to wherever the link came
    /// from — because the hand-off moved him out of the app he was reading.
    @ViewBuilder
    private var saveLinkToast: some View {
        if saveLinkWorking || saveLinkResult != nil {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                    if saveLinkWorking {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: (saveLinkResult?.isFailure ?? false)
                              ? "exclamationmark.circle" : "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle((saveLinkResult?.isFailure ?? false)
                                             ? Color.orange : Color.green)
                    }
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(saveLinkWorking ? "Saving to Satchel" : (saveLinkResult?.headline ?? ""))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    if let detail = saveLinkWorking ? nil : saveLinkResult?.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)

                if !saveLinkWorking, let back = saveLinkReturn {
                    Button("Back") {
                        saveLinkResult = nil
                        openURL(back)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.37, green: 0.66, blue: 1.0))
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 34)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onTapGesture { saveLinkResult = nil }
            .task(id: saveLinkResult.map(\.headline)) {
                // Clears itself, except on a failure, which stays until tapped:
                // a message explaining why nothing was saved is the one worth
                // reading twice.
                guard let result = saveLinkResult, !result.isFailure else { return }
                try? await Task.sleep(for: .seconds(4))
                withAnimation { saveLinkResult = nil }
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 12.5, weight: .medium))
                    .kerning(0.5)
                    .foregroundStyle(Color.satchelSecondary)
                Text("Satchel")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(Color.satchelInk)
            }
            Spacer(minLength: 0)
            // **Satchel's first setting, and therefore its first settings
            // door** (D407 Build 3). The build starter said "a Settings row";
            // there is no Settings screen in this app and one row does not earn
            // a whole one, so the gear opens the sheet directly. When a second
            // setting arrives, this becomes the list and the sites become a row
            // in it.
            Button { showingSignedInSites = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.satchelSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
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
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.satchelSecondary)
                TextField("Search documents", text: $query)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.satchelInk)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($searchFocused)
                    // Return puts the keyboard away and keeps the results. The
                    // search runs as you type, so Return has nothing else to do.
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                // **Shown while focused, not only while there is text.** An empty
                // field with the keyboard up was the exact dead end: nothing to
                // clear, so no button, so no way out.
                if isSearching || searchFocused {
                    Button {
                        query = ""
                        searchFocused = false
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

            // A worded way out beside the field, because the `x` inside it reads
            // as "clear" and this reads as "done". Two intentions, two controls.
            if searchFocused {
                Button("Done") { searchFocused = false }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.satchelBlue)
                    .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: searchFocused)
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
                // **Up Next first, then what he is carrying, then what landed**
                // (D416). Browse and Kind have gone to the All tab: they were
                // never things to look at, they were ways of narrowing a list,
                // and this screen does not have the list.
                SatchelUpNextSection(store: store)
                kitSection
                dueSection
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
                // Folded, like Up Next (D418). Either drawer can be the one on
                // top of the screen depending on the week: on the road he folds
                // Up Next and Kit is under the search field; at home he folds
                // Kit. Neither had to be moved for that to work.
                SatchelCollapsibleSectionTitle(title: "Kit",
                                               isExpanded: $kitExpanded,
                                               collapsedCount: kit.all.count) {
                    // `showsKitDoor`, not `showsSeeAll` — with four or fewer
                    // items there was no way onto the Kit screen, and that screen
                    // holds the trip-slots stepper, so the setting was
                    // unreachable exactly when Kit was small. See the note on
                    // `KitMembership.Layout.showsKitDoor`.
                    if kit.showsKitDoor {
                        NavigationLink {
                            SatchelKitView(result: kit, store: store)
                        } label: {
                            HStack(spacing: 2) {
                                Text(kit.kitDoorLabel)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.satchelBlue)
                        }
                    }
                }

                // ── Sideways, not two-across (D418) ──────────────────────
                //
                // David: *"Kit takes up a lot more room on the home screen with
                // the square cards than Up Next."* True, and the tiles were
                // right when Kit was the whole of Home. Home now has three jobs
                // and two documents were spending four rows of height.
                //
                // The strip keeps everything the tiles were FOR — you recognise
                // a boarding pass by its picture and you want it in one tap —
                // and spends one row instead of four. The extra ones live to
                // the right rather than pushing Recent off the screen. 150pt is
                // two and a bit on a 6.1" phone, so the cut-off third card is
                // what says it scrolls.
                if kitExpanded {
                  ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                      ForEach(kit.strip) { entry in
                        NavigationLink {
                            SatchelOpenView(document: entry.document, store: store)
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
                        .frame(width: 150)
                      }
                    }
                    // The strip bleeds to both screen edges — the section's own
                    // 15pt gutter is cancelled outside and reapplied inside, so
                    // a card can sit half off the edge and SAY it scrolls.
                    .padding(.horizontal, 15)
                  }
                  .padding(.horizontal, -15)

                  kitFootnote
                }
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
    // Browse leads with SUBJECT, because that is how David retrieves: *what the
    // document is about* first, then name, then date, tags last.
    //
    // **It said TYPE until Session 73**, and so did every string on this screen.
    // That word was chosen before D123 existed; D123 then gave "kind of thing"
    // to COLOUR and left the icon answering "what is it ABOUT". The phone went on
    // saying Type for the icon while the Mac's pane said TYPE and meant the
    // colour, so one word named opposite axes in two apps built from one model.
    // Three words now, each true and each used in exactly one place:
    //
    //   Subject — the icon. What the document is about.
    //   Kind    — the colour. What kind of thing it is. D123's own phrase.
    //   Format  — PDF or image. Was `Kind`, which is what forced the collision.
    //
    // The row used to lead with
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
    /// Trips shown as chips before the rest go behind `All trips`.
    private static let endeavorChipLimit = 2

    /// Saved links in the library (D386), for the one Browse chip they get.
    private var linkCount: Int { store.documents.filter { $0.isLink }.count }

    @ViewBuilder
    private var browseSection: some View {
        if !typeCounts.isEmpty || !endeavorCounts.isEmpty || linkCount > 0 {
            VStack(alignment: .leading, spacing: 0) {
                SatchelCollapsibleSectionTitle(title: "Browse",
                                               isExpanded: $browseExpanded,
                                               collapsedCount: browseChipCount)
                if browseExpanded {
                    // 160, matching the colour row below. See the long note
                    // there for where the number comes from.
                    //
                    // This row was left at 104 for one pass, on the argument
                    // that Endeavor names are arbitrarily long and truncate at
                    // any width, so widening buys nothing the long press does
                    // not already give. **David: "same for the browse then."**
                    // He is right, and the argument was answering the wrong
                    // question: it asked whether wider cells fix truncation
                    // here, when what matters is that these two grids sit two
                    // rows apart. Chips of two different widths stacked like
                    // that read as a mistake, and no user has the context to
                    // know that one row has a fixed vocabulary and the other
                    // does not.
                    //
                    // Type labels also stop truncating as a side effect —
                    // `Reference` and `Education` did not fit at 104 either.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(shownEndeavors, id: \.0) { id, name, count in
                            SatchelBrowseChip(label: name, count: count, endeavor: true)
                                .chipGestures(id: id, name: name, count: count,
                                              revealed: $revealedChip) {
                                    chipRoute = .endeavor(id)
                                }
                        }

                        // THE DOOR TO THE REST. Two chips have always been the cap,
                        // and until now the third trip onwards was reachable only by
                        // searching for a name you had to already remember. `All
                        // types` has had this door since the row was built; trips
                        // never got one. David, 2026-08-01: *"being able to see files
                        // for endeavors would be nice (a filter or a way to look at
                        // past trips and the documents that are associated)."*
                        if endeavorCounts.count > Self.endeavorChipLimit {
                            SatchelBrowseChip(label: "All trips",
                                              count: endeavorCounts.count,
                                              showsChevron: true)
                                .chipGestures(id: "all-trips", name: "All trips",
                                              count: endeavorCounts.count,
                                              revealed: $revealedChip) {
                                    chipRoute = .allTrips
                                }
                        }

                        ForEach(shownTypes, id: \.0) { type, count in
                            SatchelBrowseChip(type: type, count: count)
                                .chipGestures(id: type.label, name: type.label, count: count,
                                              revealed: $revealedChip) {
                                    chipRoute = .type(type)
                                }
                        }

                        if typeCounts.count > shownTypes.count {
                            SatchelBrowseChip(label: "All subjects",
                                              count: typeCounts.count,
                                              showsChevron: true)
                                .chipGestures(id: "all-subjects", name: "All subjects",
                                              count: typeCounts.count,
                                              revealed: $revealedChip) {
                                    chipRoute = .allTypes
                                }
                        }
                        // **One chip for links, and only when there are any**
                        // (D386). Not a room: it opens Show all with Format
                        // set to Links, so the grid, the sort and the other
                        // filters are the same ones every other chip lands on.
                        if linkCount > 0 {
                            SatchelBrowseChip(label: "Links",
                                              count: linkCount,
                                              showsChevron: true)
                                .chipGestures(id: "links", name: "Links",
                                              count: linkCount,
                                              revealed: $revealedChip) {
                                    chipRoute = .links
                                }
                        }
                    }
                    .padding(.horizontal, 6)
                }

                // The colour axis, Session 73. Its own titled row rather than
                // more chips in the grid above: they answer a different
                // question, and mixed into one grid the only thing telling them
                // apart would be that some are round-cornered squares of colour
                // and some are glyphs. That is a distinction you have to be told
                // about, which means it is not one.
                //
                // "Kind", D123's own word for what colour answers. Session 73
                // freed it: the icon axis gave up "Type" for "Subject" and the
                // PDF-or-image filter gave up "Kind" for "Format".
                if !tintCounts.isEmpty {
                    SatchelCollapsibleSectionTitle(title: "Kind",
                                                   isExpanded: $kindsExpanded,
                                                   collapsedCount: tintCounts.count)
                        .padding(.top, 14)
                    if kindsExpanded {
                        // **160, not the 104 the Browse grid above uses.**
                        //
                        // Session 73. At 104 an iPhone fits three columns, which
                        // leaves about 42pt for the label once the swatch, the
                        // count and the padding are paid for — roughly six
                        // characters. Paid fitted and Booked did not, and because
                        // SwiftUI shares the squeeze between the label and the
                        // count it truncated INCONSISTENTLY: Official survived
                        // while Untyped became `Unty…`. That inconsistency is
                        // what made it read as a defect rather than as tight.
                        //
                        // 160 gives two columns on every iPhone size — 328pt of
                        // grid against 333 available on the narrowest, 351 on a
                        // regular Pro — and about 100pt of label, which clears
                        // "Needs action" with room. It stays `.adaptive` rather
                        // than two `.flexible()` columns so an iPad still uses
                        // the width it has.
                        //
                        // Browse above uses the same 160. It was briefly left
                        // at 104 on the argument that Endeavor names truncate at
                        // any width anyway; that argument was true and beside
                        // the point, since the two grids are two rows apart and
                        // chips of two widths that close read as a mistake.
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 160), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(tintCounts, id: \.0) { tint, count in
                                SatchelBrowseChip(tint: tint, count: count)
                                    .chipGestures(id: "tint-" + tint.rawValue,
                                                  name: tint.satchelLongLabel,
                                                  count: count,
                                                  revealed: $revealedChip) {
                                        chipRoute = .tint(tint)
                                    }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 14)
        }
    }

    /// How many chips Browse is holding when it is folded shut.
    ///
    /// Counts what the row would actually DRAW, doors included, not how many
    /// types and trips exist. A folded section saying 24 that opens to show
    /// six chips has told you something false.
    private var browseChipCount: Int {
        shownEndeavors.count
            + (endeavorCounts.count > Self.endeavorChipLimit ? 1 : 0)
            + shownTypes.count
            + (typeCounts.count > shownTypes.count ? 1 : 0)
            + (linkCount > 0 ? 1 : 0)
    }

    /// The most-used types, capped, then sorted alphabetically so their positions
    /// hold still between captures.
    private var shownTypes: [(DocumentIcon, Int)] {
        let slots = max(0, Self.browseChipLimit
                        - min(endeavorCounts.count, Self.endeavorChipLimit)
                        - (endeavorCounts.count > Self.endeavorChipLimit ? 1 : 0)
                        - (typeCounts.count > Self.browseChipLimit ? 1 : 0))
        return typeCounts
            .prefix(slots)
            .sorted { $0.0.label < $1.0.label }
    }

    /// The two trips that get chips.
    ///
    /// **Chosen by recency, rendered alphabetically** — the same split the type
    /// chips use, and for the same reason. Which two you see should track what you
    /// are actually near; where they sit should not move under your thumb.
    ///
    /// `endeavorCounts` alone was sorted by NAME, so which two trips got chips was
    /// decided by the alphabet. A trip from last spring could hold a slot while
    /// the one you were on did not.
    private var shownEndeavors: [(String, String, Int)] {
        endeavorCounts
            .sorted { endeavorRecency($0.0) > endeavorRecency($1.0) }
            .prefix(Self.endeavorChipLimit)
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    /// How recent a trip is, for ordering. An Endeavor whose note has been
    /// deleted still has documents pointing at it and no date to sort by; those
    /// sort last rather than disappearing, because the documents are still real.
    private func endeavorRecency(_ id: String) -> Date {
        guard let trip = endeavorStore.endeavor(id: id) else { return .distantPast }
        return trip.end ?? trip.start ?? .distantPast
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

    /// Colours in use, in the palette's own documented order.
    ///
    /// **Not sorted by count, and not capped.** There are only ever six type
    /// colours plus the two reserved ones, so the row cannot run away — the
    /// fixed-footprint problem the type chips have does not exist here. Fixed
    /// order for the same reason §5 gives: a target that moves is worse than
    /// one you have to look for once. `DocumentTint.typeCases` is the order the
    /// scan prompt and both pickers already read down.
    private var tintCounts: [(DocumentTint, Int)] {
        var counts: [DocumentTint: Int] = [:]
        for doc in store.documents {
            counts[doc.resolvedTint, default: 0] += 1
        }
        let order = DocumentTint.typeCases + [.amber, .red]
        return order.compactMap { t in
            guard let n = counts[t], n > 0 else { return nil }
            return (t, n)
        }
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

    // MARK: Due
    //
    // David, 2026-08-01: *"I would want to see items with dates somehow."*
    //
    // Above Recent, because a date is a claim on your attention and a capture time
    // is not. Overdue first and never dropped — the same rule Trace's Coming Up
    // follows, and for the same reason: a document you meant to deal with last
    // week is still waiting, and ageing it off screen would be the app deciding
    // that for you.
    //
    // Hidden entirely when nothing has a date, rather than sitting there empty.

    // MARK: Due
    //
    // **Two sources, one band** (D381). A document earns a place here when it
    // carries a reminder date, and ALSO when the date printed on it is still in
    // the future. The second case exists because of one document: David's
    // Round-Trip Flight Itinerary was dated 21 November with no reminder set, so
    // the moment Recent started sorting by arrival it belonged to no band at all
    // and was reachable only by search. A booking that says when it is does not
    // need a second date typed on top of it to be worth surfacing.
    //
    // **Strictly future, and that is the whole guard.** `created` is the date the
    // scan read off the page, which for an ordinary receipt is the day it was
    // scanned. `>=` today would drop every receipt he files into a band about
    // what is coming.

    /// How far ahead Due shows as rows before parking the rest behind Later.
    ///
    /// **Fixed, not a setting.** A number he would set once and never revisit is
    /// the same trap as the per-document defer field this replaced. And the
    /// collapse below is what makes the exact value cheap: nothing is hidden by
    /// getting it wrong, only folded.
    private static let dueHorizonDays = 30

    /// The date a document is asking to be looked at, or nil if it is not asking.
    private func dueDate(for doc: TraceMacDocument) -> Date? {
        if let remind = doc.remindOn { return remind }
        let cal = Calendar.current
        if let created = doc.created,
           cal.startOfDay(for: created) > cal.startOfDay(for: Date()) {
            return created
        }
        return nil
    }

    private struct DueEntry: Identifiable {
        let document: TraceMacDocument
        let date: Date
        var id: UUID { document.id }
    }

    private var dueEntries: [DueEntry] {
        store.documents
            .compactMap { doc in dueDate(for: doc).map { DueEntry(document: doc, date: $0) } }
            .sorted { $0.date < $1.date }
    }

    private var dueHorizon: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: Self.dueHorizonDays,
                        to: cal.startOfDay(for: Date())) ?? Date()
    }

    private var dueNear: [DueEntry] { dueEntries.filter { $0.date <= dueHorizon } }
    private var dueLater: [DueEntry] { dueEntries.filter { $0.date > dueHorizon } }

    @ViewBuilder
    private var dueSection: some View {
        if !dueEntries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SatchelSectionTitle("Due")
                VStack(spacing: 0) {
                    ForEach(Array(dueNear.enumerated()), id: \.element.id) { idx, entry in
                        dueRow(entry)
                        if idx < dueNear.count - 1 || !dueLater.isEmpty {
                            Divider().overlay(Color.satchelHairline).padding(.leading, 59)
                        }
                    }
                    if !dueLater.isEmpty {
                        laterRow
                        if laterExpanded {
                            ForEach(dueLater) { entry in
                                Divider().overlay(Color.satchelHairline).padding(.leading, 59)
                                dueRow(entry)
                            }
                        }
                    }
                }
                .satchelCard()
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 14)
        }
    }

    private func dueRow(_ entry: DueEntry) -> some View {
        Button {
            path.append(SatchelDeepLink.document(entry.document.relativePath))
        } label: {
            HStack(spacing: 11) {
                SatchelDocumentMark(icon: entry.document.resolvedIcon,
                                    tint: entry.document.resolvedTint,
                                    size: 34, cornerRadius: 10, glyphSize: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.document.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.satchelInk)
                        .lineLimit(1)
                    Text(dueCaption(entry.date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(isOverdue(entry.date)
                                         ? Color.satchelPin : Color.satchelSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.satchelTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The parked tail of Due.
    ///
    /// **Folded, not hidden.** A hard cutoff would have emptied this band
    /// outright on the library that prompted the change - the three dated
    /// documents were 70, 77 and 240 days out, so any horizon under ten weeks
    /// showed nothing at all and there was no way to tell that from a band that
    /// had broken. A row carrying its own count can always be counted.
    private var laterRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { laterExpanded.toggle() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.satchelTertiary)
                    .rotationEffect(.degrees(laterExpanded ? 90 : 0))
                    .frame(width: 34)
                Text("Later")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.satchelSecondary)
                Text("\(dueLater.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.satchelTertiary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isOverdue(_ date: Date) -> Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }

    private func dueCaption(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: date)).day ?? 0
        let stamp = date.formatted(.dateTime.month(.abbreviated).day())
        if days < 0  { return "Overdue by \(-days) day\(days == -1 ? "" : "s") · \(stamp)" }
        if days == 0 { return "Today · \(stamp)" }
        return "In \(days) day\(days == 1 ? "" : "s") · \(stamp)"
    }

    // MARK: Recent

    /// Recent shows five. Everything else needs a door, and the Browse chips are
    /// not it: a document with no tags, no linked note and no Endeavor appears
    /// under none of them, so without this it was reachable only by search.
    /// David lost a document exactly this way — unpinning it dropped it out of
    /// Kit, it was not in the newest five, and it vanished from the app.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **Articles leave Recent** (D407), so the count beside it counts
            // what Recent actually holds. A "Show all 31" over a list that has
            // silently dropped nine articles is the header disagreeing with the
            // list under it. `Show all` itself still shows everything — that is
            // what it is for — and gains an Articles entry in its Format menu.
            SatchelCollapsibleSectionTitle(title: "Recent",
                                           isExpanded: $recentExpanded,
                                           collapsedCount: SatchelShelf.notOnShelf(store.documents).count) {
                if SatchelShelf.notOnShelf(store.documents).count > 5 {
                    NavigationLink {
                        SatchelAllDocumentsView(documents: store.documents, store: store)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Show all \(SatchelShelf.notOnShelf(store.documents).count)")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.satchelBlue)
                    }
                }
            }
            if recentExpanded {
                DocumentCard(documents: Array(SatchelShelf.notOnShelf(store.documents).prefix(5)), store: store)
            }
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 14)
    }

    // MARK: Capture FABs

    /// The blue one, and a smaller orange one beside it.
    ///
    /// **A second button rather than a mode, a menu entry or a toggle.** The
    /// long-press menu was the obvious cheap home for this and is the wrong one:
    /// scope §5 hides the three rare sources behind a hold precisely because
    /// they are rare, and a control you reach for while holding a bank statement
    /// must not be behind a gesture. David asked for a button and a button is
    /// right.
    ///
    /// Orange with a lock, matching the `private` tag on the Mac as of this
    /// session, so the button, the tag and the warning are one idea rather than
    /// three.
    private var captureButtons: some View {
        HStack(alignment: .bottom, spacing: 12) {
            privateButton
            scanButton
        }
    }

    private var privateButton: some View {
        VStack(spacing: 4) {
            Button {
                captureRequest = SatchelCaptureRequest(source: .scan, isPrivate: true)
            } label: {
                Image(systemName: "lock.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.orange, in: Circle())
                    .shadow(color: Color.orange.opacity(0.40), radius: 7, x: 0, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Private scan, nothing is sent")

            Text("PRIVATE")
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.3)
                .foregroundStyle(Color.satchelSecondary)
        }
        .padding(.bottom, 7)
    }

    private var scanButton: some View {
        VStack(spacing: 4) {
            Button {
                captureRequest = SatchelCaptureRequest(source: .scan)
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
                    captureRequest = SatchelCaptureRequest(source: .photo)
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                Button {
                    captureRequest = SatchelCaptureRequest(source: .library)
                } label: {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
                Button {
                    captureRequest = SatchelCaptureRequest(source: .file)
                } label: {
                    Label("Import File", systemImage: "folder")
                }
                // Session 102 (D386): the Stash idea. One motion from the
                // clipboard, no questions; the capture sheet opens on the
                // result the way it does for a share.
                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            }
            .alert("Nothing to paste", isPresented: $showPasteEmpty) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Copy a link, some text or a picture first.")
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
/// What "search" means for a document, in one place.
///
/// **Added 2026-07-30 because two things were wrong.** The Library and the All
/// Documents screen had *separate* predicates that had already drifted — the
/// Library matched the Endeavor name, All Documents did not — so a search could
/// find something on one screen and miss it on the other.
///
/// And both missed the fields most likely to be typed. David has a business card
/// filed against `Notes/People/Mitch Weiss.md`; searching "mitch" found nothing,
/// because the linked note and the `people` field were never searched. The person
/// is often the ONLY thing you remember about a document.
///
/// The linked note is matched on its display name, not its path: nobody types
/// "Notes/People/", and matching the raw path would let "notes" match every
/// document in the library.
// `SatchelDocumentSearch` lived here until 2026-08-24. It is now
// `DocumentSearch` in `Trace/DocumentSearchPredicate.swift`, shared with
// TraceMac through `membershipExceptions` — one predicate rather than two kept
// in step by hand. See that file's header for what the hand-keeping cost.

struct DocumentCard: View {
    let documents: [TraceMacDocument]
    let store: iOSDocumentStore

    @State private var pendingDelete: TraceMacDocument?
    /// Session 78 — live leftward slide per row, the pin-to-Kit reveal.
    @State private var rowDragOffsets: [UUID: CGFloat] = [:]
    /// The document a task is being written for, or nil. Session 100, D382 —
    /// the rightward half of the same slide.
    @State private var taskFor: TraceMacDocument?
    /// The document whose Edit screen the long press asked for (D389).
    @State private var editing: TraceMacDocument?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(documents.indices, id: \.self) { index in
                // Scope §5: "Viewer — full screen, direct tap from any row."
                // A row tap opens the document itself, never its metadata.
                NavigationLink {
                    SatchelOpenView(document: documents[index], store: store)
                } label: {
                    DocumentRow(document: documents[index])
                }
                .buttonStyle(.plain)
                // Session 78: LEFT-swipe pins to Kit (David's ask) — the
                // Dayflow row-reveal pattern mirrored. These rows sit in a
                // VStack, not a List, so `.swipeActions` is unavailable (the
                // delete contextMenu below records that); a custom drag with
                // the pin glyph rising at the trailing edge speaks the same
                // language as the task rows' calendar reveal. Toggles: an
                // already-pinned document shows pin.slash and unpins.
                .offset(x: rowDragOffsets[documents[index].id] ?? 0)
                .background(alignment: .trailing) {
                    let progress = min(max(-(rowDragOffsets[documents[index].id] ?? 0) / 60, 0), 1)
                    if progress > 0 {
                        Image(systemName: documents[index].pinned ? "pin.slash.fill" : "pin.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.satchelPin)
                            .opacity(Double(progress))
                            .scaleEffect(0.7 + 0.3 * progress)
                            .padding(.trailing, 14)
                    }
                }
                // **The other direction, and it had to be the other direction**
                // (D382). Left is already pin-to-Kit and has been since Session
                // 78; a second meaning on one gesture would be a coin toss at the
                // moment of release. Right reveals at the leading edge, so which
                // glyph appears says which way he is going before he lets go.
                .background(alignment: .leading) {
                    let progress = min(max((rowDragOffsets[documents[index].id] ?? 0) / 60, 0), 1)
                    if progress > 0 {
                        Image(systemName: "checklist")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.satchelBlue)
                            .opacity(Double(progress))
                            .scaleEffect(0.7 + 0.3 * progress)
                            .padding(.leading, 14)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 28)
                        .onChanged { value in
                            let h = value.translation.width
                            guard abs(h) > abs(value.translation.height) else { return }
                            rowDragOffsets[documents[index].id] = h < 0 ? max(h, -80) : min(h, 80)
                        }
                        .onEnded { value in
                            let h = value.translation.width
                            withAnimation(.spring(duration: 0.3)) {
                                rowDragOffsets[documents[index].id] = 0
                            }
                            guard abs(h) > abs(value.translation.height) * 1.5 else { return }
                            if h < -40 {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                togglePin(documents[index])
                            } else if h > 40 {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                taskFor = documents[index]
                            }
                        }
                )
                // Long press, not swipe. These rows sit inside a plain VStack
                // rather than a List, so `.swipeActions` is unavailable, and a
                // context menu is the honest alternative — it also puts the
                // confirmation one step further from a stray thumb than a swipe
                // would, which suits an action that destroys a file.
                // The swipe is the fast path; this is the discoverable one.
                // A gesture with no visible counterpart is a feature only the
                // person who built it knows about. Grown into the document's
                // card (D389): preview, then Open (links), task, Edit, pin,
                // delete. Shared with the grid tile.
                .satchelDocumentMenu(documents[index],
                                     onTask: { taskFor = documents[index] },
                                     onEdit: { editing = documents[index] },
                                     onPin: { togglePin(documents[index]) },
                                     onDelete: { pendingDelete = documents[index] },
                                     onRetry: {
                                         let doc = documents[index]
                                         Task {
                                             await SatchelArticleSweep.retry(
                                                 doc, store: store, noteStore: NoteStore.shared)
                                         }
                                     })

                if index < documents.count - 1 {
                    Divider()
                        .overlay(Color.satchelHairline)
                        .padding(.leading, 66)
                }
            }
        }
        .satchelCard()
        .sheet(item: $taskFor) { doc in
            SatchelTaskCard(document: doc)
        }
        .sheet(item: $editing) { doc in
            NavigationStack {
                SatchelDocumentDetailView(document: doc, store: store)
            }
        }
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

    private func togglePin(_ doc: TraceMacDocument) {
        _ = try? store.setPinned(!doc.pinned, for: doc)
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
                HStack(spacing: 5) {
                    // David: *"there is no way to see which are private without
                    // opening each one which is not like the good visual i have
                    // on Mac."* On the title line rather than among the chips,
                    // because it is a property of the document rather than one
                    // more thing it is filed under, and because a row is scanned
                    // left to right and this is the thing to notice first.
                    if SatchelPrivateTag.isPrivate(document) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    Text(document.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.satchelInk)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    SatchelChip(filing: SatchelFiling.of(document))
                    Text(kindLabel(for: document))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.satchelSecondary)
                }
                // **"read Sep 13", under the title** (D407). An article he has
                // finished leaves the Shelf entirely, so without this the only
                // difference between "read it" and "never saved it" is that one
                // of them is still in the library. Drawn as its own faint line
                // rather than another chip: it is not something the document is
                // filed under, it is something he did.
                if let read = SatchelShelf.readLine(document) {
                    Text(read)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.satchelTertiary)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                // **Arrival, not the printed date** (D381). The list is ordered by
                // when things landed, so the label has to say the same thing or
                // the order reads as random. What the document itself says is
                // shown by the Due caption and by the viewer.
                Text(relativeDateLabel(document.listDate))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.satchelTertiary)
                // Session 78: a Kit member says so on the row, matching the
                // new swipe — without this the flag was invisible outside
                // the Kit grid.
                if document.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.satchelPin)
                }
            }
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
    // A link says where it goes rather than "WEBLOC" (D384).
    if document.isLink {
        if let web = TraceMacDocument.openableURL(document.url) { return TraceMacDocument.webLabel(web) }
        return "Link"
    }
    if document.isText { return "Text" }
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
// MARK: - Short names for the colour axis
//
// Session 73. The colour axis reaches the phone as Browse chips, and a chip is
// about eleven characters wide. `DocumentTint.typeMeaning` is a sentence —
// "Receipt, bill, proof of payment" — which is right for the scan prompt and
// for the Mac pane's list, and impossible here.
//
// **These six words are new vocabulary and they are chosen to collide with
// nothing.** No `DocumentIcon` label is Paid, Booked, Official, Reference,
// Personal or Untyped — which matters most for green: calling it "Receipts"
// would put it a thumb away from the `receipt` SUBJECT chip, two chips reading
// the same and filtering differently.
//
// The long press every chip already has reveals the full sentence, and the
// filtered screen is titled with it, so nothing is lost by shortening.
//
// The wider naming collision this note used to describe — "type" meaning the
// icon here and the colour on the Mac — was resolved later the same session.
// See the Subject / Kind / Format note above `browseSection`.
extension DocumentTint {
    var satchelShortLabel: String {
        switch self {
        case .green:  return "Paid"
        case .blue:   return "Booked"
        case .indigo: return "Official"
        case .teal:   return "Reference"
        case .rose:   return "Personal"
        case .gray:   return "Untyped"
        case .amber:  return "Private"
        case .red:    return "Needs action"
        }
    }

    /// What the long press reveals, and what the filtered screen is titled.
    var satchelLongLabel: String { typeMeaning ?? satchelShortLabel }
}

struct SatchelBrowseChip: View {
    var type: DocumentIcon? = nil
    /// The colour axis. Draws a plain swatch rather than a glyph — the whole
    /// point of this chip is that colour IS the content, so putting an icon in
    /// it would say the subject axis is answering again.
    var tint: DocumentTint? = nil
    var label: String = ""
    let count: Int
    var endeavor: Bool = false
    /// The "All subjects" chip — swaps the mark for a grid glyph and adds a chevron,
    /// so the door to the full list does not look like just another type.
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if let type {
                SatchelDocumentMark(icon: type, tint: type.defaultTint,
                                    size: 26, cornerRadius: 8, glyphSize: 14)
            } else if let tint {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(tint.foreground.opacity(0.45), lineWidth: 1.5)
                    }
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: showsChevron ? "square.grid.2x2" : "briefcase.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(showsChevron ? Color.satchelSecondary : Color.satchelAuto)
                    .frame(width: 26, height: 26)
                    .background(showsChevron ? Color.satchelFill : DocumentTint.indigo.background,
                                in: RoundedRectangle(cornerRadius: 8))
            }

            Text(type?.label ?? tint?.satchelShortLabel ?? label)
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

// MARK: - Chip tap and long-press
//
// David, 2026-08-01: *"Could we long press on any pill and the full name is
// revealed? Is that an approach while pressing without long press still works?"*
//
// First attempt hung a `.simultaneousGesture` off the `NavigationLink`. It read
// correctly and behaved wrongly, which he caught immediately: *"the long press
// shows the full name but when i release I am brought to that filter… The way it
// is now defeats the purpose since i could just go the filter anyway."*
//
// **`simultaneousGesture` means simultaneous.** Both recognizers fire. It is the
// right tool for adding a gesture that should coexist with a button's tap, and
// the wrong one when the new gesture must *replace* the tap for that press.
//
// A `NavigationLink` owns its tap and will not give it up, so the chips are no
// longer links. The push is driven from `chipRoute` and a
// `.navigationDestination(item:)`, which frees the chip to be a plain view
// carrying `.onTapGesture` and `.onLongPressGesture`. Those two DO arbitrate:
// hold past the threshold and the tap is cancelled, release early and the long
// press never fires. One or the other, which is what was asked for.
//
// A popover rather than a tooltip: it points at the chip you pressed, so there is
// no doubt which name you are reading, and it dismisses by tapping anywhere.
// `presentationCompactAdaptation(.popover)` is load-bearing — without it iPhone
// serves a popover as a half-height sheet, which for four words would be absurd.
//
// On every chip, not only the long ones. Types truncate too (`Doc…`, `Rece…`),
// and a gesture that works on some chips is worse than one that works on none:
// the ones it fails on read as broken rather than as short.

private extension View {
    func chipGestures(id: String, name: String, count: Int,
                      revealed: Binding<String?>,
                      onTap: @escaping () -> Void) -> some View {
        // The chip's own background does not cover the grid cell's full width,
        // and a gap that does not respond reads as a dead chip.
        contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.45) {
                revealed.wrappedValue = id
            }
            .popover(isPresented: Binding(
                get: { revealed.wrappedValue == id },
                set: { if !$0 { revealed.wrappedValue = nil } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Color.satchelInk)
                    Text(count == 1 ? "1 document" : "\(count) documents")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.satchelSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .presentationCompactAdaptation(.popover)
            }
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

// MARK: - People picker
//
// 2026-08-27. List-only, from `PeopleIndex` (the Notion People list mirrored
// into the App Group by Trace and Dayflow). David: *"list only on the phone …
// I dont want a loose string"* — a name that matches nobody links to nothing.
// The way out when someone is missing is a button to Trace's add-person sheet,
// not a text field.

struct SatchelPeoplePickerView: View {
    @Binding var selected: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    private let entries = PeopleIndex.read()

    private var filtered: [PeopleIndex.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    Text("No people yet. Open Trace once so its People list reaches Satchel.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.satchelSecondary)
                }
                ForEach(filtered) { person in
                    let isOn = selected.contains { $0.caseInsensitiveCompare(person.name) == .orderedSame }
                    Button {
                        if isOn { selected.removeAll { $0.caseInsensitiveCompare(person.name) == .orderedSame } }
                        else { selected.append(person.name) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name).foregroundStyle(.primary)
                                if let r = person.relationship, !r.isEmpty {
                                    Text(r).font(.caption).foregroundStyle(Color.satchelSecondary)
                                }
                            }
                            Spacer()
                            if isOn { Image(systemName: "checkmark").foregroundStyle(Color.satchelAI) }
                        }
                    }
                }
                Section {
                    Button {
                        // `trace://addperson` is an existing Trace route. Trace
                        // opens on its add-person sheet; the next Trace launch
                        // refreshes the mirror and the name is here.
                        if let url = URL(string: "trace://addperson") { openURL(url) }
                    } label: {
                        Label("Not here? Add in Trace", systemImage: "person.badge.plus")
                            .foregroundStyle(Color.satchelAI)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search people")
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// This is the prerequisite for scope §7 — Trace cannot retire its Add Document
// flow until Satchel can create the link that flow currently creates.

struct SatchelNotePickerView: View {
    @Binding var linkedNote: String?
    @Environment(\.dismiss) private var dismiss

    @State private var noteStore = NoteStore.shared
    @State private var query = ""

    /// The note folders worth filing a document against, as (section title,
    /// container-relative folder).
    ///
    /// `Notes/Inbox` is deliberately absent — it is a staging area, and filing a
    /// permanent document to a place things are meant to leave is a trap.
    ///
    /// **`Calendar` is not under `Notes/`.** Dayflow writes day notes to
    /// `Calendar/<date>.md` at the container root, not `Notes/Journal/`, which
    /// is why this is a list of paths rather than a list of names. The
    /// `Trace-Backlog.md` E-CHIP entry had the wrong path for a while; this is
    /// the real one.
    private static let folders: [(title: String, path: String)] = [
        ("Day notes", "Calendar"),
        // Added 2026-07-29 with the Endeavor first pass. Filing a document to a
        // trip is the motivating case for Endeavors existing at all — the
        // boarding pass and the hotel confirmation are the whole reason Kit
        // folds a trip's documents in while it is running (scope §5). Listed
        // second, under day notes, because those are the two that get filed to
        // most often.
        ("Endeavors", "Notes/Endeavors"),
        ("Projects",  "Notes/Projects"),
        ("Places",    "Notes/Places"),
        ("People",    "Notes/People"),
        ("Horizons",  "Notes/Horizons"),
    ]

    /// Un-searched, day notes are capped at the most recent handful. There is one
    /// per day forever, so the honest flat list is hundreds of rows of dates —
    /// which is why this section was left out entirely until now, and why the
    /// answer is a cap plus search rather than a longer list. Type any part of a
    /// date ("2026-03", "03-14") and the cap lifts for the matches.
    private static let dayNoteLimit = 8

    private var groups: [(String, [String])] {
        Self.folders.compactMap { section in
            var names = ((try? noteStore.listFiles(in: section.path)) ?? [])
                .filter { $0.hasSuffix(".md") }
                .map { ($0 as NSString).deletingPathExtension }
                .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }

            if section.path == "Calendar" {
                // Newest first — a document being filed to a day note is nearly
                // always today's or yesterday's.
                names.sort(by: >)
                if query.isEmpty { names = Array(names.prefix(Self.dayNoteLimit)) }
            } else {
                names.sort()
            }

            return names.isEmpty ? nil : (section.path, names)
        }
    }

    /// Section heading for a folder path. Kept separate from the path so the
    /// heading can read "Day notes" while the rows build `Calendar/…`.
    private func sectionTitle(for path: String) -> String {
        Self.folders.first { $0.path == path }?.title ?? path
    }

    /// Day notes are named by their date, so the raw filename reads as a stray
    /// timestamp in a list. `noteDisplayName` already solves this everywhere else
    /// — reused here rather than re-derived, so the picker row, the Filed-to row
    /// and the capture form cannot disagree about what a note is called.
    private func rowLabel(folder: String, name: String) -> String {
        noteDisplayName("\(folder)/\(name).md") ?? name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    clearRow

                    ForEach(groups, id: \.0) { folder, names in
                        VStack(alignment: .leading, spacing: 0) {
                            SatchelSectionTitle(sectionTitle(for: folder))
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
        // `folder` is already container-relative — "Calendar" or "Notes/Places" —
        // so it is NOT prefixed with "Notes/" here. Getting this wrong writes a
        // `linked_note` that renders fine inside Satchel and matches nothing on
        // the reverse lookup, so the chip never appears and nothing explains why.
        let path = "\(folder)/\(name).md"
        let isDay = folder == "Calendar"
        return VStack(spacing: 0) {
            Button {
                linkedNote = path
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isDay ? "calendar" : "note.text")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.satchelBlue)
                        .frame(width: 24)
                    Text(rowLabel(folder: folder, name: name))
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

/// Which app owns a note, and the URL that opens it there — the return leg of
/// the cross-app model.
///
/// Trace and Dayflow can already reach into Satchel (`satchel://document?path=`),
/// and Satchel records which note every document belongs to, but until now there
/// was no way back: tapping the linked note opened the picker to CHANGE it, and
/// getting to the person meant leaving the app and finding them by hand.
///
/// **Satchel does not display notes and must not start.** It hands the path to
/// whichever app owns that part of the tree, exactly as Trace hands documents the
/// other way. Ownership is by path prefix, matching who writes each folder:
/// Trace authors Place and Person notes, Dayflow authors day and project notes.
///
/// Returns nil for anything that cannot be opened, so no dead button is drawn.
///
/// **Dayflow's half arrived 2026-07-29 (backlog E35).** Day notes, Endeavors and
/// project notes now offer "Open in Dayflow"; before that they returned nil,
/// deliberately, rather than offering a button that opens the app and lands
/// nowhere.
///
/// `Notes/Horizons/` still returns nil: weekly and monthly notes have no deep
/// link on the Dayflow side, and half a hand-off is worse than none. Recorded in
/// E35 rather than guessed at here.
///
/// THE PREFIX LIST IS THE CONTRACT. Adding a prefix here without adding the
/// matching branch to `DayflowContentView.resolveNoteRoute()` draws a button that
/// opens Dayflow and does nothing, which is precisely the failure this function
/// was written to prevent.
/// The jump to an Endeavor's own note, keyed by slug rather than path.
///
/// Separate from `noteOwnerAppURL` because it answers a different field: that one
/// reads `linked_note`, this one reads `endeavor`. A document can have both — a
/// business card linked to a person AND filed to a trip — and each deserves its
/// own way back. Conflating them is what made "Open in Dayflow" appear missing
/// when it was simply reading the other field.
func endeavorAppURL(for endeavorID: String?) -> URL? {
    guard let endeavorID, !endeavorID.isEmpty else { return nil }
    var comps = URLComponents()
    comps.scheme = "dayflow"
    comps.host = "endeavor"
    comps.queryItems = [URLQueryItem(name: "id", value: endeavorID)]
    return comps.url
}

func noteOwnerAppURL(for path: String?) -> (label: String, url: URL)? {
    guard let path, !path.isEmpty else { return nil }

    let scheme: String
    let label: String

    if path.hasPrefix("Notes/People/") || path.hasPrefix("Notes/Places/") {
        scheme = "trace"
        label = "Open in Trace"
    } else if path.hasPrefix("Calendar/")
                || path.hasPrefix("Notes/Endeavors/")
                || path.hasPrefix("Notes/Projects/") {
        scheme = "dayflow"
        label = "Open in Dayflow"
    } else {
        return nil
    }

    var comps = URLComponents()
    comps.scheme = scheme
    comps.host = "note"
    // `URLComponents`, not interpolation — "Gayle & Harvey Weiss.md" carries both
    // a space and an ampersand, and an unescaped one truncates the path.
    comps.queryItems = [URLQueryItem(name: "path", value: path)]
    guard let url = comps.url else { return nil }
    return (label, url)
}

// MARK: - Type index
//
// The door behind `All subjects`. Every subject in use, alphabetical, with counts.
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
        .navigationTitle("All subjects")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Endeavor index
//
// The door behind `All trips`. Every Endeavor that has documents, newest trip
// first, with its dates and a count.
//
// **Newest first, not alphabetical — unlike the type index next to it.** That one
// is scanned by name, because you arrive already knowing you want "Receipts".
// This one is read as a history: you come here to find the trip, and trips are
// remembered by when they were, not by their initial. It is the answer to
// David's *"a way to look at past trips and the documents that are associated"*.
//
// Endeavors with NO documents are absent, the same rule the type chips follow —
// an empty drawer only teaches you the list is unreliable. So this is a list of
// trips that have paperwork, not a list of trips.
//
// A document can also outlive its Endeavor note. Those rows keep the name the
// sidecar recorded and sort last, because the documents are still real and still
// need a way back to each other.

struct SatchelEndeavorIndexView: View {
    let documents: [TraceMacDocument]
    let store: iOSDocumentStore
    let endeavorStore: SatchelEndeavorStore

    private struct Row: Identifiable {
        let id: String
        let name: String
        let count: Int
        let trip: Endeavor?
        /// `nil` when the Endeavor note is gone. Sorts last.
        var sortDate: Date? { trip?.end ?? trip?.start }
    }

    private var rows: [Row] {
        var counts: [String: (String, Int)] = [:]
        for doc in documents {
            guard let id = doc.endeavor else { continue }
            counts[id] = (doc.endeavorName ?? counts[id]?.0 ?? "Endeavor",
                          (counts[id]?.1 ?? 0) + 1)
        }
        return counts
            .map { Row(id: $0.key, name: $0.value.0, count: $0.value.1,
                       trip: endeavorStore.endeavor(id: $0.key)) }
            .sorted { a, b in
                switch (a.sortDate, b.sortDate) {
                case let (l?, r?): return l > r
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
    }

    /// "31 Jul 2026", or "4 – 13 Oct 2026" when the trip spans days. Absolute,
    /// never relative: `kitTimingPhrase` says "ended yesterday", which is the
    /// right thing on a shelf of documents you are holding and the wrong thing in
    /// a list of trips from the last two years.
    private func dateCaption(_ trip: Endeavor?) -> String? {
        guard let trip, let start = trip.start ?? trip.end else { return nil }
        let end = trip.end ?? start
        let cal = Calendar.current
        let day = DateFormatter()
        day.dateFormat = "d MMM yyyy"
        if cal.isDate(start, inSameDayAs: end) { return day.string(from: start) }
        let short = DateFormatter()
        short.dateFormat = cal.isDate(start, equalTo: end, toGranularity: .month)
            ? "d" : "d MMM"
        return "\(short.string(from: start)) – \(day.string(from: end))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    NavigationLink {
                        SatchelAllDocumentsView(documents: documents, store: store,
                                                endeavorID: row.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "briefcase.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.satchelAuto)
                                .frame(width: 34, height: 34)
                                .background(DocumentTint.indigo.background,
                                            in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Color.satchelInk)
                                    .lineLimit(1)
                                if let caption = dateCaption(row.trip) {
                                    Text(caption)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.satchelSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text("\(row.count)")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.satchelSecondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.satchelTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < rows.count - 1 {
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
        .navigationTitle("All trips")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Full Kit
//
// Build step 7. Frame 2 of the mockup: two labelled groups, rows rather than
// tiles, Edit for reorder and unpin, and a note on the trip group stating it
// clears a day after the trip ends and the documents stay in the Endeavor.
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
        // "when \(name) ends" was true until Kit gained a one-day tail. It now
        // clears the day AFTER, which is the whole point of the tail — the return
        // leg is flown and the last receipts collected on the final day.
        text += "Clears on its own a day after \(name) ends; the documents stay in the Endeavor."
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
            SatchelOpenView(document: entry.document, store: store)
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
    @Environment(\.openURL) private var openURL
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
    /// Optional hint for the AI, and for the on-device pass. See `rescanButton`.
    @State private var userContext = ""
    /// Sidecar `remind:`. See `remindField`.
    @State private var remindOn: Date? = nil
    /// Sidecar `people:`, list-only. See `peopleField`.
    @State private var people: [String] = []
    @State private var peopleAIFilled = false
    @State private var showPeoplePicker = false
    /// The document's own date (`created` in the sidecar, "Added" on screen
    /// until now). The scan fills it from the printed date; see `dateField`.
    @State private var docDate: Date = Date()
    @State private var dateAIFilled = false
    /// The AI set `remindOn` on the last scan; cleared the moment he edits it.
    @State private var remindAIFilled = false
    private enum ReminderState: Equatable { case idle, working, added, failed(String) }
    @State private var reminderState: ReminderState = .idle
    @State private var scanError: String?
    /// Raised when the AI button is pressed on a document tagged `private`.
    @State private var showPrivatePrompt = false
    @State private var showPrivateSummaryPrompt = false
    @State private var note = ""
    @State private var isSummarising = false
    @State private var summaryError: String?
    /// Web addresses found in `## Text`. **Derived on every load, never
    /// stored** -- see `MacTextExtraction.links(in:)`. Held in state rather
    /// than computed in `body` because `body` re-renders on every keystroke in
    /// the title field and the detector is not free.
    @State private var links: [URL] = []
    /// Sidecar `url:` - one web address he typed himself. See `urlField`, and
    /// note that it is the opposite of `links` above: that one is recomputed
    /// from the page every load, this one cannot be recomputed at all.
    @State private var docURL = ""

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
                peopleField
                dateField
                remindField
                linksField
                urlField
                tasksField
                // "Filed to" sits ABOVE the typed note and Summary as of
                // 2026-07-28. It used to be second from the bottom, next to
                // Delete, which meant anyone looking for "how do I link this to
                // a person" hit `noteField` first, found a free-text box, and
                // concluded there was no link control. Cost David a real test
                // session on device.
                filedToField
                noteField
                summaryField
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
        // Extraction can land while this screen is open -- a scan that arrives
        // during `extractTextForNewArrivals` refreshes the store underneath us.
        // Without this the Links row would be right only for documents whose
        // text was already on disk when the screen opened.
        .onChange(of: current.extractedText) { _, new in
            links = MacTextExtraction.links(in: SatchelArticleText.withoutImages(new))
        }
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
                                    if SatchelPrivateTag.matches(tag) {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 8, weight: .bold))
                                    }
                                    Text(tag)
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SatchelPrivateTag.tint(
                                    tag, base: Color(red: 0.420, green: 0.420, blue: 0.439)))
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

    // MARK: Links

    /// Web addresses read off the scan.
    ///
    /// David: *"I have a lot of urls that are part of scans... Id like the url
    /// if it is something picked up in the scan it would show up as a field in
    /// the document like the other fields like a person or an endeavor."*
    ///
    /// **Derived, not stored.** No frontmatter key, no parser change, no
    /// migration, and it cannot go stale because it is recomputed from the text
    /// it came from. Detection is `NSDataDetector`, entirely local, so this
    /// works on a `private` document exactly as it does on any other.
    ///
    /// The row is absent when there are none rather than showing an empty card:
    /// most documents have no links and a permanent "None" is a line of noise
    /// on every receipt.
    ///
    /// Same shape and the same teal on the Mac panel, so the two apps show one
    /// feature rather than two.
    // MARK: People

    private var peopleField: some View {
        field("People") {
            VStack(alignment: .leading, spacing: 8) {
                if !people.isEmpty {
                    SatchelFlowLayout {
                        ForEach(people, id: \.self) { name in
                            Button {
                                people.removeAll { $0 == name }
                                peopleAIFilled = false
                                dirty = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.fill").font(.system(size: 9))
                                    Text(name)
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.satchelAI.opacity(0.10), in: Capsule())
                                .foregroundStyle(Color.satchelAI)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Button {
                        showPeoplePicker = true
                    } label: {
                        Label(people.isEmpty ? "Add a person" : "Add another", systemImage: "person.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.satchelAI)
                    }
                    .buttonStyle(.plain)
                    if peopleAIFilled {
                        Text("AI")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.satchelAI.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.satchelAI)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .satchelCard()
            .sheet(isPresented: $showPeoplePicker, onDismiss: { dirty = true }) {
                SatchelPeoplePickerView(selected: $people)
            }
        }
    }

    // MARK: Date
    //
    // The date the document is ABOUT, not when it was scanned: a meal receipt
    // is the night of the meal. Filled by the scan (`dated`), editable here,
    // stored as the sidecar's `created`. Distinct from Remind on purpose — a
    // past date is not a reminder, and David agreed it should not be.
    private var dateField: some View {
        field("Date") {
            HStack(spacing: 10) {
                DatePicker("", selection: Binding(
                    get: { docDate },
                    set: { docDate = $0; dateAIFilled = false; dirty = true }
                ), displayedComponents: .date)
                .labelsHidden()
                if dateAIFilled {
                    Text("AI")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.satchelAI.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.satchelAI)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .satchelCard()
        }
    }

    // MARK: Remind
    //
    // 2026-08-27. The CD One receipt said "Ready On: Saturday 8/15" and nothing
    // read it. The scan now fills `remind:`; this row shows it, lets him fix
    // or clear it, and hands it to Apple's Reminders through the same
    // `ReminderService` Dayflow's Endeavor screen already uses (list "Trace",
    // 9am alarm, link tracked so completing round-trips). David: *"I would like
    // a way to surface this on my daily note of Dailyflow and ideally in a
    // task app."* The day note half lives in `SatchelDocumentChips`.
    private var remindField: some View {
        field("Remind") {
            VStack(alignment: .leading, spacing: 8) {
                remindRow
                // With or without a date. Undated, it lands in the Trace list
                // with no day and no alarm — Reminders' inbox shape. David,
                // 2026-08-27, after asking whether he had to add a date first.
                reminderButton(for: remindOn)
            }
        }
    }

    /// The date itself: picker + AI badge + clear, or "Add a date".
    private var remindRow: some View {
        HStack(spacing: 10) {
            if let remindOn {
                DatePicker("", selection: Binding(
                    get: { remindOn },
                    set: { self.remindOn = $0; remindAIFilled = false; dirty = true }
                ), displayedComponents: .date)
                .labelsHidden()
                if remindAIFilled {
                    Text("AI")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.satchelAI.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.satchelAI)
                }
                Spacer()
                Button {
                    self.remindOn = nil
                    remindAIFilled = false
                    dirty = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.satchelSecondary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    remindOn = Calendar.current.startOfDay(for: Date())
                    dirty = true
                } label: {
                    Label("Add a date", systemImage: "bell")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.satchelAI)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .satchelCard()
    }

    /// "Add to Reminders" / "In Reminders", plus the failure line. Split out of
    /// `remindField` so the builder stays simple enough to type-check — the
    /// first version put the `let`s inline and the compiler gave up on it.
    @ViewBuilder
    private func reminderButton(for date: Date?) -> some View {
        let key = "document|\(current.relativePath)"
        let already = ReminderService.isLinked(key) || reminderState == .added
        Button {
            addToReminders(on: date, key: key)
        } label: {
            HStack(spacing: 7) {
                if reminderState == .working {
                    ProgressView().controlSize(.small)
                    Text("Adding…")
                } else {
                    Image(systemName: already ? "checkmark" : "bell.badge")
                        .font(.system(size: 12, weight: .semibold))
                    Text(already ? "In Reminders" : (date == nil ? "Add to Reminders, no date" : "Add to Reminders"))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(already ? Color.satchelSecondary : Color.satchelAI)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .satchelCard()
        }
        .buttonStyle(.plain)
        .disabled(already || reminderState == .working)
        if case .failed(let why) = reminderState {
            Text(why)
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .padding(.horizontal, 4)
        }
    }

    /// One reminder per document, in the Trace list, due that day with the 9am
    /// alarm `ReminderService` adds. The note carries the Satchel link so the
    /// reminder opens the receipt. Saves first, so the date on disk is the
    /// date in Reminders.
    private func addToReminders(on date: Date?, key: String) {
        save()
        let doc = current
        reminderState = .working
        Task {
            do {
                let id = try await ReminderService.add(
                    title: doc.title,
                    due: date,
                    // Built here rather than via `TraceSatchelHandoff.documentURL`,
                    // which is Trace's and Dayflow's half of the hand-off and is
                    // not compiled into this target. Same shape, same parser on
                    // the receiving side (`SatchelRouter`).
                    notes: Self.documentLink(path: doc.relativePath))
                ReminderService.link(id, to: key)
                reminderState = .added
            } catch ReminderService.Failure.denied {
                reminderState = .failed("Satchel does not have access to Reminders. Settings › Privacy › Reminders.")
            } catch {
                reminderState = .failed("Could not add the reminder.")
            }
        }
    }

    private static func documentLink(path: String) -> String? {
        var comps = URLComponents()
        comps.scheme = "satchel"
        comps.host = "document"
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        return comps.url?.absoluteString
    }

    @ViewBuilder
    private var linksField: some View {
        if !links.isEmpty {
            field("Links") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(links, id: \.absoluteString) { url in
                        Button { openURL(url) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.teal)
                                Text(TraceMacDocument.webLabel(url))
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Color.satchelInk)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.satchelSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .satchelCard()
            }
        }
    }


    // MARK: URL

    /// One web address the document is ABOUT, typed by hand (D350, iOS half).
    ///
    /// **Directly under Links, and that adjacency is the explanation.** The row
    /// above is every address printed ON the page, recomputed on every load and
    /// stored nowhere. This one is a fact about the document that the document
    /// does not contain - the shuttle timetable with no booking site anywhere in
    /// its own text - so nothing can recompute it and it has to be written down.
    /// Two rows that look alike and are opposites: side by side, the difference
    /// is at least visible.
    ///
    /// **The open button appears only when the text can actually be opened**,
    /// tested on what he typed rather than assumed from a field named URL. A
    /// button that is always there and does nothing for half its life claims
    /// this is a link before anything has established that it is one. The test
    /// is `TraceMacDocument.openableURL`, the same one the Mac row asks.
    private var urlField: some View {
        field("URL") {
            HStack(spacing: 10) {
                TextField("https://", text: $docURL)
                    .font(.system(size: 13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: docURL) { _, _ in dirty = true }

                if let open = TraceMacDocument.openableURL(docURL) {
                    Button { openURL(open) } label: {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.teal)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .satchelCard()
        }
    }

    // MARK: Tasks (Session 81, D234 — the iOS half of D230)

    /// Between Links and Filed-to: the band is about what the document NEEDS,
    /// not where it lives. Reads `current`, so a rescan or retitle underneath
    /// does not strand it on a stale path. Reasoning in SatchelDocTasksPanel.
    private var tasksField: some View {
        SatchelDocTasksPanel(document: current)
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
                    // **The third AI button in this app, and the one nobody had
                    // thought about.** It now asks the same question the other
                    // two do — and the service refuses regardless, so this is
                    // the explanation rather than the defence.
                    if isPrivate { showPrivateSummaryPrompt = true }
                    else { Task { await summarise(using: store) } }
                } label: {
                    HStack(spacing: 7) {
                        if isSummarising {
                            ProgressView().controlSize(.small)
                            Text("Reading the whole document…")
                        } else {
                            Image(systemName: isPrivate ? "lock.fill" : "text.append")
                                .font(.system(size: 12, weight: .semibold))
                            Text(isPrivate
                                 ? "Private. Nothing has been sent"
                                 : (current.summary.isEmpty ? "Summarise this document" : "Summarise again"))
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSummarising ? Color.satchelSecondary
                                     : (isPrivate ? Color.orange : Color.satchelAI))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSummarising || store == nil)
                .confirmationDialog("Send this private document to the AI?",
                                    isPresented: $showPrivateSummaryPrompt,
                                    titleVisibility: .visible) {
                    Button("Send and remove private tag", role: .destructive) {
                        tags.removeAll { $0.caseInsensitiveCompare("private") == .orderedSame }
                        dirty = true
                        save()
                        if let store { Task { await summarise(using: store) } }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Summarising sends the whole document to the AI. That removes "
                         + "the private tag permanently and makes it readable by Ask.")
                }

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
                    // Computed ONCE. Called per-use it would run the scan three
                    // times a body pass and, worse, could straddle midnight
                    // between calls and disagree with itself about which list a
                    // trip belongs in.
                    let filing = endeavorStore.filingChoices()
                    Button("None") { endeavorID = nil; endeavorName = nil; dirty = true }
                    ForEach(filing.current) { endeavor in
                        Button(endeavor.name) {
                            endeavorID = endeavor.id
                            endeavorName = endeavor.name
                            dirty = true
                        }
                    }
                    // Demoted, not removed — see SatchelCaptureView's copy of this
                    // menu and `filingTailDays` for why.
                    if !filing.past.isEmpty {
                        Menu("Past") {
                            ForEach(filing.past) { endeavor in
                                Button(endeavor.name) {
                                    endeavorID = endeavor.id
                                    endeavorName = endeavor.name
                                    dirty = true
                                }
                            }
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

                // The way to the Endeavor's own note. Added 2026-07-29 after
                // David filed a document to Japan and saw no "Open in Dayflow" —
                // correctly, because `noteOwnerAppURL` reads `linked_note`, and
                // that document's linked note was a PERSON. **Filing to an
                // Endeavor and linking a note are two different fields**, and
                // only the second had a way back. An Endeavor is a note too, and
                // "boarding pass → the Japan note" was the motivating case for
                // Endeavors existing at all.
                //
                // Routed BY ID, not by path: `dayflow://endeavor?id=japan-2026`.
                // The sidecar already holds the id, Dayflow already looks up by
                // id, and renaming the note cannot break the link. A path-based
                // route would also have needed a sixth field on Satchel's
                // `Endeavor` to carry `relativePath` — which is the trigger
                // condition in backlog E34 for consolidating the two models, and
                // not a cost worth paying for a jump button.
                if let jump = endeavorAppURL(for: endeavorID) {
                    Divider().overlay(Color.satchelHairline).padding(.leading, 14)

                    Button {
                        openURL(jump)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Open in Dayflow")
                                .font(.system(size: 14, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Color.satchelAuto)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(Color.satchelHairline).padding(.leading, 14)

                Button {
                    showNotePicker = true
                } label: {
                    HStack {
                        // "Linked note", not "Note" — `noteField` below is a
                        // free-text box also called Note, and two rows with one
                        // name on one screen is how the link control got missed.
                        Text("Linked note")
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

                // The way back. Only drawn when the note belongs to an app that
                // can actually open it — see `noteOwnerAppURL`. Deliberately a
                // separate row rather than a second tap target on the one above:
                // that row's job is to CHANGE the link, and one row doing both
                // would make every tap a guess.
                if let jump = noteOwnerAppURL(for: linkedNote) {
                    Divider().overlay(Color.satchelHairline).padding(.leading, 14)

                    Button {
                        openURL(jump.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 13, weight: .semibold))
                            Text(jump.label)
                                .font(.system(size: 14, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Color.satchelBlue)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

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
    /// The folder lives here on purpose — see this file's header. As of
    /// 2026-07-28 it is always a year, so the row is labelled "Year" rather than
    /// "Folder": calling it a folder invited the question "can I change it?",
    /// and the answer is no, because it is not a filing decision any more.
    private var fileFacts: some View {
        field("File") {
            VStack(spacing: 0) {
                factRow("Kind", kindLabel(for: current))
                factRow("Size", fileSize)
                // The row is labelled "Added" and was reading the date printed on
                // the document, which is the one thing it is not (D381).
                factRow("Added", relativeDateLabel(current.listDate))
                factRow("Year", current.category)
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
            // Context hint (2026-08-26). The Mac has had this field since the
            // AI row was rebuilt there and David asked for it here: *"I dont
            // think i have the Context field on IOS Satchel and it is helpful
            // on Mac."* Same contract as the Mac: the text goes into the prompt
            // as authoritative, `#tag` markers are honoured explicitly, and the
            // local (private) path reads it as its hint. Sits directly above
            // the button that consumes it, which is the Mac's lesson about
            // where the affordance belongs.
            // Labelled "Context" like Title and Description below it — David,
            // on the first build: *"can we call it Context like we do for the
            // title or description?"*
            field("Context") {
                TextField("Hint: who, what, when. Use #tag to force a tag", text: $userContext)
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .satchelCard()
            }
            VStack(spacing: 6) {
                Button {
                    // **The gate, and it is a gate rather than a warning.**
                    // Before this, the phone had no notion of `private` at all
                    // outside Ask — one tap here sent a bank statement with no
                    // prompt, which was worse than the Mac has ever been.
                    if isPrivate { showPrivatePrompt = true }
                    else { Task { await rescan(using: store) } }
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
                .confirmationDialog("Send this private document to the AI?",
                                    isPresented: $showPrivatePrompt,
                                    titleVisibility: .visible) {
                    // **The safe door first**, exactly as on the Mac. It is also
                    // the retry path: the capture-time local pass can come back
                    // empty if the on-device model was still downloading, and
                    // without this there was no way to ask again short of
                    // sending the document.
                    Button("Fill in from text on this phone") { fillLocally() }
                    Button("Send and remove private tag", role: .destructive) {
                        promoteFromPrivate(using: store)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("It was captured privately and has never left this phone. "
                         + "Sending it to the AI removes the private tag permanently "
                         + "and makes the document readable by Ask.")
                }

                // Said where the button is, not buried in a dialog nobody opens.
                if isPrivate {
                    Text("Private. Nothing about this document has been sent.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.orange)
                }

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
    /// Carries the `private` tag. Read off the live editor state, not the
    /// stored document, so removing the tag and pressing the button in one
    /// sitting behaves the way it looks.
    private var isPrivate: Bool {
        tags.contains { $0.caseInsensitiveCompare("private") == .orderedSame }
    }

    /// Drop the tag, save it, then scan.
    ///
    /// **Saved before the request goes out**, exactly as the Mac does, so the
    /// file on disk can never claim to be private while its contents are in
    /// flight.
    /// Title, summary and tags from text already on this phone. Sends nothing,
    /// keeps the tag. The phone's half of the Mac's local fill.
    private func fillLocally() {
        let text = current.extractedText
        guard !text.isEmpty else {
            scanError = current.textExtracted
                ? "No readable text was found in this document."
                : "This document has not been read yet. Pull the list down to refresh, then try again."
            return
        }
        scanError = nil
        Task {
            let hint = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
            let suggestion = await MacLocalIntelligence.suggest(text: text, hint: hint)
            await MainActor.run {
                for marked in MacTextExtraction.hashTags(in: hint)
                where !tags.contains(where: { $0.caseInsensitiveCompare(marked) == .orderedSame }) {
                    tags.append(marked)
                }
                if let headline = MacTextExtraction.localHeadline(from: text) {
                    title = headline.title
                    if descriptionText.isEmpty { descriptionText = headline.description }
                }
                if let suggestion {
                    if !suggestion.summary.isEmpty { descriptionText = suggestion.summary }
                    for tag in suggestion.tags
                    where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                        tags.append(tag)
                    }
                }
                dirty = true
                save()
            }
        }
    }

    private func promoteFromPrivate(using store: iOSDocumentStore) {
        tags.removeAll { $0.caseInsensitiveCompare("private") == .orderedSame }
        dirty = true
        save()
        Task { await rescan(using: store) }
    }

    private func rescan(using store: iOSDocumentStore) async {
        // A hard gate, not a courtesy, and the same shape as the Mac's:
        // `promoteFromPrivate` is the only way past it and it clears the tag
        // first, so no future caller can reintroduce the hole by wiring itself
        // straight to `rescan`.
        guard !isPrivate else { return }
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
                userContext: userContext.trimmingCharacters(in: .whitespacesAndNewlines),
                filenameIsGenerated: doc.title.isEmpty
                    || doc.title.lowercased().hasPrefix("scan")
                    || doc.title.lowercased().hasPrefix("photo"),
                knownPeople: PeopleIndex.read().map(\.name)
            )
            // `#tag` in the hint is honoured whether or not the model chose to.
            var mergedTags = result.tags.isEmpty ? doc.tags : result.tags
            for marked in MacTextExtraction.hashTags(in: userContext)
            where !mergedTags.contains(where: { $0.caseInsensitiveCompare(marked) == .orderedSame }) {
                mergedTags.append(marked)
            }
            // Names only from the list, spelled the list's way, added to what
            // was already there.
            let known = PeopleIndex.known(result.people, in: PeopleIndex.read())
            var mergedPeople = doc.people
            for name in known where !mergedPeople.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                mergedPeople.append(name)
            }
            try store.saveSidecar(
                for: doc,
                title: result.title ?? doc.title,
                tags: mergedTags,
                linkedNote: doc.linkedNote,
                people: mergedPeople,
                description: result.description.isEmpty ? doc.description : result.description,
                date: result.datedOn ?? doc.created,
                icon: result.icon,
                // Session 72: colour is the document's type, not a function
                // of its icon. No fallback.
                tint: result.tint,
                // A stated date wins over none; a date already on the document
                // is kept unless the scan found one (an explicit re-run).
                remindOn: result.remindOn.map { Optional.some($0) }
            )
            await store.reload()
            loadFromDocument()
            remindAIFilled = result.remindOn != nil
            dateAIFilled = result.datedOn != nil
            peopleAIFilled = !known.isEmpty
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
        remindOn = doc.remindOn
        people = doc.people
        docDate = doc.created ?? Date()
        // Photo lines out first (D419): an article's photo addresses are not
        // links he saved.
        links = MacTextExtraction.links(in: SatchelArticleText.withoutImages(doc.extractedText))
        docURL = doc.url
    }

    private func save() {
        guard let store, dirty else { return }
        let doc = current
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // MERELY OPENING THIS SCREEN USED TO REWRITE THE FILE.
        //
        // `loadFromDocument()` assigns every field, which trips the
        // `.onChange(of:)` handlers on `linkedNote`, `icon` and `tint`, which
        // set `dirty = true`. `.onDisappear` then saved. So viewing a document
        // and backing out wrote its sidecar, with whatever this screen happened
        // to be holding.
        //
        // Harmless while Satchel is the only writer. Actively destructive once
        // it is not: David edited a title in Trace, opened the document in
        // Satchel to check, and backing out wrote Satchel's copy of the title
        // straight back over the edit. The file was rewritten twice, both times
        // with the old title, which looked like Trace failing to save.
        // Found in device testing 2026-07-28, test 10.
        //
        // Guarding here rather than fixing `dirty` at its eleven assignment
        // sites: `dirty` is set from `onChange`, which fires a render pass after
        // the load, so any flag-based suppression is a race. Comparing against
        // what is actually on the document is not.
        let unchanged = trimmed == doc.title
            && descriptionText.trimmingCharacters(in: .whitespacesAndNewlines) == doc.description
            && tags == doc.tags
            && icon == doc.resolvedIcon
            && tint == doc.resolvedTint
            && endeavorID == doc.endeavor
            && endeavorName == doc.endeavorName
            && pinned == doc.pinned
            && linkedNote == doc.linkedNote
            && note == doc.note
            && remindOn == doc.remindOn
            && people == doc.people
            && docURL.trimmingCharacters(in: .whitespacesAndNewlines) == doc.url
            && Calendar.current.isDate(docDate, inSameDayAs: doc.created ?? .distantPast)
        if unchanged {
            dirty = false
            return
        }

        try? store.saveSidecar(
            for: doc,
            title: trimmed.isEmpty ? doc.title : trimmed,
            tags: tags,
            linkedNote: linkedNote,
            people: people,
            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            date: docDate,
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
            note: note,
            remindOn: .some(remindOn),
            // Passed explicitly on every save, not only when it has a value:
            // this screen owns the field, so an emptied box has to be able to
            // remove the key. `nil` here would mean "preserve", and clearing a
            // URL would silently do nothing.
            url: .some(docURL)
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
        case newest, oldest, title
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: return "Newest first"
            case .oldest: return "Oldest first"
            case .title:  return "Title A–Z"
            }
        }
        var symbol: String {
            switch self {
            case .newest: return "arrow.down"
            case .oldest: return "arrow.up"
            case .title:  return "textformat.abc"
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case all, pdf, image, link, article, text
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:     return "Any format"
            case .pdf:     return "PDFs"
            case .image:   return "Images"
            case .link:    return "Links"
            case .article: return "Articles"
            case .text:    return "Text"
            }
        }
    }

    /// Grid or list (D386). The one preference this screen DOES remember,
    /// against the rule at the top of the file: sort and filter are a way of
    /// looking at the list right now, but grid-or-list is how the screen is
    /// read at all, and re-choosing it on every visit would be a tax on
    /// opening the library. Grid by default, per the approved mockup.
    enum Layout: String {
        case grid, list
    }
    @AppStorage("satchel.allDocuments.layout") private var layoutRaw: String = Layout.grid.rawValue
    private var layout: Layout {
        get { Layout(rawValue: layoutRaw) ?? .grid }
        nonmutating set { layoutRaw = newValue.rawValue }
    }

    @State private var sort: Sort = .newest
    /// The chosen formats (D388). Empty means any. A set rather than one
    /// choice so PDFs and Images together, or everything with Links left
    /// out, are each a couple of taps. `.all` never sits in the set; it is
    /// the entry that clears it.
    @State private var formats: Set<Kind> = []
    @State private var type: DocumentIcon? = nil
    @State private var tint: DocumentTint? = nil
    @State private var endeavorID: String? = nil
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
         tint: DocumentTint? = nil,
         endeavorID: String? = nil,
         kind: Kind = .all) {
        self.documents = documents
        self.store = store
        _type = State(initialValue: type)
        _tint = State(initialValue: tint)
        _endeavorID = State(initialValue: endeavorID)
        _formats = State(initialValue: kind == .all ? [] : [kind])
    }

    private func matchesFormat(_ doc: TraceMacDocument) -> Bool {
        if formats.isEmpty { return true }
        return formats.contains { entry in
            switch entry {
            case .all:   return true
            case .pdf:   return doc.isPDF
            case .image: return doc.isImage
            // **Articles beside Links, not inside them** (D407). Both are
            // `.webloc` files, so `Links` alone would return the shelf as well
            // and "everything but links" would quietly drop his reading. Links
            // now means the ones that are NOT articles, which is what the word
            // means to him: a link is somewhere to get back to.
            case .link:    return doc.isLink && doc.articleState != .article
            case .article: return doc.articleState == .article
            case .text:    return doc.isText
            }
        }
    }

    /// "PDFs + Images", or "All but Links" when that is the shorter truth.
    private var formatLabel: String? {
        if formats.isEmpty { return nil }
        let chosen = Kind.allCases.filter { $0 != .all && formats.contains($0) }
        let others = Kind.allCases.filter { $0 != .all && !formats.contains($0) }
        if others.count == 1, chosen.count >= 2, let left = others.first { return "All but \(left.label)" }
        return chosen.map(\.label).joined(separator: " + ")
    }

    /// Only types present in the library. Offering all 23 as filters when six are
    /// in use makes the menu a wall of dead ends.
    private var availableTypes: [DocumentIcon] {
        Array(Set(documents.map { $0.resolvedIcon }))
            .sorted { $0.label < $1.label }
    }

    private var tags: [String] {
        Array(Set(documents.flatMap { $0.tags })).sorted()
    }

    /// Same rule as `availableTypes`: only colours something is actually
    /// wearing. In the palette's fixed order rather than by count.
    private var availableTints: [DocumentTint] {
        let present = Set(documents.map { $0.resolvedTint })
        return (DocumentTint.typeCases + [.amber, .red]).filter { present.contains($0) }
    }

    private var filtered: [TraceMacDocument] {
        var out = documents

        if let type { out = out.filter { $0.resolvedIcon == type } }
        if let tint { out = out.filter { $0.resolvedTint == tint } }
        if let endeavorID { out = out.filter { $0.endeavor == endeavorID } }
        if let tag { out = out.filter { $0.tags.contains(tag) } }
        if kitOnly { out = out.filter { $0.pinned } }
        if !formats.isEmpty { out = out.filter { matchesFormat($0) } }

        let tokens = DocumentSearch.tokens(from: query)
        if !tokens.isEmpty {
            // Shared predicate — now shared with the Mac as well, not just with
            // the Library screen above. These two searches had drifted apart
            // once already, which is how "it finds it on one screen but not the
            // other" happens; `DocumentSearch` is the file that makes that
            // impossible rather than merely unlikely.
            out = out.filter { DocumentSearch.matches($0, tokens: tokens) }
        }

        switch sort {
        case .newest:
            out.sort { ($0.listDate ?? .distantPast) > ($1.listDate ?? .distantPast) }
        case .oldest:
            out.sort { ($0.listDate ?? .distantPast) < ($1.listDate ?? .distantPast) }
        case .title:
            out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return out
    }

    struct MonthGroup: Identifiable {
        /// `2026-07`, so it sorts as a string and cannot collide across years.
        let key: String
        let label: String
        let documents: [TraceMacDocument]
        var id: String { key }
    }

    /// `filtered` split into month sections, order preserved.
    ///
    /// Built by walking the already-sorted array rather than with `Dictionary
    /// (grouping:)` — a dictionary would lose the sort order and force a re-sort
    /// of the keys, and `.oldest` would then need the opposite comparison. Walking
    /// it means whatever `sort` decided is simply kept.
    ///
    /// Undated documents get a "No date" section wherever the sort puts them —
    /// last under Newest first, first under Oldest first, since `created` falls
    /// back to `.distantPast`. Verified rather than assumed; they do exist,
    /// because `created` is optional and a hand-written sidecar may omit it.
    private var monthGroups: [MonthGroup] {
        var groups: [MonthGroup] = []
        var currentKey: String?
        var bucket: [TraceMacDocument] = []

        func flush() {
            guard let currentKey, !bucket.isEmpty else { return }
            groups.append(MonthGroup(key: currentKey,
                                     label: Self.monthLabel(for: bucket.first?.listDate),
                                     documents: bucket))
            bucket = []
        }

        for doc in filtered {
            // Grouped by the same date the rows print and the sort uses (D381).
            // Grouping on `created` while the row says something else would put
            // a row labelled Sep 6 under a heading reading November 2026.
            let key = Self.monthKey(for: doc.listDate)
            if key != currentKey {
                flush()
                currentKey = key
            }
            bucket.append(doc)
        }
        flush()
        return groups
    }

    private static let monthKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // grouping key, never shown
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"                     // shown, so device locale
        return f
    }()

    private static func monthKey(for date: Date?) -> String {
        guard let date else { return "0000-00" }
        return monthKeyFormatter.string(from: date)
    }

    private static func monthLabel(for date: Date?) -> String {
        guard let date else { return "No date" }
        let cal = Calendar.current
        let now = Date()
        if cal.isDate(date, equalTo: now, toGranularity: .month) { return "This month" }
        if let lastMonth = cal.date(byAdding: .month, value: -1, to: now),
           cal.isDate(date, equalTo: lastMonth, toGranularity: .month) {
            return "Last month"
        }
        return monthLabelFormatter.string(from: date)
    }

    private var isFiltered: Bool {
        type != nil || tint != nil || endeavorID != nil || tag != nil || kitOnly || !formats.isEmpty
    }

    private var endeavorLabel: String? {
        guard let endeavorID else { return nil }
        return documents.first { $0.endeavor == endeavorID }?.endeavorName ?? "Endeavor"
    }

    /// Named after what you asked for, not "17 of 42". Arriving from a Receipts
    /// chip should say Receipts.
    private var screenTitle: String {
        // Arriving from the Links chip should say Links (D386), same rule as
        // a subject chip below.
        if let formatLabel, type == nil, tint == nil, endeavorID == nil { return "\(formatLabel) · \(filtered.count)" }
        if let type { return "\(type.label) · \(filtered.count)" }
        // The long name, not the chip's short one. A screen has room for
        // "Receipt, bill, proof of payment" and arriving from a chip labelled
        // Paid is exactly when you want to be told what Paid meant.
        if let tint { return "\(tint.satchelLongLabel) · \(filtered.count)" }
        if let endeavorLabel { return "\(endeavorLabel) · \(filtered.count)" }
        if filtered.count == documents.count { return "\(documents.count) documents" }
        return "\(filtered.count) of \(documents.count)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if filtered.isEmpty {
                    Text(query.isEmpty ? "Nothing matches those filters." : "No matches.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.satchelSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if sort == .title {
                    // A–Z is an alphabetical question, so month headers would be
                    // noise: consecutive rows would each get their own header.
                    if layout == .grid {
                        SatchelDocumentGrid(documents: filtered, ordered: filtered, store: store)
                            .padding(.horizontal, 15)
                    } else {
                        DocumentCard(documents: filtered, store: store)
                            .padding(.horizontal, 15)
                    }
                } else {
                    // Grouped by month. A flat list of two hundred rows cannot be
                    // scanned however good the filters are, and because the Browse
                    // chips land in THIS screen pre-filtered, sectioning here also
                    // turns "Receipts" from a wall into something with landmarks.
                    ForEach(monthGroups, id: \.key) { group in
                        // `SatchelSectionTitle(_:)`, the EmptyView convenience
                        // init — the memberwise `init(title:trailing:)` cannot
                        // infer `Trailing` without a closure, so the labelled form
                        // does not compile here. It carries its own bottom padding,
                        // so none is added.
                        SatchelSectionTitle(group.label)
                            .padding(.horizontal, 15)
                            .padding(.top, group.key == monthGroups.first?.key ? 0 : 16)
                        // The grid (D386) or the rows, same groups, same order.
                        // The viewer is handed the whole filtered set, not the
                        // month, so a swipe crosses a month boundary the way
                        // scrolling does.
                        if layout == .grid {
                            SatchelDocumentGrid(documents: group.documents, ordered: filtered, store: store)
                                .padding(.horizontal, 15)
                        } else {
                            DocumentCard(documents: group.documents, store: store)
                                .padding(.horizontal, 15)
                        }
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .satchelBackground()
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search documents")
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .toolbar {
            // Grid or list (D386). A toggle, not a menu entry: it is the one
            // control on this screen that changes what the screen IS, and it
            // should be where a thumb finds it without opening anything.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layout = (layout == .grid) ? .list : .grid
                    }
                } label: {
                    Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(layout == .grid ? "Show as list" : "Show as grid")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { option in
                            Label(option.label, systemImage: option.symbol).tag(option)
                        }
                    }

                    Menu("Kind") {
                        Button("Any kind") { tint = nil }
                        ForEach(availableTints, id: \.self) { candidate in
                            Button {
                                tint = (tint == candidate) ? nil : candidate
                            } label: {
                                if tint == candidate {
                                    Label(candidate.satchelShortLabel, systemImage: "checkmark")
                                } else {
                                    Text(candidate.satchelShortLabel)
                                }
                            }
                        }
                    }

                    Menu("Subject") {
                        Button("Any subject") { type = nil }
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

                    // "In Kit only" left the menu with Format (D418): it is a
                    // chip on the bar now, and two doors to one switch is how a
                    // control ends up disagreeing with itself.

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

    // MARK: - The filter bar (D418)
    //
    // David: *"If i want to see PDFs and Images together i have to tap the
    // filter button, then tap format, then tap pdf then it brings me back to the
    // screen and i have to tap filter, then format then image. There has to be a
    // better way."*
    //
    // **The logic was never the problem.** `formats` has been a `Set` since
    // D388 and the menu entries already toggle. What costs the taps is that a
    // UIKit `Menu` dismisses on every selection, so a multi-select control was
    // put somewhere that cannot express multi-select. Two of everything he
    // wanted, and no way to see what was on without opening it again.
    //
    // So the formats come out onto the screen: chips that toggle in place, stay
    // put, and say what is chosen by looking at them. PDFs + Images is two taps.
    //
    // Second line is what he actually reaches for beside format — Kit, and the
    // endeavours that have documents in them. That is also where the Browse
    // chips D417 left as dead code finally get spent rather than deleted: the
    // Home section was the wrong home for them, not the idea.
    //
    // Everything rarer — subject, colour, tag, sort — stays in the toolbar
    // menu, where a dismiss-on-tap menu is the right shape because those are
    // one-at-a-time choices. A filter set there still appears here as a
    // removable chip, because a filter you cannot see is a filter you forget you
    // set, and then the library looks like it has lost documents.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Kind.allCases.filter { $0 != .all }) { option in
                        toggleChip(option.label, on: formats.contains(option)) {
                            if formats.contains(option) { formats.remove(option) }
                            else { formats.insert(option) }
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    toggleChip("In Kit", on: kitOnly) { kitOnly.toggle() }
                    ForEach(availableEndeavors) { entry in
                        toggleChip(entry.name, on: endeavorID == entry.id) {
                            endeavorID = (endeavorID == entry.id) ? nil : entry.id
                        }
                    }
                    // Set from the toolbar menu, removed from here.
                    if let type { filterChip(type.label, systemImage: type.sfSymbol) { self.type = nil } }
                    if let tint { filterChip(tint.satchelShortLabel, systemImage: "circle.fill") { self.tint = nil } }
                    if let tag { filterChip(tag, systemImage: "tag") { self.tag = nil } }
                    if isFiltered {
                        Button("Clear") { clearFilters() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.satchelBlue)
                            .padding(.leading, 2)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
        .background(Color.satchelCanvas)
    }

    /// The endeavours with documents in this library, by name, most-used first.
    /// Only the ones something is actually filed under — offering the whole list
    /// would make the row a wall of dead ends, the same rule `availableTypes`
    /// follows.
    struct EndeavorFacet: Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
    }

    private var availableEndeavors: [EndeavorFacet] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for doc in documents {
            guard let id = doc.endeavor, !id.isEmpty else { continue }
            names[id] = doc.endeavorName ?? "Endeavor"
            counts[id, default: 0] += 1
        }
        // **Written out, not chained.** map → sorted → prefix → map, with a
        // ternary inside the sort closure and a `??` inside the map, is four
        // generic inferences over a Dictionary in one expression, and it timed
        // out the type-checker on the first build of D418. Every type here is
        // spelled, and none of it is clever. `feedback_typecheck_timeout`: when
        // this happens, the fix is always to write the loop.
        var facets: [EndeavorFacet] = []
        for (id, count) in counts {
            let name: String = names[id] ?? "Endeavor"
            facets.append(EndeavorFacet(id: id, name: name, count: count))
        }
        facets.sort { (lhs: EndeavorFacet, rhs: EndeavorFacet) -> Bool in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name < rhs.name
        }
        return Array(facets.prefix(6))
    }

    /// On or off, and it says which by looking at it. Blue filled when on, so
    /// the only blue on the row is a thing that is doing something.
    private func toggleChip(_ text: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(text).font(.system(size: 12.5, weight: .semibold))
                if on {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(on ? Color.white : Color.satchelSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(on ? Color.satchelBlue : Color.satchelCard,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(on ? Color.clear : Color.satchelHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
        type = nil; tint = nil; endeavorID = nil; tag = nil; kitOnly = false; formats = []
    }
}

// MARK: - Capture source
//
// Which of the four paths the FAB asked for. Tap is always scan; the other
// three sit behind a long press (scope §5). `SatchelCaptureView` reads this to
// decide which picker to open. The step-9 placeholder sheet that used to live
// here is gone, replaced by the real flow.

/// A capture the library has decided to start, with everything the sheet needs
/// to start it. See `captureRequest` for why the payload travels with the item
/// rather than beside it.
struct SatchelCaptureRequest: Identifiable {
    let source: SatchelCaptureSource
    var incoming: IncomingDocument? = nil
    var noteLink: String? = nil
    /// Private captures skip the AI entirely. See `SatchelCaptureView.isPrivate`.
    var isPrivate: Bool = false

    /// One capture sheet is presentable at a time, so the source identifies the
    /// request. Including the payload here would re-present the sheet whenever
    /// it changed, which is the opposite of what is wanted.
    /// Privacy is part of the identity: a private scan and an ordinary scan are
    /// two different requests, and re-presenting the sheet for the other one is
    /// exactly what should happen if both are somehow asked for.
    var id: String { isPrivate ? "\(source.rawValue)-private" : source.rawValue }
}

enum SatchelCaptureSource: String, Identifiable {
    case scan, photo, library, file
    /// Session 102 (D386). Whatever is on the clipboard, saved in one motion:
    /// a link becomes a `.webloc`, text a `.txt`, a picture a `.png`. The
    /// library reads the pasteboard and hands the bytes across as an
    /// `IncomingDocument`, the same shape the share extension uses, so the
    /// capture sheet treats a paste exactly like a share.
    case paste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan:    return "Scan Document"
        case .photo:   return "Take Photo"
        case .library: return "Choose from Library"
        case .file:    return "Import File"
        case .paste:   return "Paste"
        }
    }

    var symbol: String {
        switch self {
        case .scan:    return "doc.viewfinder"
        case .photo:   return "camera"
        case .library: return "photo.on.rectangle"
        case .file:    return "folder"
        case .paste:   return "doc.on.clipboard"
        }
    }

}
