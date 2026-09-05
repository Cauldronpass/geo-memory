// TraceMacTodayView.swift
// The day, on the Mac. Sidebar destination one (D186).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 79 (2026-08-30), built from the "Trace Mac Day" canvas.
//
// ── What this screen is for ──────────────────────────────────────────────
//
// The phone's Today screen squeezes the day note into a band at the bottom,
// because a phone has one column and the day's meetings have to have it. The
// Mac's whole gain is that it does not: THE DAY sits at a fixed reading
// measure on the left and the DAY NOTE is a real full-height editor beside it,
// so writing the day and reading the day happen at once. Everything else here
// is the iOS screen, faithfully — same masthead, same TO DO before THE DAY,
// same 8pt classified chips, same track.
//
// ── What is NOT here yet, deliberately ───────────────────────────────────
//
//   * AGENDA lines under meetings (D171-D176). No longer blocked: Session 82
//     (D244) lifted `DayflowAgendaMatch` into `Trace/` and moved `noteStem`
//     onto it, so this target can see the matcher. When the line is built it
//     belongs on `MacMeetingRow`, not in this file — Today and Upcoming draw
//     the same meeting row, and two agendas is the drift the iOS extraction
//     note exists to prevent.
//   * The month rail. `TraceMacCalendarPanel` exists and works, but it wears
//     the old dress; putting it in an Editorial screen unrestyled would look
//     exactly like what it would be.
//   * The endeavor presence line (D182) and the weather in the standfirst.
//     Both are real on iOS; both are their own small pieces.
//
// ── The type-checker ──────────────────────────────────────────────────────
//
// Every colour and every conditional in this file is hoisted to a typed `let`
// before it reaches a view modifier. That is not style. Session 79 lost a
// build to "unable to type-check this expression in reasonable time" in a file
// nobody had edited, and inline ternaries feeding `.background`/`.foregroundStyle`
// were the whole cause. Keep it this way.

import SwiftUI
import AppKit

struct TraceMacTodayView: View {

    @Environment(NoteStore.self) private var noteStore
    /// Every endeavor's name, for the row's endeavor flag (Session 87).
    /// Loaded once when this screen appears; `MacTaskRow` is handed the set
    /// rather than reaching for one, because rows are drawn dozens at a time.
    @State private var endeavorNames: Set<String> = []

    /// Owned by `TraceMacContentView` so the arrow-key monitor can move it and
    /// so the day survives leaving the section and coming back.
    @Binding var date: Date
    /// Opens a place record in Directory, for the meeting card's WHERE row
    /// (D223). Defaulted, so nothing that builds this view alone has to know
    /// about Directory.
    var onOpenPlace: (String) -> Void = { _ in }
    /// Opens a daily or project note — the agenda's note rows (D246). REQUIRED,
    /// not defaulted like `onOpenPlace`: see the note on `MacMeetingRow`'s four.
    let onOpenNote: (String) -> Void
    /// A week note (or a day) to open in DAYS, set by `TraceMacContentView`
    /// for the routes that used to land on the Weekly tab (D255). Consumed and
    /// cleared here, the `pendingHorizonsFile` shape.
    var deepLinkDaysPick: Binding<MacDaysPick?>? = nil

    @State private var events: [NextCalendarEvent] = []
    @State private var newTaskTitle: String = ""
    /// The one task whose card is open (D190) — at most one at a time, so
    /// opening a second closes the first without either row having to know
    /// about the other.
    @State private var openTaskID: String? = nil
    /// The one meeting whose card is open. Separate from `openTaskID` but
    /// mutually exclusive with it — opening either closes the other, because
    /// two cards open at once on a 524pt column is a scroll, not a screen.
    @State private var openEventID: String? = nil
    /// The month grid, unfolded under the masthead. Same door as the phone's
    /// chevron (Session 80): the three-word day nav reaches yesterday, today
    /// and tomorrow, and the month reaches everything else.
    @State private var monthUnfolded: Bool = false
    /// A task that just moved, and where it went. Drives the one quiet line
    /// offering to follow it (Session 80). Cleared on a timer, on a day change,
    /// or when he takes the offer.
    @State private var movedTo: Date? = nil
    @State private var movedClearTask: Task<Void, Never>? = nil
    @FocusState private var addFieldFocused: Bool
    /// Focus on the day note.
    ///
    /// **A plain `Bool`, not `@FocusState`** (Session 80). The day note is an
    /// `NSTextView` now, and `@FocusState` cannot see inside an
    /// `NSViewRepresentable` — it would simply never become true. The flag is
    /// fed by `MacTextEditor.onFocusChange`, which reports the AppKit fact
    /// directly instead of asking SwiftUI to infer it.
    ///
    /// Everything hanging off it is unchanged: the accent rule, the Escape
    /// handler, and collapsing an open card when attention moves here (D206).
    @State private var noteFocused = false

    /// DAYS (D254, D255). While true THE DAY column is the running list of
    /// days, grouped by week, and the note column shows whatever the list has
    /// picked — a day's note or a week's. Off, nothing about this screen is
    /// different from before the list existed; that was the design's first
    /// requirement ("today (the concept)" stays a day).
    @State private var daysMode = false
    @State private var daysPick: MacDaysPick? = nil
    /// The editor's command channel. The day note has no toolbar, but
    /// `MacTextEditor` requires one, and an unused instance is cheaper than a
    /// second initialiser on a shared component.
    @State private var noteActions = MacEditorActions()
    /// The task being dragged. Set when the drag STARTS, which is why the rows
    /// use `.onDrag` rather than `.draggable`: the newer modifier has no
    /// start callback, and without knowing what is in flight a row cannot say
    /// "make room for it".
    @State private var draggingID: String? = nil
    /// The row list's width, so the drag preview can be the same width as the
    /// row it came from. David: "the width of the row should not change as it
    /// moves and it currently shrinks in width."
    @State private var rowWidth: CGFloat = 0
    /// Bumped after a reorder. `tasksForDay` reads `UserDefaults`, which
    /// SwiftUI does not observe, so without this the list would not redraw
    /// until something else happened to invalidate it.
    ///
    /// **Mutating it is the whole mechanism** — no `.id()` on the view. The
    /// first version added one, which would have rebuilt the entire Today
    /// screen on every drag and taken the day note editor's focus and caret
    /// with it. Any `@State` write already invalidates the body, and
    /// `tasksForDay` re-reads the stored order when the body runs. The counter
    /// exists to be written, not to be read.
    @State private var reorderToken = 0
    /// The + opens the composer (D200). The inline "Add a to-do" row stays
    /// exactly as it was: that one is the contextual add, this one is the
    /// considered one.


    /// The store is an `@Observable` singleton; reading its properties inside
    /// `body` is what registers the dependency, so a plain computed accessor is
    /// enough and there is no second source of truth to keep in step.
    private var store: ReminderTaskStore { ReminderTaskStore.shared }

    private let cal = Calendar.current

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if daysMode { daysColumn } else { dayColumn }
            }
            .frame(width: MacEditorialLayout.dayColumnWidth)
            Rectangle()
                .fill(MacEditorialColor.hairline)
                .frame(width: 1)
            noteColumn
                .frame(maxWidth: .infinity)
        }
        .background(MacEditorialColor.paper)
        .task(id: dayKey) { await load() }
        .task { endeavorNames = Set(EndeavorFile.nameIndex(from: NoteStore.shared).keys) }
        // Any change of day — a day word, the month grid, the arrow keys —
        // is an answer to "which day", and the list was only a way of asking.
        .onChange(of: date) { _, _ in daysMode = false }
        .task(id: deepLinkDaysPick?.wrappedValue) {
            guard let pick = deepLinkDaysPick?.wrappedValue else { return }
            daysPick = pick
            daysMode = true
            deepLinkDaysPick?.wrappedValue = nil
        }
    }

    // MARK: - Keys and formatting

    private var dayKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private var isToday: Bool { cal.isDateInToday(date) }

    private var mastheadKicker: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f.string(from: date)
    }

    private var mastheadNumeral: String {
        String(cal.component(.day, from: date))
    }

    private var mastheadWeekday: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    // `clockString` and `durationString` retired with `meetingRow`, Session 80
    // — both were only ever its helpers, and they now live inside
    // `MacMeetingRow` where the one thing that formats a meeting also draws it.

    // MARK: - Data

    private var timedEvents: [NextCalendarEvent] {
        events.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
    }

    private var allDayEvents: [NextCalendarEvent] {
        events.filter { $0.isAllDay }
    }

    /// Today reads the store's `tasks` (due today or overdue); any other day
    /// filters `upcomingTasks` to that day. Same rule as `DayflowTodaySection`,
    /// so a task is on the same day in both apps.
    private var tasksForDay: [ThingsTask] {
        let base: [ThingsTask]
        if isToday {
            base = store.tasks
        } else {
            base = store.upcomingTasks.filter { task in
                guard let due = task.date else { return false }
                return cal.isDate(due, inSameDayAs: date)
            }
        }
        // The hand-arranged order, if there is one for this day. `apply` takes
        // the store's list and rearranges it rather than replacing it, so a
        // task completed or deleted elsewhere simply stops appearing — see the
        // note in MacTaskOrder for why that direction matters.
        return MacTaskOrder.apply(base, dayKey: dayKey)
    }

    /// The start of the next meeting on one of HIS calendars after this one
    /// ends — what the row's parenthetical measures (D194).
    ///
    /// Foreign meetings are skipped on both sides: his wife's breakfast sits
    /// inside his morning without taking any of it, so counting it would report
    /// free time he actually has as time he does not.
    private func nextOwnStart(after event: NextCalendarEvent) -> Date? {
        let choices = MacCalendarChoices.shared
        return timedEvents
            .filter { !choices.isForeign($0.calendarIdentifier) }
            .first { $0.startDate >= event.endDate }?
            .startDate
    }

    private func load() async {
        clearMovedOffer()
        // Picking a day is the end of picking a day: the grid folds itself away
        // rather than sitting open over the day it just chose.
        if monthUnfolded { withAnimation(.easeInOut(duration: 0.2)) { monthUnfolded = false } }
        await MacCalendarChoices.shared.load()
        events = await CalendarService.shared.fetchDayEvents(for: date)
        await store.refreshAll()
    }

    // MARK: - THE DAY column

    private var dayColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Yesterday / today / tomorrow are most of where a task
                // actually goes, and they are already on screen — no calendar
                // to open first (D231).
                dayNav
                MacEditorialMasthead(kicker: mastheadKicker,
                                     numeral: mastheadNumeral,
                                     weekday: mastheadWeekday,
                                     onTapSubject: {
                                         withAnimation(.easeInOut(duration: 0.2)) {
                                             monthUnfolded.toggle()
                                         }
                                     },
                                     unfolded: monthUnfolded,
                                     // Resting a dragged task on the title
                                     // opens the grid under it. Unfold only —
                                     // never fold — because a grid that closed
                                     // while you were aiming at it would be
                                     // the worst possible answer to a hover.
                                     onDragOverSubject: {
                                         guard !monthUnfolded else { return }
                                         withAnimation(.easeInOut(duration: 0.2)) {
                                             monthUnfolded = true
                                         }
                                     })
                if monthUnfolded {
                    MacEditorialMonthGrid(selected: $date,
                                          onDropTask: { id, day in
                                              moveTask(id, to: day)
                                              return true
                                          })
                        .padding(.top, 12)
                        .transition(.opacity)
                }
                allDayRows
                todoSection
                if !timedEvents.isEmpty { daySection }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, MacEditorialLayout.margin)
            .padding(.top, MacEditorialLayout.topMargin)
        }
    }

    /// One nav for both modes, so the four words never differ between them.
    private var dayNav: some View {
        MacEditorialDayNav(date: $date,
                           onDropTask: { id, day in
                               moveTask(id, to: day)
                               return true
                           },
                           onDays: { daysMode = true },
                           daysActive: daysMode,
                           onPickDay: { daysMode = false })
    }

    // MARK: - DAYS column (D254)

    /// The running list in the day column's place. The nav stays at the top
    /// exactly where the day mode draws it, so pressing DAYS moves nothing
    /// above the masthead; the masthead, search and rows are the list's own.
    private var daysColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            dayNav
                .padding(.horizontal, MacEditorialLayout.margin)
                .padding(.top, MacEditorialLayout.topMargin)
            MacDaysList(pick: $daysPick,
                        onOpenDay: { day in
                            date = day          // `onChange(of: date)` leaves the list
                            daysMode = false    // and this covers "double-click today"
                        })
        }
    }

    /// What the note column shows: the day, or whatever the list picked.
    private var noteRelativePath: String {
        daysMode ? (daysPick?.relativePath ?? notePath) : notePath
    }
    private var noteHeading: String {
        daysMode ? (daysPick?.heading ?? "Day note") : "Day note"
    }

    @ViewBuilder
    private var allDayRows: some View {
        if !allDayEvents.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(allDayEvents) { event in
                    HStack(spacing: 8) {
                        Text(event.title)
                            .editorialQuietLabel()
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                }
            }
            .padding(.top, 10)
        }
    }

    // MARK: TO DO

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialSectionLabel(text: "To do", trailing: remainLabel)
                // One measurement for the whole list, taken from the section
                // rather than per row: every row is the same width, and reading
                // it once avoids a GeometryReader behind each one.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { rowWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in rowWidth = w }
                    }
                )
            if tasksForDay.isEmpty {
                emptyTodo
            } else {
                ForEach(tasksForDay) { task in
                    // **The dragged row becomes a gap.** David: "as i drag the
                    // drag row and the destination row overlap their text until
                    // i let go... The way things does it is that the two rows
                    // can never ocupy the same space."
                    //
                    // Exactly right, and the cause was that the row stayed in
                    // the list while its preview floated over it — so the thing
                    // under the cursor was always a row, and the preview always
                    // sat on top of some text. Leaving a slot instead means the
                    // space under the preview is empty by construction, and the
                    // two can never overlap because only one of them is ever
                    // drawn.
                    //
                    // Same height as a row, so nothing jumps when the swap
                    // happens; a whisper of accent so the slot reads as "here"
                    // rather than as a rendering glitch.
                    if draggingID == task.id {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(MacEditorialColor.accent.opacity(0.06))
                            .frame(height: 42)
                    } else {
                    // `isToday` last, matching its declaration order in
                    // MacTaskRow: a memberwise init takes its arguments in the
                    // order the properties are written, not in reading order.
                    MacTaskRow(task: task,
                               isOpen: openTaskID == task.id,
                               onToggle: { toggle(task) },
                               onChanged: { refresh() },
                               onMoved: { day in noteMove(to: day) },
                               isToday: isToday,
                               endeavorNames: endeavorNames)
                        // **`.onDrag`, not `.draggable`**, for one reason: it
                        // fires when the drag BEGINS. `.draggable` does not,
                        // and a row cannot slide out of the way for something
                        // it does not know is coming.
                        .onDrag {
                            draggingID = task.id
                            return NSItemProvider(object: task.id as NSString)
                        } preview: {
                            dragPreview(task)
                        }
                        // **The reorder happens on HOVER, not on drop.** David:
                        // "as the row moves down the row that it is moving to
                        // slides up or down visually so you can see it as the
                        // two rows are swapping places."
                        //
                        // So the list really does reorder as the cursor passes,
                        // and the animation is SwiftUI moving the rows it is
                        // already drawing. A drop-only version cannot show that
                        // — there is nothing to animate until the gesture is
                        // over, which is one moment too late to be feedback.
                        //
                        // Writing through on every hover rather than holding a
                        // temporary order also means an abandoned drag leaves
                        // the list where you last saw it, with no shadow state
                        // that can outlive the gesture and freeze the order.
                        .dropDestination(for: String.self) { _, _ in
                            endDrag()
                            return true
                        } isTargeted: { over in
                            guard over, let dragged = draggingID,
                                  dragged != task.id else { return }
                            // Slower than a normal transition on purpose.
                            // David: the replaced row "just jumps into the new
                            // row in a slower way so it looks like it is moving
                            // there." At 0.16s it reads as a jump; the point of
                            // the animation is that you SEE the swap happen.
                            withAnimation(.easeInOut(duration: 0.22)) {
                                MacTaskOrder.move(dragged, toward: task.id,
                                                  in: tasksForDay, dayKey: dayKey)
                                reorderToken += 1
                            }
                        }
                    }
                    MacEditorialRule.hair
                }
            }
            addRow
            movedOffer
        }
        .padding(.top, 16)
        // **The gap has to close even when the drop misses.** A row released
        // over the day note, the sidebar or the masthead never reaches a row's
        // own `dropDestination`, and without this the source row would stay
        // blank until the next drag started.
        //
        // Returns false — it accepts nothing and reorders nothing. It exists
        // only to notice that the gesture ended somewhere in this column.
        .dropDestination(for: String.self) { _, _ in
            endDrag()
            // **True, not false.** A rejected drop makes AppKit animate the
            // drag image back to where it started, which is a second copy of
            // the row flying across the screen for no reason — the gesture
            // ended where he let go, and snapping back says otherwise. It still
            // accepts nothing and reorders nothing; the reorder already
            // happened on hover.
            return true
        }
    }

    /// One quiet line, four seconds, after a task is moved off this day.
    ///
    /// David, Session 80: "do you think there is an option that could be shown
    /// briefly to ask if i want to move to that day that we moved the task to?
    /// this would have to be subtle to work." So: no capsule, no toast, no
    /// dimming — a caps line where the task used to be, with the day in accent
    /// because the accent means acting. Ignoring it is free and it removes
    /// itself. Nothing about the move is undone by letting it go.
    @ViewBuilder
    private var movedOffer: some View {
        if let day = movedTo {
            let f = DateFormatter()
            let label: String = { f.dateFormat = "EEEE, MMM d"; return f.string(from: day) }()
            HStack(spacing: 8) {
                Text("Moved to \(label)")
                    .editorialQuietLabel()
                Button {
                    date = cal.startOfDay(for: day)
                    clearMovedOffer()
                } label: {
                    Text("Go there")
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(MacEditorialColor.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .transition(.opacity)
        }
    }

    /// Re-dates a task by id — the drop half of D231.
    ///
    /// Same shape as Upcoming's `move(taskID:to:)`, including the guard that a
    /// drop onto the day a task is ALREADY on writes nothing: dragging within
    /// the screen you are standing on is the easiest accidental gesture here,
    /// and a no-op write would still fire `onMoved` and offer to send you
    /// somewhere you already are.
    private func moveTask(_ taskID: String, to day: Date) {
        guard let task = store.allTasks.first(where: { $0.id == taskID }) else { return }
        let target = cal.startOfDay(for: day)
        guard task.date.map({ !cal.isDate($0, inSameDayAs: target) }) ?? true else { return }
        endDrag()
        Task {
            _ = await store.update(taskID: task.id,
                                   title: task.title,
                                   date: target,
                                   clearDate: false,
                                   list: task.list,
                                   notes: task.notes)
            await store.refreshAll()
            noteMove(to: target)
        }
    }

    private func noteMove(to day: Date) {
        guard !cal.isDate(day, inSameDayAs: date) else { return }
        movedClearTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) { movedTo = day }
        movedClearTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) { movedTo = nil }
        }
    }

    private func clearMovedOffer() {
        movedClearTask?.cancel()
        movedTo = nil
    }

    private var remainLabel: String? {
        let count: Int = tasksForDay.count
        guard count > 0 else { return nil }
        return "\(count) remain"
    }

    private var emptyTodo: some View {
        Text(isToday ? "Nothing for today yet." : "Nothing here yet.")
            .font(MacEditorialType.note)
            .foregroundStyle(MacEditorialColor.muted)
            .padding(.vertical, 10)
    }

    // `taskRow` retired, Session 80. A task row is now `MacTaskRow`
    // (TraceMacTaskCard.swift) so that Today, Upcoming and Tasks all draw the
    // same row and open the same card (D190). This screen's copy would have
    // been the one that drifted.

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(addFieldFocused ? MacEditorialColor.accent
                                                     : MacEditorialColor.faint)
                    .frame(width: 18)
                TextField("Add a to-do", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .font(MacEditorialType.taskTitle)
                    .focused($addFieldFocused)
                    .onSubmit { submitNewTask() }
                Spacer(minLength: 0)
            }
            .frame(height: 38)
            // **A rule, because the glyph alone was not enough.**
            //
            // The first version tinted only the 11pt `+`. That is a weaker
            // signal than the day note's full-width rule, and it sits where
            // nobody is looking: your eye is on the words you are typing, not
            // on a small mark to their left. The day note works because a wide
            // line changing colour is visible in peripheral vision.
            //
            // Same vocabulary, then — accent underline while this row holds the
            // keyboard, nothing when it does not. The `+` keeps its tint too;
            // two quiet signals in the same place cost nothing and the row is
            // read from either end.
            Group {
                if addFieldFocused { MacEditorialRule.accent } else { Color.clear.frame(height: 1) }
            }
        }
        // Same treatment as the day note, and for the same reason (D206).
        // David: "when i click in the add a to-do it stops working" — the day
        // nav standing down for a focused text field is correct, and silent, so
        // this row says when it holds the keyboard and Escape hands it back.
        //
        // **Deliberately NOT letting up/down escape this field.** It is single
        // line, so up and down have nothing to do here and could in principle
        // navigate — but pressing down out of habit while half-typing a to-do
        // would throw you onto another screen mid-thought. Escape is the one
        // way out of a text field on this platform; one idiom beats two.
        .background {
            if addFieldFocused {
                Color.clear.escapeCloses(includingTextFields: true) {
                    addFieldFocused = false
                }
            }
        }
    }

    /// One card open at a time: opening a second closes the first, and no row
    /// needs to know another exists.
    /// Opening a card takes focus off the day note.
    ///
    /// Correct on its own terms — your attention just moved — and load-bearing
    /// for the collapse above: `onChange(of: noteFocused)` only fires on a
    /// CHANGE, so a note that still held focus from before would give the next
    /// click over there nothing to report.
    /// Ends a drag, a beat after the drop.
    ///
    /// **The delay is the fix for the double image.** David: "when I release
    /// the row the wording of the row seems to be double exposed... slightly
    /// offset for a fraction of a second before it settles."
    ///
    /// Clearing `draggingID` immediately puts the real row back the instant the
    /// drop is accepted — while AppKit is still removing the drag image it was
    /// carrying. For those few frames the same words are drawn twice, a few
    /// points apart, which is exactly what he described.
    ///
    /// Nothing observable says "the drag image is gone", so this waits out the
    /// removal and then swaps the slot for the row. The fade makes the swap
    /// look deliberate rather than late, and it is short enough that the gap
    /// never reads as lag.
    ///
    /// 0.14s is tuned by eye against AppKit's own removal, not derived from
    /// anything — if it ever looks wrong on a slower machine this is the number
    /// to move.
    private func endDrag() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.easeOut(duration: 0.12)) { draggingID = nil }
        }
    }

    private func toggle(_ task: ThingsTask) {
        // Any click on a row also clears a stranded drag. Belt and braces for
        // the one case the catch-all above cannot see: a release outside the
        // window entirely, which this app never hears about.
        draggingID = nil
        releaseNote()
        openEventID = nil
        openTaskID = (openTaskID == task.id) ? nil : task.id
    }

    private func toggle(_ event: NextCalendarEvent) {
        releaseNote()
        openTaskID = nil
        openEventID = (openEventID == event.id) ? nil : event.id
    }

    private func collapseCards() {
        openTaskID = nil
        openEventID = nil
    }

    private func refresh() {
        Task { await store.refreshAll() }
    }

    private func submitNewTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newTaskTitle = ""
        let day: Date = date
        Task {
            _ = await store.addTask(title: title, date: day)
            await store.refreshAll()
        }
    }

    // MARK: THE DAY

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialSectionLabel(text: "The day")
            track
            trackTicks
            ForEach(timedEvents) { event in
                MacMeetingRow(event: event,
                              isOpen: openEventID == event.id,
                              onToggle: { toggle(event) },
                              onOpenPlace: onOpenPlace,
                              nextOwnStart: nextOwnStart(after: event),
                              onOpenNote: onOpenNote,
                              agendaOpenTaskID: openTaskID,
                              onToggleAgendaTask: { toggle($0) },
                              onAgendaChanged: { refresh() })
            }
        }
        .padding(.top, 14)
    }

    /// The track spans a fixed 7am to 8pm, as on the phone. An event outside
    /// that window is clamped rather than dropped — a 6am flight should still
    /// show a mark at the left edge, and a track whose span moved with the day
    /// would make two days impossible to compare at a glance.
    private static let trackStartHour: Double = 7
    private static let trackEndHour: Double = 20

    private func fraction(for d: Date) -> Double {
        let hour = Double(cal.component(.hour, from: d))
        let minute = Double(cal.component(.minute, from: d))
        let raw = hour + minute / 60
        let span = Self.trackEndHour - Self.trackStartHour
        let clamped = min(max(raw, Self.trackStartHour), Self.trackEndHour)
        return (clamped - Self.trackStartHour) / span
    }

    private var track: some View {
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(MacEditorialColor.hairline)
                ForEach(timedEvents) { event in
                    trackBlock(event, width: width)
                }
            }
        }
        .frame(height: 7)
    }

    private func trackBlock(_ event: NextCalendarEvent, width: CGFloat) -> some View {
        let start: Double = fraction(for: event.startDate)
        let end: Double = fraction(for: event.endDate)
        let verdict = DayflowMeetingColor.classify(event.title, organizer: event.organizerName)
        let pastel: Color? = DayflowMeetingColor.tintTrackBlocks ? verdict.block : nil
        let fill: Color = pastel ?? MacEditorialColor.noteText
        let w: CGFloat = max(2, CGFloat(end - start) * width)
        let x: CGFloat = CGFloat(start) * width
        // D193 amended, Session 80. The first cut drew a foreign block at HALF
        // height. David killed it, correctly: weight is a RELATIVE signal, and
        // on a day whose events are all his wife's there is nothing on screen
        // to compare a short block against. Colour is absolute — it says the
        // same thing on a day with one event as on a day with nine.
        let foreign: Bool = MacCalendarChoices.shared.isForeign(event.calendarIdentifier)
        let paint: Color = foreign ? MacEditorialColor.foreignEvent : fill
        return Rectangle()
            .fill(paint)
            .frame(width: w, height: 7)
            .offset(x: x)
    }

    private var trackTicks: some View {
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            ZStack(alignment: .leading) {
                ForEach([7, 9, 11, 13, 15, 17], id: \.self) { hour in
                    tick(hour, width: width)
                }
            }
        }
        .frame(height: 15)
        .padding(.top, 3)
    }

    private func tick(_ hour: Int, width: CGFloat) -> some View {
        let span: Double = Self.trackEndHour - Self.trackStartHour
        let x: CGFloat = CGFloat((Double(hour) - Self.trackStartHour) / span) * width
        let label: String = hour > 12 ? String(hour - 12) : String(hour)
        return Text(label)
            .font(.system(size: 8.5).monospacedDigit())
            .foregroundStyle(MacEditorialColor.faint)
            .offset(x: x)
    }

    // `meetingRow` retired, Session 80 — it is `MacMeetingRow`
    // (TraceMacMeetingCard.swift) now, so Today and Upcoming draw the same
    // meeting and open the same card. Same move as `taskRow` before it.

    // `meetingChip(_:hollow:)` retired the same session it was written.
    // The hollow-versus-filled distinction never landed at 8pt, and its track
    // counterpart was worse — see `trackBlock`. A foreign event is now simply
    // painted `MacEditorialColor.foreignEvent`, chip and block alike.

    // MARK: - DAY NOTE column

    private var noteColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **The shared note view, not the bare editor** (D258, Session 83).
            //
            // Session 80 put `MacTextEditor` here directly and gave it its own
            // heading, floating bar and ⓘ box. That left this column with no
            // `[[` suggestions (the callback was never wired), a toolbar that
            // differed from the one project notes drew over the same editor,
            // and — found in testing the first fix — heading controls no other
            // note had. All of it is `TraceMacNoteEditor`'s job now: it loads
            // and saves the file, draws the heading with its `B I U` and ⓘ,
            // the accent rule, the floating bar and the suggestion pills, and
            // reports focus back up (this screen still needs the fact, for
            // the card collapse and Escape below). `relativePath` follows the
            // day, so a day switch is a reload inside the editor.
            //
            // `noteActions` is still passed in so this screen keeps a command
            // channel to the live editor (`externalActions`); nothing uses it
            // today, and it costs nothing to keep the seam.
            TraceMacNoteEditor(relativePath: noteRelativePath,
                               heading: noteHeading,
                               headingInset: 0,
                               showMoveButton: true,
                               externalActions: noteActions,
                               onFocusChange: { focused in noteFocused = focused })
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, MacEditorialLayout.margin)
        .padding(.top, MacEditorialLayout.topMargin)
        .contentShape(Rectangle())
        // Covers the label and the empty space below the editor. It does NOT
        // cover the editor itself: `TextEditor` is an `NSTextView`, AppKit
        // consumes the click outright, and there is no SwiftUI gesture there
        // for `simultaneousGesture` to run alongside. That is why the first
        // attempt at this did nothing — same family as the arrow keys and
        // Escape, where AppKit had the event and SwiftUI never saw it.
        .simultaneousGesture(TapGesture().onEnded { collapseCards() })
        // **Focus is the signal that survives AppKit.** Whatever the click did
        // on its way through, landing in the editor makes it first responder,
        // and SwiftUI reports that faithfully. So the collapse hangs off the
        // fact rather than off the gesture.
        //
        // David: "if i click outside of the expanded task (like in the day note
        // pane) it should collapse the task that was expanded." The general
        // shape: a card is open because your attention is on it, and moving
        // your attention to the other half of the screen answers the question
        // the card was asking.
        .onChange(of: noteFocused) { _, focused in
            if focused { collapseCards() }
        }
        // **Escape hands the keyboard back.** The standard way out of a text
        // field on this platform, and the counterpart to the accent rule above:
        // one says where the keyboard went, the other takes it back.
        //
        // The monitor exists only while the note is focused, which is the rule
        // `escapeCloses` was written for — apply it to the thing whose lifetime
        // IS the scope. It cannot collide with the open card's Escape, because
        // the two states are mutually exclusive by construction: focusing the
        // note collapses the cards (just above), and opening a card releases
        // the note (`toggle(_:)`).
        .background {
            if noteFocused {
                Color.clear.escapeCloses(includingTextFields: true) { releaseNote() }
            }
        }
    }

    /// What travels with the cursor on a reorder — the same shaded row shape
    /// the Upcoming spread uses, so one gesture looks like itself on both
    /// screens.
    /// What travels with the cursor.
    ///
    /// **The same width as the row it left**, which is the whole of David's
    /// complaint about the first version: a preview that sizes to its own
    /// content shrinks to the length of the title, and a row that changes shape
    /// the instant you pick it up does not read as the row any more.
    ///
    /// `rowWidth` is measured once off the section heading rather than per row,
    /// and falls back to sizing naturally if the measurement has not landed yet
    /// — a preview one frame too narrow beats a preview zero points wide.
    private func dragPreview(_ task: ThingsTask) -> some View {
        // **Geometry copied from `MacTaskRow.collapsed`, character for
        // character.** David: on release the words "move from upper right
        // diagonally to lower left slightly."
        //
        // That is the preview's text and the row's text not being in the same
        // place. The first version inset its content by 8pt and drew a bare
        // 18pt circle, while the row has no inset and a circle that occupies 22
        // (18 plus `.padding(2)`) — so the title sat 12pt right of where the
        // real one lands, and the eye reads the correction as a slide.
        //
        // The rule this is an instance of: **a drag preview is a promise about
        // where the thing will be.** Any difference between it and the real row
        // is paid back as movement at the moment of the drop, which is the one
        // moment the gesture should look settled.
        //
        // So: spacing 12, a circle padded to 22, no horizontal inset, height
        // 42. The wash and border go OUTSIDE the frame, where they colour the
        // row without moving anything inside it.
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(MacEditorialColor.faint, lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .padding(2)
            Text(task.title)
                .font(MacEditorialType.taskTitle)
                .foregroundStyle(MacEditorialColor.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .frame(width: rowWidth > 0 ? rowWidth : nil, height: 42)
        .background(MacEditorialColor.accent.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(MacEditorialColor.accent.opacity(0.40), lineWidth: 1)
        }
    }

    /// Hands the keyboard back from the day note.
    ///
    /// **Setting the flag is no longer enough.** With `@FocusState`, writing
    /// `false` moved the focus. With an `NSTextView` the flag is a REPORT of
    /// AppKit's state, not a lever on it — so this resigns first responder and
    /// lets `onFocusChange` set the flag on the way back.
    ///
    /// Writing the flag directly would have left the caret blinking in a note
    /// the app believed was unfocused, with the arrow keys still dead and the
    /// rule back to ink saying otherwise. That is the worst version of this
    /// bug: the indicator lying about the thing it exists to report.
    private func releaseNote() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var notePath: String { "Calendar/\(dayKey).md" }

}
