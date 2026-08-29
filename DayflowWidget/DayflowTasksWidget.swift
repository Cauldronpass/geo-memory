// DayflowTasksWidget.swift — the tasks widget (Session 78, 2026-08-29).
//
// David: "I have underneath that the Things task widget which i like but we
// dont have things anymore." This is its replacement, third widget in the
// bundle: today's tasks (due today or overdue, straight from Reminders),
// tappable circles that COMPLETE the task right on the Home Screen
// (interactive AppIntent, the CheckInIntent pattern — the widget's circle
// does what the app's circle does, no launch), a count, and a "+" that
// deep-links into the Inbox capture card (dayflow://addTask, consumed by the
// same router the Home Screen quick action uses).
//
// Reads EventKit directly in the widget process — the date widget has read
// calendar EVENTS this way since Session 63, and reminders ride the same
// authorization the containing app already holds. No app-group snapshot to
// keep in sync. Wears DayflowWidgetSkin (same file, same target), so the
// two widgets stacked on David's Home Screen read as one family; the same
// Appearance edit-widget setting applies.

import WidgetKit
import SwiftUI
import EventKit
import AppIntents

// MARK: - Entry + row

struct DayflowTasksEntry: TimelineEntry {
    let date: Date
    let tasks: [DayflowTaskRow]
    let totalCount: Int
    let remindersUnavailable: Bool
    let appearance: DayflowWidgetAppearance
}

struct DayflowTaskRow: Identifiable {
    let id: String
    let title: String
    let overdue: Bool
    let hasAlarm: Bool
}

// MARK: - Provider

struct DayflowTasksProvider: AppIntentTimelineProvider {
    typealias Entry = DayflowTasksEntry
    typealias Intent = DayflowWidgetConfigIntent

    func placeholder(in context: Context) -> DayflowTasksEntry {
        DayflowTasksEntry(date: Date(),
                          tasks: [
                            DayflowTaskRow(id: "1", title: "Water the plants", overdue: false, hasAlarm: false),
                            DayflowTaskRow(id: "2", title: "Call Mickey about the lake weekend", overdue: false, hasAlarm: true),
                          ],
                          totalCount: 2, remindersUnavailable: false, appearance: .light)
    }

    func snapshot(for configuration: DayflowWidgetConfigIntent, in context: Context) async -> DayflowTasksEntry {
        await fetchEntry(appearance: configuration.appearance)
    }

    func timeline(for configuration: DayflowWidgetConfigIntent, in context: Context) async -> Timeline<DayflowTasksEntry> {
        let entry = await fetchEntry(appearance: configuration.appearance)
        // The complete-circle intent and the app's own writes both force
        // reloads; the timeline itself only needs to survive the midnight
        // boundary (overdue math changes) plus a slow ambient refresh.
        let cal = Calendar.current
        let nextMidnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: entry.date) ?? entry.date)
        let nextHour = entry.date.addingTimeInterval(60 * 60)
        return Timeline(entries: [entry], policy: .after(min(nextMidnight, nextHour)))
    }

    private static var hasReminderAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    private func fetchEntry(appearance: DayflowWidgetAppearance) async -> DayflowTasksEntry {
        let now = Date()
        guard Self.hasReminderAccess else {
            return DayflowTasksEntry(date: now, tasks: [], totalCount: 0,
                                     remindersUnavailable: true, appearance: appearance)
        }
        let store = EKEventStore()
        let cal = Calendar.current
        let endOfToday = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }
        let today = cal.startOfDay(for: now)
        let rows = reminders
            .compactMap { reminder -> (Date, DayflowTaskRow)? in
                guard let comps = reminder.dueDateComponents,
                      let due = cal.date(from: comps) else { return nil }
                return (due, DayflowTaskRow(
                    id: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "",
                    overdue: cal.startOfDay(for: due) < today,
                    hasAlarm: !(reminder.alarms ?? []).isEmpty))
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.title.localizedCaseInsensitiveCompare(rhs.1.title) == .orderedAscending
            }
            .map(\.1)
        return DayflowTasksEntry(date: now, tasks: rows, totalCount: rows.count,
                                 remindersUnavailable: false, appearance: appearance)
    }
}

// MARK: - Complete-from-the-widget intent
//
// CheckInIntent's shape: no launch, do the work in the widget process,
// reload the timeline on every path so the tap always visibly lands.

struct DayflowCompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Task"
    static var description = IntentDescription("Marks the task done in Reminders.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}
    init(taskID: String) { self.taskID = taskID }

    @MainActor
    func perform() async throws -> some IntentResult {
        defer { WidgetCenter.shared.reloadTimelines(ofKind: "DayflowTasksWidget") }
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder
        else { return .result() }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        return .result()
    }
}

// MARK: - View

struct DayflowTasksWidgetView: View {
    let entry: DayflowTasksEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var systemScheme

    private var skin: DayflowWidgetSkin {
        switch entry.appearance {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemScheme == .dark ? .dark : .light
        }
    }

    private var rowLimit: Int { family == .systemSmall ? 3 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(skin.weekday)
                Text("TODAY")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(skin.today)
                Spacer()
                if entry.totalCount > 0 {
                    Text("\(entry.totalCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(skin.month)
                }
            }
            if entry.remindersUnavailable {
                Text("Open Dayflow once to allow Reminders.")
                    .font(.system(size: 12))
                    .foregroundStyle(skin.month)
                Spacer(minLength: 0)
            } else if entry.tasks.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing due today.")
                    .font(.system(size: 13))
                    .foregroundStyle(skin.month)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.tasks.prefix(rowLimit)) { task in
                    HStack(spacing: 9) {
                        Button(intent: DayflowCompleteTaskIntent(taskID: task.id)) {
                            Circle()
                                .strokeBorder(skin.month.opacity(0.75), lineWidth: 1.4)
                                .frame(width: 17, height: 17)
                        }
                        .buttonStyle(.plain)
                        // The circle completes; the TEXT opens the task's
                        // edit sheet in the app (David, 2026-08-29) — two
                        // verbs per row, matching the in-app grammar where
                        // the circle and the row are different taps.
                        Link(destination: URL(string: "dayflow://task?id=\(task.id)")!) {
                            Text(task.title)
                                .font(.system(size: 13.5))
                                .foregroundStyle(skin.eventText)
                                .lineLimit(1)
                        }
                        if task.overdue {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(skin.month)
                        }
                        Spacer(minLength: 0)
                        if task.hasAlarm {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(skin.month.opacity(0.8))
                        }
                    }
                }
                if entry.totalCount > rowLimit {
                    Text("and \(entry.totalCount - rowLimit) more")
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(skin.month)
                }
                Spacer(minLength: 0)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // The same blue "+" the date widget wears, aimed at tasks: the
            // Inbox capture card, cursor ready.
            Link(destination: URL(string: "dayflow://addTask")!) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(skin.today, in: Circle())
            }
        }
        .containerBackground(skin.background, for: .widget)
        .widgetURL(URL(string: "dayflow://launch?target=today"))
    }
}

// MARK: - Widget

struct DayflowTasksWidget: Widget {
    let kind: String = "DayflowTasksWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DayflowWidgetConfigIntent.self,
                               provider: DayflowTasksProvider()) { entry in
            DayflowTasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Dayflow Tasks")
        .description("Today's tasks, completable from the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
