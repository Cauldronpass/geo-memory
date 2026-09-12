//  DayflowQuickIntents.swift
//  Dayflow
//
//  Three actions Shortcuts can call, so the Action Button can add a task, put
//  an event in an open slot, or write a line into today's note without Dayflow
//  ever coming to the front.
//
//  **Why these are in the app target and CheckInIntent is not.** That one lives
//  in DayflowWidget because its work is done entirely in the widget process
//  against the App Group. These three write to EventKit and to the iCloud note
//  store through the app's own singletons, and those are the app's. An intent
//  in the app target runs the app in the background without showing it, which
//  is exactly the behaviour the Action Button needs.
//
//  **`openAppWhenRun` is false on all three, and that is the point.** Bringing
//  Dayflow to the front to add a task is a slower version of opening Dayflow.
//
//  **Every one of them can fail for a reason the person can act on** — no
//  Reminders access, no Calendar access, no default calendar, iCloud not
//  linked — so each returns a dialog saying which, rather than reporting a
//  silent success. An Action Button press with no visible outcome is
//  indistinguishable from a broken one (the note CheckInIntent already makes).

import AppIntents
import Foundation

// MARK: - Errors

enum DayflowIntentError: Error, CustomLocalizedStringResourceConvertible {
    case remindersRefused
    case calendarRefused
    case noteStoreUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .remindersRefused:
            return "Dayflow could not save the task. Check Reminders access in iOS Settings."
        case .calendarRefused:
            return "Dayflow could not save the event. Check Calendar access in iOS Settings and your Default Calendar in Dayflow Settings."
        case .noteStoreUnavailable:
            return "Dayflow could not reach your notes. iCloud Drive may still be loading."
        }
    }
}

// MARK: - Add a task

/// **The list is chosen by the store's own rule, not by this file.** Passing
/// `list: nil` lands an undated task in the Inbox and lets a dated one graduate
/// to Personal, which is D262 and D225 exactly as `addTask` already implements
/// them. Naming a list here would be a second place deciding where a capture
/// goes, and the two would disagree the first time either changed.
struct AddDayflowTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Task"
    static var description = IntentDescription(
        "Opens the task card: a list, a when, and the name asked at the end. Work sends straight to Todoist."
    )
    static var openAppWhenRun: Bool = false

    /// Optional (D368). Supplied, the task is filed straight away with whatever
    /// the other parameters say and the card opens on the confirmation — so a
    /// shortcut that already knows the title still takes one press. Left empty,
    /// the card asks at the end, which is the Action Button case.
    @Parameter(title: "Task")
    var taskTitle: String?

    @Parameter(title: "Day")
    var day: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Add a task") {
            \.$taskTitle
            \.$day
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        let draft = DayflowTaskDraft.shared
        draft.reset()
        draft.finished = false
        if let day { draft.when = .on(day) }
        draft.applyRules(changed: "")

        if let taskTitle, !taskTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            await draft.save(title: taskTitle)
        }
        return .result(snippetIntent: DayflowTaskSnippetIntent())
    }
}

// MARK: - Reading the day

/// The day's blocks, and two ways of printing a time.
///
/// **Deleted by accident and restored here (D371).** A range replace that
/// rewrote the task action ran from that struct to the next `MARK`, and this
/// enum was sitting between them. Nothing complained at the time because
/// nothing in this file used it — every caller is in `DayflowEventSnippet.swift`
/// — so the damage was a file away from the edit that caused it.
///
/// The exclusions are `CalendarService`'s own: all-day events dropped, and the
/// placeholder titles it filters at source, `rehab` among them — which is why a
/// placeholder's hour reads as free rather than as a meeting.
enum DayflowOpenSlotFinder {

    private static let windowEnd = 22 * 60

    /// `nonisolated`, both of them. They are pure string formatting called from
    /// view bodies, and under this project's default main-actor isolation an
    /// unmarked static is main-actor bound — which is the warning Xcode raised
    /// against `label(start:minutes:)` before this file was cleaned up.
    nonisolated static func label(start: Int, minutes: Int) -> String {
        "\(clock(start)) to \(clock(start + minutes))"
    }

    nonisolated static func clock(_ m: Int) -> String {
        var comps = DateComponents()
        comps.hour = m / 60
        comps.minute = m % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }

    /// The day's commitments as (start, end, title), minutes from midnight.
    @MainActor
    static func busyBlocks(on day: Date) async -> [(start: Int, end: Int, title: String)] {
        let cal = Calendar.current
        let events = await CalendarService.shared.fetchDayEvents(for: day)
        return events
            .filter { !$0.isAllDay }
            .filter { !CalendarService.isExcludedPlaceholderTitle($0.title) }
            .map { ev in
                let s = cal.component(.hour, from: ev.startDate) * 60
                      + cal.component(.minute, from: ev.startDate)
                let e = cal.component(.hour, from: ev.endDate) * 60
                      + cal.component(.minute, from: ev.endDate)
                // An event ending past midnight comes back with an end earlier
                // than its start once both are reduced to minutes of a day.
                // Treated as running to the end of the window, because the
                // alternative is a negative block that blocks nothing.
                return (s, e <= s ? windowEnd : e, ev.title)
            }
            .sorted { $0.0 < $1.0 }
    }
}

// MARK: - Add an event

struct AddDayflowEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Show My Day"
    static var description = IntentDescription(
        "Opens the day as a card: what is booked, how long the gaps between them are, and a way to put something in one."
    )
    static var openAppWhenRun: Bool = false

    /// Optional, and that is the change (D365). The action used to ask what the
    /// event was before showing anything, which made it impossible to press the
    /// button simply to look at Wednesday. Supplied, it skips the question at the
    /// end; left empty, the card asks once he has chosen where it goes.
    @Parameter(title: "Event")
    var eventTitle: String?

    @Parameter(title: "Day")
    var day: Date?

    @Parameter(title: "Length in minutes", default: 60)
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Show my day") {
            \.$day
            \.$eventTitle
            \.$minutes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        let draft = DayflowEventDraft.shared
        draft.minutes = minutes
        draft.title = eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        draft.justAdded = nil
        await draft.load(day: day ?? Date())
        return .result(snippetIntent: DayflowEventSnippetIntent())
    }
}

// MARK: - Add to today's note

/// **Appends to the PROSE, never to the end of the file.** A daily note is
/// `# yyyy-MM-dd`, then what he wrote, then an optional `## Related Notes`
/// table that `DayflowDailyNoteEditor` owns and reassembles on every save. A
/// line appended after that table would survive exactly until the next time he
/// opened the note in Dayflow, which is the worst shape a bug can have: it
/// works when you test it and loses the capture later, silently.
struct AddDayflowNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Today's Note"
    static var description = IntentDescription("Writes a line into today's daily note in Dayflow.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Note", requestValueDialog: "What do you want to note?")
    var text: String

    /// Defaults to today. Present so the same action can catch up yesterday.
    @Parameter(title: "Day")
    var day: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Note \(\.$text)") {
            \.$day
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw DayflowIntentError.noteStoreUnavailable }

        let target = day ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let dateStr = f.string(from: target)
        let path = "Calendar/\(dateStr).md"

        let existing = (try? NoteStore.shared.readFile(path)) ?? ""
        let updated = DayflowDailyNoteAppend.appending(line, to: existing, dateStr: dateStr)
        do {
            try NoteStore.shared.writeFile(path, content: updated)
        } catch {
            throw DayflowIntentError.noteStoreUnavailable
        }
        return .result(dialog: "Added to \(dateStr).")
    }
}

/// The insertion rule, on its own so it can be reasoned about without a note
/// store, a calendar or an intent in the way.
enum DayflowDailyNoteAppend {

    static let relatedHeader = "## Related Notes"

    /// Returns the note with `line` added at the end of the prose.
    ///
    /// Creates the file's `# yyyy-MM-dd` header when there is nothing there
    /// yet, because a capture made on a day he has not opened still has to
    /// land somewhere readable — and an untitled daily note is one the editor
    /// would rebuild a header onto anyway.
    static func appending(_ line: String, to existing: String, dateStr: String) -> String {
        let body = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return "# \(dateStr)\n\n\(line)"
        }

        var lines = body.components(separatedBy: "\n")
        let tableStart = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == relatedHeader }

        guard let tableStart else {
            return body + "\n\n" + line
        }

        // Back up over the blank lines that separate prose from the table, so
        // the new line joins the prose rather than opening a gap in front of a
        // heading.
        var insertAt = tableStart
        while insertAt > 0, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertAt -= 1
        }
        lines.insert(contentsOf: ["", line, ""], at: insertAt)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Siri phrases

/// The three actions also appear in the Shortcuts app without this — any
/// `AppIntent` in the app target does. This is only what makes them sayable
/// and what puts them in the Shortcuts gallery under Dayflow.
struct DayflowAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddDayflowTaskIntent(),
            phrases: ["Add a task to \(.applicationName)"],
            shortTitle: "Add a Task",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: AddDayflowEventIntent(),
            phrases: ["Show my day in \(.applicationName)"],
            shortTitle: "Show My Day",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: DayflowSearchIntent(),
            phrases: ["Search \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: AddDayflowNoteIntent(),
            phrases: ["Add a note to \(.applicationName)"],
            shortTitle: "Add to Today's Note",
            systemImageName: "square.and.pencil"
        )
    }
}
