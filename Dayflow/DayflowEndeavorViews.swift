// DayflowEndeavorViews.swift
// Dayflow
//
// The Endeavor browse list, the Endeavor screen, and the sheet that creates and
// edits one. Model and store: `DayflowEndeavor.swift`. Design record and the
// sixteen locked decisions: `Endeavor-Design.md`. Visual reference:
// `endeavor-mockup-v1.html`, approved 2026-07-28.
//
// THE ONE THING TO KEEP STRAIGHT (D4): the editor is handed `body` only. The
// frontmatter is parsed off by the store, rendered as the header by this file,
// and edited through the details sheet — never as text. David's exact objection
// to the first proposal was that raw `starts: 2026-09-14` sitting at the top of
// his Japan note would be worse than useless, and he was right.
//
// NOT IN THIS PASS, deliberately:
//   • cover photos (D8 — Travel only, Unsplash + photo library, image copied
//     into the container and referenced by path, never a URL)
//   • Satchel's own Endeavor screen (build step 11, unblocked by D2)

import SwiftUI
import PhotosUI

// MARK: - Presentation tokens

private extension EndeavorStatus {
    var tint: Color {
        switch self {
        case .active:    return Color(red: 0.055, green: 0.486, blue: 0.525) // teal
        case .upcoming:  return Color(red: 0.788, green: 0.463, blue: 0.039) // amber
        case .idea:      return Color(red: 0.345, green: 0.337, blue: 0.839) // indigo
        case .onHold:    return Color(red: 0.420, green: 0.420, blue: 0.439) // gray
        case .past:      return Color(red: 0.557, green: 0.557, blue: 0.576)
        case .cancelled: return Color(red: 0.843, green: 0.000, blue: 0.082) // red
        }
    }
    var wash: Color { tint.opacity(0.12) }
}

/// A shared `DocumentTint` in the phone's own colours.
///
/// Extracted from `Endeavor.typeColor` in Session 88, when the booking bands
/// needed the same eight cases for `BookingKind.tint(for:)`. **Two copies of
/// this switch would drift the first time a tint changed and the drift would
/// be invisible** - standing warning FIVE. The literals are the exact ones the
/// type extension has carried since Session 78; nothing here is a new colour.
func dayflowTint(_ tint: DocumentTint) -> Color {
    switch tint {
    case .indigo: return Color(red: 0.345, green: 0.337, blue: 0.839)
    case .green:  return Color(red: 0.141, green: 0.541, blue: 0.239)
    case .rose:   return Color(red: 0.812, green: 0.184, blue: 0.467)
    case .amber:  return Color(red: 0.788, green: 0.463, blue: 0.039)
    case .teal:   return Color(red: 0.173, green: 0.478, blue: 0.471)
    case .blue:   return Color(red: 0.039, green: 0.518, blue: 1.000)
    case .red:    return Color(red: 0.843, green: 0.000, blue: 0.082)
    case .gray:   return Color(red: 0.420, green: 0.420, blue: 0.439)
    }
}

private extension Endeavor {
    /// The shared `typeTint` (a `DocumentTint`) in the phone's own colours.
    ///
    /// The mapping is `dayflowTint` and the CHOICE is on the model, so adding
    /// a type is one edit in `Endeavor.swift` rather than one here and one on
    /// the Mac that drift.
    var typeColor: Color { dayflowTint(typeTint) }
    var glyph: String { typeGlyph }
}

// MARK: - Cover image

/// Draws an Endeavor's cover from the container.
///
/// Its own loader rather than `AsyncImage`, because the file is a local iCloud
/// path and may be a stub whose bytes have not arrived — see
/// `EndeavorStore.coverData`.
///
/// Keyed on the path, which reloads on replacement **only because cover
/// filenames are stamped**. This comment used to claim the keying was what made
/// re-choosing a cover reload, and that was simply false: covers were all named
/// `<slug>.jpg`, so the path was identical before and after and `.task(id:)`
/// never fired again. The dependency runs the other way round — see
/// `EndeavorStore.setCover`. Do not go back to a fixed filename without also
/// giving this view something else to key on.
struct EndeavorCoverImage: View {

    let path: String
    let height: CGFloat
    var cornerRadius: CGFloat = 0
    /// Fixed width, for the thumbnail case. Nil keeps the original behaviour:
    /// fill whatever width is offered, which is what the 132pt header cover
    /// wants and what every caller got whether they wanted it or not.
    var width: CGFloat? = nil
    /// 0 is the top edge of the photograph, 1 the bottom. See
    /// `Endeavor.coverOffset`. Default 0.5 is centred, which is exactly what the
    /// bare `scaledToFill()` below did before and what the 42pt row thumbnail
    /// still wants — a square crop of a square has nothing to reposition.
    var offset: Double = 0.5

    @State private var image: UIImage?
    @State private var attempted = false

    var body: some View {
        ZStack {
            if let image {
                // **Not `scaledToFill()` plus an `.offset`.** That produces a view
                // of the band's size whose content overflows *centred*, and
                // offsetting it moves the frame too, sliding empty space in from
                // one edge. The filled size — what `scaledToFill` computes
                // internally and does not expose — is worked out here so the
                // picture moves inside a fixed window instead. Same shape as the
                // Mac's `MacEndeavorCover` (D66/D67).
                GeometryReader { geo in
                    let box = fill(image.size, in: geo.size)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: box.width, height: box.height)
                        .offset(x: (geo.size.width - box.width) / 2,
                                y: -max(0, box.height - geo.size.height) * offset)
                }
            } else {
                // A muted wash rather than a spinner. This sits at the top of
                // the card, and a spinner there reads as "something is wrong"
                // for the half second before an image that is almost always
                // already local appears.
                LinearGradient(colors: [Color.dayflowInk.opacity(0.10),
                                        Color.dayflowInk.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        // WIDTH BEFORE CLIP, and only greedy when asked.
        //
        // This was always `.frame(maxWidth: .infinity)`, so the view took every
        // point offered and then clipped to that. In the 42pt row thumbnail the
        // result was a landscape photo spilling sideways across the Endeavor's
        // name — David's screenshot, 2026-07-31. An outer `.frame(width: 42)` at
        // the call site could not save it: constraining a view from outside does
        // not un-declare the greed inside, and `.clipped()` had already run
        // against the wide frame.
        .frame(width: width, height: height)
        .frame(maxWidth: width ?? .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: path) {
            attempted = false
            image = nil
            // Resolve the path on the main actor (a cheap string join), read the
            // bytes off it (slow: may wait on an iCloud download and a file
            // coordinator). See `EndeavorStore.coverBytes(at:)` for why this is
            // split rather than just marked `await`.
            let url = NoteStore.shared.resolvedURL(for: path)
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let url else { return UIImage?.none }
                return EndeavorStore.coverBytes(at: url).flatMap { UIImage(data: $0) }
            }.value
            image = loaded
            attempted = true
        }
    }

    /// The size the image is drawn at to cover `box` without distortion, i.e.
    /// what `scaledToFill()` computes internally and does not expose.
    private func fill(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = max(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

// MARK: - Browse list

/// Rendered by `DayflowNotesView` when the Endeavors scope is selected.
///
/// Sorted by imminence, not alphabetically or by creation: what is running now,
/// then what is coming, then what is done. That order is the whole reason to
/// look at this list — see `Endeavor.sortKey`.
struct DayflowEndeavorListSection: View {

    @State private var store = EndeavorStore.shared
    @State private var noteStore = NoteStore.shared
    @State private var showingCreate = false
    /// Presented as a sheet, NOT pushed. `DayflowNotesView` has no
    /// `NavigationStack` of its own — its two NavigationStacks are inside
    /// sheets — so a `NavigationLink` here compiles, renders, highlights on
    /// tap, and navigates nowhere. That is exactly what David hit: the row
    /// looked alive and did nothing. Every other row on that screen presents a
    /// sheet for the same reason; this now matches.
    @State private var openEndeavorID: String?
    @State private var showFinished = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            Button {
                showingCreate = true
            } label: {
                // Editorial (Session 77): the shared dashed-circle add
                // grammar — see DayflowNotesView.newProjectRow.
                // Redesign (Session 78): the quiet caps grammar the Notes
                // tab's NEW PROJECT row set.
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("NEW ENDEAVOR")
                        .font(.system(size: 10.5, weight: .medium))
                        .tracking(1.6)
                    Spacer()
                }
                .foregroundStyle(Color.dayflowFaint)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)

            if store.endeavors.isEmpty {
                Text("Nothing yet. A trip, a renovation, anything with a start and an end.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                group(current)

                // PAST AND CANCELLED FOLD AWAY. They already sort to the
                // bottom, but "at the bottom" stops being enough the moment
                // there are more finished than live ones — which is the steady
                // state of a list like this. Collapsed by default, with the
                // count on the label so it is never a mystery how much is
                // hidden.
                if !finished.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showFinished.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("FINISHED \u{00B7} \(finished.count)")
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.6)
                            Image(systemName: showFinished ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Color.dayflowFaint)
                        .padding(.top, 18)
                        .padding(.bottom, showFinished ? 8 : 0)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showFinished { group(finished) }
                }
            }
        }
        .task(id: noteStore.hasAccess) { store.reload() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.reload()
        }
        // Reload on dismiss as well as on appear. `create` reloads the store
        // itself, but relying on that alone leaves the list at the mercy of one
        // code path — and a list that silently fails to show what was just
        // created is indistinguishable from a create that did not happen.
        .sheet(isPresented: $showingCreate, onDismiss: { store.reload() }) {
            DayflowEndeavorDetailsSheet(existing: nil)
        }
        // `item:` keyed on the slug, so the screen is rebuilt per Endeavor
        // rather than reusing one screen's state for the next. A COVER, not a
        // sheet — David, Session 78: "the test trip 2 slides up which we
        // decided we didnt want in this app... more joy to have full view."
        // The screen's own Done button is the way back (dismiss works the
        // same under a cover).
        .fullScreenCover(item: Binding(
            get: { openEndeavorID.map { EndeavorRef(id: $0) } },
            set: { openEndeavorID = $0?.id }
        )) { ref in
            NavigationStack {
                DayflowEndeavorView(endeavorID: ref.id)
            }
        }
    }

    /// Live. `on hold` stays here deliberately — a paused project is one you
    /// still mean to come back to, and hiding it is how it quietly stops
    /// happening.
    private var current: [Endeavor] {
        store.endeavors.filter { e in
            switch e.status() {
            case .past, .cancelled: return false
            default:                return true
            }
        }
    }

    private var finished: [Endeavor] {
        store.endeavors.filter { e in
            switch e.status() {
            case .past, .cancelled: return true
            default:                return false
            }
        }
    }

    @ViewBuilder
    private func group(_ items: [Endeavor]) -> some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, endeavor in
                    Button {
                        // No slide (Session 78 round three): the cover
                        // presents with animations disabled and the screen
                        // crossfades itself in — D162's pattern.
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) { openEndeavorID = endeavor.id }
                    } label: {
                        row(endeavor)
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                    }
                }
            }
            // Redesign (Session 78): the card panel died with the rest of
            // the Notes tab's cards — open rows on paper, hairline rules.
        }
    }

    private func row(_ e: Endeavor) -> some View {
        let status = e.status()
        return HStack(spacing: 12) {
            if let cover = e.cover {
                EndeavorCoverImage(path: cover, height: 42, cornerRadius: 11, width: 42)
            } else {
                RoundedRectangle(cornerRadius: 11)
                    .fill(e.typeColor.opacity(0.14))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: e.glyph)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(e.typeColor)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(e.name)
                    .font(.dayflowSerif(16, weight: .semibold))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                Text("\(e.type) \u{00B7} \(endeavorDateLabel(e))".uppercased())
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color.dayflowFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // SIZE TO CONTENT, and never wrap.
            //
            // `.layoutPriority(1)` on the name column was tried first and was the
            // wrong tool, in a way worth recording: priority gave the name its
            // full ideal width, which left this column almost nothing, and these
            // two Texts had no `lineLimit`. So instead of truncating they WRAPPED
            // — "Starts tomorrow" and "upcoming" rendered one character per line,
            // and the row grew to roughly 700pt. David's screenshot, minutes after
            // the build: "The endeavor block is way too big."
            //
            // `fixedSize` is the honest expression of the intent: this column
            // takes exactly the width its text needs, the flexible name column
            // absorbs everything left. No priority games, and no arrangement of
            // the two can produce a tall row. `lineLimit(1)` as well, so a future
            // longer status string clips instead of reopening this.
            VStack(alignment: .trailing, spacing: 2) {
                if let countdown = endeavorCountdownLabel(e) {
                    Text(countdown)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(status.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Identifiable wrapper so a slug can drive `.sheet(item:)`. A bare `String?`
/// cannot — `String` is not `Identifiable`.
private struct EndeavorRef: Identifiable, Hashable {
    let id: String
}

// MARK: - The Endeavor screen

struct DayflowEndeavorView: View {

    /// Keyed by slug rather than holding a copy, so an edit made in the details
    /// sheet is reflected the moment the store reloads — the same reason
    /// `SatchelDocumentDetailView` reads its document back out of the store.
    let endeavorID: String

    @State private var store = EndeavorStore.shared
    @State private var noteStore = NoteStore.shared
    @State private var body_ = ""
    @State private var loaded = false
    @State private var showingDetails = false
    @State private var showingTripLog = false
    /// Which attachment picker the visible Attach button asked for. Cleared by
    /// `MarkdownEditorView` once it has fired. Added 2026-07-30: the paperclip
    /// used to live only on the keyboard accessory bar, so attaching required
    /// already typing.
    @State private var attachRequest: MarkdownAttachKind? = nil
    /// Set when a tapped `[[wikilink]]` resolves to a real place or person.
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    /// A tapped name that resolved to nothing. Held so the screen can SAY so.
    /// A tapped name that opened nothing, and why (Session 88, D282).
    @State private var wikiMiss: DayflowWikiMissNotice? = nil
    /// A project note PUSHED onto this screen's own navigation stack.
    ///
    /// David, after the first round: *"when I went into megans wedding endeavor
    /// and clicked on final wedding speech it opens but when i click the back
    /// arrow it takes me to notes instead of back to Megans endeavor. that
    /// seems too far back to me."*
    ///
    /// He is right, and the cause is that opening it was never navigation at
    /// all. `dayflow://note?path=` sets `showNotes = true`, and `route(_:)`
    /// clears every presentation first — including the sheet this endeavor is
    /// sitting in — so the endeavor was torn down and rebuilt as the Notes
    /// screen with a project selected. Back then means back to Notes, because
    /// Notes is genuinely where he now is. Nothing was broken; the wrong verb
    /// was used.
    @State private var pushedNoteTitle: String? = nil
    /// Which attach picker is open, if any. One enum and one sheet rather than
    /// two of each — two `.sheet` modifiers on one view is a coin flip and the
    /// later one wins silently (the Mac's D36, and this view already carries
    /// three sheets).
    @State private var attaching: AttachKind? = nil
    /// Used to open a linked note through the app's own `dayflow://note` route.
    @Environment(\.openURL) private var openURL

    private enum AttachKind: String, Identifiable {
        case place, person
        var id: String { rawValue }
    }
    /// True while the note editor holds the keyboard. Collapses the header, so
    /// the thing being typed into is not the smallest thing on screen.
    @State private var editorFocused = false
    /// Height of everything above the note editor inside the page's scroll:
    /// header (or its compact form), tag bar, bands, ATTACHED (D303, Session
    /// 90). Measured, not summed from constants. The 310pt figure in
    /// `content(_:)`'s comment was written before D279 added the bands and
    /// was already wrong by the time it mattered.
    @State private var chromeAboveEditor: CGFloat = 0
    /// The least the note gets when the bands push it down the page (D303).
    /// About ten lines. David: *"ill be most interested in the flight and
    /// hotel information on the road with my phone"*, so the schedule
    /// outranks the note and the floor is set low enough that more of the
    /// bands show before the first swipe. Not applied while typing: then the
    /// editor is exactly the room above the keyboard, and a floor larger than
    /// that room would leave the page scrollable under the caret.
    private let editorFloor: CGFloat = 240
    /// Session 78 round two — tasks on the endeavor (David: "it wont go
    /// unused"): the OPEN TASKS band's edit/add sheets, and the clutter fix
    /// (the three chip rows + documents fold behind one ATTACHED row).
    @State private var editingTask: ThingsTask? = nil
    /// Which task sheet the OPEN TASKS band is showing (Session 88).
    ///
    /// **One host, not two `.sheet` modifiers.** `attach` is the chooser over
    /// existing tasks and `compose` is the composer for a new one, and the
    /// chooser reaches the composer by setting this rather than presenting a
    /// sheet of its own. Dismissing one presentation and starting another in
    /// the same turn is exactly what `openNote` above records going wrong:
    /// two presentations in flight and SwiftUI drops one.
    ///
    /// This replaced a plain `addingTask` bool, which could only ever mean the
    /// composer.
    @State private var taskSheet: TaskSheet? = nil

    private enum TaskSheet: Identifiable {
        case attach
        /// Carrying whatever was typed into the chooser's search field, so the
        /// handover does not throw it away.
        case compose(String)
        var id: String {
            switch self {
            case .attach:  return "attach"
            case .compose: return "compose"
            }
        }
        var draftTitle: String {
            if case .compose(let title) = self { return title }
            return ""
        }
    }
    @State private var attachedExpanded = false
    /// The schedule band's fold. Two days, like the Mac's (Session 88).
    @State private var scheduleExpanded = false
    /// The PLACES band's fold: visit-derived rows, closed by default (D354,
    /// iOS half). **Its own flag, not `scheduleExpanded` or `attachedExpanded`**
    /// - one flag shared between two folds opens both at once for no reason a
    /// reader could see, which is the same note the Mac wrote when it kept this
    /// separate from the rail's.
    @State private var showVisitedPlaces = false
    /// How far each OPEN TASKS row is slid, keyed by task id (Session 88).
    @State private var taskRowOffsets: [String: CGFloat] = [:]
    /// Which booking the sheet is editing, or which band's `+` opened it.
    @State private var bookingTarget: BookingTarget? = nil
    /// Crossfade in/out (Session 78 round three) — the cover presents with
    /// animations disabled (no slide, David's call), so the screen fades
    /// itself. Copied from DayflowNoteFullPageView (D162).
    @State private var appeared = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var endeavor: Endeavor? { store.endeavor(id: endeavorID) }

    var body: some View {
        // **The top bar is the first child, not a `safeAreaInset`** (Session
        // 89, on David's TestFlight build).
        //
        // It was `.safeAreaInset(edge: .top)` on this Group, inside a
        // `NavigationStack` in a `fullScreenCover` with the navigation bar
        // hidden. On his phone ENDEAVOR and Done were drawn INSIDE the status
        // bar, overlapping the Dynamic Island, and Done could not be tapped.
        //
        // `DayflowNoteFullPageView` wears the same row — this file's own
        // comment says the row copied its grammar — and that screen has always
        // been right on his phone. It puts the header as the first child of a
        // plain VStack and uses no inset at all. Copying the shape that works
        // beats reasoning about why the other one does not.
        //
        // The `safeAreaInset` further down this file stays: it is inside a
        // SHEET, where the behaviour differs and where it exists to keep a
        // text field out of a scroll view rather than to place a bar.
        //
        // **Not proven until David builds it.** A mechanism plus a real
        // symptom is not a diagnosis (D283) — but this is the same row, in the
        // same app, laid out the way the working copy lays it out.
        VStack(spacing: 0) {
            endeavorTopBar
            Group {
                if let endeavor {
                    content(endeavor)
                } else {
                    // The note was deleted or renamed out from under this screen.
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                        Text("This Endeavor is no longer there.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dayflowSkinBackground()
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2)) { appeared = true }
        }
        // Editorial chrome (Session 78, D181's second piece): the system
        // nav bar (Done pill, glyph capsule) is hidden; the screen wears the
        // day-note full page's own top row instead — kicker left, the
        // details Menu and Done in ink on the right.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingDetails) {
            DayflowEndeavorDetailsSheet(existing: endeavor)
        }
        .sheet(isPresented: $showingTripLog) {
            if let e = endeavor {
                // **THE BODY IS READ INSIDE THE CLOSURES, NEVER PASSED IN.**
                //
                // This passed `currentBody: body_`, and a `.sheet` builds its
                // content from a SNAPSHOT of the view — a sibling `@State` read
                // in that closure is not guaranteed to be the current value.
                // `body_` arrived EMPTY, `TripLog.append` appended to nothing,
                // and the write replaced David's note with just the trip log.
                // It also made every day look unwritten, which is why no day was
                // marked "already in note".
                //
                // Identical to the `captureIncoming` bug in Satchel earlier the
                // same day, and diagnosed there before being written here. A
                // closure is evaluated when it is CALLED, so `liveBody()` below
                // is always current; a value is captured when the view is BUILT.
                EndeavorTripLogSheet(
                    endeavor: e,
                    liveBody: { body_ },
                    onWrite: { days in
                        // SAFETY NET, added after this exact write destroyed a
                        // note on 2026-08-01. An empty live body while the stored
                        // note has content can only mean the editor has not
                        // loaded — and appending to nothing then saving replaces
                        // the note with the append. Refuse rather than write.
                        let live = body_
                        let liveEmpty = live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let storedHasContent = !e.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        guard !(liveEmpty && storedHasContent) else { return }

                        let updated = TripLog.append(days, to: live)
                        body_ = updated
                        save(updated, into: e)
                    }
                )
            }
        }
        .sheet(item: $attaching) { kind in
            NavigationStack {
                EndeavorAttachPicker(kind: kind == .place ? .place : .person,
                                     endeavor: endeavor) { name in
                    if let e = endeavor { attach(name, kind: kind, to: e) }
                }
            }
        }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target, sourceNoteText: body_)
            }
        }
        // A pill that does nothing is indistinguishable from a pill that is
        // broken, and David reported these as "not clickable" — which is what
        // silence looks like from the outside. See `resolveWikiLink`.
        // Every host presents this view inside a `NavigationStack`. This
        // comment once said "checked, all four". D301 counted six and found
        // the backlinks door bare; D303 counted again with a grep of the call
        // itself and found SEVEN: DayflowEndeavorViews (the list),
        // ContentView (the route), DayflowProjectNoteView, DayflowVisitDetailView,
        // DayflowWikiSummaryView, DayflowTaskEditSheet, and DayflowBacklinksView,
        // whose body swap now wraps it too. A `navigationDestination` with no
        // stack above it compiles, renders and does nothing, which is why a
        // bare host is silent. Count with the grep, not from memory.
        .navigationDestination(item: $pushedNoteTitle) { title in
            DayflowProjectNoteView(title: title, onBack: { pushedNoteTitle = nil })
        }
        .dayflowWikiMissAlert($wikiMiss)
        .task(id: noteStore.hasAccess) {
            store.reload()
            guard !loaded, let endeavor else { return }
            body_ = endeavor.body
            loaded = true
        }
        // **The bands need `bookingsLoad` to have been ASKED.** The launch
        // task fetches bookings, but this screen can be reached in a session
        // where that ran before Notion was reachable, and an idle load draws
        // no band at all rather than an empty one - which would look like an
        // endeavor with nothing on it. Only when idle: a `.failed` stays
        // failed until something retries it deliberately, and re-fetching on
        // every appearance would hide a real outage behind a spinner.
        .task {
            if NotionService.shared.bookingsLoad == .idle {
                await NotionService.shared.fetchBookings()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.reload()
        }
    }

    @ViewBuilder
    private func content(_ e: Endeavor) -> some View {
        // **THE PAGE SCROLLS** (D303, Session 90). It did not, and once D279's
        // bands were on it the fixed stack ran taller than the display. A
        // view taller than the space it is offered is CENTRED, so the overflow
        // split top and bottom and the ENDEAVOR row went above the glass,
        // measured at y = -2 against the day note page's 62 (D302). Four
        // fixes aimed at safe areas and navigation moved it by zero pixels,
        // because none of them changed how much content there was.
        //
        // The shape: the top row stays outside this, pinned. Everything else
        // is one `ScrollView`, and the editor is given a REAL height inside
        // it: `viewport - chrome`, floored at `editorFloor` when the bands
        // push it down, exactly `viewport - chrome` while typing. Inside a
        // scroll view a `maxHeight: .infinity` editor is offered no height
        // and collapses to nothing with its footer rows climbing over the
        // text. The home screen learned that on 2026-08-28 and answered it
        // with `.frame(height: 360)` on the Daily Note card. Same answer
        // here, with the number measured rather than fixed. A `UITextView`
        // inside a scroll view is already the home card's daily reality;
        // "Bug 4" (stale contentSize) was fixed in the editor itself and
        // covers every host.
        //
        // The three wrapping lines below are deliberately NOT re-indented
        // with the body they wrap. Re-indenting 140 lines is how Session 89
        // put English into ContentView as Swift.
        GeometryReader { viewport in
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            // Everything above the editor, measured as one block so the
            // editor can take exactly what is left (D303). Same alignment and
            // spacing as its parent, so the nesting draws nothing.
            VStack(alignment: .leading, spacing: 0) {
            // COLLAPSE WHILE TYPING. David, 2026-07-31: *"when i click in the note
            // section the keyboard jumps up and dominates the screen and i cant see
            // the note any more."*
            //
            // Measured rather than eyeballed: the full header runs about 310pt
            // (cover 132, name at 27pt, two pills, date, countdown, padding), and
            // with the chips and Add Document rows the fixed chrome is near 400.
            // The keyboard and the editor's own toolbar take about 380. That left
            // roughly 65pt of editor — two lines — on the screen whose entire
            // purpose is writing.
            //
            // The name stays (David's call, and the right one: an editor that does
            // not say what it is editing is its own small problem). Everything else
            // returns the moment the keyboard goes down.
            //
            // The collapse stays now that the page scrolls (D303): scrolling
            // answers "the bands are taller than the screen", not "the keyboard
            // covers the note". While typing the editor is sized to the room
            // above the keyboard and the page has nothing left to scroll.
            if editorFocused {
                compactHeader(e)
            } else {
                header(e)
            }

            // Free, because the chip reader asks "which sidecars name this
            // note?" and has no idea what kind of note it is being asked about.
            // An Endeavor note is a note like any other.
            DayflowNoteTagBar(text: $body_, onCommit: { save($0, into: e) }, attach: $attachRequest)

            // Both rows are ABOUT the note rather than part of it, so they yield
            // to the note while it is being written. The tag bar stays: it is one
            // line, its pills are the note's own subject, and its Attach button is
            // useful mid-sentence.
            if !editorFocused {
                // THE BODY, in the order this endeavor's TYPE gives it
                // (D268, Session 88). Bands, then the tasks, or the
                // tasks then the bands on a Project - see
                // `endeavorBody`. OPEN TASKS is unchanged and is
                // still drawn exactly once.
                endeavorBody(e)

                // The clutter fix (David: "destinations, people, notes...
                // there has to be a better way" on iOS). The chip rows
                // and the documents fold behind ONE quiet row, collapsed by
                // default with the count on the label — the same move
                // FINISHED and RELATED NOTES already make. The Mac keeps its
                // rail; a phone screen is for the note and the tasks.
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { attachedExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("ATTACHED \u{00B7} \(attachedCount(e))")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.6)
                        Image(systemName: attachedExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color.dayflowFaint)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if attachedExpanded {
                    attachedChips(e)
                    SatchelDocumentChips(notePath: e.relativePath, endeavorID: e.id, grouped: true)
                    SatchelAddDocumentButton(notePath: e.relativePath, style: .bar)
                }
            }
            } // the chrome above the editor (D303)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                chromeAboveEditor = height
            }

            // D4: the editor gets prose only. `body_` is what the store split
            // off; saving puts it back with the frontmatter re-rendered around
            // it, so nothing the user types can corrupt the fields and nothing
            // the fields do can disturb what they typed.
            MarkdownEditorView(
                text: $body_,
                onSave: { newBody in save(newBody, into: e) },
                placeholder: "Summary, plan, open items…",
                // Declaration order: onFocusChange comes after `placeholder` and
                // before `relativePath`. Swift requires call-site order to match.
                onFocusChange: { focused in editorFocused = focused },
                relativePath: e.relativePath,
                // WIKILINKS, added 2026-07-31. David tried to link the place
                // "Nicks on the Lake" from an Endeavor note and got no suggestion
                // pills, because this editor was never handed the two closures
                // that produce them.
                //
                // Third time this exact omission has been found: the Daily Note
                // had them from Session 5, Project Notes were missing them until
                // Session 13, and Endeavor notes since they were built. The
                // editor asks for them per call site and says nothing when a
                // caller leaves them out — the feature simply does not exist on
                // that screen, and looks like a bug in autocomplete rather than
                // a missing argument. Worth checking any FUTURE host against
                // this list rather than waiting to be told.
                onWikiTap: { name in resolveWikiLink(name) },
                wikiSuggestions: { query in wikiSuggestions(for: query) },
                attachTrigger: $attachRequest,
                // Checkbox → task (Session 78): swipe right on a ☐ line in
                // the endeavor's note files a real task linked [[name]] —
                // it lands in OPEN TASKS above. Checking the dimmed ↗ line
                // completes it.
                onPromoteTask: { line, done in promoteEndeavorTask(line, e, done) },
                onCompletePromoted: { line in completeEndeavorTask(titled: line, e) }
            )
            // **A definite height, not `maxHeight: .infinity`** (D303, Session
            // 90). This was `minHeight: 180, maxHeight: .infinity` from Session
            // 72, when David found Megan's Wedding Week had squeezed the note
            // to one line and the fix was a floor. That worked in a fixed
            // stack. Inside the page's `ScrollView` an infinite maxHeight is
            // offered nothing and collapses, so the editor is now told its
            // height outright: the room left under the chrome, never less than
            // `editorFloor` when the bands are showing, exactly the room above
            // the keyboard while typing. See `editorHeight(viewport:)`.
            .frame(maxWidth: .infinity)
            .frame(height: editorHeight(viewport: viewport.size.height))
            // **The inline editor IS the typing surface again (Session 78).**
            //
            // The full-screen editor cover (Session 72's answer) earned its
            // keep when the fixed chrome ate ~400pt and typing inline left two
            // lines. That chrome is gone: the header collapses to one serif
            // line while focused, and the chip rows now fold behind ATTACHED.
            // David, on the two-hop that remained: "when i tap the note I get
            // another upward screen to the full note to type in." Tap, type,
            // done — and wikilinks and capture markers are tappable inline
            // again, which the old tap-catcher had traded away.
        }
        .animation(.easeInOut(duration: 0.2), value: editorFocused)
        } // ScrollView (D303)
        // A short endeavor fits, and a page that fits should not bounce like
        // one with more to give.
        .scrollBounceBehavior(.basedOnSize)
        } // GeometryReader (D303)
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await ReminderTaskStore.shared.refreshAll() }
            }
        }
        .sheet(item: $taskSheet) { which in
            if let live = endeavor {
                switch which {
                case .attach:
                    DayflowEndeavorTaskAttachSheet(
                        endeavorName: live.name,
                        link: EndeavorFile.link(named: live.name),
                        tasks: ReminderTaskStore.shared.allTasks,
                        onAttach: { picked in await attachTasks(picked, to: live) },
                        onNewTask: { typed in taskSheet = .compose(typed) })
                case .compose:
                    // `compact: false` - this shares its presentation with the
                    // chooser above, so both arms must size the same way.
                    DayflowNoteTaskSheet(anchor: live.name,
                                         initialTitle: which.draftTitle,
                                         compact: false)
                }
            }
        }
        // **On `content`, not on the outer `Group`.** That one already carries
        // four `.sheet` modifiers and this file's own comment records what
        // stacking them costs: the later one wins silently. The two task
        // sheets live here for the same reason.
        .sheet(item: $bookingTarget) { target in
            // Re-read rather than using the captured `e`, the rule the trip
            // log sheet above learned the hard way: a value is captured when
            // the view is BUILT, and this sheet writes to Notion under the
            // endeavor's slug.
            if let live = endeavor {
                DayflowBookingSheet(endeavor: live,
                                    existing: target.booking,
                                    seedLedger: target.isLedger)
            }
        }
    }

    // `fullScreenEditor` retired (Session 78): the inline editor is the
    // typing surface again — see the note above the editor's frame.

    /// The Editorial top row — DayflowNoteFullPageView's grammar: caps
    /// kicker, quiet menu glyph, Done as plain ink text. The menu keeps its
    /// two residents (Details, Add what happened…) — a menu rather than two
    /// glyphs, for the reason the old toolbar recorded: two unlabeled glyphs
    /// in a row is a guessing game.
    private var endeavorTopBar: some View {
        HStack(spacing: 0) {
            Text("ENDEAVOR")
                .font(.system(size: 11, weight: .medium))
                .tracking(2.2)
                .foregroundStyle(Color.dayflowMuted)
            Spacer()
            Menu {
                Button {
                    showingDetails = true
                } label: {
                    Label("Details", systemImage: "slider.horizontal.3")
                }
                if endeavor?.starts != nil && endeavor?.ends != nil {
                    Button {
                        showingTripLog = true
                    } label: {
                        Label("Add what happened…", systemImage: "text.badge.plus")
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dayflowMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            Button { fadeOut() } label: {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dayflowInk)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(Color.dayflowPaper)
    }

    /// D162's crossfade out: content fades, then the cover drops with
    /// animations disabled so no slide sneaks in behind it.
    private func fadeOut() {
        withAnimation(.easeInOut(duration: 0.16)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { dismiss() }
        }
    }

    /// What the note gets on the page (D303). The room left under the chrome,
    /// never less than `editorFloor` when the bands are showing; while typing
    /// exactly the room above the keyboard, so the page has nothing left to
    /// scroll and cannot move under the caret. The 80 is a sanity floor for
    /// the one layout pass before `chromeAboveEditor` has been measured, and
    /// for a keyboard that leaves almost nothing.
    private func editorHeight(viewport: CGFloat) -> CGFloat {
        let remaining = viewport - chromeAboveEditor
        return max(editorFocused ? 80 : editorFloor, remaining)
    }

    /// The header while the keyboard is up: the name, and nothing else.
    private func compactHeader(_ e: Endeavor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(e.name)
                .font(.dayflowSerif(17, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
                .lineLimit(1)
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func header(_ e: Endeavor) -> some View {
        let status = e.status()
        // Redesign (Session 78): Editorial masthead — cover full-bleed, then
        // a caps kicker line (TYPE in its tint, STATUS in its own), serif
        // name, caps date + DAY N, one ink rule. The card panel and capsule
        // pills retired with the rest of the Notes world's.
        return VStack(alignment: .leading, spacing: 0) {
            if let cover = e.cover {
                EndeavorCoverImage(path: cover, height: 132, offset: e.coverOffset)
                    .padding(.bottom, 14)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(e.type.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(e.typeColor)
                    Text(status.label.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(status.tint)
                }
                .padding(.bottom, 5)

                Text(e.name)
                    .font(.dayflowSerif(26, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                    .padding(.bottom, 7)

                HStack(spacing: 10) {
                    Text(endeavorDateLabel(e).uppercased())
                        .font(.system(size: 10.5, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(Color.dayflowMuted)
                    if let countdown = endeavorCountdownLabel(e) {
                        Text(countdown.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(1.0)
                            .foregroundStyle(Color.dayflowAccent)
                    } else if let figure = typeFigure(e) {
                        Text(figure.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(1.0)
                            .foregroundStyle(Color.dayflowAccent)
                    }
                }

                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 13)
    }

    // `pill(_:tint:)` retired with the header's capsules (Session 78
    // redesign) — the kicker line carries type and status as caps now.

    // MARK: - The body's bands (Session 88, D268 on the phone)
    //
    // The Mac gained two band shapes in Sessions 86 and 87 and a PLACES band
    // in D273, and the phone drew none of them. **Everything below is view
    // work.** `Booking`, `BookingStatus`, `BookingKind` and every band helper
    // on `Endeavor` were already compiled into this target and had never been
    // read here - there were zero occurrences of "Booking" in `Dayflow/`.
    //
    // **No view here switches on the endeavor's type.** `scheduleBandLabel`
    // and `ledgerBandLabel` return the word or nil, and a nil band is an
    // absent band, which is what keeps the ledger off a trip and the schedule
    // off a decision without either one naming a type. That rule is D268's and
    // it is why the phone's half of this is small.

    /// What the booking sheet was opened FOR.
    ///
    /// `newLedger` is not a mode and not a second sheet: it is three seeds -
    /// no date, Kind `Other`, Status `Quoted` - on the one editor, because a
    /// `+` on QUOTES that opened a dated Flight would be asking for the shape
    /// the band it came from cannot show.
    private enum BookingTarget: Identifiable {
        case new
        case newLedger
        case edit(Booking)
        var id: String {
            switch self {
            case .new:         return "new"
            case .newLedger:   return "new-ledger"
            case .edit(let b): return b.id
            }
        }
        var booking: Booking? {
            if case .edit(let b) = self { return b }
            return nil
        }
        var isLedger: Bool {
            if case .newLedger = self { return true }
            return false
        }
    }

    /// One line on the schedule, which is not one booking.
    ///
    /// **A booking whose end falls on a later day makes two lines** (D268). A
    /// calendar draws a multi-day thing as a bar across its grid; a list of
    /// days has no grid to cross, so it splits - and on the morning you leave,
    /// "check out, 11:00" is what you need rather than a row filed four days
    /// earlier.
    private struct BookingEntry: Identifiable {
        let booking: Booking
        let isEnd: Bool
        var date: Date? { isEnd ? booking.end : booking.start }
        var id: String { isEnd ? booking.id + "-end" : booking.id }
    }

    /// One day's entries. Undated rows share the key `undated`, carry no
    /// numeral and sort last.
    private struct BookingDay: Identifiable {
        let id: String
        let numeral: String
        let label: String
        let entries: [BookingEntry]
    }

    /// Days shown before the fold. Two, for the Mac's reason and more so: on
    /// the morning you leave, the next two days with something on them are the
    /// whole answer, and this screen is a phone.
    private static let scheduleDayCap = 2

    private static let bookingDayKey: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let bookingDayNumeral: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    private static let bookingDayWord: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM"; return f
    }()
    private static let bookingTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let bookingMoney: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f
    }()

    private func spansDays(_ b: Booking) -> Bool {
        guard let start = b.start, let end = b.end else { return false }
        return !Calendar.current.isDate(start, inSameDayAs: end)
    }

    /// **A Bookings row with a cost and no date is a ledger line** (D268).
    /// No flag, no second database, and no switch on the type to decide what a
    /// row IS - the row's own two fields decide, and the type only decides
    /// whether there is a band to put it in. Zero is not a cost.
    private func isLedgerRow(_ b: Booking) -> Bool {
        b.start == nil && (b.cost ?? 0) > 0
    }

    private func entryIsBefore(_ a: BookingEntry, _ b: BookingEntry) -> Bool {
        switch (a.date, b.date) {
        case let (x?, y?):
            if x != y { return x < y }
            if a.booking.name != b.booking.name { return a.booking.name < b.booking.name }
            return !a.isEnd && b.isEnd
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.booking.name < b.booking.name
        }
    }

    private func bookingEntries(_ e: Endeavor) -> [BookingEntry] {
        // **A row belongs to one band, never two** (warning FIVE). When this
        // endeavor HAS a ledger, its ledger lines come out of the schedule
        // band; when it does not, an undated costed row stays in the Undated
        // bucket. Filtering unconditionally would make a real Notion row
        // appear on no screen at all - see `Endeavor.ledgerBandLabel`.
        let hasLedger: Bool = e.ledgerBandLabel != nil
        var out: [BookingEntry] = []
        for booking in NotionService.shared.bookings(for: e.id) {
            if hasLedger, isLedgerRow(booking) { continue }
            out.append(BookingEntry(booking: booking, isEnd: false))
            if spansDays(booking) {
                out.append(BookingEntry(booking: booking, isEnd: true))
            }
        }
        return out.sorted(by: entryIsBefore)
    }

    private func bookingDays(_ e: Endeavor) -> [BookingDay] {
        let rows = bookingEntries(e)
        var order: [String] = []
        var buckets: [String: [BookingEntry]] = [:]
        var numerals: [String: String] = [:]
        var labels: [String: String] = [:]
        for entry in rows {
            let key: String
            if let date = entry.date {
                let day = Calendar.current.startOfDay(for: date)
                key = Self.bookingDayKey.string(from: day)
                numerals[key] = Self.bookingDayNumeral.string(from: day)
                labels[key] = Self.bookingDayWord.string(from: day)
            } else {
                key = "undated"
                numerals[key] = ""
                labels[key] = "Undated"
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map {
            BookingDay(id: $0, numeral: numerals[$0] ?? "",
                       label: labels[$0] ?? "", entries: buckets[$0] ?? [])
        }
    }

    /// **A range only when both ends fall on the same day.** Each line of a
    /// spanning booking is a moment rather than a duration, and the hotel's
    /// check-in row read "10:13 AM - 10:13 AM" on the Mac before this. A dated
    /// booking with no clock time reads "All day": the column is there either
    /// way and an empty cell looks like a bug.
    private func entryTime(_ entry: BookingEntry) -> String {
        let b = entry.booking
        guard let date = entry.date else { return "" }
        guard b.hasTime else { return "All day" }
        if !entry.isEnd, let start = b.start, let end = b.end, !spansDays(b) {
            return Self.bookingTime.string(from: start) + " - " + Self.bookingTime.string(from: end)
        }
        return Self.bookingTime.string(from: date)
    }

    /// "Check in" / "Check out", in the kind's own words, and only on a
    /// booking that spans days where one line of two needs to say which it is.
    /// `BookingKind.labels` already holds this vocabulary for the Mac's sheet.
    private func entryQualifier(_ entry: BookingEntry) -> String {
        guard spansDays(entry.booking) else { return "" }
        let labels = BookingKind.labels(for: entry.booking.kind)
        return entry.isEnd ? labels.end : labels.start
    }

    /// First names, resolved from Notion People by relation id. **An id that
    /// resolves to nobody is skipped, not printed** - a raw UUID mid-line is
    /// noise no one can act on.
    private func bookingWho(_ b: Booking) -> String {
        let names: [String] = b.whoIDs.compactMap { id in
            NotionService.shared.people.first { $0.id == id }?.name
        }
        return names.compactMap { $0.split(separator: " ").first.map(String.init) }
                    .joined(separator: ", ")
    }

    private func bookingCost(_ b: Booking) -> String {
        guard let cost = b.cost, cost > 0 else { return "" }
        return Self.bookingMoney.string(from: NSNumber(value: cost)) ?? ""
    }

    /// The schedule row's second line.
    private func scheduleSub(_ b: Booking) -> String {
        var parts: [String] = []
        if let provider = b.provider, !provider.isEmpty { parts.append(provider) }
        let who = bookingWho(b)
        if !who.isEmpty { parts.append(who) }
        if let c = b.confirmation, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The LEDGER row's second line.
    ///
    /// **The provider is dropped when it is already the headline.** On Kind
    /// `Other`, which is what a quote usually is, `writtenName` builds the
    /// Name out of the provider, so a quote with only a provider is named
    /// after it and `scheduleSub` would print that same word directly under
    /// its own headline. The schedule band never hits this because a journey's
    /// name leads with its number and a stay's ends in a night count.
    private func ledgerSub(_ b: Booking, headline: String) -> String {
        var parts: [String] = []
        let provider = (b.provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !provider.isEmpty, provider != headline { parts.append(provider) }
        let who = bookingWho(b)
        if !who.isEmpty { parts.append(who) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// This endeavor's ledger rows, cheapest first.
    ///
    /// **Cheapest first rather than accepted first.** A ledger is read to
    /// compare, and prices out of order are work the reader does twice. The
    /// accepted row is found by its wash rather than by its position, which
    /// also stops it jumping to the top the moment it is chosen.
    private func ledgerRows(_ e: Endeavor) -> [Booking] {
        NotionService.shared.bookings(for: e.id)
            .filter(isLedgerRow)
            .sorted {
                let a = $0.cost ?? 0
                let b = $1.cost ?? 0
                if a != b { return a < b }
                return $0.name < $1.name
            }
    }

    // MARK: Band chrome

    /// One header for every band on this screen, in the grammar OPEN TASKS
    /// already spoke: caps label, count, an optional `+`, an ink rule.
    ///
    /// **One function, not four.** On a Project all four bands are on screen
    /// at once, and headers written separately drift the first time any one of
    /// them changes - standing warning FIVE, and the same extraction the Mac
    /// made in Session 87.
    ///
    /// `onAdd` is optional: a band with no door draws no `+`, because a button
    /// that opens nothing is worse than no button.
    private func bandHeader(_ label: String,
                            count: Int,
                            addLabel: String = "Add",
                            onAdd: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Color.dayflowFaint)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dayflowFaint)
                }
                Spacer()
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dayflowFaint)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(addLabel)
                }
            }
            .padding(.bottom, 4)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
        }
    }

    private func bandEmpty(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
    }

    /// A hairline under every band row, so the three bands read as one system.
    private var bandHair: some View {
        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
    }

    // MARK: The schedule band

    /// ITINERARY on a Travel endeavor, SCHEDULE on Milestone, Gathering and
    /// Project, and absent on a Decision - all of it from
    /// `Endeavor.scheduleBandLabel`, which is why no type is named here.
    ///
    /// **Three states off `bookingsLoad`, not two** (warning TWELVE). Idle and
    /// loading draw nothing at all, so no heading flashes in before the answer
    /// and nothing claims an absence while the fetch is in flight. `.failed`
    /// says Notion did not answer, which is a different statement from "there
    /// are none" - and the likeliest first failure of this feature is the
    /// integration not being connected to the database, which returns nothing.
    ///
    /// **The count is of BOOKINGS, not lines.** A hotel is one reservation
    /// drawn on two lines for the same reason a flight has a departure and an
    /// arrival; the second line is a rendering decision, not a second thing
    /// bought. David caught this on the Mac in Session 87.
    ///
    /// **The `+` and the row both open `DayflowBookingSheet`.** They did not
    /// when this band first shipped, on the reasoning that a door which is
    /// drawn and does not open is worse than no door - true, and the wrong
    /// conclusion. David: *"there is no plus sign to open anything for Quote,
    /// Schedule."* The answer to a band with no editor is the editor.
    ///
    /// One sheet for both bands, because there is one Bookings row.
    @ViewBuilder
    private func scheduleBand(_ e: Endeavor) -> some View {
        let state = NotionService.shared.bookingsLoad
        let settled = state == .loaded || state == .failed
        let days = bookingDays(e)
        let count = Set(days.flatMap { $0.entries.map(\.booking.id) }).count
        let shown = scheduleExpanded ? days : Array(days.prefix(Self.scheduleDayCap))
        let hidden = days.count - shown.count
        if let bandLabel = e.scheduleBandLabel, settled {
            VStack(alignment: .leading, spacing: 0) {
                bandHeader(bandLabel, count: count,
                           addLabel: "Add a booking") { bookingTarget = .new }
                if state == .failed {
                    bandEmpty("Notion did not answer.")
                } else if days.isEmpty {
                    bandEmpty("Nothing booked yet.")
                } else {
                    ForEach(shown) { day in
                        scheduleDayLead(day)
                        ForEach(day.entries) { entry in scheduleRow(entry) }
                    }
                    if hidden > 0 || scheduleExpanded {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { scheduleExpanded.toggle() }
                        } label: {
                            Text(scheduleExpanded ? "SHOW FEWER DAYS"
                                 : (hidden == 1 ? "+ 1 MORE DAY" : "+ \(hidden) MORE DAYS"))
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.4)
                                .foregroundStyle(Color.dayflowMuted)
                                .padding(.top, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
    }

    /// The day's own heading. A serif numeral, because a day is the structure
    /// of a trip; smaller than the Mac's, because this is a phone.
    private func scheduleDayLead(_ day: BookingDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !day.numeral.isEmpty {
                Text(day.numeral)
                    .font(.dayflowSerif(20, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
            }
            Text(day.label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Color.dayflowMuted)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.bottom, 1)
    }

    /// One entry, two lines rather than the Mac's four columns.
    ///
    /// **What the phone drops, and what it does not.** The Mac gives the time
    /// its own 148pt column and the confirmation its own cell; at this width
    /// both would squeeze the name, which is the row's subject. So the time
    /// goes to the right of the headline and the confirmation joins the second
    /// line with the provider and who is on it. Nothing is dropped: a
    /// confirmation code is what you need standing at a counter, and a screen
    /// that holds one and does not show it is the shape this app has already
    /// been bitten by five times.
    ///
    /// **NOT BOOKED and the cost show on the opening line only.** Being booked
    /// is a fact about the whole reservation and a price is not paid twice.
    private func scheduleRow(_ entry: BookingEntry) -> some View {
        let b = entry.booking
        let tint = dayflowTint(BookingKind.tint(for: b.kind))
        let glyph = BookingKind.glyph(for: b.kind)
        // A hand-added row can reach Notion with no Name. The kind is a poorer
        // headline than "UA 1642 - DEN to ORD" and a much better one than a
        // blank line where the subject should be.
        let headline = b.name.isEmpty ? b.kind : b.name
        let qualifier = entryQualifier(entry)
        let sub = scheduleSub(b)
        let time = entryTime(entry)
        let cost = entry.isEnd ? "" : bookingCost(b)
        let isPast = (entry.date).map { $0 < Date() } ?? false
        let showNotBooked = !b.booked && !entry.isEnd
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(headline)
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                if !qualifier.isEmpty {
                    Text(qualifier.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(Color.dayflowFaint)
                }
                Spacer(minLength: 6)
                Text(time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dayflowMuted)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spacer().frame(width: 16)
                if !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dayflowMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if showNotBooked {
                    Text("NOT BOOKED")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(Color.dayflowAccent)
                }
                if !cost.isEmpty {
                    Text(cost)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dayflowInk)
                }
            }
        }
        .padding(.vertical, 7)
        .opacity(isPast ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { bookingTarget = .edit(b) }
        .overlay(alignment: .bottom) { bandHair }
    }

    // MARK: The ledger band

    /// QUOTES on a Project, OPTIONS on a Decision, nil everywhere else - from
    /// `Endeavor.ledgerBandLabel`, so again no type is named here.
    ///
    /// **No fold.** The schedule band caps at two days because a nine-day trip
    /// has more days than this screen can spare. A ledger is the three or four
    /// things being compared, and hiding some of them hides the comparison.
    @ViewBuilder
    private func ledgerBand(_ e: Endeavor) -> some View {
        let state = NotionService.shared.bookingsLoad
        let settled = state == .loaded || state == .failed
        let rows = ledgerRows(e)
        if let bandLabel = e.ledgerBandLabel, settled {
            VStack(alignment: .leading, spacing: 0) {
                bandHeader(bandLabel, count: rows.count,
                           addLabel: "Add a \(bandLabel.dropLast().lowercased())") {
                    bookingTarget = .newLedger
                }
                if state == .failed {
                    bandEmpty("Notion did not answer.")
                } else if rows.isEmpty {
                    bandEmpty("No \(bandLabel.lowercased()) yet.")
                } else {
                    ForEach(rows) { b in ledgerRow(b) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
    }

    /// One ledger row.
    ///
    /// **The accepted row carries a faint accent wash, at 0.06.** A decision
    /// that has been made should be visible without reading three prices. Not
    /// 0.12, which is what this app washes a selected row with: at 0.12 the
    /// chosen quote and a highlighted row would be the same colour, and the
    /// one that means something would be the one that does not.
    ///
    /// **A declined row is dimmed, not struck and not dropped.** It is part of
    /// the comparison: what it cost is why the accepted one was chosen.
    ///
    /// **A quoted row says nothing at the right.** Quoted is the resting state
    /// of every row in the band, and a column that prints the same word on
    /// every line says nothing. `BookingStatus.rowLabel` already returns nil
    /// for it, and is total over `String`, so a fourth option typed into
    /// Notion counts as open rather than crashing or vanishing.
    private func ledgerRow(_ b: Booking) -> some View {
        let tint = dayflowTint(BookingKind.tint(for: b.kind))
        let glyph = BookingKind.glyph(for: b.kind)
        let headline = b.name.isEmpty ? b.kind : b.name
        let sub = ledgerSub(b, headline: headline)
        let cost = bookingCost(b)
        let accepted = BookingStatus.isAccepted(b.status)
        let declined = BookingStatus.isDeclined(b.status)
        let stateLabel = BookingStatus.rowLabel(b.status) ?? ""
        let stateColor = accepted ? Color.dayflowAccent : Color.dayflowMuted
        let wash = accepted ? Color.dayflowAccent.opacity(0.06) : Color.clear
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(headline)
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(cost)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dayflowInk)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spacer().frame(width: 16)
                if !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dayflowMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if !stateLabel.isEmpty {
                    Text(stateLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(stateColor)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .background(wash)
        .opacity(declined ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { bookingTarget = .edit(b) }
        .overlay(alignment: .bottom) { bandHair }
    }

    // MARK: The PLACES band (D273)

    /// One place on this endeavor: planned, visited, or both.
    ///
    /// **Two things were one thing in two tenses.** The Destinations chip row
    /// held what David attached; the trip log held where he turned up. Attach
    /// Gibsons, check in at Gibsons, and the screen said nothing to connect
    /// them. David: *"I will add places that i want to go... I also may go
    /// places during a trip that were never on the destination place in the
    /// first place and then it appears in the endeavor after the fact."*
    private struct EndeavorPlace: Identifiable {
        let name: String
        let attached: Bool
        let visitDate: Date?
        let skipped: Bool
        var id: String
    }

    /// The one key this band matches on, and the same one the Mac's band and
    /// its catch-up panel use. **Two matchers would eventually let one screen
    /// say "went" about a place another is still asking about.**
    private func placeKey(_ name: String) -> String {
        TripLog.shortPlaceName(name).lowercased()
    }

    /// Planned first, in the order he attached them, then anywhere he went
    /// that he never planned.
    ///
    /// **"Went" is a check-in inside the endeavor's dates**, David's own
    /// definition, day-granular at both ends through `Endeavor.covers`.
    ///
    /// **Warning TWELVE is satisfied by the DEFAULT, not by a guard.** A place
    /// with no matching check-in shows NOTHING at its right, never "Didn't
    /// go" - that word comes only from `skippedPlaces`, which is stored rather
    /// than derived. So an unfetched `visits` array costs an absent row and
    /// never a false statement.
    private func endeavorPlaces(_ e: Endeavor) -> [EndeavorPlace] {
        let tripVisits = NotionService.shared.visits
            .filter { e.covers($0.date) }
            .sorted { $0.date < $1.date }
        var firstVisit: [String: Date] = [:]
        for v in tripVisits {
            let k = placeKey(v.placeName)
            if let seen = firstVisit[k], seen <= v.date { continue }
            firstVisit[k] = v.date
        }
        let skipped = Set(e.skippedPlaces.map(placeKey))

        var out: [EndeavorPlace] = []
        var seen = Set<String>()
        for name in e.places {
            let k = placeKey(name)
            guard seen.insert(k).inserted else { continue }
            out.append(EndeavorPlace(name: name, attached: true,
                                     visitDate: firstVisit[k],
                                     skipped: skipped.contains(k), id: k))
        }
        for v in tripVisits {
            let k = placeKey(v.placeName)
            guard seen.insert(k).inserted else { continue }
            out.append(EndeavorPlace(name: v.placeName, attached: false,
                                     visitDate: firstVisit[k],
                                     skipped: false, id: k))
        }
        return out
    }

    /// PLACES, under the schedule and above the note (D273).
    ///
    /// **Every type gets this band**, unlike the other two. A trip has places,
    /// a gathering happens somewhere, a project has a site. A type that
    /// silently could not attach a place would be a second rule to remember.
    ///
    /// It replaces the Destinations chip row inside the ATTACHED fold, which
    /// could not carry a second line and so could not say "Went - Sat 21 Nov".
    @ViewBuilder
    private func placesBand(_ e: Endeavor) -> some View {
        let rows = endeavorPlaces(e)
        // **Attached rows are the band; visits collapse** (D354, iOS half).
        //
        // David, on Megan's Wedding Week finished with 24 visits: *"you warned
        // me about the places overlap with the rail... i see this as
        // untenable."* The Mac had the worse version of it - PLACES and the
        // rail's Trip log printing the same list twice, side by side - and this
        // screen has no rail, so only half of that reason ports. The half that
        // does is the half that matters here: 3 places he chose and 21 he
        // merely passed through, at equal weight, down a phone.
        //
        // **The rule is the Trip log's own, applied to a second list.** Its
        // comment: *"They are the pool the log is selected from, and a pool is
        // only interesting while you are choosing from it."*
        //
        // Nothing is hidden and nothing is deleted. The header still counts all
        // of them, so 24 on the lid and 3 + 21 underneath agrees, and every
        // collapsed row keeps its state, its tap through to the Place record and
        // its context menu - including "Add to this endeavor", which promotes it
        // into the band proper.
        let attached = rows.filter { $0.attached }
        let visited  = rows.filter { !$0.attached }
        VStack(alignment: .leading, spacing: 0) {
            bandHeader("Places", count: rows.count,
                       addLabel: "Attach a place") { attaching = .place }
            if rows.isEmpty {
                bandEmpty("Nowhere attached yet.")
            } else {
                ForEach(attached) { row in placeRow(row, in: e) }
                if attached.isEmpty, !visited.isEmpty {
                    // A band whose only content is a closed lid reads as empty.
                    // Say what is behind it before asking him to open it.
                    bandEmpty("Nowhere attached yet \u{2014} the visits below are where you actually went.")
                }
                if !visited.isEmpty {
                    if showVisitedPlaces {
                        ForEach(visited) { row in placeRow(row, in: e) }
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showVisitedPlaces.toggle() }
                    } label: {
                        // The schedule band's fold, in the same words and the
                        // same weight, because it is the same gesture. A second
                        // idiom for "there is more below" is a second thing to
                        // learn on one screen.
                        Text(showVisitedPlaces
                             ? "SHOW FEWER"
                             : (visited.count == 1 ? "ALSO VISITED (1)"
                                                   : "ALSO VISITED (\(visited.count))"))
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.4)
                            .foregroundStyle(Color.dayflowMuted)
                            .padding(.top, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    /// One place: the pin, the name, whether it is on the list, and whether he
    /// went.
    ///
    /// **The category's own glyph and colour**, from `placeIcon` and
    /// `placeColor` - the same two functions the Mac and the Trace app draw
    /// every place with. `PlaceHelpers.swift` was not in this target when the
    /// band shipped, so it drew one pin for everything; adding the file was a
    /// `project.pbxproj` edit and therefore waited for an Xcode-quit window.
    ///
    /// A place the app does not hold gets the default glyph rather than a
    /// question mark: the row already says "not in your places" underneath,
    /// and saying it twice in two alphabets is not saying it better.
    ///
    /// **The row still opens the place.** `resolveWikiLink` is the same door
    /// the chip carried, and a screen that names a record it can open and does
    /// not is the shape Session 87 found five times.
    private func placeRow(_ row: EndeavorPlace, in e: Endeavor) -> some View {
        let place = NotionService.shared.places.first { placeKey($0.name) == row.id }
        let known = place != nil
        let glyph = placeIcon(for: place?.category ?? "")
        let tint = placeColor(for: place?.category ?? "")
        let state: String = {
            if row.skipped { return "DIDN'T GO" }
            if let d = row.visitDate {
                let f = DateFormatter(); f.dateFormat = "EEE d MMM"
                return "WENT \u{00B7} " + f.string(from: d).uppercased()
            }
            return ""
        }()
        let sub: String = {
            if !known { return "not in your places" }
            if !row.attached { return "not on your list" }
            return ""
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(TripLog.shortPlaceName(row.name))
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowInk)
                    .strikethrough(row.skipped)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !state.isEmpty {
                    Text(state)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(Color.dayflowMuted)
                }
            }
            if !sub.isEmpty {
                HStack(spacing: 8) {
                    Spacer().frame(width: 16)
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dayflowFaint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .opacity(row.skipped ? 0.55 : 1)
        .onTapGesture { resolveWikiLink(row.name) }
        .overlay(alignment: .bottom) { bandHair }
        .contextMenu {
            if row.attached {
                Button("Remove", role: .destructive) { detach(row.name, from: e) }
            } else {
                Button("Add to this endeavor") { attach(row.name, kind: .place, to: e) }
            }
        }
    }

    /// Takes a place off the endeavor. **The skipped mark is not touched here
    /// and is still read-only on the phone** (D273): the question is asked on
    /// the Mac's Active tab and that is where the answer is given and taken
    /// back.
    private func detach(_ name: String, from e: Endeavor) {
        var updated = store.endeavor(id: e.id) ?? e
        let key = placeKey(name)
        updated.places.removeAll { placeKey($0) == key }
        try? store.save(updated)
    }

    // MARK: The body, in the type's own order (D268)

    /// The bands between the tag bar and the note, in the order D268's table
    /// gives for this type.
    ///
    /// | Type | Body |
    /// |---|---|
    /// | Travel | ITINERARY, PLACES, tasks, note |
    /// | Milestone, Gathering | SCHEDULE, PLACES, tasks, note |
    /// | Project | tasks, QUOTES, SCHEDULE, PLACES, note |
    /// | Decision | OPTIONS, PLACES, tasks, note |
    ///
    /// **Where the tasks go is the one thing D268's table could not answer**,
    /// and it is answered here rather than absorbed. On the Mac a non-Project
    /// endeavor keeps its tasks on the rail, so they are not in the body at
    /// all. The phone has no rail, so they have to go somewhere, and putting
    /// them first for every type would put back on top the exact thing D268
    /// demoted: David's brief was that the flights and the hotels were buried.
    /// So the type's own band leads, and the tasks sit under PLACES, directly
    /// above the note.
    ///
    /// **`bodyLeadsWithTasks` therefore means the same thing on both
    /// platforms** - Project leads with the punch list and nothing else does.
    ///
    /// **The section is drawn once, in one of two places, never both.** It is
    /// the same `openTasksSection`, not a second copy: standing warning FIVE,
    /// and the shape the Mac solved with `tasksSection(_:placement:)`.
    @ViewBuilder
    private func endeavorBody(_ e: Endeavor) -> some View {
        if e.bodyLeadsWithTasks {
            openTasksSection(e)
            ledgerBand(e)
            scheduleBand(e)
            placesBand(e)
        } else {
            scheduleBand(e)
            ledgerBand(e)
            placesBand(e)
            openTasksSection(e)
        }
    }

    // MARK: Tasks on the endeavor (Session 78 round two)

    /// The type's own count, for the kicker's third segment (D268, Session 87
    /// on the Mac and Session 88 here).
    ///
    /// **The countdown first, the count only when there is none.** Replacing a
    /// countdown with a count on anything carrying a real date is a downgrade:
    /// a wedding twelve days out wants "Starts in 12 days", not "4 items on the
    /// schedule". In practice this fires for Project and Decision, the two
    /// types that usually carry no dates and whose kicker otherwise read "NO
    /// DATES YET" - two segments, the second an apology.
    ///
    /// **It reads "4 tasks open", not "4 of 11 done"** (warning FOUR).
    /// `ReminderTaskStore.allTasks` is filled by
    /// `predicateForIncompleteReminders` and has never held a completed
    /// reminder, so there is no denominator to print. A fraction whose bottom
    /// half is invented is worse than a count. Backlogged on both platforms.
    ///
    /// Decision counts options that are neither accepted nor declined, which
    /// covers Quoted and a row nobody has given a status. `BookingStatus` is
    /// total over `String`, so a fourth option typed into Notion counts as open
    /// rather than vanishing.
    ///
    /// Nil at zero: on a project with nothing on it the absence is not worth a
    /// third of the line.
    private func typeFigure(_ e: Endeavor) -> String? {
        switch e.type.lowercased() {
        case "project":
            let n = linkedOpenTasks(e).count
            guard n > 0 else { return nil }
            return n == 1 ? "1 task open" : "\(n) tasks open"
        case "decision":
            let n = ledgerRows(e).filter {
                !BookingStatus.isAccepted($0.status) && !BookingStatus.isDeclined($0.status)
            }.count
            guard n > 0 else { return nil }
            return n == 1 ? "1 option open" : "\(n) options open"
        default:
            return nil
        }
    }

    private func linkedOpenTasks(_ e: Endeavor) -> [ThingsTask] {
        ReminderTaskStore.shared.allTasks.filter {
            ($0.notes ?? "").contains("[[\(e.name)]]")
        }
    }

    private func attachedCount(_ e: Endeavor) -> Int {
        unionedPeople(e).count + linkedNotes(e).count
    }

    private func promoteEndeavorTask(_ line: String, _ e: Endeavor,
                                     _ completion: @escaping (Bool) -> Void) {
        Task {
            let ok = await ReminderTaskStore.shared.addTask(
                title: line,
                list: ReminderTaskStore.inboxListName,
                notes: "[[\(e.name)]]\n")
            completion(ok)
        }
    }

    private func completeEndeavorTask(titled taskTitle: String, _ e: Endeavor) {
        guard let task = linkedOpenTasks(e).first(where: { $0.title == taskTitle }) else { return }
        Task { await ReminderTaskStore.shared.complete(taskID: task.id) }
    }

    @ViewBuilder
    private func openTasksSection(_ e: Endeavor) -> some View {
        let tasks = linkedOpenTasks(e)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OPEN TASKS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Color.dayflowFaint)
                Spacer()
                Button { taskSheet = .attach } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a task")
            }
            .padding(.bottom, 4)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
            ForEach(tasks) { task in
                HStack(spacing: 12) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await ReminderTaskStore.shared.complete(taskID: task.id) }
                    } label: {
                        Circle()
                            .strokeBorder(Color.dayflowInk, lineWidth: 1.6)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Button { editingTask = task } label: {
                        Text(task.title)
                            .font(.dayflowSerif(15))
                            .foregroundStyle(Color.dayflowInk)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    // The Mac row's bolt (D239) — runs without opening.
                    if let source = task.dayflowSource, source.icon == "bolt" {
                        Button {
                            UIApplication.shared.open(source.url)
                        } label: {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.dayflowAccent)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    // D229 marks (Session 81) — same pair as Today's rows.
                    if task.hasNoteProse {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.dayflowAccent)
                    }
                    if task.hasFollowableLink {
                        Image(systemName: "link")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dayflowAccent)
                    }
                    Text(endeavorTaskWhenLabel(task))
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(task.date == nil ? Color.dayflowFaint : Color.dayflowAccent)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                }
                // **Swipe LEFT to take the task off this endeavor**, and the
                // edge is chosen rather than assumed. David asked for a right
                // swipe, and right is already spoken for: on Today, Upcoming
                // and Quick Find a rightward swipe on a task row reveals a
                // calendar and opens the when picker. Reusing it here would be
                // one gesture meaning two things depending on which screen you
                // are on, which is standing warning FIVE and the thing this
                // project keeps paying for.
                //
                // Left is free IN THIS BAND. It means multi-select on the three
                // full task rooms, but this band has no selection mode at all,
                // so nothing is displaced - and leftward-to-remove is the
                // platform's own convention, which is a better teacher than
                // either of us.
                //
                // **The reveal is a word, not a glyph.** Today's rightward
                // swipe can afford a bare calendar because scheduling is what
                // that gesture does everywhere; this one is local to this band,
                // so it says REMOVE and teaches itself on the first half-swipe.
                //
                // `.offset` is visual only, so the `.background` applied after
                // it keeps the original frame and the label stays put while the
                // row slides. Dominance-guarded, so vertical scrolling is
                // untouched.
                .offset(x: taskRowOffsets[task.id] ?? 0)
                .background(alignment: .trailing) {
                    let slid = -(taskRowOffsets[task.id] ?? 0)
                    let progress = min(max(slid / 60, 0), 1)
                    if progress > 0 {
                        Text("REMOVE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(Color.dayflowAccent)
                            .opacity(Double(progress))
                            .padding(.trailing, 2)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 28)
                        .onChanged { value in
                            let h = value.translation.width
                            guard abs(h) > abs(value.translation.height) else { return }
                            // Leftward slides and reveals; rightward stays put,
                            // because rightward means something else in this app
                            // and a row that moved would promise it.
                            taskRowOffsets[task.id] = h < 0 ? max(h, -90) : 0
                        }
                        .onEnded { value in
                            let h = value.translation.width
                            withAnimation(.spring(duration: 0.3)) {
                                taskRowOffsets[task.id] = 0
                            }
                            guard abs(h) > abs(value.translation.height) * 1.5,
                                  h < -50 else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            detachTask(task, from: e)
                        }
                )
                // Long press stays, and is the direct equivalent of the Mac's
                // right click. Two ways to reach ONE verb is not warning FIVE;
                // one gesture reaching two verbs is.
                .contextMenu {
                    Button("Remove from this endeavor", role: .destructive) {
                        detachTask(task, from: e)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// Appends the link to each chosen task, preserving everything already in
    /// its notes.
    ///
    /// **`setNotes`, not `update`.** The latter is a routing function that
    /// recomputes list and date rules and, for a task in the Inbox or Someday,
    /// clears the due date and the alarms even when passed no date - warning
    /// FOUR, and the Mac paid for that lesson in Session 87. Attaching has no
    /// opinion about when a task is due.
    private func attachTasks(_ tasks: [ThingsTask], to e: Endeavor) async -> Bool {
        let link = EndeavorFile.link(named: e.name)
        var allOK = true
        for task in tasks {
            guard let merged = EndeavorFile.notesAttaching(link, to: task.notes) else { continue }
            let ok = await ReminderTaskStore.shared.setNotes(taskID: task.id, notes: merged)
            if !ok { allOK = false }
        }
        await ReminderTaskStore.shared.refreshAll()
        return allOK
    }

    /// Takes a task off this endeavor, leaving the rest of its notes alone.
    ///
    /// **It ships with attach rather than after it.** A mis-attach otherwise
    /// has no way back from inside the app, which is the reason D269 built the
    /// Mac's detach in the same session as its chooser.
    private func detachTask(_ task: ThingsTask, from e: Endeavor) {
        let link = EndeavorFile.link(named: e.name)
        guard let kept = EndeavorFile.notesDetaching(link, from: task.notes) else { return }
        Task {
            _ = await ReminderTaskStore.shared.setNotes(taskID: task.id, notes: kept)
            await ReminderTaskStore.shared.refreshAll()
        }
    }

    private func endeavorTaskWhenLabel(_ task: ThingsTask) -> String {
        guard let date = task.date else {
            return task.list == ReminderTaskStore.somedayListName ? "SOMEDAY" : "ANYTIME"
        }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInTomorrow(date) { return "TOMORROW" }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return f.string(from: date).uppercased()
    }

    /// Places first, then people, deduped, capped at 8 — identical to
    /// `DayflowProjectNoteView`'s. Copied rather than adapted on purpose: three
    /// hosts offering three different vocabularies from the same two lists would
    /// be a worse bug than the one this fixes.
    /// One shared list (Session 88). This was a copy - six of them, already
    /// disagreeing about which kinds to offer and whether to cap.
    private func wikiSuggestions(for query: String) -> [(name: String, kind: WikiSuggestionKind)] {
        WikiSuggestions.matches(for: query)
    }

    /// No `[[yyyy-MM-dd]]` day-note peek here, unlike the other two hosts: that
    /// needs its own date sheet, and an Endeavor note is about a thing rather
    /// than about a day. A date wikilink still types and still renders; it just
    /// does not open anything, which is what it did before this change too.
    /// Every `[[name]]` on this screen, through the one resolver (D282).
    ///
    /// **This screen used to be the RICHEST of the four copies** - it matched
    /// case-insensitively, resolved notes as well as records, and said why when
    /// nothing matched. The other three did less, silently. Rather than teach
    /// the other three what this one knew, all four now call the same function,
    /// and this screen keeps only what is genuinely local to it: a project note
    /// is PUSHED onto its own stack so back returns to the endeavor, instead of
    /// routing away through `dayflow://note`.
    ///
    /// It gains endeavors in the trade, which is the bug that started D282: an
    /// endeavor name here produced "Nothing named X exists as a place, a person
    /// or a note yet" while the endeavor itself was on screen.
    private func resolveWikiLink(_ name: String) {
        DayflowWikiLink.follow(name,
                               openURL: openURL,
                               onRecord: { wikiLinkTarget = $0 },
                               onNote: { openNote($0.relativePath) },
                               onMiss: { wikiMiss = $0 })
    }


    /// Routes to a note through the app's own deep link.
    ///
    /// **Not in the same turn as a dismissal.** `dayflow://note` ends in
    /// `route { showNotes = true }`, which presents a screen; firing that while
    /// the full-screen editor is still animating away means two presentations in
    /// flight, and SwiftUI drops one. David: *"it brings me to Dayflow projects
    /// but not the specific project note"* — the presentation survived, the
    /// routed title did not.
    ///
    /// Waited on the cover's own `onDismiss` rather than a delay. Session 63
    /// deleted four hand-tuned `asyncAfter` values from this codebase for being
    /// guesses at exactly this; the framework reports when it is finished, so
    /// ask it.
    ///
    /// Extracted from `resolveWikiLink` in Session 71 so the Notes chips route
    /// the same way rather than growing a second copy of it.
    private func openNote(_ relativePath: String) {
        // PUSH A PROJECT NOTE, ROUTE ANYTHING ELSE.
        //
        // A project note is the case David actually hits from here — a speech,
        // a packing list, a plan linked out of the endeavor body — and pushing
        // it keeps the endeavor underneath, so back returns to the endeavor.
        // `DayflowProjectNoteView` is built to be pushed and carries no
        // `NavigationStack` of its own, which is why it fits with no wrapper.
        //
        // **Direct children of `Notes/Projects` only.** An archived note lives
        // in `Notes/Projects/Archive/`, and `DayflowProjectNoteView` looks its
        // content up by title in the Projects list, so pushing one would open a
        // screen that renders empty. Same judgement `MacSearchEngine.destination`
        // makes about the Archive, for the same reason.
        //
        // A Calendar note still goes through the URL: a daily note has its own
        // full-page screen and its own date plumbing, and re-implementing that
        // inside this stack would be a second answer to a solved question.
        let projects = NoteStore.projectsFolder
        if relativePath.hasPrefix(projects + "/"),
           !relativePath.dropFirst(projects.count + 1).contains(where: { $0 == "/" }),
           relativePath.hasSuffix(".md") {
            let title = String(relativePath
                .dropFirst(projects.count + 1)
                .dropLast(3))
            pushedNoteTitle = title
            return
        }

        var comps = URLComponents()
        comps.scheme = "dayflow"
        comps.host   = "note"
        comps.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        guard let url = comps.url else { return }
        openURL(url)
    }

    /// The notes this endeavor's body links to, in the order it names them.
    ///
    /// The Mac's Linked notes rail (D64), as chips. Reads `body_` rather than
    /// `e.body` so a link typed in this sitting appears without a save-and-
    /// reload, and falls back to the stored body before the editor has loaded.
    private func linkedNotes(_ e: Endeavor) -> [LinkableNote] {
        let source = body_.isEmpty ? e.body : body_
        let targets = NoteStore.wikilinkTargets(in: source)
        guard !targets.isEmpty else { return [] }
        let all = NoteStore.shared.linkableNotes()
        var seen = Set<String>()
        return targets
            .compactMap { t in
                all.first { $0.title.localizedCaseInsensitiveCompare(t) == .orderedSame }
            }
            .filter { seen.insert($0.relativePath).inserted }
    }

    // MARK: - Destinations and People

    /// The two attached-record rows, above the document chips.
    ///
    /// Everyone the trip log names is unioned in alongside the people attached by
    /// hand, exactly as the Mac does (D69): letting the explicit list win would
    /// make the row get *shorter* as you added to it. Derived names are not
    /// separately marked here — the phone has no right-click to hang a
    /// "promote" action off, and a badge on a chip at this size is noise.
    @ViewBuilder
    private func attachedChips(_ e: Endeavor) -> some View {
        let people = unionedPeople(e)
        let notes  = linkedNotes(e)
        VStack(alignment: .leading, spacing: 6) {
            // Destinations left this fold in Session 88 and is the
            // PLACES band in the body now (D273). A chip cannot carry
            // a second line, so it could not say "Went - Sat 21 Nov",
            // and the skipped mark was the only thing it ever said
            // about a place beyond its name.
            chipRow(title: "People",
                    icon: "person.circle.fill",
                    names: people,
                    empty: "Nobody attached yet.",
                    onTap: { resolveWikiLink($0) }) { attaching = .person }
            // Notes, ported from the Mac's Linked notes rail (D64). No plus:
            // a note is linked by typing `[[` in the body, so an add button
            // here would be a second, worse way to do one thing. The empty
            // string says that instead, exactly as the Mac's does.
            chipRow(title: "Notes",
                    icon: "doc.text",
                    names: notes.map(\.title),
                    empty: "Type [[ in the note to link one.",
                    onTap: { title in
                        // Straight to the note, not through `resolveWikiLink`.
                        // These chips were built FROM the note list, so the
                        // records-first ordering that is right for a wikilink
                        // would be a way to open something else from here.
                        if let n = notes.first(where: {
                            $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
                        }) { openNote(n.relativePath) }
                    })
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    /// Attached names first, then everyone the trip log named, deduplicated
    /// case-insensitively. See `DayflowEndeavorView`'s Mac counterpart.
    private func unionedPeople(_ e: Endeavor) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in e.people where seen.insert(name.lowercased()).inserted {
            out.append(name)
        }
        let ids = Set(NotionService.shared.visits
            .filter { v in
                guard let starts = e.starts else { return false }
                let cal = Calendar.current
                let d = cal.startOfDay(for: v.date)
                return d >= cal.startOfDay(for: starts)
                    && d <= cal.startOfDay(for: e.ends ?? starts)
                    && e.body.localizedCaseInsensitiveContains(TripLog.shortPlaceName(v.placeName))
            }
            .flatMap { $0.peopleIDs })
        for p in NotionService.shared.people where ids.contains(p.id) {
            if seen.insert(p.name.lowercased()).inserted { out.append(p.name) }
        }
        return out
    }

    @ViewBuilder
    /// `onAdd` is optional and stays last so the existing trailing-closure call
    /// sites read unchanged; the Notes row has nothing to add by hand.
    private func chipRow(title: String,
                         icon: String,
                         names: [String],
                         empty: String,
                         /// Short names, lowercased, to draw struck through.
                         /// Defaulted empty so the People and Notes rows are
                         /// unchanged. Session 72.
                         dimmed: Set<String> = [],
                         onTap: @escaping (String) -> Void,
                         onAdd: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Color.dayflowFaint)
                Spacer()
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dayflowFaint)
                }
            }
            if names.isEmpty {
                Text(empty).font(.caption2).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            let isDimmed = dimmed.contains(TripLog.shortPlaceName(name).lowercased())
                            Button {
                                onTap(name)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: icon).font(.caption2)
                                    Text(name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .strikethrough(isDimmed)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.14))
                                .clipShape(Capsule())
                                // Still tappable, still opens the place. A
                                // skipped destination is a place you did not go
                                // to, not a place that stopped existing.
                                .opacity(isDimmed ? 0.55 : 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// Both writers re-read from the store first, for the reason `save` records:
    /// `e` was captured when the editor was built, and writing it back would undo
    /// anything changed since.
    private func attach(_ name: String, kind: AttachKind, to e: Endeavor) {
        var updated = store.endeavor(id: e.id) ?? e
        switch kind {
        case .place:  if !updated.places.contains(name) { updated.places.append(name) }
        case .person: if !updated.people.contains(name) { updated.people.append(name) }
        }
        try? store.save(updated)
    }

    private func save(_ newBody: String, into e: Endeavor) {
        // Re-read rather than writing `e`. It was captured when the editor was
        // built, so a cover chosen since then would be written back out of
        // existence by a plain body save. Same class of bug as the details
        // sheet's stale snapshot, found at the same time.
        var updated = store.endeavor(id: e.id) ?? e
        updated.body = newBody
        try? store.save(updated)
    }
}

// MARK: - Cover picker (Wikimedia Commons)

/// Review what the app thinks happened during a trip, then write it into the note.
///
/// Everything arrives ticked. **The sheet is for taking things out**, which is
/// the common case — a trip where one afternoon was work, or a lunch you would
/// rather not memorialise. Writing everything and deleting lines afterwards was
/// the alternative David considered and rejected.
struct EndeavorTripLogSheet: View {

    let endeavor: Endeavor
    /// Reads the live editor text. A closure, not a value — see the call site
    /// for the bug that distinction cost.
    ///
    /// **Named `liveBody`, not `body`.** A SwiftUI View already owns `body`, so
    /// declaring a stored property with that name is "Invalid redeclaration of
    /// 'body'" and the file does not compile. Worth knowing rather than just
    /// fixing: the same closure-not-a-value change made elsewhere would have been
    /// fine, and it was only the coincidence of this type being a View that turned
    /// a naming choice into a build error.
    let liveBody: () -> String
    var onWrite: ([TripLogDay]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days: [TripLogDay] = []
    @State private var loaded = false

    /// Where the daily-note scan has got to.
    ///
    /// **`failed` and `noKey` are separate cases, and both are shown.** Every other
    /// AI call site in this codebase returns nil on error, which is why a rate limit
    /// there is indistinguishable from the feature deciding there was nothing to do.
    /// Before writing to a note David has to be able to tell "nothing in your daily
    /// notes was about this trip" from "I could not ask" — so the sheet says which.
    enum DayNoteScan { case idle, running, done, failed, noKey }
    @State private var scan: DayNoteScan = .idle

    /// Only what pressing Add would actually write. A day already in the note
    /// contributes nothing, because `TripLog.append` will skip it.
    private var selectedCount: Int {
        days
            .filter { !alreadyWritten($0) }
            .reduce(0) { $0 + $1.entries.filter(\.include).count
                            + $1.dayNotes.filter(\.include).count }
    }

    /// Days already written about. Shown as such rather than hidden, so pressing
    /// the button twice does not look like it silently did nothing.
    private func alreadyWritten(_ day: TripLogDay) -> Bool {
        liveBody().contains(TripLog.heading(for: day.date))
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    ContentUnavailableView(
                        "Nothing found",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("No visits logged between these dates.")
                    )
                } else {
                    List {
                        ForEach($days) { $day in
                            Section {
                                // DAY NOTES FIRST, then the visits. These are
                                // usually the plan and the context; the visits
                                // are what actually happened. Same order they
                                // land in the note.
                                ForEach($day.dayNotes) { $dayNote in
                                    Toggle(isOn: $dayNote.include) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            // Stripped for display only — the line
                                            // written to the note keeps its wikilink.
                                            Text(TripLog.plainPreview(dayNote.text))
                                                .lineLimit(3)
                                            Text(dayNote.tagged ? "from your day note · #trip"
                                                                : "from your day note")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                ForEach($day.entries) { $entry in
                                    Toggle(isOn: $entry.include) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            // SHORT names, same as the note is
                                            // about to get. A preview that reads
                                            // differently from the result is worse
                                            // than no preview.
                                            Text(entry.place.short)
                                            if !entry.people.isEmpty {
                                                Text(entry.people.map(\.short).joined(separator: ", "))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            // The note itself, so a visit whose
                                            // note you would rather not have in
                                            // the log can be recognised and
                                            // unticked HERE, rather than deleted
                                            // out of the note afterwards.
                                            //
                                            // lineLimit is not optional. A Text
                                            // with no limit does not truncate
                                            // under pressure, it wraps and grows
                                            // — that is what produced a 700pt row
                                            // in the Endeavor list on 2026-07-31,
                                            // and these strings run to 700
                                            // characters.
                                            if let preview = entry.notePreview {
                                                Text(preview)
                                                    .font(.caption)
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(2)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                    if alreadyWritten(day) {
                                        Spacer()
                                        Text("already in note")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .textCase(nil)
                                    }
                                }
                            }
                            // A DAY ALREADY IN THE NOTE CANNOT BE ADDED TO.
                            // `append` skips such a day whole, which is exactly what
                            // stops it eating prose written under an old heading. But
                            // the sheet still drew every row switched on and offered
                            // "Add 7", so the honest result of pressing it was nothing
                            // at all. David pressed it. Toggles you cannot act on
                            // should not look like toggles you can.
                            .disabled(alreadyWritten(day))
                        }
                        if let status = scanStatus {
                            Section {
                                Label(status, systemImage: scan == .running
                                      ? "arrow.triangle.2.circlepath"
                                      : "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("What happened")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selectedCount)") {
                        onWrite(days)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedCount == 0)
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                // Visits are local and instant. They go on screen BEFORE the
                // network call starts, so pressing the button never feels
                // slower than it did — the daily-note rows arrive into a sheet
                // that is already up and already usable.
                days = TripLog.gather(for: endeavor,
                                      visits: NotionService.shared.visits,
                                      people: NotionService.shared.people)
                await scanDayNotes()
            }
        }
    }

    private var scanStatus: String? {
        switch scan {
        case .idle, .done: return nil
        case .running:     return "Reading your daily notes…"
        case .failed:      return "Could not read your daily notes. Everything above is from your visits."
        case .noKey:       return "No Claude key set, so daily notes were not read. Add one in Settings."
        }
    }

    // MARK: - Daily notes

    private func scanDayNotes() async {
        let candidates = TripLog.dayNoteCandidates(for: endeavor)
        guard !candidates.isEmpty else { scan = .done; return }
        scan = .running
        do {
            let picked = try await TripLog.selectDayNoteIndices(candidates, endeavor: endeavor)
            apply(candidates, picked: picked)
            scan = .done
        } catch TripLog.DayNoteScanError.noKey {
            // TAGGED LINES SURVIVE A FAILURE. `#trip` never needed the model, so
            // an outage or a missing key costs the judged lines and nothing else.
            apply(candidates, picked: [])
            scan = .noKey
        } catch {
            apply(candidates, picked: [])
            scan = .failed
        }
    }

    private func apply(_ candidates: [TripLog.DayNoteCandidate], picked: Set<Int>) {
        let cal = Calendar.current
        let chosen = candidates.filter { $0.tagged || picked.contains($0.index) }
        let grouped = Dictionary(grouping: chosen) { cal.startOfDay(for: $0.day) }

        for (dayStart, found) in grouped {
            // THE CAP LIVES HERE. The prompt asks for at most this many per day,
            // and asking is not the same as getting. David, 2026-08-01: *"the list
            // of the items might be ling so lets be careful about creating a lot of
            // work for me when I press the button."*
            //
            // **It applies to the model's picks only.** A `#trip` line is not a
            // guess that needs limiting, it is David saying which lines he wants;
            // truncating those would be the app overruling him. And a tagged day
            // is his own doing, so its length is never a surprise.
            // Filtered rather than concatenated, so the lines stay in the order
            // they appear in the file. Tagged-first would read as reordered prose.
            let guessedIDs = Set(found.filter { !$0.tagged }
                                      .prefix(TripLog.maxDayNoteLines)
                                      .map(\.index))
            let notes = found.filter { $0.tagged || guessedIDs.contains($0.index) }.map {
                TripLogDayNote(id: "\(Int(dayStart.timeIntervalSince1970))#\($0.index)",
                               text: $0.text,
                               tagged: $0.tagged)
            }
            if let i = days.firstIndex(where: { cal.startOfDay(for: $0.date) == dayStart }) {
                days[i].dayNotes = notes
            } else {
                // A day he wrote on but did not check in anywhere. `gather` works
                // from visits, so it never produced this day at all — and dropping
                // it would silently lose a travel day whose entire record is the
                // sentence he typed.
                days.append(TripLogDay(date: dayStart, entries: [], dayNotes: notes))
            }
        }
        days.sort { $0.date < $1.date }
    }
}

/// Pick a saved Place or Person to attach to an Endeavor.
///
/// One picker for both, because they differ only in which array they read and
/// what the second line says. Two near-identical files is how `shortPlaceName`
/// ended up with three copies and two different rules.
///
/// **Saved records only**, matching the Mac: Discover owns finding and saving a
/// place, Trace owns creating a person, and a second search that could create
/// records would be a second home for that decision.
///
/// Already-attached names are filtered out rather than shown ticked. This adds;
/// removing is done from the chip row.
struct EndeavorAttachPicker: View {

    enum Kind { case place, person }

    let kind: Kind
    let endeavor: Endeavor?
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var rows: [(name: String, detail: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        switch kind {
        case .place:
            let taken = Set((endeavor?.places ?? []).map { $0.lowercased() })
            return NotionService.shared.places
                .filter { !taken.contains($0.name.lowercased()) }
                .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.city.lowercased().contains(q) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { ($0.name, $0.city) }
        case .person:
            let taken = Set((endeavor?.people ?? []).map { $0.lowercased() })
            return NotionService.shared.people
                .filter { !$0.isArchived }
                .filter { !taken.contains($0.name.lowercased()) }
                .filter { q.isEmpty || $0.name.lowercased().contains(q) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { ($0.name, $0.relationship ?? "") }
        }
    }

    var body: some View {
        List {
            ForEach(rows, id: \.name) { row in
                Button {
                    onAdd(row.name)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).foregroundStyle(Color.dayflowInk)
                        if !row.detail.isEmpty {
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if rows.isEmpty {
                Text(query.isEmpty
                     ? (kind == .place ? "Everywhere is already attached."
                                       : "Everyone is already attached.")
                     : "Nothing matches.")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query,
                    prompt: kind == .place ? "Search your places" : "Search your people")
        .navigationTitle(kind == .place ? "Add a destination" : "Add someone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

/// Pick a Trace Place for an Endeavor, or clear it.
///
/// Same shape as Satchel's note picker: the clear row FIRST, so removing a link
/// is not something you have to scroll to find. That ordering is the whole
/// reason David could remove a tag once the door was visible.
struct EndeavorPlacePicker: View {

    @Binding var placeID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [Place] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return NotionService.shared.places
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.city.lowercased().contains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    placeID = nil
                    dismiss()
                } label: {
                    HStack {
                        Text("No place").foregroundStyle(Color.dayflowInk)
                        Spacer()
                        if placeID == nil {
                            Image(systemName: "checkmark").foregroundStyle(Color.dayflowAccent)
                        }
                    }
                }
                ForEach(matches) { place in
                    Button {
                        placeID = place.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(Color.dayflowInk)
                                if !place.city.isEmpty {
                                    Text(place.city).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if placeID == place.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.dayflowAccent)
                            }
                        }
                    }
                }
                if matches.isEmpty {
                    Text(query.isEmpty ? "No places yet." : "No places match.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Search places")
            .navigationTitle("Link a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

/// Candidate photographs for a destination, tap one.
///
/// Not a search experience. David's requirement was explicit — "finding images
/// is a waste of my time" — so the term is pre-filled from the Endeavor's
/// destination and the whole interaction is meant to be one tap. The field is
/// editable because "Japan" and "Mount Fuji" return very different things, and
/// he asked for Mount Fuji.
///
/// How many are shown lives in `CommonsImageService.resultCount`, not here — the
/// service needs it to size its over-fetch, and two places holding the same
/// number is how they drift apart.
///
/// PUSHED, NOT PRESENTED, and it deliberately has no `NavigationStack` of its
/// own. It used to be a sheet raised from inside the details sheet, which is
/// itself a sheet, and David could not reliably tap into the search field: that
/// field sits at the top of a scroll view already at its scroll origin, which is
/// exactly where a sheet's interactive dismiss gesture lives. A tap carrying a
/// few points of downward travel read as a drag and threw the sheet away.
/// Pushing removes the gesture rather than suppressing it, and costs nothing —
/// the details sheet already has a stack, and the back chevron replaces the
/// Cancel button this used to need.
struct EndeavorCommonsPickerView: View {

    let endeavor: Endeavor

    @Environment(\.dismiss) private var dismiss
    @State private var store = EndeavorStore.shared

    @State private var term = ""
    @State private var results: [CommonsImage] = []
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var started = false

    /// ONE column, and the tile is the exact height the cover renders at.
    ///
    /// This was two columns of 108pt tiles, which looked better and lied. The
    /// cover is full width at 132pt — roughly 3:1 on a phone — so a half-width
    /// tile at about 1.6:1 was showing a crop that would never be seen. Photos
    /// that look right in the picker and wrong once chosen is worse than a list
    /// that needs a scroll to get through.
    private let columns = [GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                resultsArea
            }
            .padding(16)
        }
        // Dragging the results puts the keyboard away. Tapping a photograph
        // while it is up still chooses that photograph — `.interactively` only
        // claims the drag.
        .scrollDismissesKeyboard(.interactively)
        // THE SEARCH FIELD LIVES OUTSIDE THE SCROLL VIEW. This is the whole fix
        // for a bug that survived one wrong attempt, so it is worth stating
        // exactly:
        //
        // A sheet's interactive dismiss gesture is owned by THE SHEET. Any
        // scroll view sitting at its scroll origin inside that sheet hands a
        // downward drag straight up to it. The field used to be the first thing
        // in this ScrollView, at the origin, so a tap carrying a few points of
        // travel dismissed the sheet instead of focusing the field.
        //
        // The first attempt at this pushed the picker instead of presenting it,
        // on the theory that the gesture belonged to the picker. It does not —
        // the picker is still INSIDE the details sheet either way, so pushing
        // changed nothing. David reported "no different", correctly.
        //
        // In a `safeAreaInset` the field is not in a scroll view at all, so
        // there is no drag to hand anywhere.
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        // And while a photo is being picked, the sheet should not be swipeable
        // away underneath it. There is a back chevron and the sheet below has its
        // own buttons, so nothing becomes unescapable. Removed automatically when
        // this screen pops.
        .interactiveDismissDisabled()
        .navigationTitle("Cover photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSaving {
                ToolbarItem(placement: .confirmationAction) { ProgressView() }
            }
        }
        .task {
            guard !started else { return }
            started = true
            // Pre-filled from the destination, and searched immediately, so
            // the common case is: open, tap, done.
            term = endeavor.destination?.nilIfEmptyView ?? endeavor.name
            runSearch()
        }
    }

    /// Fixed header, deliberately not part of the scrolling content — see the
    /// note in `body`. `.bar` material so results do not show through it.
    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Kyoto, Mount Fuji, Traverse City…", text: $term)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { runSearch() }
            Button("Search") { runSearch() }
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Split out for the same reason the details sheet's Form was: four
    /// branches plus a grid in one expression is where the type-checker starts
    /// timing out rather than failing usefully.
    @ViewBuilder
    private var resultsArea: some View {
        if isSearching {
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking on Wikimedia Commons…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 30)
        } else if let error {
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 30)
        } else if results.isEmpty {
            Text("Type where it is, and pick a photo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 30)
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(results) { image in
                    Button { choose(image) } label: { tile(image) }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                }
            }
            Text("Featured and quality-reviewed photographs from Wikimedia Commons, shown at the size they will appear. The credit is saved with the note.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ image: CommonsImage) -> some View {
        AsyncImage(url: image.thumbURL) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            case .failure:
                Color.dayflowInk.opacity(0.06)
                    .overlay(Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary))
            default:
                Color.dayflowInk.opacity(0.06)
                    .overlay(ProgressView())
            }
        }
        .frame(height: 132)   // matches EndeavorCoverImage in the header exactly
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func runSearch() {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        error = nil
        results = []
        Task {
            defer { isSearching = false }
            do {
                results = try await CommonsImageService.search(query)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func choose(_ image: CommonsImage) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let data = try await CommonsImageService.download(image)
                // Downloaded and stored, NOT hotlinked — which is the whole
                // reason this is Commons and not Unsplash.
                _ = try store.setCover(data, credit: image.credit, for: endeavor)
                // Pops rather than dismissing a sheet, since this is pushed now.
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private extension String {
    var nilIfEmptyView: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Details sheet (create and edit)

/// One sheet for both, because the field set is identical and two sheets that
/// must stay in step is one sheet with extra steps.
///
/// `existing == nil` creates. The slug is assigned on create and never shown or
/// edited afterwards (D9) — it is machinery, and putting it on screen invites
/// somebody to "tidy" it and orphan every document filed against it.
struct DayflowEndeavorDetailsSheet: View {

    /// What was handed in when the sheet was presented. **A snapshot**, and it
    /// goes out of date the moment a child sheet writes to the note — which the
    /// Commons picker and the photo library picker both do.
    ///
    /// 2026-07-29: this was `let existing: Endeavor?` and used directly. David
    /// chose a new cover photo and then tapped Save, and `commit()` wrote this
    /// stale copy back — putting the PREVIOUS `cover_credit` on the new
    /// photograph, and, had it been the first cover, deleting the `cover:` line
    /// outright. Silent, and it names the wrong photographer.
    private let snapshot: Endeavor?

    /// The store's current copy, falling back to the snapshot.
    ///
    /// The fallback is not belt-and-braces, it is load-bearing: `reload()`
    /// returns early when the container is briefly unavailable, and a nil here
    /// would turn this sheet into a create form mid-edit and produce a duplicate
    /// on Save.
    private var existing: Endeavor? {
        guard let snapshot else { return nil }
        return store.endeavors.first { $0.id == snapshot.id } ?? snapshot
    }

    init(existing: Endeavor?) {
        self.snapshot = existing
    }

    @Environment(\.dismiss) private var dismiss
    @State private var store = EndeavorStore.shared

    @State private var name = ""
    @State private var type = "Travel"
    @State private var hasStart = true
    @State private var starts = Date()
    @State private var hasEnd = true
    @State private var ends = Date()
    @State private var statusOverride: EndeavorStatus?
    @State private var loaded = false
    /// Creating a note touches the filesystem and can fail — no iCloud, no
    /// container, a name the path cannot hold. The first version used `try?`
    /// and dismissed regardless, so a failed create looked exactly like a
    /// successful one that had not appeared yet. David hit precisely that.
    @State private var saveError: String?
    @State private var confirmingDelete = false
    @State private var remindState: ReminderButtonState = .idle
    @State private var coverItem: PhotosPickerItem?
    @State private var isSettingCover = false
    @State private var destination = ""
    @State private var placeID: String?
    @State private var showingPlacePicker = false
    @State private var stampsCaptures = false
    /// True once the user has touched the toggle. Until then the toggle follows
    /// the dates, so creating a nine-day trip arrives with filing already on
    /// and a day trip does not. After one tap it is theirs and stops moving.
    @State private var stampTouched = false

    /// D10 held this at Travel and Project because a type changed no behaviour.
    /// D268's body band ended that, and the list is now the model's five.
    ///
    /// **Plus whatever this endeavor already is.** The Mac's sheet used to fall
    /// back to `types[0]` for an unrecognised value and write it on the next
    /// Save; this one seeds verbatim and showed an empty picker instead. Both
    /// were wrong and neither would have surfaced until a real endeavor was
    /// retyped. Carrying the value keeps the picker honest on both.
    private var types: [String] {
        var out = Endeavor.offeredTypes
        if let existing, !existing.type.isEmpty, !out.contains(existing.type) {
            out.append(existing.type)
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                // Split into one property per section 2026-07-29. As a single
                // expression this Form defeated the type-checker outright —
                // "unable to type-check in reasonable time" — once the cover
                // and delete sections joined it. Each part is small; only the
                // whole was too much.
                basicsSection
                datesSection
                coverSection
                remindSection
                deleteSection
                statusSection
            }
            // ATTACHED TO THE FORM, not to `basicsSection`.
            //
            // It was on the Section, and the result was that tapping Place
            // dismissed the whole details sheet and dropped back to the Endeavor
            // — David, 2026-07-31: "when i press it it jumps back to the endeavor
            // page unfortunately without letting me change anything."
            //
            // A `Section` is a layout element inside a `Form`, not a view that
            // owns presentation. A `.sheet` hung on one is attached to something
            // whose identity the Form is free to churn, so the presentation is
            // torn down as soon as it starts, taking its host with it. Sheets
            // belong on the container.
            .sheet(isPresented: $showingPlacePicker) {
                EndeavorPlacePicker(placeID: $placeID)
            }
            .alert("Could not save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(saveError ?? "")
            }
            .onChange(of: coverItem) { _, item in
                guard let item, let existing else { return }
                isSettingCover = true
                Task {
                    defer { isSettingCover = false; coverItem = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            saveError = "That photo could not be read."
                            return
                        }
                        _ = try store.setCover(data, for: existing)
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
            }
            .confirmationDialog("Delete this Endeavor?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let existing else { return }
                    do {
                        try store.delete(existing)
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The note and everything written in it. This cannot be undone from inside Dayflow.")
            }
            .navigationTitle(existing == nil ? "New Endeavor" : "Endeavor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                guard let existing else { return }
                name = existing.name
                type = existing.type
                hasStart = existing.starts != nil
                starts = existing.starts ?? Date()
                hasEnd = existing.ends != nil
                ends = existing.ends ?? Date()
                statusOverride = existing.statusOverride
                destination = existing.destination ?? ""
                placeID = existing.placeID
                stampsCaptures = existing.stampsCaptures
                // An existing endeavor's value is a decision already made.
                stampTouched = true
            }
        }
    }

    /// Follows the dates until the user touches the toggle. See `stampTouched`.
    private func seedStampDefault() {
        guard !stampTouched else { return }
        stampsCaptures = Endeavor.defaultStampsCaptures(starts: hasStart ? starts : nil,
                                                        ends: hasEnd ? ends : nil)
    }

    private func commit() {
        let start = hasStart ? starts : nil
        let end = hasEnd ? ends : nil

        do {
            if var updated = existing {
                updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.type = type
                updated.starts = start
                updated.ends = end
                updated.statusOverride = statusOverride
                updated.destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.placeID = placeID
                updated.stampsCaptures = stampsCaptures
                // NOTE: the filename is deliberately NOT renamed to follow the
                // name. The slug is the identity (D9), the path is where the
                // bytes are, and moving a file to keep it cosmetically in step
                // would break `linked_note` on every document filed against it.
                try store.save(updated)
            } else {
                _ = try store.create(name: name, type: type, starts: start, ends: end,
                                     destination: destination, placeID: placeID,
                                     stampsCaptures: stampsCaptures)
            }
        } catch {
            // Stay on the sheet. Dismissing on failure is what made this
            // indistinguishable from success.
            saveError = error.localizedDescription
            return
        }
        dismiss()
    }

    @ViewBuilder
    private var basicsSection: some View {
        Section {
            TextField("Name", text: $name)
            // **The push, not the menu** (Session 88). This was a plain
            // `Picker`, which renders as a `.menu` in a Form, and the menu did
            // not present at all inside this sheet - David, on the simulator:
            // *"type for the endeavor is not clickable."* Every other control
            // in the same Form takes its taps, so the Form is not the problem
            // and the menu presentation is.
            //
            // `.navigationLink` sidesteps menu presentation entirely and
            // pushes a list, which is the mechanism the Place row directly
            // below has always used successfully in this same sheet. It reads
            // better too: five options is a list, and the two rows now carry
            // the same chevron and behave the same way.
            Picker("Type", selection: $type) {
                ForEach(types, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)
            // Doubles as the cover search term, which is why it is worth
            // a field rather than a line in the body: type it once and
            // the photograph comes from it.
            TextField("Destination", text: $destination)

            // The optional half. Text says where it is; this says where to
            // drive to. Only worth setting when a real Place exists — see
            // `Endeavor.placeID` for why a country should stay text.
            Button {
                showingPlacePicker = true
            } label: {
                HStack {
                    Text("Place")
                        .foregroundStyle(Color.dayflowInk)
                    Spacer(minLength: 10)
                    Text(linkedPlaceName ?? "None")
                        .foregroundStyle(placeID == nil ? .secondary : Color.dayflowInk)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var linkedPlaceName: String? {
        guard let placeID else { return nil }
        return NotionService.shared.places.first(where: { $0.id == placeID })?.name
    }

    @ViewBuilder
    private var datesSection: some View {
        // `Section(_:content:footer:)` does not exist in SwiftUI —
        // there is a title-only form and a header/footer form, and
        // mixing them fails to infer `Content`. Header spelled out.
        Section {
            Toggle("Has a start date", isOn: $hasStart)
            if hasStart {
                DatePicker("Starts", selection: $starts, displayedComponents: .date)
            }
            Toggle("Has an end date", isOn: $hasEnd)
            if hasEnd {
                DatePicker("Ends", selection: $ends, displayedComponents: .date)
            }

            // Sits with the dates because it is seeded from them. Stated
            // positively: "skip stamping" would be a checkbox you untick to
            // stop something not happening.
            Toggle("File captures to this endeavor", isOn: $stampsCaptures)
                .onChange(of: stampsCaptures) { _, _ in stampTouched = true }
        } header: {
            Text("Dates")
        } footer: {
            // D12, said plainly, because the absence of a status field
            // is the surprising part of this screen.
            Text("Status is worked out from the dates. Set one below only to pause or abandon it.\n\nWhile this is running, anything you scan or photograph is filed to it. On by default for trips longer than three days.")
        }
        .onChange(of: [hasStart, hasEnd]) { _, _ in seedStampDefault() }
        .onChange(of: starts) { _, _ in seedStampDefault() }
        .onChange(of: ends) { _, _ in seedStampDefault() }
    }

    @ViewBuilder
    private var coverSection: some View {
        // D8 — TRAVEL ONLY. A photograph makes a trip note feel like a
        // trip; a stock photo of a kitchen makes a renovation feel like
        // a brochure. Not offered at all for other types rather than
        // offered and discouraged.
        //
        // Edit only: on create there is no slug yet to name the file
        // after, and no note to attach it to.
        if let existing, existing.isTravel {
            // Header spelled out, NOT `Section("Cover photo") { } footer: { }`.
            // That initialiser does not exist — SwiftUI has a title-only form
            // and a header/footer form and no way to mix them. This was wrong
            // from the moment it was written; the Form's type-check timeout was
            // masking it, and it only surfaced once the Form was split.
            Section {
                // NavigationLink, not a sheet. See the note on
                // EndeavorCommonsPickerView — a sheet on top of this sheet made
                // the search field almost untappable. This Form IS inside a
                // NavigationStack, unlike DayflowNotesView where a
                // NavigationLink silently did nothing, so this pushes properly.
                NavigationLink {
                    EndeavorCommonsPickerView(endeavor: existing)
                } label: {
                    HStack {
                        Text(existing.cover == nil ? "Find a photo" : "Find a different photo")
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }
                PhotosPicker(selection: $coverItem, matching: .images) {
                    HStack {
                        Text(existing.cover == nil ? "Choose a photo" : "Replace photo")
                        Spacer()
                        if isSettingCover { ProgressView() }
                    }
                }
                if existing.cover != nil {
                    Button("Remove photo", role: .destructive) {
                        try? store.clearCover(for: existing)
                    }
                }
            } header: {
                Text("Cover photo")
            } footer: {
                // Was "Unsplash search comes once an API key is set."
                // Unsplash was ruled out on 2026-07-29: its guidelines
                // require hotlinked URLs and forbid storing the file,
                // which is the opposite of what this needs.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Copied onto the phone, so it still shows with no signal.")
                    if let credit = existing.coverCredit, !credit.isEmpty {
                        Text(credit).italic()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        if existing != nil {
            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Delete Endeavor")
                        Spacer()
                    }
                }
            } footer: {
                Text("Deletes the note. Documents filed to it are left alone — Satchel owns those.")
            }
        }
    }

    // MARK: Remind me
    //
    // David, 2026-08-01, on what else deserves reminders: *"dayflow endeavors
    // about to start"* — his own first example, and the natural one, because an
    // Endeavor already carries a start date and the agenda already reads it.
    //
    // **Three days.** Satchel starts surfacing a trip's
    // documents three days out for exactly this reason: that is when packing and
    // checking in happen. A trip reminder that fires on the morning of departure
    // is a reminder about a trip you are already on.
    //
    // Undated Endeavors get nothing rather than a disabled row — there is no date
    // to remind about, and offering it would raise a question the screen cannot
    // answer.

    /// Days before a trip starts that the reminder fires.
    ///
    /// **Deliberately a separate constant from Satchel's `kitLeadInDays`, not a
    /// reference to it.** `Endeavor` is TWO different structs — `Dayflow/
    /// DayflowEndeavor.swift` and `Satchel/SatchelEndeavor.swift` — compiled into
    /// two apps that do not share a type. `Endeavor.kitLeadInDays` read perfectly
    /// and did not compile here, because this `Endeavor` has never had it.
    ///
    /// They agree on 3 for the same reason: that is when packing and checking in
    /// happen. If one moves, move the other by hand — there is no mechanism that
    /// can hold them together, and pretending otherwise is what produced the error.
    private static let startReminderLeadDays = 3

    @ViewBuilder
    private var remindSection: some View {
        // Gated on `hasStart`, not on `starts` being non-nil — `starts` is a plain
        // Date that always holds a value; `hasStart` is what says whether it means
        // anything. And on `existing`, because a reminder for a trip that has not
        // been saved yet would have nothing to link itself to.
        if hasStart, existing != nil {
            let start = starts
            Section {
                Button {
                    addStartReminder(on: start)
                } label: {
                    HStack {
                        Label(remindState == .added ? "Reminder added" : "Remind me before it starts",
                              systemImage: remindState == .added ? "checkmark" : "bell")
                        Spacer()
                        if remindState == .working { ProgressView() }
                    }
                }
                .disabled(remindState != .idle)
                if case .failed(let why) = remindState {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Text("Adds a reminder in Apple's Reminders app three days before \(name.isEmpty ? "this" : name) starts.")
            }
        }
    }

    private func addStartReminder(on start: Date) {
        let cal = Calendar.current
        let lead = cal.date(byAdding: .day, value: -Self.startReminderLeadDays,
                            to: cal.startOfDay(for: start)) ?? start
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        remindState = .working
        Task {
            do {
                let id = try await ReminderService.add(
                    title: "\(title.isEmpty ? "Trip" : title) starts in 3 days",
                    due: lead,
                    notes: "Dayflow · \(start.formatted(.dateTime.month(.wide).day()))")
                ReminderService.link(id, to: "endeavor|\(existing?.id ?? title)")
                remindState = .added
            } catch ReminderService.Failure.denied {
                remindState = .failed("Dayflow does not have access to Reminders. Settings › Privacy › Reminders.")
            } catch {
                remindState = .failed("Could not add the reminder.")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status override") {
            Picker("Status", selection: $statusOverride) {
                Text("Derived from dates").tag(EndeavorStatus?.none)
                ForEach(EndeavorStatus.storable, id: \.self) { s in
                    Text(s.label).tag(EndeavorStatus?.some(s))
                }
            }
        }
    }

}
