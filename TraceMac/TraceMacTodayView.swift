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
    @FocusState private var addFieldFocused: Bool

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
        .overlay(alignment: .bottomTrailing) {
            MacEditorialPlus { addFieldFocused = true }
        }
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

    private func clockString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    private func durationString(_ event: NextCalendarEvent) -> String? {
        let minutes = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "(\(minutes)m)" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "(\(hours)h)" }
        return "(\(hours)h \(rest)m)"
    }

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

    private func load() async {
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
                                     weekday: mastheadWeekday)
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
                    taskRow(task)
                    MacEditorialRule.hair
                }
            }
            addRow
        }
        .padding(.top, 16)
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

    private func taskRow(_ task: ThingsTask) -> some View {
        let listName: String? = task.list
        let alarm: String? = task.alarmTimeString
        return HStack(spacing: 12) {
            Button {
                Task { await store.complete(taskID: task.id) }
            } label: {
                Circle()
                    .strokeBorder(MacEditorialColor.faint, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)

            Text(task.title)
                .font(MacEditorialType.taskTitle)
                .foregroundStyle(MacEditorialColor.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            if task.repeats {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacEditorialColor.faint)
            }
            if let alarm {
                Text(alarm)
                    .font(MacEditorialType.time)
                    .foregroundStyle(MacEditorialColor.faint)
            }
            if let listName {
                Text(listName).editorialListLabel()
            }
        }
        .frame(height: 42)
    }

    private var addRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MacEditorialColor.faint)
                .frame(width: 18)
            TextField("Add a to-do", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .font(MacEditorialType.taskTitle)
                .focused($addFieldFocused)
                .onSubmit { submitNewTask() }
            Spacer(minLength: 0)
        }
        .frame(height: 38)
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
                meetingRow(event)
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
        return Rectangle()
            .fill(fill)
            .frame(width: w)
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

    private func meetingRow(_ event: NextCalendarEvent) -> some View {
        let verdict = DayflowMeetingColor.classify(event.title, organizer: event.organizerName)
        let chip: Color = verdict.chip ?? MacEditorialColor.faint
        let duration: String? = durationString(event)
        return HStack(spacing: 10) {
            Text(clockString(event.startDate))
                .font(MacEditorialType.time)
                .foregroundStyle(MacEditorialColor.muted)
                .frame(width: 66, alignment: .leading)
            Rectangle()
                .fill(chip)
                .frame(width: 8, height: 8)
            Text(event.title)
                .font(MacEditorialType.rowTitle)
                .foregroundStyle(MacEditorialColor.ink)
                .lineLimit(1)
            if let duration {
                Text(duration)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.faint)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
    }

    // MARK: - DAY NOTE column

    private var noteColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialSectionLabel(text: "Day note")
            MacEditorialRule.ink
            TextEditor(text: $noteText)
                .font(MacEditorialType.note)
                .foregroundStyle(MacEditorialColor.noteText)
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .background(MacEditorialColor.paper)
                .padding(.top, 12)
                .padding(.leading, -5)   // TextEditor's own inset, removed
                .onChange(of: noteText) { _, _ in scheduleSave() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MacEditorialLayout.margin)
        .padding(.top, MacEditorialLayout.topMargin)
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
