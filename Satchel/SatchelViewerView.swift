import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

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

    /// The document this viewer was opened on.
    let opened: TraceMacDocument
    let store: iOSDocumentStore
    /// The ordered set the caller was showing, or empty (D386, Session 102).
    /// A horizontal swipe on the stage moves to the neighbour in THIS list,
    /// never the whole library: arriving through the Links chip means you
    /// swipe through links. Every existing call site passes nothing and gets
    /// a viewer that does not swipe, exactly as before.
    let siblings: [TraceMacDocument]
    @State private var position: Int

    init(document: TraceMacDocument, store: iOSDocumentStore, siblings: [TraceMacDocument] = []) {
        self.opened = document
        self.store = store
        self.siblings = siblings
        _position = State(initialValue: siblings.firstIndex { $0.relativePath == document.relativePath } ?? 0)
    }

    /// What is on screen now: the neighbour swiped to, or the one opened.
    var document: TraceMacDocument {
        (siblings.indices.contains(position) ? siblings[position] : nil) ?? opened
    }

    private var canSwipeBack: Bool { !siblings.isEmpty && position > 0 }
    private var canSwipeForward: Bool { !siblings.isEmpty && position < siblings.count - 1 }

    @Environment(\.openURL) private var openURL
    @State private var noteStore = NoteStore.shared
    @State private var endeavorStore = SatchelEndeavorStore()
    /// **One sheet host, one presentation.** This screen had a single `.sheet`
    /// for Remind me, and adding a second modifier for the tasks panel is the
    /// mistake this codebase has now made twice: *"two `.sheet` modifiers on one
    /// view is a coin flip and the later one wins silently"* (the Mac's D36),
    /// which is exactly how Dayflow's task sheet lost its date picker. A case
    /// rather than a race, and a third sheet is another case.
    private enum ViewerSheet: String, Identifiable {
        case remind, tasks
        var id: String { rawValue }
    }
    @State private var sheet: ViewerSheet? = nil
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

    @Environment(SatchelChrome.self) private var chrome: SatchelChrome?
    @State private var showNote = false

    // MARK: Highlights in a PDF (D450)

    @State private var pdfStage = SatchelPDFStage()
    @State private var highlights: [SatchelHighlight] = []
    @State private var showHighlights = false
    @State private var openHighlight: SatchelHighlight? = nil
    @State private var writingLine = false
    @State private var lineDraft: String = ""
    @State private var sentNoteName: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            stage
            metaStrip
            actions
            Spacer(minLength: 0)
        }
        .satchelBackground()
        // **Clear of the tab bar** (D444). The root draws its own bar over
        // everything (D417) and only the Shelf and All tabs were padded for it,
        // so a document opened from Home had Share, Edit info and Add to Kit
        // sitting underneath it. David: *"the bottom row ... is covered up by the
        // home, shelf, all and plus icons."* The screen now owns its clearance
        // wherever it is pushed from.
        //
        // **And the same complaint came back on 2026-09-21, for a reason worth
        // keeping** (D494). This 72 was measured against the card as it stood,
        // whose last element was the four-across button row. The Remind button
        // was added BELOW that row a month later and nobody re-checked the number
        // it was landing in, so it sat in the margin this fix had created and
        // half under the bar - *"too far down and difficult to reach."* **A
        // clearance is measured against a specific last element, and adding
        // anything after it silently spends the measurement.** Remind has moved
        // into the button row, so the element this number was measured against is
        // the last one again.
        //
        // **And the number itself was wrong, which D494 did not catch** (D495).
        // 72 is the bar's own HEIGHT - see the derivation on
        // `SatchelTabBar.clearance` - so it stopped the content two points above
        // the bar rather than leaving a gap. Moving the reminder up made that
        // visible instead of fixing it: *"the pills at the bottom are slightly
        // still too low. they seem to be riding the bottom pane."* One named
        // constant now, 110, the value Home had been using all along.
        .safeAreaPadding(.bottom, chrome?.hidesTabBar == true ? 0 : SatchelTabBar.clearance)
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
        .sheet(item: $sheet) { which in
            switch which {
            case .remind: remindSheet
            case .tasks:  tasksSheet
            }
        }
        .sheet(isPresented: $showNote) {
            SatchelNoteView(document: current, store: store)
        }
        .sheet(isPresented: $showHighlights) {
            SatchelHighlightsList(
                highlights: highlights,
                colors: SatchelArticleInk(ink: Color.satchelInk,
                                          secondary: Color.satchelSecondary,
                                          faint: Color.satchelTertiary,
                                          card: Color.satchelFill,
                                          accent: Color.satchelBlue),
                onJump: { highlight in
                    showHighlights = false
                    pdfStage.go(toPage: highlight.block)
                },
                onAddLine: { highlight in
                    // Close the list first (D451): an alert asked for from
                    // behind a sheet has nowhere to appear.
                    showHighlights = false
                    openHighlight = highlight
                    lineDraft = highlight.line
                    writingLine = true
                },
                onRemove: { highlight in removeHighlight(highlight.id) },
                onSend: { sendHighlightsToNote() },
                onClose: { showHighlights = false }
            )
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(openHighlight?.text ?? "",
                            isPresented: highlightMenuShown,
                            titleVisibility: .visible) {
            Button(openHighlight?.line.isEmpty == false ? "Edit the line" : "Add a line") {
                lineDraft = openHighlight?.line ?? ""
                writingLine = true
            }
            Button("Remove highlight", role: .destructive) {
                if let open = openHighlight { removeHighlight(open.id) }
                openHighlight = nil
            }
            Button("Cancel", role: .cancel) { openHighlight = nil }
        }
        .alert("Your line", isPresented: $writingLine) {
            TextField("A line of your own", text: $lineDraft)
            Button("Save") { saveHighlightLine() }
            Button("Cancel", role: .cancel) { openHighlight = nil }
        }
        .task(id: current.highlightsRaw) {
            highlights = SatchelHighlightText.parse(current.highlightsRaw)
            pdfStage.redraw(highlights)
        }
        // Keyed on the path so a swipe to the next document re-runs it: the
        // page count belongs to the document on screen, not the one opened.
        .task(id: document.relativePath) {
            await endeavorStore.reload()
            pageCount = 0
            guard document.isPDF, let fileURL else { return }
            pageCount = PDFDocument(url: fileURL)?.pageCount ?? 0
        }
    }

    private var navTitle: String {
        var base: String
        if document.isPDF && pageCount > 0 {
            base = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        } else if document.isImage {
            base = "Photo"
        } else if document.isLink {
            base = "Link"
        } else if document.isText {
            base = "Text"
        } else {
            base = "Document"
        }
        // "3 of 19" when there is somewhere to swipe to, so the gesture has a
        // visible reason to exist.
        if siblings.count > 1 { base += " · \(position + 1) of \(siblings.count)" }
        return base
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
                    SatchelPDFView(url: fileURL, stage: pdfStage, highlights: highlights,
                                   highlightsRaw: current.highlightsRaw,
                                   onOpenHighlight: { found in openHighlight = found })
                        .padding(.horizontal, 34)
                        .padding(.vertical, 18)
                } else if document.isImage {
                    SatchelImagePreview(url: fileURL)
                } else if document.isLink {
                    linkStage
                } else if document.isText {
                    SatchelTextPreview(url: fileURL)
                } else {
                    unsupported
                }
            } else if document.isLink {
                linkStage
            } else {
                unsupported
            }
        }
        .frame(height: 460)
        .id(document.relativePath)
        // **Swipe between neighbours** (D386). Horizontal only, and only when
        // there is a neighbour: a vertical drag is the PDF scrolling and must
        // stay with it. The threshold is a real swipe, not a nudge, so a
        // pinch or a scroll that drifts sideways does not change the page.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let h = value.translation.width
                    guard abs(h) > abs(value.translation.height) * 1.5, abs(h) > 60 else { return }
                    if h < 0, canSwipeForward {
                        withAnimation(.easeInOut(duration: 0.22)) { position += 1 }
                    } else if h > 0, canSwipeBack {
                        withAnimation(.easeInOut(duration: 0.22)) { position -= 1 }
                    }
                },
            including: siblings.count > 1 ? .all : .subviews
        )
    }

    /// A saved link on the stage (D384, D386): its cached preview when the
    /// page offered one, else its host large on the document's own tint, the
    /// same tile the grid draws. The address is one tap away, here on the
    /// stage as well as in the chip below, because this is the screen where
    /// the only thing a link can do should be the biggest thing on it.
    @ViewBuilder
    private var linkStage: some View {
        let web = TraceMacDocument.openableURL(current.url)
        VStack(spacing: 14) {
            if let image = SatchelLinkPreview.image(for: current.url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 34)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 34, weight: .medium))
                    Text(web.map { TraceMacDocument.webLabel($0) } ?? current.url)
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .foregroundStyle(current.resolvedTint.foreground)
                .frame(width: 200, height: 200)
                .background(current.resolvedTint.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            if let web {
                Button {
                    openURL(web)
                } label: {
                    Label("Open \(TraceMacDocument.webLabel(web))", systemImage: "safari")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
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

            descriptionLines

            filedToStrip
                .padding(.top, 11)

            if !current.tags.isEmpty {
                // **Wraps, for the same reason the filing strip above it does.**
                // The comment on that strip already claimed "a second line here
                // looks like the second line of tags directly below it" — but
                // this row was still a plain `HStack`, so it never had a second
                // line. Five AI tags on an article ("medicare", "retirement",
                // "health insurance", "enrollment", "reading") squeezed every
                // pill at once and each LABEL wrapped inside its own pill:
                // "medicar / e". The strip's fix was never applied here.
                // `Spacer` goes with the HStack — a flow layout is already
                // leading-aligned and a greedy spacer inside it is a view
                // claiming the rest of the row.
                SatchelFlowLayout(spacing: 6) {
                    ForEach(current.tags, id: \.self) { tag in
                        SatchelTagPill(text: tag)
                    }
                }
                .padding(.top, 9)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        // **The count needs the store loaded, and nothing in Satchel loads it
        // for this screen.** `SatchelDocTasksPanel` refreshes when Edit info
        // opens; the viewer has no such moment, so `allTasks` would be empty on
        // a cold open and the chip silently absent on a document that HAS tasks
        // — a wrong answer that looks like a calm one, which is the exact
        // failure shape this session kept finding.
        //
        // An EventKit read, local and cheap, once per document opened.
        .task { await ReminderTaskStore.shared.refreshAll() }
    }

    /// Open tasks carrying this document's `satchel:doc:` marker.
    ///
    /// The same query `SatchelDocTasksPanel` runs, spelled the same way on
    /// purpose: `linkedDocumentPaths` is the one reader of that marker, so a
    /// count derived any other way could disagree with the band it summarises.
    private var openTaskCount: Int {
        ReminderTaskStore.shared.allTasks
            .filter { $0.linkedDocumentPaths.contains(current.relativePath) }
            .count
    }

    /// One name, or a count. Two names side by side is the width that breaks
    /// this row on a phone, and a truncated person reads worse than a number.
    private var peopleLabel: String? {
        let names = current.people.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !names.isEmpty else { return nil }
        return names.count == 1 ? names[0] : "\(names.count) people"
    }

    /// What the document actually SAYS, two lines of it.
    ///
    /// **Everything else on this card is about the file and nothing was about
    /// the contents.** PDF, two pages, the date, the tags, where it is filed -
    /// all true, none of it telling him which Marriott receipt this is. The
    /// description was written by the scan or by him and then shown only inside
    /// Edit info, which is the same complaint that put the endeavor and the
    /// linked note on this card in the first place: Edit info was doing double
    /// duty as the only way to READ.
    ///
    /// **Two lines, clamped, and never a third.** This is a caption under a
    /// document, not the document. A description long enough to need scrolling
    /// belongs to the sheet that can edit it.
    @ViewBuilder
    private var descriptionLines: some View {
        let text = current.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.satchelSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
        }
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
        // Tasks and people join the test, or a document carrying three open
        // tasks and no endeavor would draw "Unfiled" beside a chip saying it has
        // three open tasks — the strip contradicting itself in one row.
        // A typed URL counts, for the same reason tasks and people do: a chip
        // saying `marriott.com` beside a chip saying "Unfiled" is the strip
        // contradicting itself in one row. And the case "Unfiled" exists for is
        // a document straight out of the scanner, which cannot have a URL -
        // Edit info is the only place one can be typed, so a document carrying
        // one has already been through the door this chip opens.
        let hasFiling = current.endeavorName?.isEmpty == false
            || noteName != nil
            || !current.tags.isEmpty
            || !current.people.isEmpty
            || openTaskCount > 0
            || TraceMacDocument.openableURL(current.url) != nil

        // **Wraps rather than squeezes.** This was a plain `HStack` while it
        // held at most three chips. The URL is a fifth, and a chip row that
        // cannot fit compresses every `lineLimit(1)` label in it at once - the
        // endeavor name and the host both truncating to nothing, on the row
        // whose entire purpose is that he can READ this without opening Edit
        // info. `SatchelFlowLayout` is the tag field's own layout, so a second
        // line here looks like the second line of tags directly below it.
        SatchelFlowLayout(spacing: 6) {
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

            // **The typed URL, and it is the one chip here that can always be
            // tapped** (D355, D358). A person is a name with no record to open
            // and a document with two tasks has no single task to open, so both
            // of those are told rather than tapped. A URL has exactly one
            // destination by definition. It was invisible on this card until
            // now, readable only by opening Edit info, which is precisely the
            // thing this row exists to stop.
            if let web = TraceMacDocument.openableURL(current.url) {
                Button { openURL(web) } label: {
                    chip(TraceMacDocument.webLabel(web), symbol: "link",
                         tint: Color.teal, navigates: true)
                }
                .buttonStyle(.plain)
            }

            if current.pinned {
                chip("In Kit", symbol: "pin.fill", tint: Color.satchelPin, navigates: false)
            } else if let trip = kitTrip {
                chip("In Kit · \(trip.name)", symbol: "airplane",
                     tint: Color.satchelAuto, navigates: false)
            }

            // **Tasks and people: told, not tapped.**
            //
            // David: "is there a way ... to see the fact that the document is
            // linked to a task or to a person ... without having to click the
            // edit info button? even smaller indicators would preserve the joy
            // of the app without crowding the main document sheet."
            //
            // Two of his four were already here — the endeavor and the linked
            // note, added 2026-07-30 for the same complaint in its first form.
            // These are the two that were not: the tasks band lives inside Edit
            // info, and `people` was on the model and drawn nowhere at all.
            //
            // **People are told; tasks now act** (D359, and the second half of
            // this note is a correction).
            //
            // A person is stored as a NAME in the sidecar, not a record id, and
            // no `person` route exists in any of the three apps, so a chip that
            // opened a search would be pretending. That still holds.
            //
            // Tasks were told for a reason about ROUTES: `dayflow://task?id=`
            // needs one id, so the chip would open something for a document with
            // one task and nothing for a document with two, and a chip that
            // sometimes acts is worse than one that never does. The reasoning
            // was right and the conclusion settled for too little. **The answer
            // was never a route.** `SatchelDocTasksPanel` already shows,
            // completes, unticks and creates, and it works the same for one task
            // or six - it was simply buried inside Edit info, which is the trip
            // this row exists to save. Pressing the chip presents it here.
            //
            // Editing a task is still the task apps' job (the panel's own rule,
            // D177): this is ticking and adding, not a second task editor.
            if openTaskCount > 0 {
                Button { sheet = .tasks } label: {
                    chip(openTaskCount == 1 ? "1 task" : "\(openTaskCount) tasks",
                         symbol: "circle.dashed", tint: Color.satchelBlue, navigates: true)
                }
                .buttonStyle(.plain)
            }

            if let people = peopleLabel {
                chip(people, symbol: "person", tint: Color.satchelAuto, navigates: false)
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
            pdfHighlightRow
            // **Four buttons, and Share is no longer one of them** (D494).
            //
            // **Share was on this screen twice**, identically: here, and as the
            // system icon at `topBarTrailing` (line ~126), same `ShareLink`, same
            // `fileURL`, same `if let` condition. One of them had to go and the
            // toolbar one is the one iOS users reach for without being taught.
            // Recorded as a REMOVAL rather than left to be noticed, which is what
            // D477-D479 cost three builds to learn.
            //
            // The slot it frees goes to Remind, which is what this change is
            // actually for - see the note below.
            HStack(spacing: 10) {
                NavigationLink {
                    SatchelDocumentDetailView(document: current, store: store)
                } label: {
                    actionLabel("Edit info")
                }
                .buttonStyle(.plain)

                // The document's own note (D433). "Add note" when there is none,
                // so the button says what pressing it will do.
                Button {
                    showNote = true
                } label: {
                    actionLabel((current.noteFile ?? "").isEmpty ? "Add note" : "Note",
                                symbol: "note.text")
                }
                .buttonStyle(.plain)

                Button {
                    togglePin()
                } label: {
                    actionLabel(kitButtonTitle, symbol: kitButtonSymbol, tint: kitButtonTint)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                // REMIND ME. David, 2026-08-01: *"documents in Satchel that might need
                // a reminder"* — his tuxedo receipt says pickup on 19 September and
                // nothing in the system knows that.
                //
                // **No `remind:` sidecar key, and that is deliberate.** Trace owns
                // the date for an agenda item because Coming Up has to show it and
                // clear it. Satchel has no screen that lists documents by date, so
                // a stored date would be a field with no reader — the exact shape
                // that has produced a bug roughly ten times this week. The reminder
                // IS the record here, until there is a surface that would read one.
                //
                // The reminder carries `satchel://document?path=…` in its notes, so
                // it opens the document rather than merely naming it.
                //
                // **It moved into this row from a full-width row of its own**
                // (D494). David, with a screenshot of the CD One Price Cleaners
                // receipt: *"The reminder at the bottom of a satchel document is
                // too far down and difficult to reach."* It was the last thing on
                // the tallest card in the app, under the four buttons, at the very
                // bottom of his thumb's range and half behind the tab bar.
                Button {
                    remindDue = current.remindOn
                        ?? Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                    remindState = .idle
                    sheet = .remind
                } label: {
                    actionLabel(current.remindOn == nil ? "Remind me" : "Due " +
                                current.remindOn!.formatted(.dateTime.month(.abbreviated).day()),
                                symbol: "bell",
                                tint: current.remindOn == nil ? .satchelBlue : .satchelPin)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }

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
                    Button("Cancel") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addReminder() }
                        .fontWeight(.semibold)
                        .disabled(remindState == .working)
                }
            }
        }
    }

    /// The tasks band, presented over the document (D359).
    ///
    /// **The document's title is the heading, not "Tasks".** The panel already
    /// carries its own TASKS label, its done summary and its + button. A sheet
    /// titled Tasks sitting above a section titled TASKS is the same word twice
    /// on one screen, and the fix for that is to delete the weaker copy rather
    /// than reword both - the note already written against the Endeavor screen
    /// naming itself three times. What this sheet has to say is WHICH document
    /// these belong to, because it is covering it.
    ///
    /// **Full height, not half.** A half sheet would show the document behind it
    /// and read better, right up until he presses `+`: the compose field is at
    /// the bottom of the panel and the keyboard rises over exactly that part of
    /// a medium detent, so the one control he just asked for would be the one
    /// under his thumb and out of sight.
    ///
    /// The count on the chip follows a tick without anything here refreshing it:
    /// the panel completes through the shared task store, which this screen
    /// already reads.
    private var tasksSheet: some View {
        NavigationStack {
            ScrollView {
                SatchelDocTasksPanel(document: current)
                    .padding(.top, 10)
            }
            .satchelBackground()
            .navigationTitle(current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { sheet = nil }
                        .fontWeight(.semibold)
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
                sheet = nil
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
            sheet = nil
        }
    }

    private func tripCaption(for trip: Endeavor) -> String {
        "In Kit · \(trip.name) \(trip.kitTimingPhrase()). "
            + "Keep it to hold its place afterwards."
    }

    /// **Only for a PDF, and only when there is something to do** (D450).
    /// Highlight appears when words are selected; the other two when there is
    /// anything marked. An image or a link sees none of this.
    @ViewBuilder
    private var pdfHighlightRow: some View {
        if current.isPDF {
            let unsent: Int = highlights.filter { $0.sent == nil }.count
            HStack(spacing: 10) {
                if pdfStage.hasSelection {
                    Button { makeHighlight() } label: {
                        actionLabel("Highlight", symbol: "highlighter", tint: .satchelPin)
                    }
                    .buttonStyle(.plain)
                }
                if !highlights.isEmpty {
                    Button { showHighlights = true } label: {
                        actionLabel("Highlights (\(highlights.count))", symbol: "list.bullet")
                    }
                    .buttonStyle(.plain)
                }
                if unsent > 0 {
                    Button { sendHighlightsToNote() } label: {
                        actionLabel(unsent == 1 ? "Send 1 to note" : "Send \(unsent) to note",
                                    symbol: "arrow.right.doc.on.clipboard", tint: .satchelPin)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let sentNoteName, unsent == 0, !highlights.isEmpty {
                Text("Sent to " + sentNoteName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.satchelTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Up while a highlight was tapped and the line editor is not (D451).
    private var highlightMenuShown: Binding<Bool> {
        Binding(
            get: { openHighlight != nil && !writingLine && !showHighlights },
            set: { shown in if !shown && !writingLine { openHighlight = nil } }
        )
    }

    // MARK: Highlight actions (D450)

    /// The selection becomes a passage. **The page takes the block's place**
    /// and nothing else about the entry changes, so a PDF highlight and an
    /// article highlight are the same thing in the same place.
    private func makeHighlight() {
        guard let passage = pdfStage.selectionPassage else { return }
        if highlights.contains(where: { $0.text == passage.text }) {
            pdfStage.clearSelection()
            return
        }
        let made = SatchelHighlight(id: SatchelHighlight.newID(),
                                    block: passage.page,
                                    text: passage.text,
                                    line: "",
                                    made: Date(),
                                    sent: nil)
        highlights.append(made)
        pdfStage.clearSelection()
        persistHighlights()
    }

    private func removeHighlight(_ id: String) {
        guard highlights.contains(where: { $0.id == id }) else { return }
        highlights.removeAll { $0.id == id }
        persistHighlights()
    }

    private func saveHighlightLine() {
        guard let open = openHighlight,
              let index = highlights.firstIndex(where: { $0.id == open.id }) else { return }
        highlights[index].line = lineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !highlights[index].line.isEmpty { highlights[index].sent = nil }
        openHighlight = nil
        lineDraft = ""
        persistHighlights()
    }

    private func persistHighlights() {
        let rendered: String = SatchelHighlightText.render(highlights)
        try? store.writeHighlights(rendered, for: current)
        pdfStage.redraw(highlights)
    }

    /// The article's own send, unchanged (D434): only what has not been sent,
    /// appended to the document's own note, which is made on the first send.
    private func sendHighlightsToNote() {
        let unsent: [SatchelHighlight] = highlights.filter { $0.sent == nil }
        guard !unsent.isEmpty else { return }
        let doc: TraceMacDocument = current
        let existingPath: String? = doc.noteFile
        let path: String = existingPath ?? SatchelHighlightNote.path(forTitle: doc.title)
        let now = Date()
        let block: String = SatchelHighlightNote.block(
            for: unsent,
            title: doc.title,
            site: SatchelShelf.site(doc),
            address: doc.url,
            firstSend: existingPath == nil,
            intoExistingNote: SatchelHighlightNote.exists(at: path),
            on: now
        )
        guard SatchelHighlightNote.append(block, to: path, title: doc.title) else { return }
        for index in highlights.indices where highlights[index].sent == nil {
            highlights[index].sent = now
        }
        let rendered: String = SatchelHighlightText.render(highlights)
        try? store.writeHighlights(rendered, for: doc, noteFile: path)
        sentNoteName = SatchelHighlightNote.name(of: path)
        pdfStage.redraw(highlights)
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
/// What the screen around the PDF needs to know about it (D450): the view
/// itself, so Highlight can act on whatever is selected, and whether anything
/// IS selected, so the button can say so. An observable rather than a binding
/// because PDFKit reports selection by notification, not by callback.
@Observable
final class SatchelPDFStage {
    @ObservationIgnored weak var view: PDFView?
    var hasSelection = false
    /// What is on the pages right now (D464). A redraw that would draw the same
    /// set again is skipped: clearing and re-adding marks before PDFKit's first
    /// render of a page loses them, and SwiftUI updates arrive in a burst right
    /// after a document is set. `load` records the set it painted before
    /// handing the document over, so those updates change nothing.
    @ObservationIgnored var painted: [SatchelHighlight] = []

    @MainActor
    var selectionPassage: (page: Int, text: String)? {
        guard let view, let document = view.document else { return nil }
        return SatchelPDFHighlights.passage(from: view.currentSelection, in: document)
    }

    @MainActor
    func clearSelection() { view?.clearSelection() }

    @MainActor
    func go(toPage page: Int) {
        guard let document = view?.document, let target = document.page(at: page) else { return }
        view?.go(to: target)
    }

    /// The highlight under a tap, in the view's own coordinates (D451).
    @MainActor
    func highlight(at point: CGPoint, among highlights: [SatchelHighlight]) -> SatchelHighlight? {
        guard let view, let page = view.page(for: point, nearest: false) else { return nil }
        let pagePoint: CGPoint = view.convert(point, to: page)
        return SatchelPDFHighlights.highlight(at: pagePoint, on: page, among: highlights)
    }

    @MainActor
    func redraw(_ highlights: [SatchelHighlight]) {
        guard let document = view?.document, highlights != painted else { return }
        SatchelPDFHighlights.apply(highlights, to: document, color: Self.markColor, in: view)
        painted = highlights
    }

    static let markColor: UIColor = UIColor.systemYellow.withAlphaComponent(0.42)
}

struct SatchelPDFView: UIViewRepresentable {
    let url: URL
    var stage: SatchelPDFStage? = nil
    var highlights: [SatchelHighlight] = []
    /// The sidecar's own section, for the moment the screen's `highlights`
    /// state has not been parsed yet (D464): a rebuilt screen hands an empty
    /// list to `makeUIView`, and the marks must be on the document BEFORE the
    /// view first renders it.
    var highlightsRaw: String = ""
    var onOpenHighlight: ((SatchelHighlight) -> Void)? = nil

    /// The set to put on a document that is about to be shown.
    private var initialMarks: [SatchelHighlight] {
        highlights.isEmpty ? SatchelHighlightText.parse(highlightsRaw) : highlights
    }

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
        stage?.view = view
        context.coordinator.stage = stage
        context.coordinator.watch(view)
        // **A tap on a highlight opens it** (D451), the same gesture the article
        // reader has had since D438. It must not fight PDFKit's own taps, so it
        // cancels nothing and only acts when the tap lands on a highlight.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        Self.load(url, into: view, marks: initialMarks, stage: stage)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // `initialMarks`, not `highlights`: right after a rebuild the screen's
        // state is still empty while the document already carries its marks,
        // and an empty set here would clear them (D464).
        let marks: [SatchelHighlight] = initialMarks
        context.coordinator.highlights = marks
        context.coordinator.onOpen = onOpenHighlight
        // Only rebuild when the file actually changed — reassigning `document`
        // on every SwiftUI update resets scroll position mid-read.
        if uiView.document?.documentURL != url {
            Self.load(url, into: uiView, marks: initialMarks, stage: stage)
        } else {
            // Cheap and idempotent: clears what it drew and draws again, so a
            // highlight made or removed shows without rebuilding the document.
            stage?.redraw(marks)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// PDFKit announces a change of selection rather than calling anyone, so the
    /// Highlight button learns about it here.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var stage: SatchelPDFStage?
        /// Kept in step by `updateUIView`, so a tap is tested against what is
        /// on the page right now.
        var highlights: [SatchelHighlight] = []
        var onOpen: ((SatchelHighlight) -> Void)?
        private var token: NSObjectProtocol?

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let stage else { return }
            let point: CGPoint = gesture.location(in: stage.view)
            guard let found = stage.highlight(at: point, among: highlights) else { return }
            onOpen?(found)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func watch(_ view: PDFView) {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    let selected: String = view?.currentSelection?.string ?? ""
                    self?.stage?.hasSelection = !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
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
    ///
    /// **The marks go on before the document is handed over** (D464). Every
    /// attempt to paint them after the load, at whatever moment, was lost to
    /// PDFKit's first render of the page; a document that already carries them
    /// when it is set renders them the first time and every time.
    @MainActor
    private static func load(_ url: URL, into view: PDFView,
                             marks: [SatchelHighlight], stage: SatchelPDFStage?) {
        if let doc = PDFDocument(url: url) {
            SatchelPDFHighlights.apply(marks, to: doc, color: SatchelPDFStage.markColor)
            stage?.painted = marks
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
            let doc: PDFDocument? = data.flatMap { PDFDocument(data: $0) }
            if let doc {
                SatchelPDFHighlights.apply(marks, to: doc, color: SatchelPDFStage.markColor)
                stage?.painted = marks
            }
            view.document = doc
        }
    }
}

// MARK: - Image

/// Image preview with the iCloud-placeholder handling Trace's
/// `AsyncImagePreview` already got right: a document can exist in the container
/// as a stub before its bytes arrive, so the download is kicked off explicitly
/// and the not-yet-available case says so instead of showing a broken frame.
/// Plain text on the stage (D337's phone half, Session 102): a research
/// reading the Mac wrote, or a paragraph shared from Mail. Selectable so a
/// line can be copied out; not editable, for the reason the Mac gives: these
/// are records of what something said on a date, and the note is where David
/// writes.
struct SatchelTextPreview: View {
    let url: URL
    @State private var text: String? = nil

    var body: some View {
        ScrollView {
            Text(text ?? "")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .task(id: url) {
            text = (try? String(contentsOf: url, encoding: .utf8))
                ?? String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .isoLatin1)
                ?? ""
        }
    }
}

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
            SatchelImagePreview.downsampled(at: target)
        }.value

        image = loaded
        isLoading = false
    }

    /// Decode at screen size rather than at full resolution.
    ///
    /// **A phone screenshot is 3.2 megapixels and decodes to about 12MB of
    /// memory** to be drawn 400 points tall. `UIImage(data:)` keeps every one of
    /// those pixels alive for the whole time the viewer is open, and a document
    /// photographed rather than screenshotted is several times worse.
    /// `CGImageSourceCreateThumbnailAtIndex` does the scaling during decode, so
    /// the full-size bitmap never exists.
    ///
    /// **2600 on the long edge, not the screen's own width.** Zoom goes to 4x,
    /// and an image decoded at exactly fit size turns to mush the moment he
    /// pinches in to read a check number, which is most of why this viewer
    /// zooms at all.
    nonisolated static func downsampled(at url: URL, maxPixel: CGFloat = 2600) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cg)
        }
        // A format ImageIO will not thumbnail still has to be viewable.
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
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
        lastBounds = .zero          // force a rescale on next layout
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            applyFit()
        }
        centreContent()
    }

    /// Size the image view to the FITTED size and leave `zoomScale` at 1.
    ///
    /// **The fit used to live in `zoomScale` and that is why a screenshot filled
    /// the stage at native size.** The image view was framed at the image's full
    /// pixel size and the scroll view was then asked to zoom out to fit. When
    /// that assignment does not take — and it did not, on a 1206x2622 screenshot
    /// in a 460-point stage — nothing reports an error: the view simply draws at
    /// 1:1 and you are looking at a third of one line of text with no way to
    /// tell whether the image, the file or the screen is wrong.
    ///
    /// Baking the fit into the frame cannot half-work. The view is the size it
    /// is drawn at, zoom starts at 1 and goes to 4, and every bounds change
    /// recomputes it. Same reasoning `SatchelPDFView` already relies on.
    private func applyFit() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: (size.width * fit).rounded(),
                            height: (size.height * fit).rounded())

        // Reset before resizing: a leftover transform from a previous fit would
        // multiply against the new frame instead of replacing it.
        zoomScale = 1
        minimumZoomScale = 1
        maximumZoomScale = 4
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
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
