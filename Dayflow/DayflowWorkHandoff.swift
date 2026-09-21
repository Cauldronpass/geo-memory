// DayflowWorkHandoff.swift
// Dayflow — the host target of the one app (D452).
//
// D489, Session 109. Work means Todoist, from wherever you say it.
//
// ── The gap this closes ─────────────────────────────────────────────────────
//
// David, moving "Ask Mike about FLT" to Work in the task edit sheet and
// expecting the flow to run: it did not. The capture card on Today has known
// since D348 that Work is not a Reminders list — it sends to Todoist, writes
// `☑ <title> → Todoist` under `## Work Items` in the day note, and never
// creates a reminder at all. The edit sheet's list picker knew none of that.
// It read the live Reminders lists, saw a list called Work among them, and did
// what it does with any other name: moved the reminder.
//
// **Two screens, one word, two meanings.** On the card, Work is a destination
// off this phone. In the sheet, Work was a folder on it. Nothing was broken in
// either one; they had simply never been asked the same question.
//
// ── What the hand-off is, and why it is not the card's code ─────────────────
//
// The card CREATES: nothing exists yet, so a failed send leaves nothing behind
// (its own comment: "nothing lives in two systems"). The sheet MOVES something
// that already exists, so the hand-off is the Mac's three steps rather than the
// card's one - send it, write the day-note line, then tick off the reminder
// that is now somewhere else. `sendToTodoist` in `DayflowTaskCard` says this in
// passing already: *"The Mac's hand-off has to send, note, then tick off a
// reminder that already existed."*
//
// **Order matters and is not arbitrary.** Send first. Only once Todoist has
// taken it is the reminder completed, because a task ticked off here that
// never arrived there is gone from both places, and that is the one outcome
// this must never produce. The reverse - it arrives at Todoist and the tick
// fails - leaves a duplicate he can see and delete, which is recoverable.
//
// The day-note line lives here rather than in the card so there is ONE writer
// of that sentence. It was private to the card; a second copy in the sheet
// would be two versions of the same line, and the day note is the one place
// this family promises to say the same thing wherever a thing was captured.

import Foundation

enum DayflowWorkHandoff {

    /// The list name that means Todoist rather than a folder on this phone.
    ///
    /// A string, matched against the live Reminders list names, because that
    /// is what the edit sheet's picker offers. If David ever renames the list,
    /// this is the one line to change.
    static let listLabel = "Work"

    enum HandoffError: LocalizedError {
        case noToken
        var errorDescription: String? {
            "No Todoist token. Add one in Settings, Connections, then try again."
        }
    }

    /// `☑ <title> → Todoist` under `## Work Items` (D348, the glyph from D352).
    /// The same sentence the Mac writes, so the day note reads the same however
    /// the task was captured.
    static func logToDayNote(_ title: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let path = "\(NoteStore.dailyFolder)/\(f.string(from: Date())).md"
        let existing = (try? NoteStore.shared.readFile(path)) ?? ""
        let line = "\u{2611} \(title) → Todoist"
        guard !existing.contains(line) else { return }
        try? NoteStore.shared.writeFile(
            path,
            content: EndeavorFile.appending(line, under: "Work Items", in: existing))
    }

    /// Send an existing reminder to Todoist, log it, and tick it off here.
    ///
    /// Throws if the send failed, and in that case **nothing local has
    /// changed** — the reminder is still where it was and the day note is
    /// untouched, so trying again costs nothing and loses nothing.
    @MainActor
    static func handOff(taskID: String, title: String, notes: String?, due: Date?) async throws {
        guard TodoistKeyStore.hasKey else { throw HandoffError.noToken }
        _ = try await TodoistService.send(title: title, notes: notes, due: due)
        logToDayNote(title)
        await ReminderTaskStore.shared.complete(taskID: taskID)
    }
}
