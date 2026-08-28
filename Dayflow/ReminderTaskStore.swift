// ReminderTaskStore.swift — personal tasks from Apple Reminders, via EventKit.
//
// 2026-08-27. Replaces `ThingsService` as the source behind the Agenda, Inbox,
// Anytime, Upcoming, Quick Add and the task edit sheet. David's decision after
// a walk through how he actually uses Things on the phone: *"I open it
// generally for inbox to process and today. Occasionally i will look at
// upcoming but thats the extent."* Reminders has those three built in and no
// Mac in the path. `Trace-Backlog.md` § "Personal task system — decided" has
// the full reasoning; `ThingsService.swift` stays compiled until the export is
// done and is referenced by nothing after this file lands.
//
// **Same API surface as `ThingsService`, on purpose.** Eleven screens read
// `tasks`, `inboxTasks`, `anytimeTasks`, `upcomingTasks`, call `fetch*`,
// `complete`, `addTask`, `update`. Keeping the names and the `ThingsTask`
// value type means the swap is a one-line change per screen and the UI is
// untouched. The UI pass that makes this a pleasure to use is a separate,
// deliberate step — David: *"An app that is annoying to look at and use will
// mean it will slowly die in my daily use cases."*
//
// **What the four lists mean here.** Things had structural Inbox / Anytime /
// Today / Upcoming. Reminders has lists and dates, nothing else, so:
//   tasks         — due today or overdue, any list
//   inboxTasks    — undated, in the Personal list (what he typed and has not
//                   decided about; Satchel and Trace write dated items to the
//                   Trace list, which never need "processing")
//   anytimeTasks  — undated, every list (the browse view)
//   upcomingTasks — dated after today, next 60 days
// Reads every list — David: no shared household lists, "looking at them all
// seems right." Completed reminders are never shown; Reminders keeps them.
//
// **One date.** A reminder's due date is the day it appears in Today. No start
// date, no alarm for a plain task; the phone shows Today without one. The
// 9am-alarm behaviour lives in `ReminderService` for documents and birthdays,
// which are nudges rather than a day's list.
//
// Refreshes on `EKEventStoreChanged`, so a reminder ticked in Apple's app, on
// the Watch, or by Siri disappears from the Agenda without a pull.

import Foundation
import EventKit
import Observation

@MainActor
@Observable
final class ReminderTaskStore {

    static let shared = ReminderTaskStore()

    /// Where typed tasks go. Created on first write if missing. The Trace list
    /// (`ReminderService.listName`) is what the apps write to.
    static let personalListName = "Personal"

    // MARK: - Published state (ThingsService-shaped)

    var tasks: [ThingsTask] = []
    var totalCount: Int = 0
    var inboxCount: Int = 0
    var isLoading = false
    private(set) var lastFetched: Date?
    private(set) var lastError: String?

    var anytimeTasks: [ThingsTask] = []
    var isLoadingAnytime = false
    var upcomingTasks: [ThingsTask] = []
    var isLoadingUpcoming = false
    var inboxTasks: [ThingsTask] = []
    var isLoadingInbox = false

    /// Kept for the edit sheet, which reads and clears it around `update`.
    /// Reminders is a local write, so nothing here ever sets it.
    var lastWriteMismatch: String? = nil

    /// Things' bridge could be unreachable, and the Agenda showed a cached list
    /// with an age. Reminders is on the device: never stale.
    var isShowingStaleTasks: Bool { false }
    var tasksAgeDescription: String? { nil }
    var shouldShow: Bool { true }

    /// Access to Reminders. `nil` until asked.
    private(set) var accessGranted: Bool?

    // MARK: - Private

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private static let upcomingWindowDays = 60

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    // MARK: - Access

    @discardableResult
    func ensureAccess() async -> Bool {
        if let accessGranted { return accessGranted }
        let granted: Bool
        if #available(iOS 17, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
            }
        }
        accessGranted = granted
        if !granted { lastError = "Dayflow does not have access to Reminders. Settings › Privacy › Reminders." }
        return granted
    }

    // MARK: - Fetching

    /// Everything, in one EventKit query. The four lists are views over one
    /// array, so one fetch fills all of them and they can never disagree.
    private func fetchIncomplete() async -> [EKReminder]? {
        guard await ensureAccess() else { return nil }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func apply(_ reminders: [EKReminder]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizon = cal.date(byAdding: .day, value: Self.upcomingWindowDays, to: today) ?? today

        let all = reminders.map(Self.task(from:)).sorted(by: Self.order)
        let dated = all.filter { $0.date != nil }
        tasks = dated.filter { $0.date! <= today }
        upcomingTasks = dated.filter { $0.date! > today && $0.date! <= horizon }
        anytimeTasks = all.filter { $0.date == nil }
        inboxTasks = anytimeTasks.filter { $0.list == Self.personalListName }
        inboxCount = inboxTasks.count
        totalCount = all.count
        lastFetched = Date()
        lastError = nil
    }

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        if let r = await fetchIncomplete() { apply(r) }
    }
    func fetchAnytime() async { isLoadingAnytime = true; defer { isLoadingAnytime = false }; await fetch() }
    func fetchUpcoming() async { isLoadingUpcoming = true; defer { isLoadingUpcoming = false }; await fetch() }
    func fetchInbox() async { isLoadingInbox = true; defer { isLoadingInbox = false }; await fetch() }
    func refreshAll() async { await fetch() }
    func refreshBrowseLists() async { await fetch() }

    // MARK: - Writes

    func complete(taskID: String) async {
        tasks.removeAll { $0.id == taskID }
        anytimeTasks.removeAll { $0.id == taskID }
        upcomingTasks.removeAll { $0.id == taskID }
        inboxTasks.removeAll { $0.id == taskID }
        inboxCount = inboxTasks.count
        totalCount = max(0, totalCount - 1)
        guard await ensureAccess(),
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return }
        reminder.isCompleted = true
        do { try store.save(reminder, commit: true) }
        catch { lastError = "Could not complete the reminder. \(error.localizedDescription)" }
    }

    /// Reminders completed on `day` — the Today card's "n done" foot
    /// (Session 77). A separate query, not part of `fetchIncomplete`'s single
    /// predicate, because completed reminders are outside it by definition.
    func fetchCompleted(on day: Date) async -> [ThingsTask] {
        guard await ensureAccess() else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: start, ending: end, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        return reminders.map(Self.task(from:)).sorted(by: Self.order)
    }

    /// Deletes a reminder outright — the Inbox's Delete choice (asks
    /// nothing, David's locked call in the task UI design). Distinct from
    /// `complete`: nothing lands in Reminders' Completed.
    @discardableResult
    func remove(taskID: String) async -> Bool {
        guard await ensureAccess(),
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return false }
        do {
            try store.remove(reminder, commit: true)
            await fetch()
            return true
        } catch {
            lastError = "Could not delete the reminder. \(error.localizedDescription)"
            return false
        }
    }

    /// Reopens a completed reminder — the "n done" list's tap-to-untick.
    @discardableResult
    func uncomplete(taskID: String) async -> Bool {
        guard await ensureAccess(),
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return false }
        reminder.isCompleted = false
        do {
            try store.save(reminder, commit: true)
            await fetch()
            return true
        } catch {
            lastError = "Could not reopen the reminder. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addTask(title: String, toToday: Bool = false, date: Date? = nil,
                 list: String? = nil, notes: String? = nil) async -> Bool {
        guard await ensureAccess() else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let notes, !notes.isEmpty { reminder.notes = notes }
        reminder.calendar = calendar(named: list) ?? personalList()
        let due = toToday ? Calendar.current.startOfDay(for: Date()) : date
        if let due { reminder.dueDateComponents = Self.components(due) }
        do {
            try store.save(reminder, commit: true)
            await fetch()
            return true
        } catch {
            lastError = "Could not add the reminder. \(error.localizedDescription)"
            return false
        }
    }

    /// `remindAt` (Session 77, the When card's REMIND toggle): a full
    /// date+time — the due date gains the time and an EKAlarm rings there,
    /// natively, app closed or not. Clearing the date clears the alarm. A
    /// day-only redate CARRIES an existing alarm's time-of-day to the new
    /// day, so a set reminder survives a plain When change.
    func update(taskID: String, title: String, date: Date?, clearDate: Bool,
                list: String?, notes: String? = nil, remindAt: Date? = nil) async -> Bool {
        guard await ensureAccess(),
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return false }
        reminder.title = title
        if clearDate {
            reminder.dueDateComponents = nil
            reminder.alarms = nil
        } else if let remindAt, let date {
            // The alarm may ring DAYS BEFORE the due day (David, 2026-08-28)
            // — a same-day alarm puts the time on the due date (Reminders
            // shows "Saturday 5:00 PM"); a lead-time alarm leaves the due
            // date day-only and rings on its own day. NOTE: the day-only
            // redate below carries an alarm's time to the NEW day — a
            // lead-time gap does not survive a plain redate; acceptable.
            let cal = Calendar.current
            if cal.isDate(remindAt, inSameDayAs: date) {
                reminder.dueDateComponents = cal.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: remindAt)
            } else {
                reminder.dueDateComponents = Self.components(date)
            }
            reminder.alarms = [EKAlarm(absoluteDate: remindAt)]
        } else if let date {
            let cal = Calendar.current
            if let existing = reminder.alarms?.compactMap(\.absoluteDate).first,
               let moved = cal.date(byAdding: cal.dateComponents([.hour, .minute], from: existing),
                                    to: cal.startOfDay(for: date)) {
                reminder.dueDateComponents = cal.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: moved)
                reminder.alarms = [EKAlarm(absoluteDate: moved)]
            } else {
                reminder.dueDateComponents = Self.components(date)
            }
        }
        if let list, !list.isEmpty, let cal = calendar(named: list) { reminder.calendar = cal }
        if let notes { reminder.notes = notes.isEmpty ? nil : notes }
        do {
            try store.save(reminder, commit: true)
            await fetch()
            return true
        } catch {
            lastError = "Could not save the reminder. \(error.localizedDescription)"
            return false
        }
    }

    /// Every list's name, for pickers. Personal first, Trace second, the rest
    /// alphabetical.
    var listNames: [String] {
        let names = store.calendars(for: .reminder).map(\.title)
        let pinned = [Self.personalListName, ReminderService.listName].filter { names.contains($0) }
        let rest = names.filter { !pinned.contains($0) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return pinned + rest
    }

    // MARK: - Helpers

    private func calendar(named name: String?) -> EKCalendar? {
        guard let name, !name.isEmpty else { return nil }
        return store.calendars(for: .reminder).first { $0.title == name }
    }

    /// The Personal list, made on first use so a typed task never lands in
    /// whatever Apple's default happens to be. Same reasoning as
    /// `ReminderService.targetList`.
    private func personalList() -> EKCalendar? {
        if let existing = calendar(named: Self.personalListName) { return existing }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = Self.personalListName
        cal.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .calDAV }
            ?? store.sources.first { $0.sourceType == .local }
        do { try store.saveCalendar(cal, commit: true); return cal }
        catch { return store.defaultCalendarForNewReminders() }
    }

    private static func components(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `ThingsTask` is the value the screens already draw. `id` is the
    /// `calendarItemIdentifier`, stable across launches and syncs.
    private static func task(from r: EKReminder) -> ThingsTask {
        var dateString: String? = nil
        if let comps = r.dueDateComponents, let d = Calendar.current.date(from: comps) {
            dateString = dayFormatter.string(from: Calendar.current.startOfDay(for: d))
        }
        let alarmString: String? = r.alarms?.compactMap(\.absoluteDate).first.map { alarmDate in
            let time = DateFormatter.localizedString(from: alarmDate, dateStyle: .none, timeStyle: .short)
            // A lead-time alarm rings on another day — say which ("Thu 5:00 PM").
            if let comps = r.dueDateComponents, let due = Calendar.current.date(from: comps),
               !Calendar.current.isDate(alarmDate, inSameDayAs: due) {
                let f = DateFormatter(); f.dateFormat = "EEE"
                return "\(f.string(from: alarmDate)) \(time)"
            }
            return time
        }
        return ThingsTask(id: r.calendarItemIdentifier,
                          title: r.title ?? "",
                          list: r.calendar?.title,
                          scheduledDateString: dateString,
                          notes: r.notes,
                          repeats: r.hasRecurrenceRules,
                          createdDateString: r.creationDate.map { dayFormatter.string(from: $0) },
                          alarmTimeString: alarmString)
    }

    /// Dated before undated, earlier first, then title. Reminders' own order
    /// within a list is manual and not worth carrying.
    private static func order(_ a: ThingsTask, _ b: ThingsTask) -> Bool {
        switch (a.date, b.date) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
