import SwiftUI

// MARK: - DayflowUpcomingView
//
// Browse: Upcoming — one of the three destinations off the top-bar calendar
// icon menu (Dayflow-Design-Plan.md "Top bar & navigation"; build order
// step 5). Ground truth: Dayflow-Mockup.html's #upcomingScrim — "Things-style
// day-grouped scrollable list — blank days show just a date header."
//
// **Real data as of 2026-07-20 — now two real sources merged per day.**
// Originally this was calendar-events-only (CalendarService.fetchEvents,
// 14-day window starting tomorrow) since the Mini bridge had no future-task
// data at all; David found the view "does not have anything yet" because his
// work calendar isn't configured on the Mac (a separate, expected EventKit
// account-scoping limitation — not fixable in-app) and there was no real
// Things data to fall back on either. Fixed by adding a real `/upcoming`
// endpoint to `things-jxa-server.py` (`things.lists.byName("Upcoming")
// .toDos()`) and `ThingsService.upcomingTasks` / `fetchUpcoming()`. Each day
// section now shows real EventKit events (unchanged, top of the section) plus
// real Things tasks scheduled that day (new, below the events), each with a
// completable checkbox and tap-to-edit on the title.
//
// Recurring-task rows (the mockup's "↻" glyph / "5d left" badge) are still
// left out — `ThingsTask` carries no recurrence field, and no backend source
// for that exists. Flag if that turns out to matter enough to justify the
// Mini-side work.
//
// **Pull-to-refresh + reactive task grouping added 2026-07-20.** David edited
// a task's note directly in Things and found it didn't show up in Dayflow —
// nothing here re-fetched on its own after the initial `.task { load() }`.
// `tasksByDay` was a `@State` snapshot manually rebuilt by `regroupTasks()` at
// specific call sites; changed to a computed property reading
// `ThingsService.shared.upcomingTasks` directly (same reactive pattern
// `DayflowAnytimeView`/`DayflowInboxView` already use) so any update to the
// shared source — a pull-to-refresh here, or the new foreground auto-refresh
// in `DayflowContentView.swift` — reflects immediately without a matching
// call to re-derive local state. `.refreshable` added to the ScrollView for
// the explicit "I'm on this screen, get me current data" case.

struct DayflowUpcomingView: View {
    var onSwitchToCalendar: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days: [Date] = []
    @State private var eventsByDay: [Date: [NextCalendarEvent]] = [:]
    @State private var isLoading = true
    @State private var editingTask: ThingsTask? = nil

    private static let windowLength = 14

    /// Real Things tasks scheduled in the window, grouped by day. Computed
    /// directly off `ThingsService.shared.upcomingTasks` — see this file's
    /// header comment (2026-07-20 addendum) for why this isn't a `@State`
    /// snapshot anymore.
    private var tasksByDay: [Date: [ThingsTask]] {
        let cal = Calendar.current
        var grouped: [Date: [ThingsTask]] = [:]
        for task in ThingsService.shared.upcomingTasks {
            guard let date = task.date else { continue }
            let dayStart = cal.startOfDay(for: date)
            grouped[dayStart, default: []].append(task)
        }
        return grouped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(days, id: \.self) { day in
                            daySection(day)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Text("Same as Things' own Upcoming list — day-grouped, scrolls, merged with your real calendar events. Tap the calendar icon above to switch to a month grid instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                }
                .refreshable { await load() }
            }
        }
        .task { await load() }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                  initialDate: task.date, initialList: task.list,
                                  initialNotes: task.notes) {
                Task { await ThingsService.shared.fetchUpcoming() }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer()
            Text("Upcoming")
                .font(.custom("Georgia", size: 20).weight(.bold))
            Spacer()

            Button(action: onSwitchToCalendar) {
                Image(systemName: "calendar")
                    .font(.system(size: 15))
                    .frame(width: 32, height: 32)
                    .background(.background, in: Circle())
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch to Calendar")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: Day sections

    private func daySection(_ day: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            dayHeader(day)
            let events = eventsByDay[day] ?? []
            let tasks = tasksByDay[day] ?? []
            // Blank days show just the header, per the mockup — no
            // "Nothing scheduled" filler row.
            ForEach(events) { ev in
                HStack(spacing: 9) {
                    Text(ev.startTimeString)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.71, green: 0.54, blue: 0.23))
                        .frame(width: 62, alignment: .leading)
                    Text(ev.title)
                        .font(.system(size: 13.5))
                        .lineLimit(2)
                }
                .padding(.vertical, 3)
            }
            ForEach(tasks) { task in
                taskRow(task)
            }
        }
        .padding(.bottom, 10)
    }

    private func taskRow(_ task: ThingsTask) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                // No local mutation needed anymore — `tasksByDay` is now a
                // computed property over `ThingsService.shared.upcomingTasks`
                // (see this file's 2026-07-20 header addendum), and
                // `complete(taskID:)` already prunes that array itself
                // (synchronously, before its network call), so the row
                // disappears on its own once the shared source updates.
                Task { await ThingsService.shared.complete(taskID: task.id) }
            } label: {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.45), lineWidth: 2)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel("Complete \(task.title)")

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 13.5))
                    .lineLimit(2)
                if let list = task.list, !list.isEmpty {
                    Text(list)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editingTask = task }
        }
        .padding(.vertical, 3)
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(dayNumberLabel(day))
                .font(.system(size: 19, weight: .bold))
            Text(dayNameLabel(day))
                .font(.system(size: 11.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
        .overlay(Divider(), alignment: .bottom)
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
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let windowDays = (0..<Self.windowLength).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let end = cal.date(byAdding: .day, value: Self.windowLength, to: start) ?? start

        async let events = CalendarService.shared.fetchEvents(from: start, to: end)
        async let taskFetch: Void = ThingsService.shared.fetchUpcoming()
        let fetchedEvents = await events
        await taskFetch

        var groupedEvents: [Date: [NextCalendarEvent]] = [:]
        for ev in fetchedEvents {
            let dayStart = cal.startOfDay(for: ev.startDate)
            groupedEvents[dayStart, default: []].append(ev)
        }

        days = windowDays
        eventsByDay = groupedEvents
        isLoading = false
    }
}
