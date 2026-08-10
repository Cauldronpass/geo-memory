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

private extension Endeavor {
    var typeTint: Color {
        isTravel ? Color(red: 0.345, green: 0.337, blue: 0.839)   // indigo
                 : Color(red: 0.141, green: 0.541, blue: 0.239)   // green
    }
    var glyph: String { isTravel ? "airplane" : "hammer" }
}

// MARK: - Date phrasing

/// "14 – 24 Sep 2026", "Since 2 Mar 2026", "From 30 Jul 2026", "No dates yet".
///
/// Prose, not ISO. The ISO form is what is stored; this is what is read. The
/// year is dropped from the first date when both fall in the same one, because
/// "14 Sep 2026 – 24 Sep 2026" makes a reader do work for nothing.
///
/// AN OPEN-ENDED ENDEAVOR READS DIFFERENTLY DEPENDING ON DIRECTION. The first
/// version said "Since" for every one of them, which is fine for a renovation
/// that began in March and plainly wrong for a trip that starts tomorrow —
/// "since" looks backwards. David caught it on his second Endeavor, 2026-07-29.
///
/// "From" rather than "Starts", because the countdown line directly underneath
/// already says "Starts tomorrow" and two verbs stacked read as a stutter.
func endeavorDateLabel(_ e: Endeavor, on now: Date = Date()) -> String {
    let day = DateFormatter(); day.dateFormat = "d MMM"
    let full = DateFormatter(); full.dateFormat = "d MMM yyyy"
    let cal = Calendar.current

    switch (e.starts, e.ends) {
    case let (start?, end?):
        if cal.component(.year, from: start) == cal.component(.year, from: end) {
            return "\(day.string(from: start)) – \(full.string(from: end))"
        }
        return "\(full.string(from: start)) – \(full.string(from: end))"
    case let (start?, nil):
        let hasBegun = cal.startOfDay(for: start) <= cal.startOfDay(for: now)
        return hasBegun ? "Since \(full.string(from: start))"
                        : "From \(full.string(from: start))"
    case let (nil, end?):
        return "Until \(full.string(from: end))"
    default:
        return "No dates yet"
    }
}

/// The line underneath — the thing a date range is actually for.
/// "Starts in 48 days" · "Day 3 of 11" · "Ended 2 months ago".
func endeavorCountdownLabel(_ e: Endeavor, on now: Date = Date()) -> String? {
    switch e.status(on: now) {
    case .upcoming:
        guard let days = e.daysUntilStart(on: now) else { return nil }
        if days == 0 { return "Starts today" }
        if days == 1 { return "Starts tomorrow" }
        return "Starts in \(days) days"
    case .active:
        guard let index = e.dayIndex(on: now) else { return nil }
        if let total = e.totalDays { return "Day \(index) of \(total)" }
        return "Day \(index)"
    case .past:
        guard let ends = e.ends else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Ended \(f.localizedString(for: ends, relativeTo: now))"
    case .idea, .onHold, .cancelled:
        return nil
    }
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
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("New Endeavor")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.blue.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            if store.endeavors.isEmpty {
                Text("Nothing yet. A trip, a renovation, anything with a start and an end.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
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
                            Image(systemName: showFinished ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Finished · \(finished.count)")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
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
        // `item:` keyed on the slug, so the sheet is rebuilt per Endeavor
        // rather than reusing one screen's state for the next.
        .sheet(item: Binding(
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
                        openEndeavorID = endeavor.id
                    } label: {
                        row(endeavor)
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        Divider().padding(.leading, 70)
                    }
                }
            }
            .dayflowCard()
            .padding(.horizontal, 16)
        }
    }

    private func row(_ e: Endeavor) -> some View {
        let status = e.status()
        return HStack(spacing: 12) {
            if let cover = e.cover {
                EndeavorCoverImage(path: cover, height: 42, cornerRadius: 11, width: 42)
            } else {
                RoundedRectangle(cornerRadius: 11)
                    .fill(e.typeTint.opacity(0.14))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: e.glyph)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(e.typeTint)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(e.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                Text("\(e.type) · \(endeavorDateLabel(e))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
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
    /// Which attach picker is open, if any. One enum and one sheet rather than
    /// two of each — two `.sheet` modifiers on one view is a coin flip and the
    /// later one wins silently (the Mac's D36, and this view already carries
    /// three sheets).
    @State private var attaching: AttachKind? = nil
    /// True while the note is open full screen. See `fullScreenEditor`.
    @State private var fullScreenEditing = false
    /// Used to open a linked note through the app's own `dayflow://note` route.
    @Environment(\.openURL) private var openURL
    /// Held while the full-screen editor is still dismissing. See
    /// `resolveWikiLink` — opening the route in the same turn as the dismissal
    /// puts two presentations in flight and the second one loses.
    @State private var pendingWikiNoteURL: URL? = nil

    private enum AttachKind: String, Identifiable {
        case place, person
        var id: String { rawValue }
    }
    /// True while the note editor holds the keyboard. Collapses the header, so
    /// the thing being typed into is not the smallest thing on screen.
    @State private var editorFocused = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private var endeavor: Endeavor? { store.endeavor(id: endeavorID) }

    var body: some View {
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
        .dayflowSkinBackground()
        .navigationTitle(endeavor?.name ?? "Endeavor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Presented as a sheet, so it needs its own way out — there is no
            // back chevron to fall back on.
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // A menu rather than a second icon. Two glyphs in a row with no
                // labels is a guessing game, and "what happened" is not something
                // you reach for often enough to earn permanent space.
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
                }
            }
        }
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
        .task(id: noteStore.hasAccess) {
            store.reload()
            guard !loaded, let endeavor else { return }
            body_ = endeavor.body
            loaded = true
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.reload()
        }
    }

    @ViewBuilder
    private func content(_ e: Endeavor) -> some View {
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
            // Deliberately NOT solved by making the page scroll. A UITextView inside
            // a ScrollView is where this codebase has already been bitten — see
            // `makeUIView`'s "Bug 4" note on contentSize and scroll lock — and it
            // would be a far larger change for the same result.
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
                // Destinations and People, ported from the Mac rail (D59, D69).
                // **Chips, not rows.** David on the Mac, about documents: *"It is
                // just added as a pill I believe."* The phone's idiom for
                // "records attached to this note" is already the chip row
                // directly below, and a second visual language two rows apart
                // would be drift rather than variety.
                attachedChips(e)
                SatchelDocumentChips(notePath: e.relativePath)
                SatchelAddDocumentButton(notePath: e.relativePath, style: .bar)
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
                checklistSendEnabled: false,
                attachTrigger: $attachRequest
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **The inline editor is a preview, not a typing surface.**
            //
            // David: *"When I am clicking the note in an Endeavor, the screen
            // itself goes up 3/4 of the way from the bottom, but it's really
            // difficult to navigate in that note. What I'd rather have is the
            // note moved to full screen with full swiping up and down navigation
            // and then a way to get back."*
            //
            // The collapsing header (2026-07-31) bought back about 240pt and was
            // the right fix for what it was aimed at, but it was still dividing a
            // screen between a page and a document. Writing wants the whole
            // screen; the endeavor page wants to show what is attached to the
            // note. Those are two screens.
            //
            // A transparent tap catcher rather than reacting to `onFocusChange`,
            // which was the obvious version: focus-then-present shows the
            // keyboard sliding up under the page for a frame before the cover
            // arrives over it. Catching the tap first means the inline editor is
            // never first responder at all and there is nothing to flash.
            //
            // Cost, stated: wikilinks and capture markers are no longer tappable
            // inline. They are tappable full screen, which is where you are one
            // tap later.
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { fullScreenEditing = true }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: editorFocused)
        .fullScreenCover(isPresented: $fullScreenEditing, onDismiss: {
            guard let url = pendingWikiNoteURL else { return }
            pendingWikiNoteURL = nil
            openURL(url)
        }) {
            fullScreenEditor(e)
        }
    }

    /// The note on its own, which is what writing in it needs.
    ///
    /// `fullScreenCover` rather than a `sheet`: a sheet dismisses on a downward
    /// drag, and this is a document you scroll down through. The way back is a
    /// button, deliberately — it cannot fire by accident mid-paragraph.
    ///
    /// The same editor with the same closures. **Nothing is passed differently**,
    /// so a feature that works on one cannot quietly be missing from the other —
    /// which is exactly how Endeavor notes went without wikilink suggestions for
    /// three sessions.
    private func fullScreenEditor(_ e: Endeavor) -> some View {
        NavigationStack {
            MarkdownEditorView(
                text: $body_,
                onSave: { newBody in save(newBody, into: e) },
                placeholder: "Summary, plan, open items…",
                relativePath: e.relativePath,
                onWikiTap: { name in resolveWikiLink(name) },
                wikiSuggestions: { query in wikiSuggestions(for: query) },
                checklistSendEnabled: false,
                attachTrigger: $attachRequest
            )
            .navigationTitle(e.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        fullScreenEditing = false
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
            // Its own copy, on its own host. The one on the page below cannot
            // present while this is covering it, and a wikilink that opens
            // nothing is worse than one that is not tappable (D36 is about two
            // sheets on ONE view; these are two views).
            .sheet(item: $wikiLinkTarget) { target in
                NavigationStack {
                    DayflowWikiSummaryView(target: target, sourceNoteText: body_)
                }
            }
        }
    }

    /// The header while the keyboard is up: the name, and nothing else.
    private func compactHeader(_ e: Endeavor) -> some View {
        Text(e.name)
            .font(.system(size: 17, weight: .semibold, design: .serif))
            .foregroundStyle(Color.dayflowInk)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .dayflowCard()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    private func header(_ e: Endeavor) -> some View {
        let status = e.status()
        return VStack(alignment: .leading, spacing: 0) {
            // Above the name on white, as in the approved mockup — not behind it
            // with a scrim. Text over a photograph is legible only as long as the
            // photograph cooperates, and a cover David chose himself will not
            // always.
            if let cover = e.cover {
                EndeavorCoverImage(path: cover, height: 132, offset: e.coverOffset)
                    .padding(.horizontal, -17)
                    .padding(.top, -15)
                    .padding(.bottom, 15)
            }

            Text(e.name)
                .font(.system(size: 27, weight: .semibold, design: .serif))
                .foregroundStyle(Color.dayflowInk)
                .padding(.bottom, 9)

            HStack(spacing: 7) {
                pill(e.type, tint: e.typeTint)
                pill(status.label, tint: status.tint)
            }
            .padding(.bottom, 11)

            Text(endeavorDateLabel(e))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.dayflowInk)

            if let countdown = endeavorCountdownLabel(e) {
                Text(countdown)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 17)
        .padding(.top, 15)
        .padding(.bottom, 16)
        .dayflowCard()
        .padding(.horizontal, 16)
        .padding(.bottom, 13)
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// Places first, then people, deduped, capped at 8 — identical to
    /// `DayflowProjectNoteView`'s. Copied rather than adapted on purpose: three
    /// hosts offering three different vocabularies from the same two lists would
    /// be a worse bug than the one this fixes.
    private func wikiSuggestions(for query: String) -> [(name: String, isPlace: Bool)] {
        let q = query.lowercased()
        var results: [(name: String, isPlace: Bool)] = []
        let placeMatches = NotionService.shared.places
            .map { $0.name }
            .filter { q.isEmpty || $0.lowercased().contains(q) }
            .sorted()
            .map { (name: $0, isPlace: true) }
        results.append(contentsOf: placeMatches)
        let peopleMatches = NotionService.shared.people
            .map { $0.name }
            .filter { name in
                (q.isEmpty || name.lowercased().contains(q)) &&
                !results.contains(where: { $0.name == name })
            }
            .sorted()
            .map { (name: $0, isPlace: false) }
        results.append(contentsOf: peopleMatches)
        // Notes as a third source (D64). `isPlace: false` gives them the person
        // pill icon, which is wrong and deliberate for now: the closure's return
        // type is a Bool, so a third kind means widening it at every host that
        // supplies one. Queued rather than smuggled in here.
        let noteMatches = NoteStore.shared.linkableNotes()
            .map { $0.title }
            .filter { title in
                (q.isEmpty || title.lowercased().contains(q)) &&
                !results.contains(where: { $0.name == title })
            }
            .sorted()
            .map { (name: $0, isPlace: false) }
        results.append(contentsOf: noteMatches)
        return Array(results.prefix(8))
    }

    /// No `[[yyyy-MM-dd]]` day-note peek here, unlike the other two hosts: that
    /// needs its own date sheet, and an Endeavor note is about a thing rather
    /// than about a day. A date wikilink still types and still renders; it just
    /// does not open anything, which is what it did before this change too.
    private func resolveWikiLink(_ name: String) {
        if let place = NotionService.shared.places.first(where: { $0.name == name }) {
            wikiLinkTarget = .place(place)
        } else if let person = NotionService.shared.people.first(where: { $0.name == name }) {
            wikiLinkTarget = .person(person)
        } else if let note = NoteStore.shared.linkableNotes().first(where: {
            $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            // D64's other half, on the phone. The Mac learned to resolve a
            // wikilink to a Project or Daily note in Session 67; here the name
            // fell out of the `if` and **did nothing at all** — the link rendered
            // blue and went nowhere, which is worse than no link because it looks
            // live. David: *"on the endeavor note the Final Wedding speech is not
            // clickable."*
            //
            // Records first, notes last, matching the Mac's order: a Place note
            // and a Place record share a name and the record is what you want.
            //
            // Routed through the app's own `dayflow://note?path=` rather than a
            // new `WikiLinkTarget` case. That route already exists, already
            // handles Calendar / Projects / Endeavors, and already uses
            // `URLComponents` so a name with an ampersand survives — a fourth
            // enum case would have rippled through `DayflowWikiSummaryView` for
            // nothing.
            var comps = URLComponents()
            comps.scheme = "dayflow"
            comps.host   = "note"
            comps.queryItems = [URLQueryItem(name: "path", value: note.relativePath)]
            if let url = comps.url {
                // **Not in the same turn as the dismissal.** `dayflow://note`
                // ends in `route { showNotes = true }`, which presents a screen;
                // firing that while the full-screen editor is still animating
                // away means two presentations in flight, and SwiftUI drops one.
                // David: *"it brings me to Dayflow projects but not the specific
                // project note"* — the presentation survived, the routed title
                // did not.
                //
                // Waited on the cover's own `onDismiss` rather than a delay.
                // Session 63 deleted four hand-tuned `asyncAfter` values from
                // this codebase for being guesses at exactly this; the framework
                // reports when it is finished, so ask it.
                if fullScreenEditing {
                    pendingWikiNoteURL = url
                    fullScreenEditing = false
                } else {
                    openURL(url)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
                chipRow(title: "Destinations",
                    icon: "mappin.circle.fill",
                    names: e.places,
                    empty: "Nowhere attached yet.") { attaching = .place }
            chipRow(title: "People",
                    icon: "person.circle.fill",
                    names: people,
                    empty: "Nobody attached yet.") { attaching = .person }
        }
        .padding(.horizontal, 16)
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
    private func chipRow(title: String,
                         icon: String,
                         names: [String],
                         empty: String,
                         onAdd: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if names.isEmpty {
                Text(empty).font(.caption2).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            Button {
                                resolveWikiLink(name)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: icon).font(.caption2)
                                    Text(name).font(.caption).lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.14))
                                .clipShape(Capsule())
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
                            Image(systemName: "checkmark").foregroundStyle(.blue)
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
                                Image(systemName: "checkmark").foregroundStyle(.blue)
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

    /// D10 — day one is Travel and Project. `Event` was considered and
    /// deliberately left out until David has used the system: it changes no
    /// behaviour, so it would be a filing decision with no consequence.
    /// `type` is an open string in the model, so adding one later is a word.
    private let types = ["Travel", "Project"]

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
            Picker("Type", selection: $type) {
                ForEach(types, id: \.self) { Text($0).tag($0) }
            }
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
