// TraceMacTaskCard.swift
// A task row that opens where it lives (D190).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 80 (2026-08-31). David, after two Things-for-Mac screenshots:
// "lets do what things does on Mac. A expansion of the task row with the
// additional pieces there."
//
// ── One component, three screens ─────────────────────────────────────────
//
// Today's TO DO, Upcoming's day groups and the Tasks screen all draw task
// rows, and all three must open the same card with the same gesture. So this
// is built once, standalone, before any of the three consume it — building it
// inside one screen would mean extracting it later, and the extraction is
// where the drift happens.
//
// ── What the card shows, and the rule behind it ──────────────────────────
//
// A row exists for each thing the task CARRIES — WHEN, LIST, REMIND, LINKED —
// and everything unset folds into one faint offer line. A bare inbox task is
// two rows; a task that has grown fills out. That is the ATTACHED-fold
// instinct from the endeavor screen (D180), and it is why this is not a fixed
// field list: a form that shows five empty rows for a one-line task is a form,
// and David is not filling in forms.
//
// The footer is the phone's decide row verbatim — Today / Tomorrow / Pick day
// / Delete over Done / Anytime / Someday with the list menu at the right — so
// the Inbox decide step and the task inspector are the same control and
// nothing was lost by retiring the separate decide card.
//
// ── Semantics come from the store, not from here ─────────────────────────
//
// Anytime moves the reminder to the Personal list and clears its date, so it
// drops out of the Inbox and appears under Anytime. Someday moves it to the
// Someday list. Both are `ReminderTaskStore`'s existing behaviour, unchanged
// from iOS — David described it from memory and the code agreed. This file
// calls; it does not decide.
//
// ── The type-checker ─────────────────────────────────────────────────────
//
// Typed `let`s before every modifier. Non-negotiable here — see
// `feedback_typecheck_timeout` and the header of TraceMacTodayView.swift.

import SwiftUI
import AppKit

// MARK: - Row

struct MacTaskRow: View {

    let task: ThingsTask
    let isOpen: Bool
    /// Click the row (not the circle) to open or close it.
    let onToggle: () -> Void
    /// Fired after any mutation, so the host can refetch and redraw.
    let onChanged: () -> Void
    /// Fired when the task was moved to a specific day, so the host can offer
    /// to follow it there (Session 80). Defaulted, so a host that does not care
    /// says nothing.
    var onMoved: (Date) -> Void = { _ in }
    /// Whether this row is being shown on TODAY. Only there can a task be
    /// "carried": on the 29th, a task dated the 29th is simply on its day.
    /// Defaulted false so Upcoming's call site needs no opinion — nothing dated
    /// in the past reaches that screen anyway.
    var isToday: Bool = false
    /// A Logbook row: already done. The circle fills and un-ticks instead of
    /// ticking, and the row does not open — see `completeCircle` and `open()`.
    /// Declared last so every existing call site's memberwise argument order is
    /// untouched.
    var completed: Bool = false
    /// What the row's trailing slot says.
    ///
    /// **The slot carries whatever the CONTEXT does not already imply**, which
    /// is why this is three values and not a flag.
    ///
    ///   * `.list` — Today and Upcoming. The day is the heading, so the useful
    ///     thing is which list the task is in.
    ///   * `.date` — the Tasks screen's list rail. `PERSONAL` on every row would
    ///     repeat the heading, so the slot shows the date instead. An undated
    ///     task shows nothing, correctly: the pool is one list and nothing is
    ///     left to say.
    ///   * `.dateElseList` — a document's task band, where NEITHER is implied.
    ///     The band mixes lists and mixes dated with undated, so a row has to
    ///     answer both questions and the date is the more specific answer when
    ///     there is one.
    ///
    /// It was a `showsDate` Bool until Session 80, and `.date` was the only
    /// alternative to `.list`. David caught the gap immediately: a task added
    /// from a document showed no label at all — *"there is no reference to
    /// inbox on the row within satchel"* — because `true` meant "the date, or
    /// nothing" and the task was undated by design.
    ///
    /// Declared last so no existing call site's argument order moves.
    var trailing: TrailingLabel = .list

    enum TrailingLabel { case list, date, dateElseList }

    @State private var draftTitle: String = ""
    @State private var draftNotes: String = ""
    @State private var editingTitle: Bool = false
    @FocusState private var titleFocused: Bool
    @State private var editingShortcut: Bool = false
    @State private var draftShortcut: String = ""
    @FocusState private var shortcutFocused: Bool
    @State private var pickingDay: Bool = false
    @State private var pickedDay: Date = Date()
    /// Set once this card has written its pending edits, so `onDisappear`
    /// cannot write them a second time. Reset in `onAppear`.
    @State private var exitCommitted: Bool = false
    @State private var pickingDocs: Bool = false
    /// Resolves linked paths to titles and icons. Built lazily and only when a
    /// link exists, so a card with no documents pays nothing — this row is
    /// drawn dozens at a time.
    @State private var docStore: TraceMacDocumentStore? = nil
    @State private var pickingRemind: Bool = false
    /// Seeded from the task's existing alarm when there is one, otherwise 9am
    /// on its due day — a default nobody has to correct as often as "now".
    @State private var remindAt: Date = Date()

    private var store: ReminderTaskStore { ReminderTaskStore.shared }

    @Environment(NoteStore.self) private var noteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isOpen { card } else { collapsed }
        }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        HStack(spacing: 12) {
            completeCircle
            Text(task.title)
                .font(MacEditorialType.taskTitle)
                // Muted and struck, not faint: a finished task is still
                // something you did, and greying it to the edge of legibility
                // makes the Logbook feel like a bin rather than a record.
                .foregroundStyle(completed ? MacEditorialColor.muted
                                           : MacEditorialColor.ink)
                .strikethrough(completed, color: MacEditorialColor.faint)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open() }
            carriedMark
            Spacer(minLength: 8)
            trailingMarks
        }
        .frame(height: 42)
        .contentShape(Rectangle())
        .onTapGesture { open() }
    }

    /// The bolt sits on the FACE of the row, not inside the card, because a
    /// shortcut is a thing you fire in passing — needing to open the task
    /// first would defeat it. A `Button` here takes the click before the row's
    /// own tap gesture, so firing it does not also open the card.
    @ViewBuilder
    private var shortcutBolt: some View {
        if shortcutLink != nil {
            Button(action: runShortcut) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(MacEditorialColor.accent)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shortcutName.map { "Run \($0)" } ?? "Run shortcut")
        }
    }

    /// A task still open from an earlier day, surfaced on Today because the
    /// store's Today bucket is `date <= today` (`ReminderTaskStore.apply`).
    ///
    /// **Copied from iOS deliberately, glyph, colour, placement and all**
    /// (`DayflowTodaySection`, 2026-08-28). David: "i think we decided in IOS to
    /// put a small glyph that is light in color. I dont want the app to appear
    /// to be repremanding me for having a task roll forward a day."
    ///
    /// The iOS note states the rule in one line worth keeping: *he wants to KNOW
    /// it followed him, not from when* — so a u-turn, never a date, and never a
    /// warning glyph, because a yield sign would make the row scold.
    ///
    /// My first proposal here was an accent date stamp in the trailing marks,
    /// which was wrong on all four counts: wrong glyph, wrong colour, wrong
    /// place, and it showed the date iOS had explicitly rejected. The lesson is
    /// narrower than "check iOS first" — it is that a decision this app has
    /// already made lives in the CODE under whatever word was chosen at the
    /// time, and "overdue" found nothing because the word here is **carried**.
    /// Grep the behaviour, not the vocabulary.
    ///
    /// Beside the title rather than in `trailingMarks` for a reason that holds
    /// on both platforms: this is a fact about the TASK's history, not about
    /// when and where it sits, and the marks cluster is for the latter.
    @ViewBuilder
    private var carriedMark: some View {
        let carried: Bool = isToday && (task.date.map {
            $0 < Calendar.current.startOfDay(for: Date())
        } ?? false)
        if carried {
            Image(systemName: "arrow.uturn.forward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MacEditorialColor.faint)
                .help("Carried over from an earlier day")
        }
    }

    /// **A task with a note said nothing about it** until Session 80. David,
    /// having just built `//` capture: "the tasks on the screen of the app that
    /// have notes have no indication of that fact."
    ///
    /// That is the worst failure a note can have. A note you cannot see is a
    /// note you will not open, so the row was quietly throwing away the only
    /// context it was carrying.
    ///
    /// **`strippedNotes`, not `task.notes`.** A task whose entire note is a
    /// Shortcuts URL already has the bolt, and one whose note is a single
    /// `[[link]]` shows the chip when it opens. Marking those as well would
    /// make the glyph mean "this row has SOMETHING", which is a mark you learn
    /// to stop reading. It means prose, and only prose.
    ///
    /// The tooltip carries the first line so the note can be read without
    /// opening anything, which is most of why you would open it.
    @ViewBuilder
    private var noteMark: some View {
        let prose: String = strippedNotes
        if !prose.isEmpty {
            // **Muted, not faint** (Session 80, second pass). It shipped in
            // `faint` and David reported it missing while it was on screen in
            // front of him, one gap away from the equally faint list label —
            // two quiet marks side by side stop being two marks.
            //
            // "I did not see it" is a legibility bug with a misleading
            // diagnosis, not a rendering bug. One step darker is the whole fix:
            // still the lightest thing on the row, but no longer the same
            // weight as the furniture beside it.
            // **Accent, third pass.** Shipped faint, darkened to muted when
            // David could not see it, and now accent at his call: "the icon on
            // a task that shows that it has a note could be in the red accent
            // color of this app to make it more visible."
            //
            // Worth recording that the quiet-first instinct was wrong twice in
            // a row on the same mark. The reason is that this glyph competes
            // with a caps list label sitting a few points away, and "quieter
            // than its neighbour" was never going to read as a signal — it
            // reads as more furniture. Accent is the only value on this row
            // that nothing else uses.
            Image(systemName: "text.alignleft")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MacEditorialColor.accent)
                .help(Self.noteHint(prose))
        }
    }

    /// The task points at something openable: a web page, a Satchel document,
    /// or both.
    ///
    /// David, Session 80: *"i think we need an indicator if the task has a link
    /// (either a web, or a document in satchel, etc)...also in the same color
    /// font."* Accent, matching the note mark beside it.
    ///
    /// **Accent from the start, which took three passes to learn on the note
    /// mark.** That one shipped `faint`, was darkened to `muted` when David
    /// could not see it, and ended `accent` at his request. The lesson was that
    /// a mark competing with a caps list label a few points away cannot win by
    /// being quieter than its neighbour — quiet reads as furniture. Accent is
    /// the only value on this row that nothing else uses, so a second mark that
    /// means "there is more here" belongs in it too.
    ///
    /// One mark for both kinds, not two. Two accent glyphs on a row would spend
    /// the loudest colour in the design on a distinction the tooltip can make
    /// for free, and the answer to "which is it" is one hover away.
    @ViewBuilder
    private var linkMark: some View {
        if task.hasFollowableLink {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MacEditorialColor.accent)
                .help(linkHint)
        }
    }

    private var linkHint: String {
        let docs = task.linkedDocumentPaths.count
        let webs = task.webLinks.count
        var parts: [String] = []
        if docs > 0 { parts.append(docs == 1 ? "1 document" : "\(docs) documents") }
        if webs > 0 { parts.append(webs == 1 ? "1 link" : "\(webs) links") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// One line, capped. A tooltip is a glance, not a reader.
    private static func noteHint(_ prose: String) -> String {
        let first = prose.split(separator: "\n").first.map(String.init) ?? prose
        let more = prose.contains("\n")
        let clipped = first.count > 90 ? String(first.prefix(90)) + "\u{2026}" : first
        return more && !clipped.hasSuffix("\u{2026}") ? clipped + "\u{2026}" : clipped
    }

    @ViewBuilder
    private var trailingMarks: some View {
        shortcutBolt
        // Beside the bolt, because both are marks about what the task CARRIES.
        // The repeat, the alarm and the list that follow are all about when and
        // where it sits, and keeping the two kinds from interleaving is what
        // stops this from reading as a row of assorted badges.
        noteMark
        linkMark
        if task.repeats {
            Image(systemName: "repeat")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MacEditorialColor.faint)
        }
        if let alarm = task.alarmTimeString {
            Text(alarm)
                .font(MacEditorialType.time)
                .foregroundStyle(MacEditorialColor.faint)
        }
        switch trailing {
        case .list:
            if let list = task.list {
                Text(list).editorialListLabel()
            }
        case .date:
            if let due = task.date {
                Text(Self.shortDate(due)).editorialListLabel()
            }
        case .dateElseList:
            if let due = task.date {
                Text(Self.shortDate(due)).editorialListLabel()
            } else if let list = task.list {
                Text(list).editorialListLabel()
            }
        }
    }

    /// Short, and dateless on the year where it can be: inside a list view most
    /// rows are this year, and printing it on every one spends width on the
    /// least surprising fact on the row.
    nonisolated private static func shortDate(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "EEE d MMM" : "d MMM yyyy"
        return f.string(from: day)
    }

    /// **The same control, both directions** (Session 80). David, on the
    /// Logbook: "i should be able to press the circle on a completed task in
    /// there to bring it back to life."
    ///
    /// A separate "restore" button would have been the safer-looking choice and
    /// the wrong one. The circle already means "this is done / this is not", so
    /// pressing it to reverse the statement is the same sentence read backwards.
    /// A second control would make the Logbook a different kind of list rather
    /// than the same list in a different state.
    ///
    /// No confirmation either way. Completing is undone by un-completing, which
    /// is the row you are already looking at.
    private var completeCircle: some View {
        Button {
            Task {
                if completed {
                    await store.uncomplete(taskID: task.id)
                } else {
                    await store.complete(taskID: task.id)
                }
                onChanged()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(completed ? MacEditorialColor.accent
                                            : MacEditorialColor.faint,
                                  lineWidth: 1.5)
                if completed {
                    Circle()
                        .fill(MacEditorialColor.accent)
                        .frame(width: 18, height: 18)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(MacEditorialColor.paper)
                }
            }
            .frame(width: 18, height: 18)
                // **`strokeBorder` is hit-testable only on the STROKE.** Without
                // a content shape, the 1.5pt ring was the entire target and the
                // hole in the middle fell straight through to the row's own tap
                // gesture — so clicking the circle expanded the task instead of
                // completing it (David, Session 80). The bolt in `trailingMarks`
                // never had this bug because it always carried a
                // `.contentShape(Rectangle())`; the circle did not, and the two
                // sat inches apart behaving differently for a year.
                //
                // The padding makes it a 22pt target around an 18pt drawing.
                // A completion control is the one thing on this row you must
                // never miss and hit something else instead.
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Expanded

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                completeCircle
                titleField
                Spacer(minLength: 0)
                closeButton
            }

            noteField
            fieldRows
            offerLine
            if pickingDay { dayPicker }
            if pickingRemind { remindPicker }
            MacEditorialRule.hair
            pills
            verbs
        }
        .padding(18)
        .background(MacEditorialColor.paper)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(MacEditorialColor.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .padding(.vertical, 8)
        // **Escape closes the card**, the third way in and out of the same
        // state (David, Session 80: "hitting escape should collapse it just
        // like the second double click"). The chevron is the discoverable one,
        // the double-click is the fast one, and Escape is the one your hand
        // already knows from every other panel on the machine.
        //
        // It unwinds one layer: an open day grid closes first, so backing out
        // of a date does not also throw away the card you were editing. The
        // same rule the composer's Escape follows.
        .escapeCloses(includingTextFields: true) { escapePressed() }
        .onAppear {
            draftTitle = task.title
            draftNotes = strippedNotes
            editingTitle = false
            exitCommitted = false
        }
        // **The backstop, and the only thing that can catch a click outside.**
        // That collapse is the HOST's — Today clears `openTaskID` when the day
        // note takes focus — so the card is never told, it simply stops
        // existing. Nothing inside it can intercept that except its own
        // disappearance.
        //
        // Safe to fire on any teardown (a scroll, a window close, a redraw)
        // because `commitPendingEdits` writes only when something changed, and
        // the save is an unstructured `Task` that outlives the view.
        .onDisappear { commitPendingEdits() }
        // Only when there is a chip to resolve. An open card with no documents
        // never scans the folder.
        .task(id: task.linkedDocumentPaths) { await loadDocsIfNeeded() }
        .sheet(isPresented: $pickingDocs) {
            MacTaskDocumentPicker(linked: task.linkedDocumentPaths) { path in
                toggleDocument(path)
            }
            .environment(noteStore)
        }
    }

    private func loadDocsIfNeeded() async {
        guard !task.linkedDocumentPaths.isEmpty else { return }
        if docStore == nil { docStore = TraceMacDocumentStore(noteStore: noteStore) }
        await docStore?.reload()
    }

    /// The title is a `Text` until you ask to edit it, and that is the whole
    /// fix for a real bug.
    ///
    /// Session 80, first attempt: a live `TextField` with a
    /// `simultaneousGesture(TapGesture(count: 2))`. David: "the double click on
    /// the task name didnt collapse it but it did expand it." On macOS an
    /// `NSTextField` claims the double-click for word selection before any
    /// SwiftUI gesture attached to it is consulted, so the gesture never fired
    /// — and stealing word-select inside a text field would have been the wrong
    /// fix anyway.
    ///
    /// So: no text field sits there until it is wanted. Single click starts
    /// editing, double click collapses the card, and the two do not race
    /// because the double-click gesture is declared FIRST and SwiftUI resolves
    /// it in that order. Escape and Return both end editing, which is also how
    /// the field stops eating the arrow keys the sidebar wants.
    @ViewBuilder
    private var titleField: some View {
        if editingTitle {
            TextField("", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(MacEditorialType.subject)
                .foregroundStyle(MacEditorialColor.ink)
                .focused($titleFocused)
                .onSubmit { endTitleEdit() }
                .onExitCommand { endTitleEdit() }
                .onAppear { titleFocused = true }
        } else {
            Text(draftTitle.isEmpty ? task.title : draftTitle)
                .font(MacEditorialType.subject)
                .foregroundStyle(MacEditorialColor.ink)
                .lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { closeCard() }
                .onTapGesture(count: 1) { editingTitle = true }
        }
    }

    private func endTitleEdit() {
        commitTitle()
        editingTitle = false
        titleFocused = false
    }

    private var closeButton: some View {
        Button(action: closeCard) {
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(MacEditorialColor.faint)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var noteField: some View {
        TextField("Add a note", text: $draftNotes, axis: .vertical)
            .textFieldStyle(.plain)
            .font(MacEditorialType.fieldValue)
            .foregroundStyle(MacEditorialColor.noteText)
            .lineLimit(1...6)
            .padding(.leading, 30)
            .padding(.top, 10)
            .onSubmit { commitNotes() }
    }

    // MARK: Field rows — only what the task carries

    @ViewBuilder
    private var fieldRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let when = whenLabel {
                MacEditorialRule.hair
                fieldRow("When") {
                    Text(when)
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.ink)
                }
            }
            if let list = task.list {
                MacEditorialRule.hair
                fieldRow("List") {
                    Text(list)
                        .font(MacEditorialType.fieldValue)
                        .foregroundStyle(MacEditorialColor.ink)
                }
            }
            if let alarm = task.alarmTimeString {
                MacEditorialRule.hair
                fieldRow("Remind") {
                    HStack(spacing: 6) {
                        Image(systemName: "bell")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MacEditorialColor.noteText)
                        Button {
                            remindAt = defaultRemindTime
                            pickingRemind = true
                        } label: {
                            Text(alarm)
                                .font(MacEditorialType.fieldValue)
                                .foregroundStyle(MacEditorialColor.ink)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Change the time")
                        Button { clearRemind() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(MacEditorialColor.faint)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("No reminder")
                    }
                }
            }
            if task.repeats {
                MacEditorialRule.hair
                // The label reads the rule off the reminder rather than saying
                // "On", which told you a repeat existed and nothing about it.
                fieldRow("Repeat") { repeatMenu(label: currentRepeat.label) }
            }
            if shortcutLink != nil || editingShortcut {
                MacEditorialRule.hair
                fieldRow("Shortcut") { shortcutControl }
            }
            if !linkedNames.isEmpty {
                MacEditorialRule.hair
                fieldRow("Linked") {
                    HStack(spacing: 6) {
                        ForEach(linkedNames, id: \.self) { name in
                            linkChip(name)
                        }
                    }
                }
            }
            if !task.webLinks.isEmpty {
                MacEditorialRule.hair
                // **"Web", not "Link".** There is already a "Linked" row for
                // people and places and a "Document" row below; a third row
                // called "Link" would be the least distinguishable label of the
                // three. The row says what the thing IS.
                //
                // These URLs stay in the note prose as well, and that is
                // deliberate: a URL is something he typed, it reads as part of
                // the sentence around it, and stripping it into machinery
                // (`isMachineryLine`) would silently rewrite his note. This row
                // makes it clickable without taking it away.
                fieldRow("Web") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(task.webLinks, id: \.self) { url in
                            Button { NSWorkspace.shared.open(url) } label: {
                                Text(url.host ?? url.absoluteString)
                                    .font(MacEditorialType.fieldValue)
                                    .foregroundStyle(MacEditorialColor.accent)
                                    .lineLimit(1)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(url.absoluteString)
                        }
                    }
                }
            }
            if !task.linkedDocumentPaths.isEmpty {
                MacEditorialRule.hair
                // Its own row, not folded into "Linked". A person and a place
                // are people-and-places; a document is a FILE, it opens
                // somewhere else, and it can go missing in a way a Notion
                // record cannot. Different failure mode, different row.
                fieldRow("Document") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(task.linkedDocumentPaths, id: \.self) { path in
                            documentChip(path)
                        }
                    }
                }
            }
        }
        .padding(.leading, 30)
        .padding(.top, 10)
    }

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .editorialFieldLabel()
                .frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    private func linkChip(_ name: String) -> some View {
        let glyph: String = isPlace(name) ? "mappin.and.ellipse" : "person"
        return HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.system(size: 9))
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
        }
        .foregroundStyle(MacEditorialColor.muted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(MacEditorialColor.hairline, lineWidth: 1)
        }
    }

    /// A linked Satchel document.
    ///
    /// **Resolved live, never cached** (D227). The title comes from the store
    /// each time; the notes hold only the path. A document that has been
    /// deleted says so rather than showing a name that no longer opens
    /// anything — the one thing a stale cached title could not do.
    private func documentChip(_ path: String) -> some View {
        let doc: TraceMacDocument? = docStore?.documents.first { $0.relativePath == path }
        let title: String = doc?.title ?? Self.filenameOf(path)
        let glyph: String = doc?.resolvedIcon.sfSymbol ?? "questionmark.square.dashed"
        let tint: Color = doc.map { MacPalette.documentTint($0.resolvedTint) }
            ?? MacEditorialColor.faint
        let missing: Bool = docStore != nil && doc == nil
        return HStack(spacing: 6) {
            Button {
                // The notification, not a closure: `.navigateToRecord` is what
                // the Photos and Places sheets already post to reach a record
                // without every intervening view growing a parameter, and
                // `TraceMacContentView` routes it through `openSearchResult`,
                // so the jump lands in the navigator's history for free.
                guard !missing else { return }
                NotificationCenter.default.post(
                    name: .navigateToRecord, object: nil,
                    userInfo: ["type": "document", "id": path])
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: glyph)
                        .font(.system(size: 9))
                        .foregroundStyle(missing ? MacEditorialColor.faint : tint)
                    Text(missing ? "\(title) (missing)" : title)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(missing ? MacEditorialColor.faint
                                                 : MacEditorialColor.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(MacEditorialColor.hairline, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(missing ? path : "Open in Documents")
            Button { toggleDocument(path) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(MacEditorialColor.faint)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unlink")
        }
    }

    /// The last path component, for a document the store cannot resolve. The
    /// timestamp prefix is dropped so a missing file still reads as something
    /// recognisable rather than as a serial number.
    private static func filenameOf(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let parts = name.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        if parts.count == 4, parts[0].count == 4, Int(parts[0]) != nil {
            return String(parts[3])
        }
        return name
    }

    /// Adds or removes one `satchel:doc:` line, leaving every other line alone.
    ///
    /// Rewrites the whole notes field because that is the only write the store
    /// offers, so the rule is that this must be lossless for everything it does
    /// not own — prose, wikilinks and the shortcut URL all survive verbatim.
    private func toggleDocument(_ path: String) {
        let marker = ThingsTask.documentMarkerPrefix + path
        let existing = task.notes ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let at = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == marker
        }) {
            lines.remove(at: at)
        } else {
            // Appended, so a document link never lands above the prose he
            // wrote. Same placement the shortcut URL gets.
            lines.append(marker)
        }
        let notes = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            _ = await store.update(taskID: task.id, title: task.title, date: task.date,
                                   clearDate: task.date == nil, list: task.list,
                                   notes: notes)
            onChanged()
        }
    }

    /// Everything the task does NOT carry, in one faint line. Nothing here when
    /// the task carries all of it.
    @ViewBuilder
    private var offerLine: some View {
        let offers: [String] = missingOffers
        if !offers.isEmpty {
            HStack(spacing: 16) {
                ForEach(offers, id: \.self) { offer in
                    // Repeat is the odd one: picking a recurrence is picking
                    // one of eight, and a button that opens a picker to choose
                    // among eight is a menu with extra steps.
                    if offer == "Repeat" {
                        repeatMenu(label: "+ Repeat")
                    } else {
                        Button { tapOffer(offer) } label: {
                            Text("+ \(offer)")
                                .editorialQuietLabel()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 38)
            .padding(.leading, 30)
        }
    }

    /// **Every label here must do something.** This action used to open
    /// `guard offer == "Shortcut" else { return }`, so four of the five offers
    /// rendered, accepted the click and swallowed it — D225, and the third bug
    /// of its kind in one session. `missingOffers` and this switch have to be
    /// read together: a label added there without an arm here is silent again.
    private func tapOffer(_ offer: String) {
        switch offer {
        case "Shortcut":
            draftShortcut = ""
            editingShortcut = true
        case "When":
            pickedDay = task.date ?? Calendar.current.startOfDay(for: Date())
            pickingDay = true
        case "Remind":
            remindAt = defaultRemindTime
            pickingRemind = true
        case "Link":
            pickingDocs = true
        default:
            // "Repeat" is a Menu and never arrives here. Anything else is a
            // label someone added to `missingOffers` without an arm.
            break
        }
    }

    /// Only the offers that DO something.
    ///
    /// All five were listed here once and four were wired to nothing (D225).
    /// Remind and Repeat came back a build later with their controls; Link is
    /// still out, because it needs a decision about how a document link is
    /// written into the notes, not just a button.
    ///
    /// **Remind and Repeat require a due date and are hidden without one.**
    /// `update(remindAt:)` only sets an alarm alongside a date, and
    /// `setRepeat`'s own note says a repeat needs a date to anchor to. Offering
    /// either on an undated task would be a fourth control that accepts a click
    /// and does nothing — the exact bug this list was trimmed for. "+ When" is
    /// the offer showing in that case, which is also the honest instruction.
    private var missingOffers: [String] {
        var out: [String] = []
        if task.date == nil { out.append("When") }
        if task.date != nil, task.alarmTimeString == nil { out.append("Remind") }
        if task.date != nil, !task.repeats { out.append("Repeat") }
        // Offered even when documents are already linked — unlike the others,
        // this is a list you add to rather than a single value you set.
        out.append("Link")
        if shortcutLink == nil { out.append("Shortcut") }
        return out
    }

    /// The shortcut is EDITABLE, which it was not when it first shipped.
    ///
    /// Session 80, David: "I was going to add a new shortcut to the Mac for
    /// this task but the shortcut link is not adjustable and it should be."
    /// Fair — I had made the URL runnable and then stripped it out of the notes
    /// prose, which between them removed the only way he had to change it.
    ///
    /// What he edits is the NAME, not the URL. `shortcuts://run-shortcut?name=`
    /// is boilerplate he should never have to retype, and a free-text URL field
    /// is a thing you can typo into silence. The bolt stays alongside, because
    /// running it is still the common case.
    @ViewBuilder
    private var shortcutControl: some View {
        if editingShortcut {
            TextField("Shortcut name", text: $draftShortcut)
                .textFieldStyle(.plain)
                .font(MacEditorialType.fieldValue)
                .foregroundStyle(MacEditorialColor.ink)
                .focused($shortcutFocused)
                .onSubmit { commitShortcut() }
                .onExitCommand { editingShortcut = false }
                .onAppear { shortcutFocused = true }
        } else {
            HStack(spacing: 10) {
                Button(action: runShortcut) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(shortcutName ?? "Run shortcut")
                            .font(MacEditorialType.fieldValue)
                    }
                    .foregroundStyle(MacEditorialColor.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    draftShortcut = shortcutName ?? ""
                    editingShortcut = true
                } label: {
                    Text("Change").editorialQuietLabel()
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Writes the shortcut line back into the notes, replacing any existing
    /// one. An empty name removes it — that is the delete, and it needs no
    /// separate control.
    private func commitShortcut() {
        let name = draftShortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        editingShortcut = false
        shortcutFocused = false

        let existing = task.notes ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !Self.hasShortcut($0) }
        if !name.isEmpty {
            lines.append(rewrittenShortcutURL(name: name))
        }
        let merged = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            _ = await store.update(taskID: task.id, title: task.title, date: task.date,
                                   clearDate: false, list: task.list, notes: merged)
            onChanged()
        }
    }

    // MARK: Pick day

    private var dayPicker: some View {
        MacEditorialMonthGrid(selected: $pickedDay)
            .padding(.leading, 30)
            .padding(.vertical, 10)
            .onChange(of: pickedDay) { _, day in
                setDate(day)
                pickingDay = false
            }
    }

    // MARK: Remind

    /// 9am on the due day, or the alarm already set. Chosen over "now" because
    /// a reminder is nearly always for a working hour on the day the task is
    /// due, and "now" is the one time it is never for.
    private var defaultRemindTime: Date {
        let cal = Calendar.current
        // `remindDate` reads the EKReminder; `ThingsTask` carries only the
        // display STRING, which cannot be parsed back into a time reliably.
        if let existing = store.remindDate(taskID: task.id) { return existing }
        let day = task.date ?? Date()
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// Time only. The DAY is the task's due day and is not re-asked here —
    /// "When" already owns that question, and two controls that can disagree
    /// about which day a task is on is a record that contradicts itself.
    private var remindPicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell")
                .font(.system(size: 11))
                .foregroundStyle(MacEditorialColor.faint)
            DatePicker("", selection: $remindAt, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            MacEditorialPill(label: "Set") { commitRemind() }
            Button("Cancel") { pickingRemind = false }
                .buttonStyle(.plain)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.muted)
            Spacer(minLength: 0)
        }
        .padding(.leading, 30)
        .padding(.vertical, 10)
    }

    private func commitRemind() {
        guard let day = task.date else { pickingRemind = false; return }
        // The picker only moved the time, so the day is re-imposed here: a
        // `.hourAndMinute` picker still carries whatever date it was seeded
        // with, and seeding drift would silently move the task.
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: remindAt)
        let when = cal.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0,
                            second: 0, of: day) ?? day
        pickingRemind = false
        Task {
            _ = await store.update(taskID: task.id, title: task.title, date: day,
                                   clearDate: false, list: task.list,
                                   notes: task.notes, remindAt: when)
            onChanged()
        }
    }

    private func clearRemind() {
        guard let day = task.date else { return }
        Task {
            _ = await store.update(taskID: task.id, title: task.title, date: day,
                                   clearDate: false, list: task.list,
                                   notes: task.notes, clearRemind: true)
            onChanged()
        }
    }

    // MARK: Repeat

    private var currentRepeat: ReminderTaskStore.DayflowRepeatRule {
        store.repeatRule(taskID: task.id)
    }

    /// Styled the long way round, matching `listMenu` above rather than calling
    /// `editorialQuietLabel()`.
    ///
    /// David: *"the wording for repeat is dark and bigger than the others."*
    /// Two causes, both about a `Menu` not being a `Button`:
    ///
    /// **A Menu imposes its own control font and colour on its label**, so the
    /// modifier's `font`/`foregroundStyle` lost to it and "+ REPEAT" came out
    /// dark and full-size beside two faint 10pt offers. Setting the font on the
    /// `Text` and the colour on the `HStack` — exactly what `listMenu` does —
    /// is what survives.
    ///
    /// **`.menuIndicator(.hidden)` has to come BEFORE `.menuStyle`**, which is
    /// written down two functions up and which I still got backwards: applied
    /// after, the style had already drawn its own chevron, so the row showed
    /// one on the left as well as the Editorial one on the right.
    private func repeatMenu(label: String) -> some View {
        Menu {
            ForEach(ReminderTaskStore.DayflowRepeatRule.allCases, id: \.self) { rule in
                Button(rule.label) { setRepeat(rule) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(MacEditorialType.quietLabel)
                    .textCase(.uppercase)
                    .tracking(MacEditorialType.quietTracking)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(MacEditorialColor.faint)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func setRepeat(_ rule: ReminderTaskStore.DayflowRepeatRule) {
        Task {
            _ = await store.setRepeat(taskID: task.id, rule: rule)
            onChanged()
        }
    }

    // MARK: Footer

    private var pills: some View {
        HStack(spacing: 7) {
            MacEditorialPill(label: "Today") {
                setDate(Calendar.current.startOfDay(for: Date()))
            }
            MacEditorialPill(label: "Tomorrow") { setDate(dayFromNow(1)) }
            MacEditorialPill(label: "Pick day") {
                pickedDay = task.date ?? Calendar.current.startOfDay(for: Date())
                pickingDay.toggle()
            }
            MacEditorialPill(label: "Delete", destructive: true) {
                Task {
                    _ = await store.remove(taskID: task.id)
                    onChanged()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    // `pill` retired, Session 80 — it is `MacEditorialPill` now, so the
    // hover wash is the same one the month grid uses and every future pill
    // gets it for free.

    private var verbs: some View {
        HStack(spacing: 20) {
            MacEditorialVerb(label: "Done", glyph: "checkmark.circle") {
                Task { await store.complete(taskID: task.id); onChanged() }
            }
            MacEditorialVerb(label: "Anytime", glyph: "books.vertical") { moveToAnytime() }
            MacEditorialVerb(label: "Someday", glyph: "archivebox") {
                Task { _ = await store.moveToSomeday(taskID: task.id); onChanged() }
            }
            Spacer(minLength: 0)
            listMenu
        }
        .padding(.top, 14)
    }

    private var listMenu: some View {
        Menu {
            ForEach(store.listNames.filter { $0 != task.list }, id: \.self) { name in
                Button(name) { setList(name) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(task.list ?? ReminderTaskStore.personalListName)
                    .font(.system(size: 11.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(MacEditorialColor.faint)
        }
        // Session 80: `.borderlessButton` draws its OWN chevron, so the row had
        // two — one from the menu style and one from the label. The label's is
        // the Editorial one, so the system's goes.
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Mutations

    private func open() {
        // A completed row does not open. The card is an editor — pills that
        // move a due date, a list picker, a shortcut field — and every one of
        // those is meaningless for something already done. Offering an editor
        // that cannot usefully edit is worse than offering none.
        //
        // The one thing you might want on a finished task, bringing it back, is
        // the circle. That is the whole interaction here.
        guard !completed else { return }
        draftTitle = task.title
        draftNotes = strippedNotes
        onToggle()
    }

    private func dayFromNow(_ days: Int) -> Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: days, to: base) ?? base
    }

    /// Escape closes the card from anywhere inside it, including out of a
    /// half-typed note.
    ///
    /// **It commits rather than discards**, which is what makes the whole
    /// behaviour safe to ask for. The note field only saves `.onSubmit`, so
    /// collapsing without this would silently throw away everything typed since
    /// the last Return — the exact failure that made the first version of this
    /// stand down for text fields at all.
    ///
    /// One layer at a time, same as everywhere else: an open day grid closes
    /// first and the card stays.
    private func escapePressed() {
        if pickingDocs { pickingDocs = false; return }
        if pickingRemind { pickingRemind = false; return }
        if pickingDay { pickingDay = false; return }
        closeCard()
    }

    /// **Every way out of the card commits**, which it did not until now.
    ///
    /// David, Session 80: *"i added a note then closed the task and reopened
    /// and the note was gone. is there a save or just exiting was suppose to
    /// save the note."* Exiting was supposed to. Only two of the four exits
    /// actually did: Return (`onSubmit`) and Escape. The chevron called
    /// `onToggle` straight through, and clicking outside the card is the host's
    /// collapse — neither passed anywhere that could save.
    ///
    /// The note field has no Save button by design (nothing else in this app
    /// does), so "it saves when you leave" has to be true of leaving in
    /// general, not of the two exits that happened to be wired.
    private func closeCard() {
        commitPendingEdits()
        onToggle()
    }

    /// Commits the title and the note if either differs from what is stored.
    ///
    /// Guarded on dirtiness because `onDisappear` calls it too: an unguarded
    /// version would write to Reminders every time a row scrolled out of view.
    private func commitPendingEdits() {
        guard !exitCommitted else { return }
        exitCommitted = true
        if editingTitle { commitTitle() }
        if draftNotes != strippedNotes { commitNotes() }
    }

    /// The note as it should be SAVED right now — the merged form when the
    /// field is dirty, the stored value when it is not.
    ///
    /// Exists so a path that both mutates the task and closes the card can
    /// carry the unsaved note in its OWN single write. Two concurrent
    /// `update`s on one reminder race on every field, and the loser here would
    /// be the one holding the new date.
    private var notesToSave: String? {
        draftNotes != strippedNotes ? rebuiltNotes(prose: draftNotes) : task.notes
    }

    private func commitTitle() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != task.title else { return }
        Task {
            _ = await store.update(taskID: task.id, title: title, date: task.date,
                                   clearDate: false, list: task.list, notes: task.notes)
            onChanged()
        }
    }

    /// The `[[wikilinks]]` are kept and the visible prose replaced, so editing a
    /// note can never silently drop the links the agenda and the endeavor
    /// screens match on.
    private func commitNotes() {
        let merged = rebuiltNotes(prose: draftNotes)
        Task {
            _ = await store.update(taskID: task.id, title: task.title, date: task.date,
                                   clearDate: false, list: task.list, notes: merged)
            onChanged()
        }
    }

    /// Moving a task closes its card. David, Session 80: "the task moves fine
    /// but it remains expanded and the behavior should be that it moves and
    /// collapses." The card is open because you were deciding; the decision is
    /// made, so it goes away. `onMoved` also tells the host where it went, so
    /// the host can offer to follow it.
    private func setDate(_ day: Date) {
        // **One write, carrying any unsaved note with it.**
        //
        // This method closes the card, and `onDisappear` now commits pending
        // edits — so without this, typing a note and then pressing a date pill
        // fired TWO updates on the same reminder. The second one is
        // `commitNotes`, built from this view's `task`, which still holds the
        // OLD date: it would land after the move and quietly undo it.
        //
        // Merging the note into this write removes the second update entirely
        // rather than trying to order the two.
        let notes = notesToSave
        exitCommitted = true
        Task {
            _ = await store.update(taskID: task.id, title: task.title, date: day,
                                   clearDate: false, list: task.list, notes: notes)
            onChanged()
            onMoved(day)
            onToggle()
        }
    }

    private func setList(_ name: String) {
        Task {
            _ = await store.update(taskID: task.id, title: task.title, date: task.date,
                                   clearDate: task.date == nil, list: name, notes: task.notes)
            onChanged()
        }
    }

    /// ANYTIME: to the Personal list, undated. Straight from
    /// `DayflowInboxView`'s own verb — this is not a Mac invention.
    private func moveToAnytime() {
        Task {
            _ = await store.update(taskID: task.id, title: task.title, date: nil,
                                   clearDate: true,
                                   list: ReminderTaskStore.personalListName,
                                   notes: task.notes)
            onChanged()
        }
    }

    /// Rebuilds the shortcut URL with a new `name`, KEEPING every other query
    /// item the original carried.
    ///
    /// The card shows a shortcut's NAME rather than its URL, which is right —
    /// `shortcuts://run-shortcut?name=` is boilerplate and a URL is a thing you
    /// can typo into silence. But a Shortcuts URL can legitimately carry more
    /// than a name (`&input=`, `&text=`), and rebuilding from the name alone
    /// would silently drop them the first time such a shortcut was renamed.
    /// Losing data invisibly to make an editor simpler is not a trade worth
    /// making.
    private func rewrittenShortcutURL(name: String) -> String {
        let encodedFallback = name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? name
        let plain = "\(Self.shortcutScheme)run-shortcut?name=\(encodedFallback)"
        guard let url = shortcutLink,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return plain }
        var items = (parts.queryItems ?? []).filter { $0.name != "name" }
        items.insert(URLQueryItem(name: "name", value: name), at: 0)
        parts.queryItems = items
        return parts.string ?? plain
    }

    // MARK: Notes and links

    private var whenLabel: String? {
        guard let due = task.date else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(due) { return "Today" }
        if cal.isDateInTomorrow(due) { return "Tomorrow" }
        if cal.isDateInYesterday(due) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: due)
    }

    /// Link names out of the notes, same scan as `DayflowTaskWikiChips`:
    /// `[[Name]]`, deduped, `visit:` prefixes skipped.
    private var linkedNames: [String] {
        guard let notes = task.notes, notes.contains("[[") else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        var rest = Substring(notes)
        while out.count < 4,
              let open = rest.range(of: "[["),
              let close = rest.range(of: "]]"),
              open.upperBound <= close.lowerBound {
            let name = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            rest = rest[close.upperBound...]
            guard !name.isEmpty, !name.hasPrefix("visit:"), seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// A Shortcuts URL buried in the task's notes.
    ///
    /// Session 80, David on a task carrying one: "it is not clickable which is
    /// wrong and it should result in a lightning bolt icon... which would
    /// automatically run the shortcut if i press it."
    ///
    /// Scanned rather than parsed with `NSDataDetector`, which only recognises
    /// web schemes and would never see `shortcuts://`. Stops at whitespace, so
    /// a link followed by prose on the same line still resolves.
    /// The scheme match is CASE-INSENSITIVE, and that is not defensiveness —
    /// David's own note reads `Shortcuts://run-shortcut?name=monarch` with a
    /// capital S, which is perfectly legal (RFC 3986: schemes are
    /// case-insensitive) and which the first version of this silently missed.
    /// Everything that looks for the scheme in this file goes through
    /// `Self.shortcutScheme` for that reason.
    /// Forwarders, not definitions. The test moved to `ThingsTask` in Session
    /// 80 so iOS could share it; these keep this file's five call sites
    /// unchanged while there stays exactly one answer to "is this a shortcut
    /// line".
    private static let shortcutScheme = ThingsTask.shortcutScheme

    private static func hasShortcut(_ text: any StringProtocol) -> Bool {
        ThingsTask.isShortcutLine(text)
    }

    private var shortcutLink: URL? {
        guard let notes = task.notes,
              let start = notes.range(of: Self.shortcutScheme, options: .caseInsensitive)
        else { return nil }
        let raw = notes[start.lowerBound...].prefix { !$0.isWhitespace && $0 != "\"" }
        // Lowercase the scheme before building the URL. `URL` keeps whatever
        // case it is given, and not every opener is as forgiving as the spec.
        let normalised = Self.shortcutScheme + raw.dropFirst(Self.shortcutScheme.count)
        return URL(string: String(normalised))
    }

    /// The `name=` query of a Shortcuts run URL, percent-decoded — what the
    /// bolt says it will run when there is room to say it.
    private var shortcutName: String? {
        guard let url = shortcutLink,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        return items.first(where: { $0.name == "name" })?.value
    }

    private func runShortcut() {
        guard let url = shortcutLink else { return }
        NSWorkspace.shared.open(url)
    }

    private func isPlace(_ name: String) -> Bool {
        NotionService.shared.places.contains { $0.name == name }
    }

    /// The note text with every `[[link]]` line and the shortcut URL removed —
    /// what the field shows, and what the row's note mark counts.
    ///
    /// Moved to `ThingsTask.noteProse` in Session 80. It was private to this
    /// row, which is why the iOS rows had no note mark at all: there was
    /// nothing for them to ask.
    private var strippedNotes: String { task.noteProse }

    /// Prose first, then every machinery line exactly as it was.
    ///
    /// **Keyed on `ThingsTask.isMachineryLine`, which is also what `noteProse`
    /// strips.** This used to carry its own list of what to preserve, and the
    /// two lists drifted the moment D227 added the `satchel:doc:` marker —
    /// `noteProse` hid it from the field, and this dropped it on save, so
    /// editing a note would have deleted the document links without a word.
    /// Whatever the reader hides, this keeps. By construction, not by care.
    private func rebuiltNotes(prose: String) -> String {
        guard let notes = task.notes else { return prose }
        let links = notes.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { ThingsTask.isMachineryLine($0) }
            .map(String.init)
        guard !links.isEmpty else { return prose }
        let body = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? links.joined(separator: "\n")
                            : body + "\n" + links.joined(separator: "\n")
    }
}
