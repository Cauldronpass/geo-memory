//
//  DayflowMorningSummary.swift
//  Dayflow
//
//  The morning summary notification (Session 77, 2026-08-28). David, choosing
//  between "dated-but-timeless tasks stay silent" and the Things-style morning
//  ping: "i like the option two and the ability to add the time as well which
//  would then go off when that arrives."
//
//  Division of labour, deliberate:
//  - PER-TASK times are Apple's job. A task with a time gets an EKAlarm on the
//    reminder (Quick Add / edit sheet work, step (b)), and the SYSTEM fires
//    that notification — Dayflow needs no engine, and it works when Dayflow
//    hasn't run in days.
//  - The MORNING SUMMARY is ours, because no system feature says "3 for
//    today: …" with real titles. Local notifications are scheduled ahead with
//    static content, so `reschedule()` runs at every foreground AND
//    background transition (DayflowApp.swift) and rewrites the next 7
//    mornings from live Reminders data.
//
//  Known honest limitation: the summary's content is as fresh as the last
//  time Dayflow ran. A task completed in Apple's Reminders app late at night,
//  with Dayflow never opened after, still appears in the 8:00 summary (the
//  count is computed at scheduling time). Backlogged: BGAppRefreshTask to
//  tighten this if it annoys in practice.
//
//  Authorization: DayflowInboxBadge asked for `.badge` only (its header
//  comment promised no banners — that promise is amended by this feature,
//  which David asked for by name). Requesting `.alert`/`.sound` on top of an
//  existing badge grant does not re-prompt; iOS extends the grant silently.
//  If summaries don't arrive on device, the check is Settings › Notifications
//  › Dayflow › Banners.
//
//  Content rules: a day with no dated tasks schedules NOTHING (a "nothing
//  today" ping is noise). "For today" means dated ≤ that morning — carried-over
//  tasks are still that day's work, same semantic as the Today list itself.
//

import Foundation
import UserNotifications

enum DayflowMorningSummary {

    /// Defaults ON — David asked for the feature; the Settings toggle is the
    /// way out, not the way in.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "morning_summary_enabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "morning_summary_enabled")
    }

    /// Fire time as minutes from midnight. Default 480 = 8:00, the hour David
    /// reacted to in the worked example.
    static var fireMinutes: Int {
        UserDefaults.standard.object(forKey: "morning_summary_minutes") == nil
            ? 480
            : UserDefaults.standard.integer(forKey: "morning_summary_minutes")
    }

    private static let windowDays = 7

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func identifier(for day: Date) -> String {
        "dayflow-morning-\(dayFormatter.string(from: day))"
    }

    /// Clears and rewrites the next `windowDays` mornings from live Reminders
    /// data. Safe to call often; deterministic identifiers make it idempotent.
    @MainActor
    static func reschedule() async {
        let center = UNUserNotificationCenter.current()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Deterministic ids over a generous range, so a stale request from a
        // schedule written yesterday (or under an old window length) cannot
        // survive a rewrite.
        let staleIDs = (-1...windowDays + 1)
            .compactMap { cal.date(byAdding: .day, value: $0, to: today) }
            .map(identifier(for:))
        center.removePendingNotificationRequests(withIdentifiers: staleIDs)

        guard enabled else { return }

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .denied { return }
        // Covers both first-ever ask and the silent upgrade from the
        // badge-only grant DayflowInboxBadge established.
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
        else { return }

        guard await ReminderTaskStore.shared.ensureAccess() else { return }
        await ReminderTaskStore.shared.refreshAll()
        let store = ReminderTaskStore.shared
        // Every open dated task; store order is date-ascending then title.
        let dated = (store.tasks + store.upcomingTasks).filter { $0.date != nil }

        for offset in 0...windowDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = fireMinutes / 60
            comps.minute = fireMinutes % 60
            guard let fireDate = cal.date(from: comps), fireDate > Date() else { continue }

            let items = dated.filter { cal.startOfDay(for: $0.date!) <= day }
            guard !items.isEmpty else { continue }

            let content = UNMutableNotificationContent()
            content.title = items.count == 1 ? "1 for today" : "\(items.count) for today"
            let titles = items.prefix(4).map(\.title)
            content.body = items.count > 4
                ? titles.joined(separator: " · ") + " · and \(items.count - 4) more"
                : titles.joined(separator: " · ")
            content.sound = .default
            content.threadIdentifier = "dayflow-morning"

            let request = UNNotificationRequest(identifier: identifier(for: day),
                                                content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(request)
        }
    }
}
