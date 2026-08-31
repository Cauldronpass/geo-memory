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
//   * AGENDA lines under meetings (D171-D176). `DayflowAgendaMatch` lives
//     inside the 1,400-line iOS `DayflowTodaySection.swift` and calls
//     `DayflowMeetingActions.noteStem`, whose enum also carries Dayflow-only
//     routing. Extracting it is a real refactor of a shared file and was not
//     smuggled into this one.
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

    /// Owned by `TraceMacContentView` so the arrow-key monitor can move it and
    /// so the day survives leaving the section and coming back.
    @Binding var date: Date
    @State private var events: [NextCalendarEvent] = []
    @State private var noteText: String = ""
    @State private var noteLoadedKey: String = ""
    @State private var saveTask: Task<Void, Never>? = nil
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
    /// Focus on the day note is what actually tells us the click landed over
    /// there. See `noteColumn`.
    @FocusState private var noteFocused: Bool
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
            dayColumn
                .frame(width: MacEditorialLayout.dayColumnWidth)
            Rectangle()
                .fill(MacEditorialColor.hairline)
                .frame(width: 1)
            noteColumn
                .frame(maxWidth: .infinity)
        }
        .background(MacEditorialColor.paper)
        .task(id: dayKey) { await load() }
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
        if isToday { return store.tasks }
        return store.upcomingTasks.filter { task in
            guard let due = task.date else { return false }
            return cal.isDate(due, inSameDayAs: date)
        }
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
        loadNote()
    }

    // MARK: - THE DAY column

    private var dayColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MacEditorialDayNav(date: $date)
                MacEditorialMasthead(kicker: mastheadKicker,
                                     numeral: mastheadNumeral,
                                     weekday: mastheadWeekday,
                                     onTapSubject: {
                                         withAnimation(.easeInOut(duration: 0.2)) {
                                             monthUnfolded.toggle()
                                         }
                                     },
                                     unfolded: monthUnfolded)
                if monthUnfolded {
                    MacEditorialMonthGrid(selected: $date)
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
            if tasksForDay.isEmpty {
                emptyTodo
            } else {
                ForEach(tasksForDay) { task in
                    // `isToday` last, matching its declaration order in
                    // MacTaskRow: a memberwise init takes its arguments in the
                    // order the properties are written, not in reading order.
                    MacTaskRow(task: task,
                               isOpen: openTaskID == task.id,
                               onToggle: { toggle(task) },
                               onChanged: { refresh() },
                               onMoved: { day in noteMove(to: day) },
                               isToday: isToday)
                    MacEditorialRule.hair
                }
            }
            addRow
            movedOffer
        }
        .padding(.top, 16)
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
    private func toggle(_ task: ThingsTask) {
        noteFocused = false
        openEventID = nil
        openTaskID = (openTaskID == task.id) ? nil : task.id
    }

    private func toggle(_ event: NextCalendarEvent) {
        noteFocused = false
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
                              nextOwnStart: nextOwnStart(after: event))
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
            MacEditorialSectionLabel(text: "Day note")
            // **The rule goes accent while the note has the keyboard.**
            //
            // David: "the issue was that i was in the Day Note section of the
            // Today screen and from there the arrows did not work." The
            // behaviour is correct — arrows must move the caret while you are
            // typing, and `MacEditorialArrowKeys` stands down for exactly that
            // reason — but it happened SILENTLY. This pane is large, pale and
            // often empty, so a caret sitting in it is invisible, and four keys
            // stopped working with nothing on screen to explain why.
            //
            // Accent already means "active, or acting" everywhere in this app,
            // so one rule changing colour is the whole fix: the day nav is not
            // broken, it is somewhere else, and now you can see where.
            Group {
                if noteFocused { MacEditorialRule.accent } else { MacEditorialRule.ink }
            }
            TextEditor(text: $noteText)
                .font(MacEditorialType.note)
                .foregroundStyle(MacEditorialColor.noteText)
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .background(MacEditorialColor.paper)
                .padding(.top, 12)
                .padding(.leading, -5)   // TextEditor's own inset, removed
                .focused($noteFocused)
                .onChange(of: noteText) { _, _ in scheduleSave() }
            Spacer(minLength: 0)
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
                Color.clear.escapeCloses(includingTextFields: true) {
                    noteFocused = false
                }
            }
        }
    }

    private var notePath: String { "Calendar/\(dayKey).md" }

    private func loadNote() {
        let key = dayKey
        let text = (try? noteStore.readFile(notePath)) ?? ""
        noteText = text
        noteLoadedKey = key
    }

    /// Debounced save. The guard on `noteLoadedKey` is what stops the day
    /// switching from writing the OUTGOING day's text into the incoming day's
    /// file: `noteText` changes twice on a switch (cleared, then filled), and
    /// only the second one belongs to the day now on screen.
    private func scheduleSave() {
        guard noteLoadedKey == dayKey else { return }
        saveTask?.cancel()
        let path = notePath
        let body = noteText
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            try? noteStore.writeFile(path, content: body)
        }
    }
}
