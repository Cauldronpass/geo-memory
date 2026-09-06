//
//  DayflowTaskPools.swift
//  Dayflow
//
//  Session 89. What each pool IS, written once for the whole phone.
//
//  The Mac's Tasks room takes its three open pools straight off the store and
//  says why in its own comment: "No filtering invented here — a second opinion
//  in this file is how two screens start disagreeing about what Anytime
//  means." The phone now has two screens showing the same pools (the Tasks
//  room and the Quick Find card), so the same sentence needs somewhere to
//  live that is neither of them.
//
//  Nothing here is a new rule. Anytime and the Inbox are the store's own
//  arrays; Someday is the one filter the store does not publish, and it was
//  already written identically in two places before this file existed.
//
//  ── The order keys ──────────────────────────────────────────────────────
//
//  Undated rows are drag-reorderable and the order is persisted under a
//  string key. Two screens showing one pool under two different keys would
//  each remember a different order for the same tasks, and neither would look
//  broken. The keys are constants here for that reason, not for tidiness.
//

import Foundation

enum DayflowTaskPools {

    /// How far back the Logbook looks.
    ///
    /// **Not a choice about how much to show.** EventKit's
    /// `predicateForCompletedReminders` demands BOTH ends of a window, so
    /// "everything I have ever finished" is not a question that can be asked.
    /// The window is the API. 90 days matches the Mac's room, and the two
    /// things a logbook is for — proving to yourself you did something
    /// recently, and undoing a tick you did not mean — both live inside it.
    static let logbookDays = 90

    private static var store: ReminderTaskStore { .shared }

    // MARK: - The pools

    /// Undated, in the Inbox list. Captured, no decision made yet (D158).
    static var inbox: [ThingsTask] { store.inboxTasks }

    /// Undated, in a topical list. WHERE decided, WHEN not (D262).
    static var anytime: [ThingsTask] { store.anytimeTasks }

    /// Undated, in Someday. Decided NOT NOW.
    ///
    /// The one pool the store does not publish as an array. It was written
    /// out longhand in `TraceMacTasksView` and again in Quick Find's browse
    /// count before this file; it is written once now.
    static var someday: [ThingsTask] {
        store.allTasks.filter {
            $0.date == nil && $0.list == ReminderTaskStore.somedayListName
        }
    }

    // MARK: - The lists

    /// Lists offered as browse rows: every real list except the two that are
    /// decision states wearing a list's clothes.
    ///
    /// Inbox and Someday are implemented as Reminders lists only because
    /// EventKit exposes no tags or flags (D158). Showing them here would show
    /// the workaround to David as though it were the model — the Mac's rail
    /// makes the same exclusion for the same reason.
    static var browseLists: [String] {
        store.listNames.filter {
            $0 != ReminderTaskStore.inboxListName
                && $0 != ReminderTaskStore.somedayListName
        }
    }

    /// Open tasks in a list, dated and undated. Completed rows are the
    /// Logbook's business and are not in `allTasks` at all.
    static func openCount(in list: String) -> Int {
        store.allTasks.filter { $0.list == list }.count
    }

    /// A list, whole, in three buckets — the Mac room's `listRows` split.
    ///
    /// Overdue is its OWN bucket rather than the front of Scheduled. A date
    /// that has passed is the one thing on this screen that wants doing
    /// today, and burying it under a heading that says "Scheduled" is the
    /// screen declining to say so.
    static func buckets(for list: String,
                        now: Date = Date()) -> (overdue: [ThingsTask],
                                                scheduled: [ThingsTask],
                                                undated: [ThingsTask]) {
        let today = Calendar.current.startOfDay(for: now)
        let all = store.allTasks.filter { task in task.list == list }
        let overdue = all.filter { task in
            guard let due = task.date else { return false }
            return due < today
        }.sorted { lhs, rhs in lhs.date! < rhs.date! }
        let scheduled = all.filter { task in
            guard let due = task.date else { return false }
            return due >= today
        }.sorted { lhs, rhs in lhs.date! < rhs.date! }
        let undated = all.filter { task in task.date == nil }
        return (overdue, scheduled, undated)
    }

    // MARK: - Order keys

    static let anytimeOrderKey = "anytime"
    static func orderKey(forList list: String) -> String { "list-" + list }
}
