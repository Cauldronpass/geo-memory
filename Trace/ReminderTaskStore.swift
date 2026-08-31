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
import WidgetKit
import Observation

@MainActor
@Observable
final class ReminderTaskStore {

    static let shared = ReminderTaskStore()

    /// Where typed tasks go. Created on first write if missing. The Trace list
    /// (`ReminderService.listName`) is what the apps write to.
    static let personalListName = "Personal"
    /// The Inbox's dateless way out (Session 78): "not now" without a fake
    /// date. A real Reminders list — the only structure EventKit exposes
    /// (tags/flags/sections are private to Apple's app) — so it reads
    /// identically in both apps and survives sync.
    static let somedayListName = "Someday"
    /// Option three (D158, 2026-08-29): capture gets its OWN list. The Inbox
    /// queue reads from here; Personal returns to being a topic, and with
    /// the other topical lists it IS the Anytime pool (Things' model, on
    /// Reminders' one exposed structure).
    static let inboxListName = "Inbox"

    /// **Lists that cannot hold a date** (D210, extended Session 80).
    ///
    /// Inbox means no decision about WHEN has been made; Someday means the
    /// decision was NOT NOW. A due date is a when-decision, so a task in either
    /// list holding one asserts two contradictory things and lands in no pool
    /// at all — it shows on Today wearing an INBOX label and appears in neither
    /// the Inbox tab nor Someday.
    ///
    /// One definition because this is now enforced in FOUR places —
    /// `update(taskID:)`, `moveToSomeday`, `uncomplete` and `addTask` — and
    /// four copies of a predicate is three chances to change one and miss the
    /// others. Every path that can write a reminder checks it, including the
    /// ones that write `EKReminder` directly and never pass through `update`.
    /// That is what it takes for an invariant to actually hold: not a rule the
    /// callers follow, a rule none of them can break.
    static func listRefusesDates(_ name: String?) -> Bool {
        guard let name else { return false }
        return name == inboxListName || name == somedayListName
    }

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
    /// Every open task, all lists, dated or not — Quick Find's literal task
    /// search and the per-list screens read this (Session 78).
    private(set) var allTasks: [ThingsTask] = []
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
        // Anytime = the active undated pool: every topical list, EXCLUDING
        // the capture Inbox (undecided) and Someday (cold storage).
        anytimeTasks = all.filter {
            $0.date == nil
                && $0.list != Self.inboxListName
                && $0.list != Self.somedayListName
        }
        inboxTasks = all.filter { $0.date == nil && $0.list == Self.inboxListName }
        allTasks = all
        inboxCount = inboxTasks.count
        totalCount = all.count
        lastFetched = Date()
        lastError = nil
        // Session 78 — the tasks widget mirrors this store; any applied
        // change refreshes it (WidgetKit coalesces, so per-apply is cheap).
        WidgetCenter.shared.reloadTimelines(ofKind: "DayflowTasksWidget")
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

    /// Completed reminders across a RANGE — the Logbook (Session 80).
    ///
    /// **The window is the API, not a simplification.** EventKit's
    /// `predicateForCompletedReminders` demands both ends; there is no "show me
    /// everything I have ever finished". So the Logbook is necessarily a
    /// window, and the only real decision is how wide.
    ///
    /// 90 days, because the two things a logbook is actually for both live
    /// inside it: proving to yourself you did something recently, and undoing a
    /// tick you did not mean. Neither is a question anyone asks about last
    /// spring, and a year of completed reminders is a slow query for rows
    /// nobody reads.
    ///
    /// Separate from `fetchIncomplete`'s single predicate because completed
    /// reminders are outside it by definition — same reason `fetchCompleted(on:)`
    /// is separate, and that one stays: the Today card's "n done" foot wants
    /// exactly one day and should not pay for ninety.
    func fetchCompleted(from start: Date, to end: Date) async -> [ThingsTask] {
        guard await ensureAccess() else { return [] }
        let predicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: start, ending: end, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        // Most recently finished first. `order(_:_:)` sorts by DUE date, which
        // is the wrong axis here: a logbook is a record of when you did things,
        // not of when they were meant to happen.
        return reminders
            .map(Self.task(from:))
            .sorted { ($0.completedDateString ?? "") > ($1.completedDateString ?? "") }
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
        // **The path D210 missed.** David: "i went to logbook again and
        // unchecked a task called pick up meds which was scheduled today
        // originally. it landed in today again so not in the inbox."
        //
        // It was an Inbox task carrying a date — a record created before the
        // rule existed. `uncomplete` writes the reminder directly and never
        // passes through `update(taskID:)`, so the stale date came back with
        // it and the task returned to being in no pool.
        //
        // Enforcing here also repairs legacy records at the moment they become
        // visible again, which is the only moment anyone would notice them. A
        // migration pass would be the alternative and is not worth it: the set
        // is small, and a reopen is exactly when the question "where does this
        // belong now" is being asked anyway.
        //
        // Deliberately narrow: reopening a PERSONAL task dated Friday keeps
        // Friday. Only the two lists that refuse dates shed them.
        if Self.listRefusesDates(reminder.calendar?.title) {
            reminder.dueDateComponents = nil
            reminder.alarms = nil
        }
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
    /// `remindAt` (Session 80): capture can now carry a time. "Call the Wrigley
    /// office tomorrow at 3pm" parses to a due DAY plus an alarm, and until now
    /// there was no way to set the second one at creation — you had to add the
    /// task and then open it, which is exactly the friction natural-language
    /// capture exists to remove.
    ///
    /// Additive with a default, so every existing call site is unchanged. The
    /// same-day rule matches `update(taskID:)`: an alarm on the due day puts
    /// the time ON the due date (Reminders then shows "Tuesday 3:00 PM"), while
    /// a lead-time alarm leaves the due date day-only.
    func addTask(title: String, toToday: Bool = false, date: Date? = nil,
                 list: String? = nil, notes: String? = nil,
                 remindAt: Date? = nil) async -> Bool {
        guard await ensureAccess() else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let notes, !notes.isEmpty { reminder.notes = notes }
        // Inbox and Someday are created on first use; anything else must
        // already exist or the task falls back to Personal.
        reminder.calendar = list.flatMap { name in
            (name == Self.inboxListName || name == Self.somedayListName)
                ? ensureList(named: name)
                : calendar(named: name)
        } ?? personalList()
        // Capture can name both a list and a date — the composer has a list
        // menu and the parser reads "friday" off the end of the line — so this
        // is the fourth path that could mint an incoherent record.
        let refuses = Self.listRefusesDates(reminder.calendar?.title)
        let due = refuses ? nil : (toToday ? Calendar.current.startOfDay(for: Date()) : date)
        let remindAt = refuses ? nil : remindAt
        if let due {
            let cal = Calendar.current
            if let remindAt, cal.isDate(remindAt, inSameDayAs: due) {
                reminder.dueDateComponents = cal.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: remindAt)
            } else {
                reminder.dueDateComponents = Self.components(due)
            }
            if let remindAt { reminder.alarms = [EKAlarm(absoluteDate: remindAt)] }
        }
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
    /// The reminder's alarm, for seeding the edit sheet (Session 78 — the
    /// sheet grew a Reminder section; ThingsTask only carries the display
    /// string).
    func remindDate(taskID: String) -> Date? {
        guard let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return nil }
        return reminder.alarms?.compactMap(\.absoluteDate).first
    }

    func update(taskID: String, title: String, date: Date?, clearDate: Bool,
                list: String?, notes: String? = nil, remindAt: Date? = nil,
                clearRemind: Bool = false) async -> Bool {
        guard await ensureAccess(),
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return false }
        reminder.title = title
        // **Inbox and Someday cannot hold a date, whatever the caller passed.**
        //
        // Session 80. David reopened a completed task, it landed on Today
        // because it still carried an old date, he moved it to Inbox to
        // re-triage it — and it vanished. It was still on Today and NOT in the
        // Inbox tab, because that tab is `date == nil && list == Inbox`.
        //
        // The tab filter was not the bug. The bug is that a task was allowed to
        // hold two contradictory statements at once: "Inbox" means no decision
        // about WHEN has been made (D158), "Someday" means the decision was NOT
        // NOW, and a due date is a when-decision. A record that says both is
        // incoherent, and the incoherence surfaced as a task that existed in
        // neither place he looked.
        //
        // Enforced HERE rather than at the call sites, on the same principle as
        // the placeholder filter in `CalendarService`: three call sites across
        // two apps already move tasks between lists, and a rule that each one
        // has to remember is a rule that gets forgotten by the fourth.
        let destinationRefusesDates = Self.listRefusesDates(list)
        let clearDate = clearDate || destinationRefusesDates
        let date = destinationRefusesDates ? nil : date
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
        } else if clearRemind, let date {
            // Session 78 — the edit sheet's Reminder toggle switched OFF:
            // drop the alarm, keep the due day (day-only, shedding any
            // alarm-carried time).
            reminder.alarms = nil
            reminder.dueDateComponents = Self.components(date)
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

    // MARK: - Repeats (Session 78 — David's Monarch case: "There is no way
    // to add repeat to the task"; until now repeats could only be set in
    // Apple's Reminders)

    enum DayflowRepeatRule: Equatable, CaseIterable {
        case none, daily, everyTwoDays, everyThreeDays, weekly, everyTwoWeeks, monthly, yearly

        var label: String {
            switch self {
            case .none: return "Never"
            case .daily: return "Daily"
            case .everyTwoDays: return "Every 2 Days"
            case .everyThreeDays: return "Every 3 Days"
            case .weekly: return "Weekly"
            case .everyTwoWeeks: return "Every 2 Weeks"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }

        var ekRule: EKRecurrenceRule? {
            switch self {
            case .none: return nil
            case .daily: return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
            case .everyTwoDays: return EKRecurrenceRule(recurrenceWith: .daily, interval: 2, end: nil)
            case .everyThreeDays: return EKRecurrenceRule(recurrenceWith: .daily, interval: 3, end: nil)
            case .weekly: return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
            case .everyTwoWeeks: return EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
            case .monthly: return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
            case .yearly: return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
            }
        }

        static func from(_ rule: EKRecurrenceRule?) -> DayflowRepeatRule {
            guard let rule else { return .none }
            switch (rule.frequency, rule.interval) {
            case (.daily, 1): return .daily
            case (.daily, 2): return .everyTwoDays
            case (.daily, 3): return .everyThreeDays
            case (.weekly, 1): return .weekly
            case (.weekly, 2): return .everyTwoWeeks
            case (.monthly, 1): return .monthly
            case (.yearly, 1): return .yearly
            // An exotic rule set in Apple's app maps to the nearest label the
            // menu offers; picking a menu item then REWRITES it — acceptable,
            // the menu is the whole vocabulary Dayflow speaks.
            case (.daily, _): return .everyThreeDays
            case (.weekly, _): return .everyTwoWeeks
            default: return .yearly
            }
        }
    }

    /// The current rule, for seeding the edit sheet.
    func repeatRule(taskID: String) -> DayflowRepeatRule {
        guard let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return .none }
        return DayflowRepeatRule.from(reminder.recurrenceRules?.first)
    }

    /// Replaces the reminder's recurrence with `rule`. A repeat needs a due
    /// date to anchor to — callers gate on that.
    func setRepeat(taskID: String, rule: DayflowRepeatRule) async -> Bool {
        guard await ensureAccess(),
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder else { return false }
        for existing in reminder.recurrenceRules ?? [] {
            reminder.removeRecurrenceRule(existing)
        }
        if let ek = rule.ekRule { reminder.addRecurrenceRule(ek) }
        do {
            try store.save(reminder, commit: true)
            await fetch()
            return true
        } catch {
            lastError = "Could not set the repeat. \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Birthday tasks (Session 78, D165)
    //
    // David: "This should be added to the task by the way automatically when
    // I add a birthday to a person record... it should land three days
    // before and... either that or the workflow is that two tasks are
    // created." Two tasks won: a heads-up three days ahead and the wish on
    // the day, both yearly repeats, created ONCE per person — no
    // completion-detection state machine, and it works even when a task is
    // checked off in Apple's Reminders where Dayflow can't see the tap.
    //
    // Dedupe is two-layer: a marker line in the reminder's notes
    // ("dayflow:birthday:<personID>:<kind>", scanned across every fetched
    // reminder — recurring reminders stay in the incomplete predicate after
    // completion), plus a UserDefaults ledger so a task David DELETED stays
    // deleted rather than resurrecting on the next sweep. Notes lead with
    // the person's [[wikilink]] — the person-chip round will render it.

    static let birthdayMarkerPrefix = "dayflow:birthday:"
    private static let birthdayLedgerKey = "dayflow_birthday_created"

    func ensureBirthdayTasks(for people: [Person]) async {
        guard !people.isEmpty, await ensureAccess() else { return }
        let defaults = UserDefaults.standard
        var ledger = Set(defaults.stringArray(forKey: Self.birthdayLedgerKey) ?? [])
        let ledgerBefore = ledger
        var markers = Set<String>()
        for reminder in await fetchIncomplete() ?? [] {
            guard let notes = reminder.notes else { continue }
            for line in notes.components(separatedBy: "\n")
            where line.hasPrefix(Self.birthdayMarkerPrefix) {
                markers.insert(line.trimmingCharacters(in: .whitespaces))
            }
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var saved = false
        for person in people where !person.isArchived {
            guard let birthday = person.birthday else { continue }
            let comps = cal.dateComponents([.month, .day], from: birthday)
            guard let month = comps.month, let day = comps.day else { continue }
            let plan: [(kind: String, title: String, offset: Int)] = [
                ("ahead", "\(person.name)'s birthday in three days", -3),
                ("day", "Wish \(person.name) a happy birthday", 0),
            ]
            for item in plan {
                let marker = Self.birthdayMarkerPrefix + person.id + ":" + item.kind
                let key = person.id + ":" + item.kind
                if markers.contains(marker) || ledger.contains(key) { continue }
                // Next FUTURE occurrence of (birthday + offset). If this
                // year's heads-up already passed but the birthday hasn't,
                // the heads-up starts next year — the day-of task covers
                // this year.
                var due: Date? = nil
                for yearAdd in 0...1 {
                    var c = DateComponents()
                    c.year = cal.component(.year, from: today) + yearAdd
                    c.month = month; c.day = day
                    if let b = cal.date(from: c),
                       let candidate = cal.date(byAdding: .day, value: item.offset, to: b),
                       cal.startOfDay(for: candidate) >= today {
                        due = cal.startOfDay(for: candidate)
                        break
                    }
                }
                guard let due else { continue }
                let reminder = EKReminder(eventStore: store)
                reminder.title = item.title
                reminder.notes = "[[\(person.name)]]\n" + marker
                reminder.calendar = personalList()
                reminder.dueDateComponents = Self.components(due)
                reminder.addRecurrenceRule(
                    EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil))
                do {
                    try store.save(reminder, commit: false)
                    saved = true
                    ledger.insert(key)
                } catch { continue }
            }
        }
        if saved {
            try? store.commit()
            await fetch()
        }
        if ledger != ledgerBefore {
            defaults.set(Array(ledger).sorted(), forKey: Self.birthdayLedgerKey)
        }
    }

    /// Moves a reminder to the Someday list, creating the list on first use.
    /// Leaves it undated — that is the point.
    @discardableResult
    func moveToSomeday(taskID: String) async -> Bool {
        guard await ensureAccess(),
              let reminder = store.calendarItem(withIdentifier: taskID) as? EKReminder,
              let list = ensureList(named: Self.somedayListName) else { return false }
        reminder.calendar = list
        // Someday means "not now", so it sheds the date and any alarm with it.
        // Same invariant `update(taskID:)` enforces; stated in both places
        // because this method writes the reminder directly and never goes
        // through it.
        reminder.dueDateComponents = nil
        reminder.alarms = nil
        do {
            try store.save(reminder, commit: true)
            await fetch()
            return true
        } catch {
            lastError = "Could not move the reminder. \(error.localizedDescription)"
            return false
        }
    }

    /// A named list, created if missing — same source-picking as
    /// `personalList()`.
    private func ensureList(named name: String) -> EKCalendar? {
        if let existing = calendar(named: name) { return existing }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = name
        cal.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .calDAV }
            ?? store.sources.first { $0.sourceType == .local }
        do { try store.saveCalendar(cal, commit: true); return cal }
        catch { return nil }
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
                          alarmTimeString: alarmString,
                          completedDateString: r.completionDate.map { dayFormatter.string(from: $0) })
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
