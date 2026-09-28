import AppIntents
import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Tell Trace, second round (D528)
//
// David, agreeing to all four at once: *"yes ok to build...build all three of
// those. I like the idea"* (with the day-note questions agreed a turn before).
// Four things, each a join of pieces the app already has:
//
//   1. "When did I order my R2?"          - answered from the day notes.
//   2. "What do I need at Target?"        - tasks tied to a place, plus tasks
//                                           that only MENTION it, shown apart.
//                                           No guessing (his call).
//   3. "Done with pick up the shirts."    - ticks a task off.
//   4. "Undo that."                       - reverses the last thing Tell Trace
//                                           did, after saying what it was.

// MARK: - Rows the card shows

struct TellTraceTaskRow: Hashable {
    let id: String
    let title: String
}

// MARK: - 4. Undo

/// The last thing Tell Trace (or one of its card buttons) changed, so "undo
/// that" can reverse exactly that and nothing else.
///
/// **Merged when steps land together.** Adding a place and checking in there is
/// two writes from one sentence; both go in one record so one "undo" takes back
/// both. A write within 20 seconds of the last one joins it.
///
/// Per device and per app by nature, so `UserDefaults.standard` (D503/D508's
/// reasoning): it is the running state of the app that did the thing.
enum TellTraceUndo {
    struct Record: Codable {
        var summary: String = ""
        var at: Date = Date()
        var taskID: String?          // a Reminders task it created
        var visitID: String?         // a check-in it logged
        var weekLogDate: Date?       // ...and the weekly log line that came with it
        var weekLogLine: String?
        var placeID: String?         // a place it CREATED (never one that already existed)
        var notePath: String?        // a line it appended to a day note
        var noteLine: String?
        var alarmPlaceID: String?    // an arrival reminder it switched ON
        var completedTaskID: String? // a task it ticked off
    }

    private static let key = "tell_trace_last_action"
    private static let joinWindow: TimeInterval = 20
    /// Older than this and "undo that" no longer means it.
    private static let staleAfter: TimeInterval = 24 * 3600

    static var last: Record? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let r = try? JSONDecoder().decode(Record.self, from: data),
              Date().timeIntervalSince(r.at) < staleAfter else { return nil }
        return r
    }

    /// Adds to the current record, or starts a new one.
    static func note(_ summary: String, _ change: (inout Record) -> Void) {
        var r: Record
        if let existing = last, Date().timeIntervalSince(existing.at) < joinWindow {
            r = existing
            r.summary = r.summary.isEmpty ? summary : r.summary + ", " + summary
        } else {
            r = Record()
            r.summary = summary
        }
        r.at = Date()
        change(&r)
        if let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Reverses the record. Returns what it did, in words.
    @MainActor
    static func undo(_ r: Record) async -> String {
        var done: [String] = []
        var failed: [String] = []
        let notion = NotionService.shared
        let tasks = ReminderTaskStore.shared

        if let id = r.taskID {
            if await tasks.remove(taskID: id) { done.append("removed the task") } else { failed.append("the task") }
        }
        if let id = r.completedTaskID {
            if await tasks.uncomplete(taskID: id) { done.append("reopened the task") } else { failed.append("reopening the task") }
        }
        if let id = r.visitID {
            do { try await notion.deleteVisit(id: id); done.append("removed the check-in") }
            catch { failed.append("the check-in") }
            if let date = r.weekLogDate, let line = r.weekLogLine {
                removeLastLine(line, from: NoteStore.weekPath(for: date))
            }
        }
        if let id = r.placeID, let place = (notion.places + notion.archivedPlaces).first(where: { $0.id == id }) {
            do { try await notion.deletePlace(place); done.append("removed \(place.name) from your places") }
            catch { failed.append("the place") }
        }
        if let path = r.notePath, let line = r.noteLine {
            if removeLastLine(line, from: path) { done.append("took the line out of the note") } else { failed.append("the note line") }
        }
        if let id = r.alarmPlaceID, DayflowPlaceAlarmStore.shared.isEnabled(id) {
            DayflowPlaceAlarmStore.shared.toggle(id)
            done.append("turned that arrival reminder back off")
        } else if r.taskID != nil {
            await tasks.refreshAll()
            await DayflowPlaceAlarms.reschedule()
        }
        clear()
        if done.isEmpty && failed.isEmpty { return "There was nothing left to undo." }
        var line = done.isEmpty ? "" : "Undone: " + done.joined(separator: ", ") + "."
        if !failed.isEmpty { line += (line.isEmpty ? "" : " ") + "Couldn't undo " + failed.joined(separator: " or ") + "." }
        return line
    }

    /// Removes the LAST occurrence of an exact line, leaving everything else.
    @discardableResult
    static func removeLastLine(_ line: String, from path: String) -> Bool {
        guard let raw = try? NoteStore.shared.readFile(path) else { return false }
        var lines = raw.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces)
                                                == line.trimmingCharacters(in: .whitespaces) }) else { return false }
        lines.remove(at: i)
        return (try? NoteStore.shared.writeFile(path, content: lines.joined(separator: "\n"))) != nil
    }
}

/// The card's "Undo" button: reverses exactly the record it was shown.
struct DayflowTellTraceUndoIntent: AppIntent {
    static var title: LocalizedStringResource = "Undo the Last Tell Trace Action"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let r = TellTraceUndo.last else { return .result(dialog: "There's nothing to undo.") }
        let line = await TellTraceUndo.undo(r)
        return .result(dialog: "\(line)")
    }
}

// MARK: - 3. Finish a task

enum TaskFinder {
    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    /// Filler that says nothing about WHICH task (D532).
    private static let filler: Set<String> = ["the", "a", "an", "my", "to", "of", "and", "for", "on", "in",
                                              "at", "it", "this", "that", "task", "todo", "i", "put"]

    private static func meaningful(_ s: String) -> [String] {
        normalized(s).split(separator: " ").map(String.init).filter { !filler.contains($0) && $0.count > 1 }
    }

    /// Open Reminders tasks matching spoken words - **not word for word** (D532).
    ///
    /// David: *"does it have to be exact word for word? I said I completed the
    /// medication into the pill box task. and it said nothing matched."* The
    /// title is "Put medication into pill box"; his "the" and missing "put"
    /// defeated both the exact and the all-words tests.
    ///
    /// Now: exact title first; otherwise each task is scored by how many of
    /// the spoken words that MATTER appear in its title (filler like "the",
    /// "my", "task" ignored; "pill box" also matches "pillbox"). The best task
    /// wins when it covers most of what was said and clearly beats the next;
    /// close scores come back together so he picks.
    @MainActor
    static func matches(_ spoken: String) async -> [ThingsTask] {
        let store = ReminderTaskStore.shared
        await store.refreshAll()
        let open = store.allTasks
        let key = normalized(spoken)
        guard !key.isEmpty else { return [] }
        let exact = open.filter { normalized($0.title) == key }
        if !exact.isEmpty { return exact }

        let words = meaningful(spoken)
        guard !words.isEmpty else { return [] }
        func score(_ t: ThingsTask) -> Double {
            let title = normalized(t.title)
            let squashed = title.replacingOccurrences(of: " ", with: "")
            let hit = words.filter { title.contains($0) || squashed.contains($0) }.count
            return Double(hit) / Double(words.count)
        }
        let scored = open.map { ($0, score($0)) }.filter { $0.1 >= 0.6 }.sorted { $0.1 > $1.1 }
        guard let top = scored.first else { return [] }
        // A clear winner, or everything close to it for him to choose from.
        let close = scored.filter { top.1 - $0.1 < 0.2 }
        return close.map { $0.0 }
    }

    /// Titles of tasks finished today that match - so "nothing matches" can
    /// say "already done" when that is the truth (D532).
    @MainActor
    static func alreadyDoneToday(_ spoken: String) async -> String? {
        let words = meaningful(spoken)
        guard !words.isEmpty else { return nil }
        let done = await ReminderTaskStore.shared.fetchCompleted(on: Date())
        return done.first { t in
            let title = normalized(t.title)
            let hit = words.filter { title.contains($0) }.count
            return Double(hit) / Double(words.count) >= 0.6
        }?.title
    }

    @MainActor
    static func complete(_ task: ThingsTask) async {
        await ReminderTaskStore.shared.complete(taskID: task.id)
        TellTraceUndo.note("ticked off \(task.title)") { $0.completedTaskID = task.id }
        await DayflowPlaceAlarms.reschedule()   // a done task stops ringing
    }
}

/// A "which one?" button for finishing a task.
struct DayflowTellTraceCompleteIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick Off a Task"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task ID") var taskID: String
    @Parameter(title: "Title") var taskTitle: String

    init() {}
    init(taskID: String, title: String) { self.taskID = taskID; self.taskTitle = title }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ReminderTaskStore.shared.complete(taskID: taskID)
        TellTraceUndo.note("ticked off \(taskTitle)") { $0.completedTaskID = taskID }
        await DayflowPlaceAlarms.reschedule()
        return .result(dialog: "Done: \(taskTitle).")
    }
}

// MARK: - 2. What do I need at a place

enum PlaceTasks {
    /// Tied tasks (notes carry `[[Place]]`) and tasks that only mention the
    /// place in their title or notes. Never a guess about what belongs there.
    @MainActor
    static func lookup(_ spoken: String) async -> (name: String, tied: [TellTraceTaskRow], mentions: [TellTraceTaskRow]) {
        var places = await DayflowCheckInAtIntent.matches(for: spoken)
        let key = DayflowCheckInAtIntent.coreName(spoken)
        let exact = places.filter { DayflowCheckInAtIntent.normalized($0.name) == key }
        if !exact.isEmpty { places = exact }
        let name = places.count == 1 ? places[0].name : spoken.trimmingCharacters(in: .whitespaces)

        let store = ReminderTaskStore.shared
        await store.refreshAll()
        let open = store.allTasks
        let tied = open.filter { ($0.notes ?? "").contains("[[\(name)]]") }
        let needle = name.lowercased()
        let mentions = open.filter { t in
            !tied.contains { $0.id == t.id }
                && (t.title.lowercased().contains(needle) || (t.notes ?? "").lowercased().contains(needle))
        }
        return (name, tied.map { TellTraceTaskRow(id: $0.id, title: $0.title) },
                mentions.map { TellTraceTaskRow(id: $0.id, title: $0.title) })
    }
}

// MARK: - 1. When did I ... (the day notes)

#if canImport(FoundationModels)
@Generable
struct TellTraceNotePick {
    @Guide(description: "The number of the one line that answers the question, or -1 if none of them actually answers it. A line that only mentions the subject without saying the thing asked about is not an answer.")
    var index: Int
}
#endif

enum DayNoteAnswer {
    struct Hit { let date: Date; let path: String; let line: String; let score: Int }

    private static let stop: Set<String> = [
        "when", "was", "it", "that", "did", "i", "my", "the", "a", "an", "to", "of", "for", "on",
        "in", "at", "is", "what", "day", "date", "do", "we", "me", "and", "or", "have", "has",
        "had", "last", "time", "ever", "about", "with"
    ]

    /// Words worth looking for. Two-letter words survive ("R2").
    static func keywords(_ text: String) -> [String] {
        TaskFinder.normalized(text).split(separator: " ").map(String.init)
            .filter { $0.count >= 2 && !stop.contains($0) }
    }

    /// Stems a verb loosely so "ordered" finds "order" and "ordering".
    private static func stem(_ w: String) -> String {
        for suf in ["ing", "ed", "es", "s"] where w.count > suf.count + 2 && w.hasSuffix(suf) {
            return String(w.dropLast(suf.count))
        }
        return w
    }

    @MainActor
    static func answer(_ question: String) async -> (line: String, path: String?) {
        let words = keywords(question)
        guard !words.isEmpty else { return ("I couldn't tell what to look for.", nil) }
        let stems = words.map(stem)
        let files = ((try? NoteStore.shared.listFiles(in: "Calendar")) ?? [])
            .filter { $0.hasSuffix(".md") }

        // Read off the main thread - a few hundred small files (the D465 rule).
        let hits: [Hit] = await Task.detached(priority: .userInitiated) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            var out: [Hit] = []
            for name in files {
                let stem = String(name.dropLast(3))
                guard let date = f.date(from: stem),
                      let raw = try? NoteStore.shared.readFile("Calendar/\(name)") else { continue }
                for line in raw.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !t.hasPrefix("#") else { continue }
                    let lower = t.lowercased()
                    let score = stems.filter { lower.contains($0) }.count
                    if score > 0 { out.append(Hit(date: date, path: "Calendar/\(name)", line: t, score: score)) }
                }
            }
            return out
        }.value

        guard let best = hits.map(\.score).max() else {
            return ("I didn't find that in your day notes.", nil)
        }
        // The strongest lines, earliest first: "when did I" is usually the first time.
        let top = hits.filter { $0.score == best }.sorted { $0.date < $1.date }.prefix(8)
        let candidates = Array(top)

        var chosen: Hit? = candidates.first
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability, candidates.count > 1 {
            let listing = candidates.enumerated()
                .map { "\($0.offset): [\($0.element.path.dropFirst(9).dropLast(3))] \($0.element.line)" }
                .joined(separator: "\n")
            let session = LanguageModelSession(instructions: """
                You pick which line from a person's own day notes answers their question. \
                You never invent anything; if no line answers it, you say -1.
                """)
            if let pick = try? await session.respond(
                to: "Question: \(question)\n\nLines:\n\(listing)",
                generating: TellTraceNotePick.self).content {
                chosen = (0..<candidates.count).contains(pick.index) ? candidates[pick.index] : nil
            }
        }
        #endif
        guard let hit = chosen else {
            return ("Your day notes mention it, but none of them says that. Try search to see them.", nil)
        }
        let day = hit.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        let quote = hit.line.count > 160 ? String(hit.line.prefix(157)) + "..." : hit.line
        return ("On \(day). From your day note: \u{201C}\(quote)\u{201D}", hit.path)
    }
}
