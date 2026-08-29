import Foundation
import EventKit
import UserNotifications

// MARK: - DayflowTaskAlarms
//
// Session 78, D168. David: "I need a reminder now for my tasks that mimics
// what reminders does. I want to remove reminders alerts and just use
// Dayflow." The alarms themselves stay EKAlarms on the reminders (they ARE
// the data model — the When card, the edit sheet and the widget's bell all
// read them); what moves is who RINGS. With Apple's Reminders notifications
// switched off in iOS Settings (David's manual step — no API can do it),
// this schedules a local notification for every upcoming alarm, so the ping
// comes from Dayflow.
//
// DayflowMorningSummary's exact shape, deliberately: rewritten wholesale on
// the same scene transitions (.active to correct the week ahead,
// .background so a session's completions and adds land), 7-day window,
// prefix-swept ids so stale pings can't linger. Honest limit, same as the
// summary's: a task completed OUTSIDE Dayflow (watch, Apple's app) keeps
// its scheduled ping until the next rewrite — the next app touch clears it.

enum DayflowTaskAlarms {

    private static let idPrefix = "dayflow-task-alarm-"
    private static let windowDays = 7

    static func reschedule() async {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
        else { return }

        // Sweep everything ours before rescheduling — completions, redates
        // and deletions are all handled by the rewrite.
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        if !ours.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }

        let store = EKEventStore()
        let now = Date()
        let cal = Calendar.current
        guard let horizon = cal.date(byAdding: .day, value: windowDays, to: now) else { return }
        // The due-date window reaches past the alarm horizon: a lead-time
        // alarm rings BEFORE its due day, so a due date up to `windowDays`
        // beyond the horizon can still own an alarm inside it.
        let dueWindowEnd = cal.date(byAdding: .day, value: windowDays, to: horizon) ?? horizon
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: dueWindowEnd, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }

        for reminder in reminders {
            for alarm in reminder.alarms ?? [] {
                guard let fireDate = alarm.absoluteDate,
                      fireDate > now, fireDate <= horizon else { continue }
                let content = UNMutableNotificationContent()
                content.title = reminder.title ?? "Task"
                if let list = reminder.calendar?.title, !list.isEmpty {
                    content.body = list
                }
                content.sound = .default
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                               from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let id = idPrefix + reminder.calendarItemIdentifier + "-"
                    + String(Int(fireDate.timeIntervalSince1970))
                try? await center.add(UNNotificationRequest(identifier: id,
                                                            content: content,
                                                            trigger: trigger))
            }
        }
    }
}
