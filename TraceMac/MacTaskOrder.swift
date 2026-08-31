// MacTaskOrder.swift
// A hand-arranged order for one day's tasks. Mac-only, on this Mac only.
//
// Session 80 (2026-08-31). David: "drag the order of the tasks in today as
// well."
//
// ── Why this file exists at all ──────────────────────────────────────────
//
// **EventKit has no writable ordering.** Apple's own Reminders app arranges a
// list by hand and keeps that arrangement in a private field; `EKReminder`
// exposes nothing. `ReminderTaskStore.order(_:_:)` has said so since it was
// written: *"Reminders' own order within a list is manual and not worth
// carrying."*
//
// So there is nothing to drag INTO. A manual order has to be something this app
// invents and stores itself, and the only question was where.
//
// ── Local, and David chose it knowing the cost ───────────────────────────
//
// Three options were on the table:
//
//   * **Here** — `UserDefaults`, per day. Simple, fast, nothing to sync and no
//     format to break. Mac-only: the phone shows date-then-title while this Mac
//     shows the arrangement.
//   * **In the reminder's notes** — syncs everywhere, and pollutes a field the
//     user reads, that Apple's Reminders shows, and that `noteProse` already
//     has to filter machinery out of. Argued against and not taken.
//   * **iCloud key-value store** — syncs the order without touching the data,
//     and adds a sync surface that can disagree with itself.
//
// The local one is defensible because of what this order IS: day-scoped and
// ephemeral. "The order I want to work through today" is a fact about a
// morning, not about a task, and it stops mattering by evening. The phone
// having its own sensible order is arguably right rather than a gap.
//
// The upgrade path is in Trace-Backlog.md. This type is the seam: every reader
// goes through `apply(_:dayKey:)` and every writer through `save(_:for:)`, so
// moving the storage means changing two function bodies and nothing else.
//
// ── What it deliberately does not do ─────────────────────────────────────
//
// It stores IDS, not positions, and it never becomes the source of truth for
// which tasks exist. `apply` takes the store's list and rearranges it: a task
// deleted elsewhere simply stops appearing, and one that arrives without a
// stored position goes to the end rather than being dropped. A view that
// trusted a stale id list would show a task that is gone, which is the failure
// mode this shape makes impossible.

import Foundation

enum MacTaskOrder {

    private static let prefix = "tracemac.taskOrder."

    /// How long an arrangement is worth keeping. Sixty days is well past the
    /// point where anyone reopens a day to check the order they worked in, and
    /// it stops one key per day accumulating for the life of the app.
    private static let keepDays = 60

    private static func key(_ dayKey: String) -> String { prefix + dayKey }

    // MARK: - Reading

    /// The store's list, rearranged.
    ///
    /// Unknown tasks go to the END, in the store's own order. That is the
    /// predictable choice rather than the clever one: a task added after you
    /// arranged the day has no place in your arrangement, and guessing one
    /// would move things you had already put where you wanted them.
    static func apply(_ tasks: [ThingsTask], dayKey: String) -> [ThingsTask] {
        let order = UserDefaults.standard.stringArray(forKey: key(dayKey)) ?? []
        guard !order.isEmpty else { return tasks }

        var position: [String: Int] = [:]
        for (i, id) in order.enumerated() where position[id] == nil { position[id] = i }

        let placed = tasks.filter { position[$0.id] != nil }
            .sorted { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
        let rest = tasks.filter { position[$0.id] == nil }
        return placed + rest
    }

    // MARK: - Writing

    static func save(_ ids: [String], for dayKey: String) {
        UserDefaults.standard.set(ids, forKey: key(dayKey))
        prune()
    }

    /// Moves one task to where another one is, and returns the new order.
    ///
    /// Takes the CURRENT displayed list rather than the stored one, because the
    /// stored one may be empty (first drag of the day) or missing tasks added
    /// since. Writing back the full displayed order on every move means the
    /// stored list is always complete and always agrees with what he just saw.
    ///
    /// **The insertion side depends on the direction of travel**, and getting
    /// that wrong is why the first version could not move a task to the bottom.
    /// It always inserted BEFORE the target, so dragging B onto C in `[A, B, C]`
    /// removed B, found C at index 1, and put B back at index 1 — the same
    /// list. The last position was unreachable by dropping on the last row,
    /// which is exactly what David hit: "when i try and move the middle of a
    /// three task list to the bottom row it doesnt seem to want to do that."
    ///
    /// Moving DOWN lands after the target; moving UP lands before it. That is
    /// what every list on this platform does, and it is the only rule under
    /// which every position is reachable.
    @discardableResult
    static func move(_ dragged: String, toward target: String,
                     in shown: [ThingsTask], dayKey: String) -> [String] {
        var ids = shown.map(\.id)
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let targetWas = ids.firstIndex(of: target) else { return ids }
        let movingDown = from < targetWas
        ids.remove(at: from)
        // Recomputed after the removal: an index found before it is off by one
        // whenever the task is moving downward.
        guard let to = ids.firstIndex(of: target) else { return ids }
        ids.insert(dragged, at: movingDown ? to + 1 : to)
        save(ids, for: dayKey)
        return ids
    }

    // MARK: - Housekeeping

    /// Drops arrangements older than `keepDays`.
    ///
    /// Cheap and rare — it runs on a drag, not on a read. Keys are parsed back
    /// into dates rather than tracked separately, so there is no second list to
    /// fall out of step with the first.
    private static func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date())
        guard let cutoff else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"

        let defaults = UserDefaults.standard
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(prefix) {
            let dayKey = String(name.dropFirst(prefix.count))
            // An unparseable key is left alone. It is not ours to interpret,
            // and deleting keys we do not understand is how a cleanup routine
            // becomes a data-loss bug.
            guard let day = f.date(from: dayKey) else { continue }
            if day < cutoff { defaults.removeObject(forKey: name) }
        }
    }
}
