//
//  DayflowTodaySection.swift
//  Dayflow
//
//  Steps (b) + the Editorial skin (Session 77, Dayflow-Tasks-Design.md and
//  the "Dayflow Skin" canvas, both locked 2026-08-28): the TO DO and THE DAY
//  sections of the Today sheet. Editorial reads as label + rule on paper —
//  no cards, hairline separators, serif task titles, one accent.
//
//  Behavior (unchanged from the structure round):
//  - Rows are 44pt: circle completes, anywhere else opens the edit sheet.
//  - Completion is staged: tap fills and strikes, the row holds ~2s (tap
//    again to undo, nothing written), then the EventKit write lands and the
//    row slides out. Last one gone: "That's the day."
//  - "Add for today" is an inline text field; return writes to Reminders.
//  - "n done ▾" expands the day's completed reminders; tap unticks.
//  - A task whose notes carry a satchel://, trace://, dayflow:// or
//    shortcuts:// link gets a source chip (bolt for shortcuts).
//
//  New with the skin (David's calls on the canvas, rounds 2-6):
//  - Gap time as a light parenthetical on the meeting title — "(30m)" is the
//    open time before the NEXT meeting (endDate → next startDate, hidden
//    under 5 minutes). No word "free", no extra rows. His reversal to the
//    simple row (no time range) is deliberate — do not re-add the range.
//  - Finished meetings fold: on today, meetings already over collapse into a
//    small italic "n earlier ▾" line so the day note comes back above the
//    fold by afternoon (the old agenda's past-meeting hiding, reborn).
//

import SwiftUI
import UIKit

struct DayflowTodaySection: View {
    let date: Date

    @State private var dayEvents: [NextCalendarEvent] = []
    @State private var completedToday: [ThingsTask] = []
    @State private var editingTask: ThingsTask? = nil
    @State private var selectedEvent: NextCalendarEvent? = nil
    @State private var completingIDs: Set<String> = []
    @State private var completionTimers: [String: Task<Void, Never>] = [:]
    @State private var showDone = false
    @State private var showEarlier = false
    @State private var addingTitle: String? = nil
    /// "Now" as of the last load — drives the earlier-meetings fold. Not a
    /// ticking clock; refreshed by load(), which reruns on date change and
    /// on every scene activation (ContentView refreshes the store then).
    @State private var nowTick = Date()
    @State private var selection = DayflowTodaySelection.shared
    @State private var whenRequest: DayflowWhenRequest? = nil
    /// Live rightward slide per row — the calendar glyph reveal.
    @State private var rowDragOffsets: [String: CGFloat] = [:]
    @FocusState private var addFieldFocused: Bool

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private var tasksForDay: [ThingsTask] {
        if isToday { return ReminderTaskStore.shared.tasks }
        let cal = Calendar.current
        return ReminderTaskStore.shared.upcomingTasks.filter { task in
            guard let d = task.date else { return false }
            return cal.isDate(d, inSameDayAs: date)
        }
    }

    private var doneCount: Int { completedToday.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            todoSection
            if !timedEvents.isEmpty { daySection }
        }
        .task(id: dayKey) { await load() }
        .onChange(of: dayKey) { _, _ in selection.exit() }
        .sheet(item: $whenRequest) { request in
            DayflowWhenSheet(tasks: request.tasks)
        }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await ReminderTaskStore.shared.refreshAll() }
            }
        }
        .sheet(item: $selectedEvent) { event in
            NavigationStack { DayflowEventDetailView(event: event) }
        }
    }

    private var dayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Editorial furniture

    private func sectionLabel(_ text: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Color.dayflowInk)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dayflowFaint)
            }
        }
        .padding(.bottom, 6)
    }

    private var hairline: some View {
        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
    }

    private var inkRule: some View {
        Rectangle().fill(Color.dayflowInk).frame(height: 1)
    }

    // MARK: - TO DO

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("TO DO", trailing: tasksForDay.isEmpty ? nil : "\(tasksForDay.count) remain")

            if tasksForDay.isEmpty {
                emptyState
            } else {
                ForEach(tasksForDay) { task in
                    taskRow(task)
                    hairline
                }
            }

            HStack(alignment: .center) {
                addRow
                Spacer()
                if doneCount > 0 { doneToggle }
            }

            if showDone && doneCount > 0 { doneList }
        }
    }

    private var emptyState: some View {
        Group {
            if doneCount > 0 {
                Text("That's the day.")
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowMuted)
            } else {
                Text(isToday ? "Nothing for today yet." : "Nothing here yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dayflowMuted)
            }
        }
        .padding(.vertical, 10)
    }

    private func taskRow(_ task: ThingsTask) -> some View {
        let completing = completingIDs.contains(task.id)
        let selected = selection.ids.contains(task.id)
        // Carried over from an earlier day (still open, dated before today).
        // David wants to KNOW it followed him, not from when — a small
        // u-turn arrow beside the title, never a date, never a yield sign
        // (a warning glyph would make the card scold). 2026-08-28.
        let carried = isToday && (task.date.map {
            $0 < Calendar.current.startOfDay(for: Date())
        } ?? false)
        return HStack(alignment: .center, spacing: 14) {
            Button {
                // In select mode the left circle selects too — completing
                // from a half-entered multi-select is how accidents happen.
                if selection.isActive {
                    if selected { selection.ids.remove(task.id) }
                    else { selection.ids.insert(task.id) }
                } else {
                    toggleCompletion(task)
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.dayflowInk, lineWidth: 1.6)
                        .frame(width: 20, height: 20)
                    if completing {
                        Circle().fill(Color.dayflowInk).frame(width: 20, height: 20)
                            .transition(.scale)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dayflowPaper)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(completing ? "Undo complete" : "Complete")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(task.title)
                        .font(.system(size: 16, design: .serif))
                        .strikethrough(completing)
                        .foregroundStyle(completing ? Color.dayflowFaint : Color.dayflowInk)
                    if carried {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dayflowFaint)
                    }
                }
                if let source = sourceLink(for: task) {
                    Button {
                        UIApplication.shared.open(source.url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: source.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(source.label.uppercased())
                                .font(.system(size: 11))
                                .tracking(0.8)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.dayflowAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            if let alarm = task.alarmTimeString {
                HStack(spacing: 3) {
                    Image(systemName: "bell")
                        .font(.system(size: 9, weight: .semibold))
                    Text(alarm)
                        .font(.system(size: 11).monospacedDigit())
                }
                .foregroundStyle(Color.dayflowFaint)
            }
            if task.repeats {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dayflowFaint)
            }

            if selection.isActive {
                // Things puts the selection circles on the RIGHT; so do we.
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Color.dayflowAccent : Color.dayflowFaint,
                                      lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if selected {
                        Circle().fill(Color.dayflowAccent).frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dayflowPaper)
                    }
                }
            }
        }
        .frame(minHeight: 46)
        .padding(.horizontal, selection.isActive ? 6 : 0)
        .background(selected ? Color.dayflowAccent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.isActive {
                if selected { selection.ids.remove(task.id) }
                else { selection.ids.insert(task.id) }
            } else if !completing {
                editingTask = task
            }
        }
        // Swipe left = select mode (Things), swipe right = the When sheet —
        // and the row slides right revealing the calendar glyph behind it
        // (David: "The joy in swiping right is that there is a little yellow
        // calendar icon" — ours wears the accent). `.offset` is visual only,
        // so the `.background` applied AFTER it keeps the original layout
        // frame and the glyph stays put while the row slides. Dominance-
        // guarded so vertical scrolling stays untouched; inert while
        // selecting.
        .offset(x: rowDragOffsets[task.id] ?? 0)
        .background(alignment: .leading) {
            let progress = min(max((rowDragOffsets[task.id] ?? 0) / 60, 0), 1)
            if progress > 0 {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
                    .opacity(Double(progress))
                    .scaleEffect(0.7 + 0.3 * progress)
                    .padding(.leading, 2)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 28)
                .onChanged { value in
                    guard !selection.isActive, !completing else { return }
                    let h = value.translation.width
                    guard abs(h) > abs(value.translation.height) else { return }
                    // Rightward slides and reveals; leftward stays put (the
                    // select flip happens on release).
                    rowDragOffsets[task.id] = h > 0 ? min(h, 80) : 0
                }
                .onEnded { value in
                    let h = value.translation.width
                    withAnimation(.spring(duration: 0.3)) { rowDragOffsets[task.id] = 0 }
                    guard !selection.isActive, !completing else { return }
                    guard abs(h) > abs(value.translation.height) * 1.5,
                          abs(h) > 40 else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if h < 0 {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection.isActive = true
                            selection.ids = [task.id]
                        }
                    } else {
                        // A short hop before presenting: a sheet presented in
                        // the same instant the drag ends inherits the tail of
                        // that gesture as ITS drag — David saw the card track
                        // the pointer downward and dismiss itself. Letting
                        // the gesture fully settle first breaks the handoff.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            whenRequest = DayflowWhenRequest(tasks: [task])
                        }
                    }
                }
        )
        .opacity(completing ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.18), value: completing)
        .animation(.easeInOut(duration: 0.15), value: selection.isActive)
    }

    private var addRow: some View {
        HStack(spacing: 14) {
            Circle()
                .strokeBorder(Color.dayflowFaint,
                              style: StrokeStyle(lineWidth: 1.3, dash: [3, 2.5]))
                .frame(width: 20, height: 20)
            if addingTitle != nil {
                TextField(isToday ? "Add for today" : "Add for this day",
                          text: Binding(get: { addingTitle ?? "" },
                                        set: { addingTitle = $0 }))
                    .font(.system(size: 14))
                    .focused($addFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { commitAdd() }
            } else {
                Text(isToday ? "Add for today" : "Add for this day")
                    .font(.system(size: 13.5))
                    .italic()
                    .foregroundStyle(Color.dayflowFaint)
            }
        }
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            if addingTitle == nil { addingTitle = "" }
            addFieldFocused = true
        }
    }

    private var doneToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showDone.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("\(doneCount) done")
                Image(systemName: showDone ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.dayflowFaint)
        }
        .buttonStyle(.plain)
    }

    private var doneList: some View {
        ForEach(completedToday) { task in
            HStack(spacing: 14) {
                Button { untick(task) } label: {
                    ZStack {
                        Circle().fill(Color.dayflowFaint)
                            .frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dayflowPaper)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark not done")
                Text(task.title)
                    .font(.system(size: 15, design: .serif))
                    .strikethrough()
                    .foregroundStyle(Color.dayflowMuted)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 38)
        }
    }

    // MARK: - THE DAY

    private var timedEvents: [NextCalendarEvent] {
        dayEvents.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
    }

    /// Meetings already over — folded behind "n earlier ▾" on today only.
    private var earlierEvents: [NextCalendarEvent] {
        guard isToday else { return [] }
        return timedEvents.filter { $0.endDate <= nowTick }
    }

    private var remainingEvents: [NextCalendarEvent] {
        guard isToday else { return timedEvents }
        return timedEvents.filter { $0.endDate > nowTick }
    }

    /// Open time between this meeting's end and the next one's start, over
    /// the FULL day list (a folded meeting never changes the math). Hidden
    /// under 5 minutes; nothing after the last meeting.
    private func gapLabel(after event: NextCalendarEvent) -> String? {
        guard let idx = timedEvents.firstIndex(where: { $0.id == event.id }),
              idx + 1 < timedEvents.count else { return nil }
        let next = timedEvents[idx + 1]
        let mins = Int(next.startDate.timeIntervalSince(event.endDate) / 60)
        guard mins >= 5 else { return nil }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("THE DAY")
                .padding(.top, 16)
            inkRule
            VStack(alignment: .leading, spacing: 0) {
                if !earlierEvents.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showEarlier.toggle() }
                    } label: {
                        HStack(spacing: 12) {
                            Spacer().frame(width: 62)
                            Text("\(earlierEvents.count) earlier")
                                .font(.system(size: 11))
                                .italic()
                            Image(systemName: showEarlier ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showEarlier {
                        ForEach(earlierEvents) { event in
                            eventRow(event, faded: true)
                        }
                    }
                }
                ForEach(remainingEvents) { event in
                    eventRow(event, faded: false)
                }
            }
            .padding(.top, 6)
        }
    }

    private func eventRow(_ event: NextCalendarEvent, faded: Bool) -> some View {
        Button { selectedEvent = event } label: {
            HStack(spacing: 12) {
                Text(event.startTimeString)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.dayflowMuted)
                    .frame(width: 62, alignment: .leading)
                Rectangle()
                    .fill(event.color)
                    .frame(width: 8, height: 8)
                Text(event.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                if let gap = gapLabel(after: event) {
                    Text("(\(gap))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dayflowFaint)
                }
                Spacer(minLength: 0)
            }
            .opacity(faded ? 0.5 : 1)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func toggleCompletion(_ task: ThingsTask) {
        if completingIDs.contains(task.id) {
            completionTimers[task.id]?.cancel()
            completionTimers[task.id] = nil
            withAnimation { _ = completingIDs.remove(task.id) }
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { _ = completingIDs.insert(task.id) }
        completionTimers[task.id] = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await ReminderTaskStore.shared.complete(taskID: task.id)
            completedToday = await ReminderTaskStore.shared.fetchCompleted(on: date)
            _ = withAnimation(.easeInOut(duration: 0.25)) { completingIDs.remove(task.id) }
            completionTimers[task.id] = nil
        }
    }

    private func untick(_ task: ThingsTask) {
        Task {
            guard await ReminderTaskStore.shared.uncomplete(taskID: task.id) else { return }
            completedToday = await ReminderTaskStore.shared.fetchCompleted(on: date)
        }
    }

    private func commitAdd() {
        let title = (addingTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        addingTitle = nil
        addFieldFocused = false
        guard !title.isEmpty else { return }
        Task {
            _ = await ReminderTaskStore.shared.addTask(
                title: title,
                toToday: isToday,
                date: isToday ? nil : date)
        }
    }

    private func load() async {
        nowTick = Date()
        async let events = CalendarService.shared.fetchDayEvents(for: date)
        async let completed = ReminderTaskStore.shared.fetchCompleted(on: date)
        if isToday { await ReminderTaskStore.shared.fetch() }
        else { await ReminderTaskStore.shared.fetchUpcoming() }
        dayEvents = await events
        completedToday = await completed
    }

    // MARK: - Provenance

    /// First satchel://, trace://, dayflow:// or shortcuts:// link in the
    /// reminder's notes, plus a short label and an icon. The app links come
    /// from ReminderService and the Satchel/Trace hand-offs (label = the
    /// path's filename stem); shortcuts:// links are David's own — he keeps
    /// Shortcuts runners in task notes (Session 77) — labelled with the
    /// shortcut's name and a bolt.
    private func sourceLink(for task: ThingsTask) -> (url: URL, label: String, icon: String)? {
        guard let notes = task.notes else { return nil }
        for scheme in ["satchel://", "trace://", "dayflow://", "shortcuts://"] {
            guard let range = notes.range(of: scheme) else { continue }
            let tail = notes[range.lowerBound...]
            let raw = tail.prefix { !$0.isWhitespace && $0 != "\n" }
            guard let url = URL(string: String(raw)) else { continue }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if scheme == "shortcuts://" {
                let name = comps?.queryItems?.first(where: { $0.name == "name" })?.value
                return (url, name ?? "Run shortcut", "bolt")
            }
            if let path = comps?.queryItems?.first(where: { $0.name == "path" })?.value {
                let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                return (url, stem, "doc")
            }
            let label = scheme.hasPrefix("satchel") ? "Open in Satchel"
                      : scheme.hasPrefix("trace") ? "Open in Trace" : "Open"
            return (url, label, "doc")
        }
        return nil
    }
}

// MARK: - Multi-select + When (Session 77, David's Things-style swipes)
//
// Swipe LEFT on a Today task row → select mode: the row highlights, selection
// circles appear on the RIGHT, and ContentView shows the action bar (When /
// Move / Done / Delete) in an ink capsule above the tab bar. Swipe RIGHT →
// the When sheet for just that task (Today / Tomorrow / Pick a day / Clear).
// Shared object because the rows live in this section while the bar has to
// be screen-fixed, which only ContentView can do.

@MainActor
@Observable
final class DayflowTodaySelection {
    static let shared = DayflowTodaySelection()
    var isActive = false
    var ids: Set<String> = []
    private init() {}
    func exit() { isActive = false; ids.removeAll() }
}

struct DayflowWhenRequest: Identifiable {
    let id = UUID()
    let tasks: [ThingsTask]
}

/// Things' "When?" dialog, Editorial-dressed: Today, Tomorrow, an expanding
/// calendar, Clear date. Applies to one task (row swipe-right) or the whole
/// selection (the action bar's When).
struct DayflowWhenSheet: View {
    let tasks: [ThingsTask]
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    /// Seeded in init, NEVER set programmatically after: the calendar's
    /// `.onChange(of: picked)` means "the user tapped a day" and applies
    /// immediately. Setting it in onAppear (2026-08-28, attempt 2's bonus
    /// fix) fired that watcher on arrival — the card applied its own seed
    /// and dismissed itself. Initial State values don't fire onChange.
    @State private var picked: Date

    init(tasks: [ThingsTask], onDone: @escaping () -> Void = {}) {
        self.tasks = tasks
        self.onDone = onDone
        _picked = State(initialValue: tasks.first?.date ?? Date())
    }
    /// Drag-dismiss stays OFF for the card's first moments. The 0.12s
    /// presentation hop was not enough: a swipe the outer ScrollView cancels
    /// mid-press fires the row gesture's onEnded with the button still down,
    /// and the continuing drag lands on the fresh sheet as ITS dismiss drag
    /// (David: "the window follows the mouse and it closes", twice). Arming
    /// dismissal after 0.6s puts the card beyond the stray gesture's reach;
    /// after that it dismisses normally.
    @State private var armed = false
    /// REMIND (Session 77, David: "It might need to be a toggle which when
    /// switched on asks for the day and time"). Off: day taps apply
    /// instantly, the fast path. On: day taps SELECT, the time chips show,
    /// and Set commits day + time as a real EKAlarm.
    @State private var remindOn = false
    @State private var remindMinutes = 9 * 60
    /// Days BEFORE the due day the alarm rings (David, 2026-08-28: "cant i
    /// add a reminder a few days before?"). 0 = on the day.
    @State private var remindLeadDays = 0
    @State private var showCustomLead = false
    @State private var showCustomTime = false
    @State private var pendingDay: Date? = nil

    var body: some View {
        // Scrolls: REMIND's rows grew the card past the sheet height, and a
        // clipped VStack showed a stray sliver of the header rule (David's
        // catch, 2026-08-28).
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            Text(tasks.count == 1 ? "WHEN" : "WHEN \u{00B7} \(tasks.count) TASKS")
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Color.dayflowInk)
                .padding(.bottom, 6)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
            // Sun and sunrise, not Things' star and moon — David asked for
            // different icons, and there is no Evening in a one-date system.
            whenRow("Today", systemImage: "sun.max") { choose(Date()) }
            hairline
            whenRow("Tomorrow", systemImage: "sunrise") {
                choose(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            }
            hairline
            // The calendar is always in view (the part of Things' When card
            // David called out) — a day tap applies instantly unless REMIND
            // is on, where it selects and Set commits.
            DatePicker("Day", selection: $picked, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Color.dayflowAccent)
                .onChange(of: picked) { _, newValue in choose(newValue) }
            hairline
            remindSection
            if remindOn { setButton }
            hairline
            whenRow("Clear date", systemImage: "slash.circle",
                    tint: Color.dayflowAccent) { apply(day: nil, remindAt: nil) }
            Spacer(minLength: 0)
        }
        .padding(20)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.height(640), .large])
        .presentationBackground(Color.dayflowPaper)
        .interactiveDismissDisabled(!armed)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { armed = true }
        }
    }

    /// A day was tapped — apply on the fast path, select when REMIND is on.
    private func choose(_ day: Date) {
        if remindOn {
            pendingDay = Calendar.current.startOfDay(for: day)
            picked = day
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            apply(day: day, remindAt: nil)
        }
    }

    private var remindSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                timeChip("REMIND", active: remindOn) {
                    withAnimation(.easeInOut(duration: 0.15)) { remindOn.toggle() }
                }
                if remindOn {
                    timeChip("8 AM", active: remindMinutes == 480 && !showCustomTime) {
                        remindMinutes = 480; showCustomTime = false
                    }
                    timeChip("NOON", active: remindMinutes == 720 && !showCustomTime) {
                        remindMinutes = 720; showCustomTime = false
                    }
                    timeChip("5 PM", active: remindMinutes == 1020 && !showCustomTime) {
                        remindMinutes = 1020; showCustomTime = false
                    }
                    timeChip("CUSTOM", active: showCustomTime) {
                        withAnimation(.easeInOut(duration: 0.15)) { showCustomTime.toggle() }
                    }
                }
                Spacer(minLength: 0)
            }
            if remindOn && showCustomTime {
                Picker("Time", selection: $remindMinutes) {
                    ForEach(Array(stride(from: 0, to: 24 * 60, by: 15)), id: \.self) { m in
                        Text(minuteLabel(m)).tag(m)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 96)
            }
            if remindOn {
                HStack(spacing: 8) {
                    timeChip("ON THE DAY", active: remindLeadDays == 0 && !showCustomLead) {
                        remindLeadDays = 0; showCustomLead = false
                    }
                    timeChip("1D", active: remindLeadDays == 1 && !showCustomLead) {
                        remindLeadDays = 1; showCustomLead = false
                    }
                    timeChip("3D", active: remindLeadDays == 3 && !showCustomLead) {
                        remindLeadDays = 3; showCustomLead = false
                    }
                    timeChip("1W", active: remindLeadDays == 7 && !showCustomLead) {
                        remindLeadDays = 7; showCustomLead = false
                    }
                    timeChip("CUSTOM", active: showCustomLead) {
                        withAnimation(.easeInOut(duration: 0.15)) { showCustomLead.toggle() }
                    }
                    Spacer(minLength: 0)
                }
                if showCustomLead {
                    Picker("Days before", selection: $remindLeadDays) {
                        ForEach(0...30, id: \.self) { d in
                            Text(d == 0 ? "On the day"
                                 : d == 1 ? "1 day before"
                                 : "\(d) days before").tag(d)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 96)
                }
                Text("Rings \(ringSummary)")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(Color.dayflowFaint)
            }
        }
        .padding(.vertical, 8)
    }

    /// The committed due day before Set is tapped.
    private var chosenDueDay: Date {
        pendingDay ?? tasks.first?.date.map { Calendar.current.startOfDay(for: $0) }
            ?? Calendar.current.startOfDay(for: Date())
    }

    private var ringMoment: Date? {
        let cal = Calendar.current
        guard let alarmDay = cal.date(byAdding: .day, value: -remindLeadDays, to: chosenDueDay)
        else { return nil }
        return cal.date(byAdding: .minute, value: remindMinutes, to: alarmDay)
    }

    private var ringSummary: String {
        guard let moment = ringMoment else { return "" }
        let f = DateFormatter(); f.dateFormat = "EEEE MMM d"
        let time = DateFormatter.localizedString(from: moment, dateStyle: .none, timeStyle: .short)
        return "\(f.string(from: moment)), \(time)"
    }

    private var setButton: some View {
        Button {
            apply(day: chosenDueDay, remindAt: ringMoment)
        } label: {
            Text("Set reminder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.dayflowPaper)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Color.dayflowInk, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    private func timeChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: active ? .bold : .regular))
                .tracking(0.5)
                .foregroundStyle(active ? Color.dayflowAccent : Color.dayflowMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? Color.dayflowAccent : Color.dayflowHairline,
                                  lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func minuteLabel(_ minutes: Int) -> String {
        var comps = DateComponents()
        comps.hour = minutes / 60; comps.minute = minutes % 60
        let d = Calendar.current.date(from: comps) ?? Date()
        return DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
    }

    private var hairline: some View {
        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
    }

    private func whenRow(_ label: String, systemImage: String,
                         tint: Color = .dayflowInk,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.dayflowAccent)
                    .frame(width: 22)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                Spacer()
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// day nil = clear date AND alarm; remindAt non-nil = date + ringing
    /// alarm at that moment.
    private func apply(day: Date?, remindAt: Date?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let targets = tasks
        Task { @MainActor in
            for t in targets {
                _ = await ReminderTaskStore.shared.update(
                    taskID: t.id, title: t.title,
                    date: day, clearDate: day == nil,
                    list: nil, notes: t.notes,
                    remindAt: remindAt)
            }
            dismiss()
            onDone()
        }
    }
}
