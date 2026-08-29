import SwiftUI
import UIKit

// MARK: - DayflowUpcomingView
//
// Step (e) of the task UI build (Session 77, Dayflow-Tasks-Design.md §
// Upcoming) — the last structural piece. Editorial rewrite of the old
// browse screen (see git for its Things-era history):
//
// - Two weeks starting tomorrow (Today's card owns today). Day headings
//   ONLY for days with something — the locked design dropped the empty
//   headers the old mockup kept.
// - Each day: its events (time · colour square · title, same language as
//   Today's strip) then its tasks (ink circle completes, serif title, tap
//   edits). A repeating task from the Trace list is almost certainly a
//   birthday/holiday written by Trace's person-page Remind button, so its
//   sub-label reads "from Trace · yearly" per the design; other tasks show
//   their list.
// - Footer, whole row tappable: "Nothing until <date>" — the next dated
//   reminder BEYOND the two weeks (the store already looks 60 days out) —
//   over "Open Reminders", which opens Apple's app.
//

struct DayflowUpcomingView: View {
    @Environment(\.dismiss) private var dismiss
    /// Session 77: true when hosted as the Upcoming tab in DayflowRootView —
    /// hides the chevron (there is no presentation to dismiss there).
    var isTabRoot: Bool = false

    @State private var days: [Date] = []
    @State private var eventsByDay: [Date: [NextCalendarEvent]] = [:]
    /// Session 78 — David's fold: "a small icon that would fold all the
    /// meetings away... and only show tasks". ONE global toggle (a per-day
    /// icon would be fourteen taps), persisted: a lens preference, not a
    /// transient state. Folded days keep a faint meeting count so a full
    /// day can't masquerade as an empty one while he's dating tasks into it.
    @AppStorage("dayflow_upcoming_tasks_only") private var tasksOnly = false
    @State private var windowEnd: Date = Date()
    @State private var isLoading = true
    @State private var editingTask: ThingsTask? = nil
    @State private var selectedEvent: NextCalendarEvent? = nil
    /// Session 77 — the Today card's swipe treatment, verbatim (David: "i
    /// would like the same swiping treatment as what we have in Today"):
    /// left = multi-select (RootView shows the shared bar), right = the When
    /// sheet with the calendar-glyph reveal.
    @State private var selection = DayflowTodaySelection.shared
    @State private var whenRequest: DayflowWhenRequest? = nil
    @State private var rowDragOffsets: [String: CGFloat] = [:]

    private static let windowLength = 14

    /// Dated tasks in the window, grouped by day — computed straight off the
    /// live store so completions prune rows on their own.
    private var tasksByDay: [Date: [ThingsTask]] {
        let cal = Calendar.current
        var grouped: [Date: [ThingsTask]] = [:]
        for task in ReminderTaskStore.shared.upcomingTasks {
            guard let date = task.date else { continue }
            grouped[cal.startOfDay(for: date), default: []].append(task)
        }
        return grouped
    }

    private var daysWithContent: [Date] {
        days.filter { day in
            if tasksOnly { return !(tasksByDay[day] ?? []).isEmpty }
            return !(eventsByDay[day] ?? []).isEmpty || !(tasksByDay[day] ?? []).isEmpty
        }
    }

    /// The next dated reminder past the two-week window — the footer's date.
    private var nextBeyondWindow: Date? {
        ReminderTaskStore.shared.upcomingTasks
            .compactMap(\.date)
            .filter { $0 >= windowEnd }
            .min()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isLoading && daysWithContent.isEmpty {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if daysWithContent.isEmpty {
                            Text("Two clear weeks ahead.")
                                .font(.dayflowSerif(16))
                                .foregroundStyle(Color.dayflowMuted)
                                .padding(.top, 32)
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(daysWithContent, id: \.self) { day in
                                daySection(day)
                            }
                        }
                        footer
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }
            }
        }
        .dayflowSkinBackground()
        .task { await load() }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await ReminderTaskStore.shared.fetchUpcoming() }
            }
        }
        .sheet(item: $selectedEvent) { event in
            NavigationStack { DayflowEventDetailView(event: event) }
        }
        .sheet(item: $whenRequest) { request in
            DayflowWhenSheet(tasks: request.tasks)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isTabRoot {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            Text("NEXT TWO WEEKS")
                .font(.system(size: 11, weight: .medium))
                .tracking(2.2)
                .foregroundStyle(Color.dayflowMuted)
            HStack(alignment: .center) {
                Text("Upcoming")
                    .font(.dayflowSerif(30, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { tasksOnly.toggle() }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: tasksOnly ? "calendar.badge.minus" : "calendar")
                        .font(.system(size: 15))
                        .foregroundStyle(tasksOnly ? Color.dayflowAccent : Color.dayflowFaint)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tasksOnly ? "Show meetings" : "Hide meetings")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, isTabRoot ? 22 : 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dayflowQuickFindPull(enabled: isTabRoot)
    }

    // MARK: Day sections

    /// True for the first RENDERED day of a month that isn't the first
    /// month on screen — the crossover David asked to see (2026-08-29: "when
    /// we have a cross over into a new month... I would expect the 1 Tuesday
    /// September to show up"). Named like a newspaper: a month masthead
    /// between the sections, not a longer day label.
    private func startsNewMonth(_ day: Date) -> Bool {
        guard let idx = daysWithContent.firstIndex(of: day), idx > 0 else { return false }
        return !Calendar.current.isDate(day, equalTo: daysWithContent[idx - 1],
                                        toGranularity: .month)
    }

    private func monthLabel(_ day: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM"
        return f.string(from: day).uppercased()
    }

    private func daySection(_ day: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if startsNewMonth(day) {
                HStack(spacing: 10) {
                    Text(monthLabel(day))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(Color.dayflowAccent)
                    Rectangle().fill(Color.dayflowAccent).frame(height: 2)
                }
                .padding(.top, 26)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dayNumberLabel(day))
                    .font(.dayflowSerif(20, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                Text(dayNameLabel(day))
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(Color.dayflowFaint)
            }
            .padding(.top, 18)
            .padding(.bottom, 5)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)

            if tasksOnly {
                let count = (eventsByDay[day] ?? []).count
                if count > 0 {
                    Text("\(count) meeting\(count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(minHeight: 24)
                }
            } else {
                ForEach(eventsByDay[day] ?? []) { ev in
                    eventRow(ev, in: day)
                }
            }
            ForEach(tasksByDay[day] ?? []) { task in
                taskRow(task)
            }
        }
    }

    private func eventRow(_ event: NextCalendarEvent, in day: Date) -> some View {
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
                // Session 78 — Today's gap parenthetical, same rule (open
                // time before the NEXT meeting, >=5 min, nothing after the
                // last). One grammar for a day's shape, wherever a day is
                // drawn (David: "wondering about the time available").
                if let gap = gapLabel(after: event, in: day) {
                    Text("(\(gap))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dayflowFaint)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func gapLabel(after event: NextCalendarEvent, in day: Date) -> String? {
        let events = eventsByDay[day] ?? []
        guard let idx = events.firstIndex(where: { $0.id == event.id }),
              idx + 1 < events.count else { return nil }
        let mins = Int(events[idx + 1].startDate.timeIntervalSince(event.endDate) / 60)
        guard mins >= 5 else { return nil }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private func taskRow(_ task: ThingsTask) -> some View {
        // The Trace list's repeating reminders are the person-page birthdays
        // and holidays — the design marks them "from Trace · yearly".
        let isTraceYearly = task.repeats && task.list == ReminderService.listName
        let selected = selection.ids.contains(task.id)
        return HStack(alignment: .center, spacing: 12) {
            Button {
                if selection.isActive {
                    if selected { selection.ids.remove(task.id) }
                    else { selection.ids.insert(task.id) }
                } else {
                    Task { await ReminderTaskStore.shared.complete(taskID: task.id) }
                }
            } label: {
                Circle()
                    .strokeBorder(Color.dayflowInk, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(task.title)")

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 14.5, design: .serif))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(2)
                if isTraceYearly {
                    Text("from Trace \u{00B7} yearly")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dayflowFaint)
                } else if let list = task.list, !list.isEmpty {
                    Text(list)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dayflowFaint)
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
            if task.repeats && !isTraceYearly {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dayflowFaint)
            }
            if selection.isActive {
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
        .frame(minHeight: 38)
        .padding(.horizontal, selection.isActive ? 6 : 0)
        .background(selected ? Color.dayflowAccent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.isActive {
                if selected { selection.ids.remove(task.id) }
                else { selection.ids.insert(task.id) }
            } else {
                editingTask = task
            }
        }
        .offset(x: rowDragOffsets[task.id] ?? 0)
        .background(alignment: .leading) {
            let progress = min(max((rowDragOffsets[task.id] ?? 0) / 60, 0), 1)
            if progress > 0 {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
                    .opacity(Double(progress))
                    .scaleEffect(0.7 + 0.3 * progress)
                    .padding(.leading, 2)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 28)
                .onChanged { value in
                    guard !selection.isActive else { return }
                    let h = value.translation.width
                    guard abs(h) > abs(value.translation.height) else { return }
                    rowDragOffsets[task.id] = h > 0 ? min(h, 80) : 0
                }
                .onEnded { value in
                    let h = value.translation.width
                    withAnimation(.spring(duration: 0.3)) { rowDragOffsets[task.id] = 0 }
                    guard !selection.isActive else { return }
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
        .animation(.easeInOut(duration: 0.15), value: selection.isActive)
    }

    // MARK: Footer

    private var footer: some View {
        Button {
            if let url = URL(string: "x-apple-reminderkit://") {
                UIApplication.shared.open(url)
            }
        } label: {
            VStack(spacing: 3) {
                if let next = nextBeyondWindow {
                    Text("Nothing until \(footerDateLabel(next))")
                        .font(.dayflowSerif(15))
                        .foregroundStyle(Color.dayflowMuted)
                } else {
                    Text("Nothing else on the books")
                        .font(.dayflowSerif(15))
                        .foregroundStyle(Color.dayflowMuted)
                }
                Text("Open Reminders")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dayflowFaint)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 26)
    }

    private func footerDateLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func dayNumberLabel(_ day: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: day)
    }

    private func dayNameLabel(_ day: Date) -> String {
        if Calendar.current.isDateInTomorrow(day) { return "TOMORROW" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: day).uppercased()
    }

    // MARK: Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let windowDays = (0..<Self.windowLength).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let end = cal.date(byAdding: .day, value: Self.windowLength, to: start) ?? start

        async let events = CalendarService.shared.fetchEvents(from: start, to: end)
        async let taskFetch: Void = ReminderTaskStore.shared.fetchUpcoming()
        let fetchedEvents = await events
        await taskFetch

        var groupedEvents: [Date: [NextCalendarEvent]] = [:]
        for ev in fetchedEvents where !ev.isAllDay {
            let dayStart = cal.startOfDay(for: ev.startDate)
            groupedEvents[dayStart, default: []].append(ev)
        }
        for (day, list) in groupedEvents {
            groupedEvents[day] = list.sorted { $0.startDate < $1.startDate }
        }

        days = windowDays
        eventsByDay = groupedEvents
        windowEnd = end
    }
}
