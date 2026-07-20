import SwiftUI

// MARK: - DayflowAgendaSection
//
// Dayflow-Design-Plan.md "Agenda section" (build order step 3). Ground truth
// is Dayflow-Mockup.html's #agendaSection: two columns (All day/no time left,
// Timed right) with a faint vertical divider, each independently
// vertically-scrollable, a header-right collapse/expand toggle with a
// one-line summary when collapsed, and a "+" that opens the quick-add sheet
// (already built — this just wires the real openSheetBtn location).
//
// Real data, two sources mixed into the left column exactly like the mockup:
//   - All-day EventKit events (CalendarService.fetchDayEvents(for:), added
//     alongside this file — separate from Trace's own Home-widget fetch, see
//     that file's comment) get a rounded-square marker (can't check off).
//   - No-date Things tasks get a round checkbox (can complete). For today,
//     pulled from the Mac Mini bridge's `/today` list (`ThingsService.shared.
//     tasks`); for any other date, filtered from the real `/upcoming` list
//     (`ThingsService.shared.upcomingTasks`, each task carrying its own real
//     `scheduled_date` — see `tasksForDay` below).
// The right "Timed" column is calendar events only — Things to-dos have no
// time field, matching the design plan's explicit call-out.
//
// **Revised 2026-07-20 (fourth addendum).** Previously any non-today date
// showed calendar events only, no tasks at all — David found this jumping
// Browse: Calendar to a real future date (July 25) whose scheduled task
// showed up in Browse: Upcoming but not here. Root cause: `showsRealTasks`
// gated task-fetching on `isDateInToday`, so the Agenda never even asked
// `ThingsService` for a non-today date's tasks, regardless of whether real
// data existed. Fixed by filtering `ThingsService.shared.upcomingTasks` (real
// per-day data, built in Session 6) down to the selected day for any
// non-today date. Yesterday (and any other past date) is still uncovered —
// `/upcoming` is forward-looking only, so there's no real backend source for
// past-dated tasks yet. That narrower remaining gap is unchanged from before.
//
// The mockup's one demo task shows an illustrative "Overdue" meta label —
// left out here since `ThingsTask` has no due-date field to back it with
// (logged in Dayflow-Design-Plan.md "Open questions").
//
// **Revised 2026-07-20 (Session 6, second addendum).** The round checkbox
// marker was purely decorative — David found tapping a task did nothing.
// `marker(for:isTimedColumn:)`'s task case is now a real `Button` calling
// `ThingsService.complete(taskID:)`, matching the pattern already used in
// `DayflowAnytimeView.swift` (built earlier the same session). Required
// threading the real `ThingsTask.id` through `DayflowAgendaItem` (new
// `taskID: String?` field, nil for calendar events) since the item's own
// `id` is a synthesized `"task-\(t.id)"` string, not a real Things id.
//
// **Revised 2026-07-20 (third addendum).** Tapping a task's title/meta text
// (not the checkbox) now opens DayflowTaskEditSheet to edit its title, date,
// or list — David asked for this alongside the Upcoming/Anytime real-data
// fixes. The tap target is the title/meta VStack only, kept separate from the
// checkbox `Button` beside it so completing and editing stay two distinct
// gestures. Calendar events (`kind == .event`) are not editable here — no
// edit path exists for EventKit events in this build, so the tap is a no-op
// for them.

struct DayflowAgendaSection: View {
    let date: Date
    var onOpenQuickAdd: () -> Void
    /// Lifted to ContentView (2026-07-19, Daily Note build) — the Daily Note
    /// card's own bounded-scroll height grows when Agenda collapses (see
    /// Dayflow-Design-Plan.md "Daily Note section": "Its scroll height grows
    /// when Agenda is collapsed, so it actually uses the freed space rather
    /// than leaving a gap"), which means ContentView needs to know this
    /// section's collapse state too. Was `@State private var isCollapsed`
    /// before this change — purely a visibility change, no new behavior here.
    @Binding var isCollapsed: Bool

    @State private var dayEvents: [NextCalendarEvent] = []
    @State private var editingItem: DayflowAgendaItem? = nil
    /// Drives the header refresh button's spin + disables it mid-fetch.
    /// **Added 2026-07-20** alongside the Browse views' pull-to-refresh — this
    /// card's two columns are only ~150pt tall and don't render a ScrollView
    /// at all when empty (see `column(label:items:isTimedColumn:)` below), so
    /// a swipe-to-refresh gesture has nowhere reliable to attach, especially
    /// in exactly the "Nothing here" case where refreshing matters most. A
    /// plain button is the reliable equivalent here.
    @State private var isRefreshing = false

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    /// Things tasks scheduled for `date`. Today pulls the real `/today` list
    /// directly; any other date filters the real `/upcoming` list down to
    /// just this day. See this file's header comment (fourth addendum) for
    /// why this changed and what's still not covered (past dates).
    private var tasksForDay: [ThingsTask] {
        if isToday {
            return ThingsService.shared.tasks
        }
        let cal = Calendar.current
        return ThingsService.shared.upcomingTasks.filter { task in
            guard let taskDate = task.date else { return false }
            return cal.isDate(taskDate, inSameDayAs: date)
        }
    }

    private var noTimeItems: [DayflowAgendaItem] {
        let events = dayEvents.filter(\.isAllDay).map { ev in
            DayflowAgendaItem(id: "event-\(ev.id)", kind: .event, title: ev.title,
                              isAllDay: true, timeLabel: nil, metaLabel: "Calendar · All day",
                              taskID: nil, taskDate: nil, taskNotes: nil)
        }
        let tasks = tasksForDay.map { t in
            DayflowAgendaItem(id: "task-\(t.id)", kind: .task, title: t.title,
                              isAllDay: true, timeLabel: nil, metaLabel: t.list,
                              taskID: t.id, taskDate: t.date, taskNotes: t.notes)
        }
        return events + tasks
    }

    private var timedItems: [DayflowAgendaItem] {
        dayEvents.filter { !$0.isAllDay }.map { ev in
            DayflowAgendaItem(id: "event-\(ev.id)", kind: .event, title: ev.title,
                              isAllDay: false, timeLabel: ev.startTimeString, metaLabel: nil,
                              taskID: nil, taskDate: nil, taskNotes: nil)
        }
    }

    private var summaryLabel: String {
        let taskCount = noTimeItems.filter { $0.kind == .task }.count
        let eventCount = noTimeItems.filter { $0.kind == .event }.count + timedItems.count
        let taskWord = taskCount == 1 ? "task" : "tasks"
        let eventWord = eventCount == 1 ? "event" : "events"
        return "\(taskCount) \(taskWord) · \(eventCount) \(eventWord) — tap to expand"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isCollapsed {
                Text(summaryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                grid
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, isCollapsed ? 10 : 16)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 0.5))
        .task(id: date) { await loadDayData() }
        .sheet(item: $editingItem) { item in
            if let taskID = item.taskID {
                DayflowTaskEditSheet(taskID: taskID, initialTitle: item.title,
                                      initialDate: item.taskDate, initialList: item.metaLabel,
                                      initialNotes: item.taskNotes) {
                    Task { await loadDayData() }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Agenda", systemImage: "calendar")
                .font(.system(size: 14.5, weight: .semibold))
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isCollapsed.toggle() }
            } label: {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand Agenda" : "Collapse Agenda")

            Button {
                guard !isRefreshing else { return }
                Task {
                    isRefreshing = true
                    await loadDayData()
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.6), in: Circle())
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh")

            Button(action: onOpenQuickAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.blue, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick add")
        }
    }

    // MARK: Two-column grid

    private var grid: some View {
        HStack(alignment: .top, spacing: 12) {
            column(label: "All day / no time", items: noTimeItems, isTimedColumn: false)
            Rectangle().fill(.quaternary.opacity(0.5)).frame(width: 1)
            column(label: "Timed", items: timedItems, isTimedColumn: true)
        }
    }

    private func column(label: String, items: [DayflowAgendaItem], isTimedColumn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            if items.isEmpty {
                Text("Nothing here")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            } else {
                // Independently scrolling per column (not the whole page) once
                // a column exceeds a few items — matches the mockup's
                // `.agenda-list { max-height: 150px; overflow-y: auto; }`.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            row(for: item, isTimedColumn: isTimedColumn)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for item: DayflowAgendaItem, isTimedColumn: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            marker(for: item, isTimedColumn: isTimedColumn)
            VStack(alignment: .leading, spacing: 1) {
                if isTimedColumn, let timeLabel = item.timeLabel {
                    Text(timeLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                if !isTimedColumn, let meta = item.metaLabel {
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard item.kind == .task, item.taskID != nil else { return }
                editingItem = item
            }
        }
    }

    /// Round checkbox for a Things task (you can complete it, and now
    /// actually can — see this file's header comment), rounded-square marker
    /// for a calendar event (you can't). The Timed column's clock glyph
    /// stands in for both, since only events ever appear there.
    @ViewBuilder
    private func marker(for item: DayflowAgendaItem, isTimedColumn: Bool) -> some View {
        if isTimedColumn {
            Text("🕒").font(.system(size: 11)).padding(.top, 1)
        } else if item.kind == .task, let taskID = item.taskID {
            Button {
                Task { await ThingsService.shared.complete(taskID: taskID) }
            } label: {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.45), lineWidth: 2)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel("Complete \(item.title)")
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.blue.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.blue, lineWidth: 2))
                .frame(width: 16, height: 16)
                .padding(.top, 1)
        }
    }

    // MARK: Data

    private func loadDayData() async {
        async let events = CalendarService.shared.fetchDayEvents(for: date)
        // Run the Things fetch concurrently with the calendar fetch above —
        // both hit the network (EventKit access + the Mac Mini bridge), no
        // reason to serialize them. Today fetches `/today`; any other date
        // fetches `/upcoming` (filtered down to the day by `tasksForDay`
        // above) — added 2026-07-20, see this file's header comment.
        if isToday {
            async let taskFetch: Void = ThingsService.shared.fetch()
            dayEvents = await events
            await taskFetch
        } else {
            async let taskFetch: Void = ThingsService.shared.fetchUpcoming()
            dayEvents = await events
            await taskFetch
        }
    }
}
