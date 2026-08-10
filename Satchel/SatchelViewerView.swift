import SwiftUI
import PDFKit

// MARK: - SatchelViewerView
//
// Build step 8. Frames 5 (PDF) and 6 (photo) of `satchel-mockup-v4.html`.
//
// Scope §5: "Viewer — full screen, direct tap from any row." That is the whole
// point of this screen. §6 calls the existing `iOSPDFView` and
// `AsyncImagePreview` in `iOSDocumentsView.swift` "already solid" and says the
// viewer "becomes the front door instead of sitting behind the in-note markdown
// link path" — the cumbersome flow David remembered.
//
// A note on "promote out of `iOSDocumentsView.swift`": that file is 38 KB of
// Trace's own UI and is NOT in the Satchel target, so nothing could be shared
// without either adding it wholesale or hand-editing `project.pbxproj`'s
// membership exception set. Neither is worth it, because the reusable part is a
// twelve-line `UIViewRepresentable` around `PDFView` — boilerplate, not logic.
// What is actually reused is the *approach*: PDFKit for PDFs, and the
// iCloud-aware "still downloading" handling for images, which matters because a
// document may exist as a placeholder before its bytes arrive. Both are
// reimplemented here to the mockup's design rather than copied.

struct SatchelViewerView: View {

    let document: TraceMacDocument
    let store: iOSDocumentStore

    @Environment(\.openURL) private var openURL
    @State private var noteStore = NoteStore.shared
    @State private var endeavorStore = SatchelEndeavorStore()
    @State private var showRemindSheet = false
    @State private var remindDue = Date()
    @State private var remindState: ReminderButtonState = .idle
    @State private var pageCount: Int = 0
    @State private var isWorking = false

    /// The active trip this document belongs to, if it is in Kit *because of*
    /// that trip rather than because it was pinned. Kit has two kinds of member
    /// (scope §5) and a button that reads only `pinned` describes half of them
    /// wrongly: a boarding pass sitting in Kit all week still said "Add to Kit".
    private var kitTrip: Endeavor? {
        guard !current.pinned, let id = current.endeavor else { return nil }
        guard let trip = endeavorStore.activeTrip(), trip.id == id else { return nil }
        return trip
    }

    private var fileURL: URL? {
        noteStore.resolvedURL(for: document.relativePath)
    }

    /// The live copy from the store, so a pin toggle updates this screen's
    /// button without a reload. Falls back to the value it was pushed with.
    private var current: TraceMacDocument {
        store.documents.first { $0.relativePath == document.relativePath } ?? document
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            metaStrip
            actions
            Spacer(minLength: 0)
        }
        .satchelBackground()
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let fileURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showRemindSheet) { remindSheet }
        .task {
            await endeavorStore.reload()
            guard document.isPDF, let fileURL else { return }
            pageCount = PDFDocument(url: fileURL)?.pageCount ?? 0
        }
    }

    private var navTitle: String {
        if document.isPDF && pageCount > 0 {
            return pageCount == 1 ? "1 page" : "\(pageCount) pages"
        }
        return document.isImage ? "Photo" : "Document"
    }

    // MARK: Stage

    /// The dark stage from frames 5 and 6. Deliberately near-black rather than
    /// the app canvas: a document is the subject here, and a light ground makes
    /// a white page float without an edge.
    @ViewBuilder
    private var stage: some View {
        ZStack {
            Color(red: 0.173, green: 0.173, blue: 0.180) // #2c2c2e

            if let fileURL {
                if document.isPDF {
                    // Inset so the dark ground shows on all four sides. Without
                    // this, `autoScales` fits the page to the full width, the
                    // stage is completely covered and the page loses its edge —
                    // it reads as a plain white screen rather than a document
                    // sitting on a surface. The mockup's paper is deliberately
                    // narrower than its stage for exactly this reason.
                    SatchelPDFView(url: fileURL)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 18)
                } else if document.isImage {
                    SatchelImagePreview(url: fileURL)
                } else {
                    unsupported
                }
            } else {
                unsupported
            }
        }
        .frame(height: 460)
    }

    private var unsupported: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.white.opacity(0.5))
            Text("Cannot preview this file")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(document.filename)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Meta

    private var metaStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                SatchelDocumentMark.header(current)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.satchelInk)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.satchelSecondary)
                }
                Spacer(minLength: 0)
            }

            filedToStrip
                .padding(.top, 11)

            if !current.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(current.tags, id: \.self) { tag in
                        SatchelTagPill(text: tag)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 9)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    // MARK: Filed to
    //
    // WHAT THIS FIXES. David, 2026-07-30: *"I dont even have a way to know what
    // the document is linked to without going to the edit info tab which isnt
    // great."* He was right, and it was the root of two complaints rather than
    // one: with no filing visible here, "Edit info" was doing double duty as the
    // only way to READ filing as well as change it, and the Kit button had to
    // carry an explanation of a state nothing else showed.
    //
    // So: state is shown here, changing it stays in Edit info, and the Kit button
    // went back to saying only what it does.
    //
    // Navigation split, David's call: the Endeavor and the linked note navigate
    // (they are the round trip Endeavors exist for), Kit status is informational
    // because the button beside it already acts on Kit. A chip that both tells
    // you something and commits you to something is how a row ends up doing two
    // jobs — the mistake already recorded against the linked-note picker.

    @ViewBuilder
    private var filedToStrip: some View {
        let noteName = current.linkedNote.map(Self.noteDisplayName)
        let hasFiling = current.endeavorName?.isEmpty == false
            || noteName != nil
            || !current.tags.isEmpty

        HStack(spacing: 6) {
            if let endeavor = current.endeavorName, !endeavor.isEmpty {
                if let url = endeavorAppURL(for: current.endeavor) {
                    Button { openURL(url) } label: {
                        chip(endeavor, symbol: "suitcase", tint: Color.satchelAuto, navigates: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    chip(endeavor, symbol: "suitcase", tint: Color.satchelAuto, navigates: false)
                }
            }

            if let noteName {
                if let jump = noteOwnerAppURL(for: current.linkedNote) {
                    Button { openURL(jump.url) } label: {
                        chip(noteName, symbol: "note.text", tint: Color.satchelBlue, navigates: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    // A note in a folder no app claims — Horizons today. Shown, not
                    // tappable: knowing what it is filed against still has value
                    // when nothing can open it.
                    chip(noteName, symbol: "note.text", tint: Color.satchelBlue, navigates: false)
                }
            }

            if current.pinned {
                chip("In Kit", symbol: "pin.fill", tint: Color.satchelPin, navigates: false)
            } else if let trip = kitTrip {
                chip("In Kit · \(trip.name)", symbol: "airplane",
                     tint: Color.satchelAuto, navigates: false)
            }

            if !hasFiling {
                // Straight out of the scanner a document has none of the above.
                // A chip that leads somewhere beats a blank space: David lost a
                // document once precisely because an unfiled one appears under no
                // Browse chip at all.
                NavigationLink {
                    SatchelDocumentDetailView(document: current, store: store)
                } label: {
                    chip("Unfiled", symbol: "tray", tint: Color.satchelSecondary, navigates: true)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, symbol: String, tint: Color, navigates: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            if navigates {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.11), in: Capsule())
    }

    /// `Notes/People/Mitch Weiss.md` → `Mitch Weiss`.
    private static func noteDisplayName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private var subtitle: String {
        var parts: [String] = []
        if current.isPDF {
            parts.append(pageCount > 1 ? "PDF · \(pageCount) pages" : "PDF")
        } else {
            parts.append(kindLabel(for: current))
        }
        let when = relativeDateLabel(current.created)
        if !when.isEmpty { parts.append(when) }
        // The Endeavor name USED to be appended here. Removed 2026-07-30 when the
        // filed-to strip below started showing it as a chip — a chip that also
        // opens the Endeavor, which plain text in a subtitle cannot. Same mistake
        // as the Endeavor screen showing its own name three times: the fix is to
        // delete the weaker copy, not to reword both.
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                if let fileURL {
                    ShareLink(item: fileURL) {
                        actionLabel("Share")
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink {
                    SatchelDocumentDetailView(document: current, store: store)
                } label: {
                    actionLabel("Edit info")
                }
                .buttonStyle(.plain)

                Button {
                    togglePin()
                } label: {
                    actionLabel(kitButtonTitle, symbol: kitButtonSymbol, tint: kitButtonTint)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }

            // REMIND ME. David, 2026-08-01: *"documents in Satchel that might need
            // a reminder"* — his tuxedo receipt says pickup on 19 September and
            // nothing in the system knows that.
            //
            // **No `remind:` sidecar key, and that is deliberate.** Trace owns the
            // date for an agenda item because Coming Up has to show it and clear
            // it. Satchel has no screen that lists documents by date, so a stored
            // date would be a field with no reader — the exact shape that has
            // produced a bug roughly ten times this week. The reminder IS the
            // record here, until there is a surface that would read one.
            //
            // The reminder carries `satchel://document?path=…` in its notes, so it
            // opens the document rather than merely naming it.
            Button {
                remindDue = current.remindOn
                    ?? Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                remindState = .idle
                showRemindSheet = true
            } label: {
                actionLabel(current.remindOn == nil ? "Remind me" : "Due " +
                            current.remindOn!.formatted(.dateTime.month(.abbreviated).day()),
                            symbol: "bell",
                            tint: current.remindOn == nil ? .satchelBlue : .satchelPin)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            if let kitTrip {
                Text(tripCaption(for: kitTrip))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.satchelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    // Three states, because Kit has two kinds of member and "not in Kit" is a
    // third thing entirely.
    //   pinned          → the way out
    //   in Kit via trip → the way to make it OUTLAST the trip
    //   neither         → add
    //
    // "Keep in Kit" was the middle one until 2026-07-30. David: *"'keep in kit'
    // is misleading. It really means move to Kit."* It was literally accurate —
    // the document was already in Kit via the trip, and pinning keeps it there
    // afterwards — but it was answering a question nothing on screen had asked,
    // because the trip membership was invisible. **The strip above now shows that
    // state, so the button only has to say what it does.** "Keep after trip"
    // names the thing pinning actually adds.
    private var kitButtonTitle: String {
        if current.pinned { return "Remove from Kit" }
        return kitTrip != nil ? "Keep after trip" : "Add to Kit"
    }

    private var kitButtonSymbol: String? {
        if current.pinned { return "pin.slash" }
        return kitTrip != nil ? "pin" : nil
    }

    private var kitButtonTint: Color {
        current.pinned ? Color.satchelPin : Color.satchelBlue
    }

    /// Was "In Kit while Japan is running, through Jul 31." — which was wrong the
    /// moment Kit gained a three-day lead-in, since the commonest case for
    /// reading this caption is the days BEFORE a trip, when it is not running.
    /// `kitTimingPhrase` is shared with the Library footnote and the Kit screen
    /// so all three say the same thing.
    @ViewBuilder
    private var remindSheet: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Remind me on", selection: $remindDue,
                               displayedComponents: .date)
                } header: {
                    Text(current.title)
                } footer: {
                    Text("Saved on the document, and added to Apple's Reminders app so it opens this document when it fires.")
                }
                if current.remindOn != nil {
                    Section {
                        Button(role: .destructive) { clearReminder() } label: {
                            Text("Clear the date")
                        }
                    }
                }
                if case .failed(let why) = remindState {
                    Text(why).font(.caption).foregroundStyle(Color.satchelPin)
                }
            }
            .navigationTitle("Remind me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRemindSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addReminder() }
                        .fontWeight(.semibold)
                        .disabled(remindState == .working)
                }
            }
        }
    }

    /// Writes the date to the sidecar AND raises the reminder.
    ///
    /// David, 2026-08-01: *"if there is no copy of the date how is it saved? I
    /// would want to see items with dates somehow."* The first version stored
    /// nothing, on the reasoning that a field no screen reads is a field that
    /// rots. He asked for the screen, so the date has a home now — the Library's
    /// Due section — and the sidecar is where it belongs.
    ///
    /// **The sidecar write comes first and stands alone.** If Reminders is denied
    /// the date is still saved and still shows in Due; only the notification is
    /// lost. The reverse order would let a permissions refusal throw away a date
    /// he had just chosen.
    private func addReminder() {
        remindState = .working
        let path = current.relativePath
        let link = "satchel://document?path=" +
            (path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path)
        Task {
            do {
                _ = try store.setReminder(on: remindDue, for: current)
                await store.reload()
            } catch {
                remindState = .failed("Could not save the date.")
                return
            }
            let key = "document|\(path)"
            do {
                // MOVE an existing reminder, or CREATE one — never both. The first
                // version did the reschedule and then fell through to the add,
                // which would have left the old reminder rescheduled AND a
                // duplicate beside it every time a date was changed.
                if ReminderService.isLinked(key) {
                    await ReminderService.reschedule(key: key, to: remindDue)
                } else {
                    let id = try await ReminderService.add(title: current.title,
                                                           due: remindDue,
                                                           notes: "Satchel\n\(link)")
                    ReminderService.link(id, to: key)
                }
                remindState = .idle
                showRemindSheet = false
            } catch ReminderService.Failure.denied {
                remindState = .failed("Date saved. Satchel does not have access to Reminders, so no notification was set. Settings › Privacy › Reminders.")
            } catch {
                remindState = .failed("Date saved, but the reminder could not be added.")
            }
        }
    }

    private func clearReminder() {
        let key = "document|\(current.relativePath)"
        Task {
            _ = try? store.setReminder(on: nil, for: current)
            await store.reload()
            // Clearing the date here has to close the reminder there, or the
            // notification outlives the thing that asked for it.
            await ReminderService.complete(key: key)
            showRemindSheet = false
        }
    }

    private func tripCaption(for trip: Endeavor) -> String {
        "In Kit · \(trip.name) \(trip.kitTimingPhrase()). "
            + "Keep it to hold its place afterwards."
    }

    private func actionLabel(_ text: String, symbol: String? = nil, tint: Color = .satchelBlue) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .satchelTile(cornerRadius: 12)
    }

    private func togglePin() {
        isWorking = true
        defer { isWorking = false }
        _ = try? store.setPinned(!current.pinned, for: current)
    }
}

// MARK: - PDF

/// PDFKit wrapper. Same shape as Trace's `iOSPDFView`, restyled for the dark
/// stage. `autoScales` plus continuous vertical paging is what makes a
/// multi-page receipt behave like a document rather than a slideshow.
struct SatchelPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1)
        // Drop shadows give the page a physical edge against the dark ground,
        // and the gap makes a multi-page document read as separate sheets
        // rather than one long scroll.
        view.pageShadowsEnabled = true
        view.pageBreakMargins = UIEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        Self.load(url, into: view)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // Only rebuild when the file actually changed — reassigning `document`
        // on every SwiftUI update resets scroll position mid-read.
        if uiView.document?.documentURL != url {
            Self.load(url, into: uiView)
        }
    }

    /// Loads the PDF, waiting for iCloud if the bytes are not here yet.
    ///
    /// THE BLANK-PAGE BUG. `PDFDocument(url:)` on a file iCloud has not
    /// downloaded returns nil, and `PDFView` with a nil document draws nothing
    /// — no error, no spinner, just an empty stage. Going back and opening the
    /// document again works, because the download completed in between, which
    /// makes it look like a random glitch. David hit it twice, once in Trace's
    /// browser and once here.
    ///
    /// The image path in this same file already handled this; the PDF path
    /// never did. `SatchelCaptureView.readImportedFile` uses the same pattern
    /// for imported files — ask for the download, then read under a file
    /// coordinator, which waits for it.
    ///
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
        // into the detached read, and only `Data` comes back. Handing a UIKit
        // object to a detached task is the kind of thing that compiles today
        // and becomes an error under stricter concurrency later.
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

// MARK: - Image

/// Image preview with the iCloud-placeholder handling Trace's
/// `AsyncImagePreview` already got right: a document can exist in the container
/// as a stub before its bytes arrive, so the download is kicked off explicitly
/// and the not-yet-available case says so instead of showing a broken frame.
struct SatchelImagePreview: View {
    let url: URL

    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let image {
                SatchelZoomableImage(image: image)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 38, weight: .thin))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Image not available")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("It may still be downloading from iCloud.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        // Nudge iCloud if this is still a placeholder rather than real bytes.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let target = url
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: target) else { return nil }
            return UIImage(data: data)
        }.value

        image = loaded
        isLoading = false
    }
}

// MARK: - Zoomable image
//
// A 12-megapixel photo has no business being laid out at its intrinsic size,
// which is exactly what `ScrollView { Image.resizable().scaledToFit() }` does:
// inside a two-axis ScrollView there is no bounded width to fit into, so the
// image renders at full pixel size and you are left looking at a few hundred
// pixels of the middle of it with no way out.
//
// `UIScrollView` is the right tool and is why PDFs already behaved: it owns the
// zoom scale, so the image can start fitted, pinch between fitted and 4x, and
// double-tap to toggle. Rebuilding that on SwiftUI gestures would mean
// reimplementing rubber-banding, momentum and centring for no gain.

struct SatchelZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView(image: image)
    }

    func updateUIView(_ uiView: ZoomableImageScrollView, context: Context) {
        uiView.setImage(image)
    }
}

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {

    private let imageView = UIImageView()
    private var lastBounds: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        setImage(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        lastBounds = .zero          // force a rescale on next layout
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            configureScale()
        }
        centreContent()
    }

    /// Fit the whole image on screen to begin with. Zooming OUT past fit is
    /// pointless, so fitted is the minimum; 4x fit is a sane ceiling for reading
    /// a serial number off a photographed label.
    private func configureScale() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 4, 1.5)
        zoomScale = fit
    }

    private func centreContent() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let target = min(minimumZoomScale * 3, maximumZoomScale)
            let w = bounds.width / target
            let h = bounds.height / target
            zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centreContent() }
}
