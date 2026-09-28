import AppIntents
import Foundation
import SwiftUI
import CoreLocation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Tell Trace (D523)
//
// David: *"Can the layer in shortcuts be more open ended"*, then *"Build it now.
// That's the preferred approach I was after."* One action that takes the whole
// sentence and decides what it is, so his Shortcut is two steps - Dictate Text,
// Tell Trace - and never changes as actions are added.
//
// **What it can do is exactly what already exists**, and nothing new is written
// here: check in at a named place (D522), open Check In on the nearby list
// (D521/D522), add a task (the task card's own save), add a line to today's note
// (the note intent's own append), and search (the search card).
//
// **Who decides.** The on-device model (Foundation Models) reads the sentence and
// fills a small typed form. If it is unavailable - no Apple Intelligence, still
// downloading - a handful of plain phrase rules stand in, so the common sentences
// still work. **When neither can tell, it says so and does nothing** (D398): a
// task filed as a note, or a check-in at the wrong place, is worse than a
// "I didn't understand".
//
// **Always one kind of answer:** a spoken line plus a card. The card is what
// lets a search show its results, an ambiguous place offer its choices as
// buttons, and "check in" with no place offer the button that opens Check In -
// all without the app coming forward unless he presses it.

/// What the card shows for the last request. Main-actor state read by the
/// snippet, the same arrangement `DayflowSearchDraft` uses for search.
@MainActor
final class TellTraceOutcome {
    static let shared = TellTraceOutcome()
    enum Kind { case message, search, choices([String]), newChoices([NewPlaceChoice], checkIn: Bool),
                reminderChoices(place: [String], task: String), nearby,
                taskList(tied: [TellTraceTaskRow], mentions: [TellTraceTaskRow], place: String),
                taskChoices([TellTraceTaskRow]), noteAnswer(path: String), undoOffer(String) }
    struct NewPlaceChoice: Hashable { let googleID: String; let name: String; let detail: String }
    var kind: Kind = .message
    var line: String = ""
    /// What the dictation handed over, shown when nothing was done (D529) -
    /// a misheard word is otherwise invisible.
    var heard: String = ""
    private init() {}
}

/// The typed form the model fills.
#if canImport(FoundationModels)
@Generable
struct TellTraceCommand {
    @Guide(description: "Exactly one of: checkin_place, add_place, place_reminder, checkin_nearby, history_last, history_day, history_count, notes_when, place_tasks, complete_task, undo, task, note, search, unknown. notes_when asks when they did or decided something that is not a place visit, answered from their daily notes (\"when did I order the car\"). place_tasks asks what they need or have to do at a named place. complete_task says a task is done, in any wording: 'done with X', 'I completed X', 'I finished the X task', 'X is done'. undo asks to reverse the last thing the app did. history_last asks when they were last at a named place. history_day asks where they went on a day. history_count asks how many times they went to a named place. place_reminder when they want to be reminded of something when they arrive at or get to a named place. checkin_place when the person names where they are checking in or says they are at a place. add_place when they want to add or save a place without checking in there. checkin_nearby when they want to check in but name no place. task for something to do. note for something to write down about today. search to find something they already have. unknown when none of these clearly fits.")
    var action: String
    @Guide(description: "For checkin_place, add_place, place_reminder, place_tasks, history_last and history_count: the place name as said, including any town they name, without words like 'at' or 'the'. Otherwise empty.")
    var place: String
    @Guide(description: "For notes_when: the question in the person's words. For complete_task: only the task's own words, without 'done with', 'I completed', 'I finished', 'is done' or a trailing 'task'. For history_day: the day asked about as YYYY-MM-DD, worked out from today's date given in the instructions. For history_count: exactly one of week, month, year, all - the period asked about, all if none. For place_reminder: only the thing to be reminded of, without the place or 'remind me'. For task: the task in the person's words, keeping any when-words like 'tomorrow' or 'Friday at 3'. For note: the line to write, in their words. For search: what to look for. Otherwise empty.")
    var text: String
}
#endif

struct TellTraceIntent: AppIntent {
    static var title: LocalizedStringResource = "Tell Trace"
    static var description = IntentDescription(
        "Say what you want in your own words: check in, add a task, add a note to today, or find something."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Request", requestValueDialog: "What do you want to do?")
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Trace \(\.$request)")
    }

    private struct Parsed { var action: String; var place: String; var text: String }

    /// Words that make a question about going somewhere, not doing something.
    private static func soundsLikeAVisit(_ said: String) -> Bool {
        let l = " " + said.lowercased() + " "
        let cues = [" last at ", " last in ", " was i at ", " was i in ", " been to ", " been at ", " go to ",
                    " went to ", " visit", " where did i ", " where was i ", " times ", " last there "]
        return cues.contains { l.contains($0) }
    }

    /// An action it can act on: known, and carrying the part it needs.
    private static func isUsable(_ p: Parsed) -> Bool {
        switch p.action {
        case "checkin_nearby", "undo": return true
        case "checkin_place", "add_place", "place_tasks", "history_last", "history_count": return !p.place.isEmpty
        case "place_reminder": return !p.place.isEmpty && !p.text.isEmpty
        case "task", "note", "search", "complete_task", "history_day": return !p.text.isEmpty
        case "notes_when": return true
        default: return false
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetIntent {
        let said = request.trimmingCharacters(in: .whitespacesAndNewlines)
        // D529: the model first, but its "unknown" (or an action missing the
        // part it needs) is not the last word - the phrase rules get a turn.
        // Build 101 answered a question the rules would have caught with
        // "I didn't understand that".
        var parsed = await Self.understand(said) ?? Self.rules(said)
        if !Self.isUsable(parsed) {
            let r = Self.rules(said)
            if Self.isUsable(r) { parsed = r }
        }
        // D531: a "when did I..." that is not about BEING somewhere is a
        // day-note question, whatever the model said. "When did I order my R2"
        // came back as history_last and answered "no visits recorded at R2".
        if parsed.action.hasPrefix("history_"), !Self.soundsLikeAVisit(said) {
            parsed = Parsed(action: "notes_when", place: "", text: said)
        }
        // The question itself is the best input for the day-note search.
        if parsed.action == "notes_when" { parsed.text = said }
        let outcome = TellTraceOutcome.shared
        outcome.kind = .message
        outcome.heard = said

        switch parsed.action {
        case "checkin_place" where !parsed.place.isEmpty:
            let candidates = await DayflowCheckInAtIntent.matches(for: parsed.place)
            if candidates.count == 1 {
                try await DayflowCheckInAtIntent.checkIn(at: candidates[0])
                outcome.line = "Checked in at \(candidates[0].name)."
            } else if candidates.count > 1 {
                outcome.kind = .choices(Array(candidates.prefix(5).map(\.name)))
                outcome.line = "More than one place matches \(parsed.place). Which one?"
            } else {
                // D524: not saved yet. Look for it around him and add it.
                switch await NewPlaceCheckIn.resolve(parsed.place, checkIn: true) {
                case .checkedIn(let name):
                    outcome.line = "Added \(name) to your places and checked in."
                case .choose(let options):
                    outcome.kind = .newChoices(options, checkIn: true)
                    outcome.line = "\(parsed.place) isn't in your places. Which of these is it?"
                case .failed(let why):
                    outcome.kind = .nearby
                    outcome.line = why
                }
            }

        case "add_place" where !parsed.place.isEmpty:
            // D525: add without a visit. Already saved: say so, add nothing.
            let saved = await DayflowCheckInAtIntent.matches(for: parsed.place)
            if let first = saved.first, saved.count == 1 {
                outcome.line = "\(first.name) is already in your places."
            } else {
                switch await NewPlaceCheckIn.resolve(parsed.place, checkIn: false) {
                case .checkedIn(let name):
                    outcome.line = "Added \(name) to your places."
                case .choose(let options):
                    outcome.kind = .newChoices(options, checkIn: false)
                    outcome.line = "Which \(parsed.place) do you want to add?"
                case .failed(let why):
                    outcome.line = why
                }
            }

        case "place_reminder" where !parsed.place.isEmpty && !parsed.text.isEmpty:
            let r = await PlaceReminder.file(parsed.text, at: parsed.place)
            outcome.line = r.line
            if let kind = r.kind { outcome.kind = kind }

        case "undo":
            if let r = TellTraceUndo.last {
                outcome.kind = .undoOffer(r.summary)
                outcome.line = "The last thing I did: \(r.summary). Undo it?"
            } else {
                outcome.line = "There's nothing recent to undo."
            }

        case "complete_task" where !parsed.text.isEmpty:
            let found = await TaskFinder.matches(parsed.text)
            if found.count == 1 {
                await TaskFinder.complete(found[0])
                outcome.line = "Done: \(found[0].title)."
            } else if found.count > 1 {
                outcome.kind = .taskChoices(found.prefix(5).map { TellTraceTaskRow(id: $0.id, title: $0.title) })
                outcome.line = "More than one task matches. Which one is done?"
            } else if let done = await TaskFinder.alreadyDoneToday(parsed.text) {
                outcome.line = "\(done) is already done today."
            } else {
                outcome.line = "No open task matches \(parsed.text)."
            }

        case "place_tasks" where !parsed.place.isEmpty:
            let r = await PlaceTasks.lookup(parsed.place)
            if r.tied.isEmpty && r.mentions.isEmpty {
                outcome.line = "Nothing open for \(r.name)."
            } else {
                outcome.kind = .taskList(tied: r.tied, mentions: r.mentions, place: r.name)
                let n = r.tied.count
                outcome.line = n == 0 ? "Nothing tied to \(r.name), but \(r.mentions.count) mention it."
                    : "\(n) for \(r.name)" + (r.mentions.isEmpty ? "." : ", and \(r.mentions.count) more that mention it.")
            }

        case "notes_when" where !parsed.text.isEmpty:
            let a = await DayNoteAnswer.answer(parsed.text)
            outcome.line = a.line
            if let path = a.path { outcome.kind = .noteAnswer(path: path) }

        case "history_last" where !parsed.place.isEmpty:
            let line = await VisitHistory.last(at: parsed.place)
            if line.hasPrefix("I have no visits") {
                // No visits: the day notes may still know (D531).
                let a = await DayNoteAnswer.answer(said)
                if let path = a.path {
                    outcome.line = a.line
                    outcome.kind = .noteAnswer(path: path)
                } else {
                    outcome.line = line
                }
            } else {
                outcome.line = line
            }
        case "history_count" where !parsed.place.isEmpty:
            outcome.line = await VisitHistory.count(at: parsed.place, period: parsed.text)
        case "history_day" where !parsed.text.isEmpty:
            outcome.line = await VisitHistory.day(parsed.text)

        case "checkin_place", "checkin_nearby":
            outcome.kind = .nearby
            outcome.line = "Open Check In to pick from your places and what's nearby."

        case "task" where !parsed.text.isEmpty:
            let draft = DayflowTaskDraft.shared
            draft.reset()
            draft.finished = false
            draft.applyRules(changed: "")
            await draft.save(title: parsed.text)
            if let failure = draft.failure {
                outcome.line = failure
            } else {
                if let id = draft.createdTaskID {
                    let t = parsed.text
                    TellTraceUndo.note("added the task \(t)") { $0.taskID = id }
                }
                outcome.line = "Added task: \(parsed.text)."
            }

        case "note" where !parsed.text.isEmpty:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            let dateStr = f.string(from: Date())
            let path = "Calendar/\(dateStr).md"
            let existing = (try? NoteStore.shared.readFile(path)) ?? ""
            let updated = DayflowDailyNoteAppend.appending(parsed.text, to: existing, dateStr: dateStr)
            do {
                try NoteStore.shared.writeFile(path, content: updated)
                let line = parsed.text
                TellTraceUndo.note("added a line to today's note") { $0.notePath = path; $0.noteLine = line }
                outcome.line = "Added to today's note."
            } catch {
                outcome.line = "Couldn't reach your notes. iCloud Drive may still be loading."
            }

        case "search" where !parsed.text.isEmpty:
            await DayflowSearchDraft.shared.run(term: parsed.text)
            outcome.kind = .search
            outcome.line = "Here's what matched \(parsed.text)."

        default:
            outcome.line = "I didn't understand that, so I did nothing. Try: check in at a place, add a task, note something, or find something."
        }

        // If this combination does not compile on this SDK, drop `dialog:` -
        // the card carries the same words.
        return .result(dialog: "\(outcome.line)",
                       snippetIntent: TellTraceSnippetIntent())
    }

    // MARK: Understanding

    /// The on-device model, when it is there. `nil` means "not available or it
    /// failed", and the rules take over.
    @MainActor
    private static func understand(_ said: String) async -> Parsed? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let today = Date().formatted(.dateTime.weekday(.wide).year().month().day())
            let iso = { () -> String in
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
            let session = LanguageModelSession(instructions: """
                You turn one spoken request into a command for a personal app. \
                Today is \(today) (\(iso)). \
                You never invent a place, a task or a note that was not said. \
                When the request does not clearly fit one action, the action is unknown.
                """)
            let reply = try await session.respond(to: said, generating: TellTraceCommand.self)
            let c = reply.content
            return Parsed(action: c.action.lowercased(),
                          place: c.place.trimmingCharacters(in: .whitespacesAndNewlines),
                          text: c.text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Plain phrase rules for when the model is not there. Deliberately few:
    /// they cover the sentences he will actually say, and anything else is
    /// `unknown` rather than a guess.
    private static func rules(_ said: String) -> Parsed {
        let lower = said.lowercased()
        func after(_ prefixes: [String]) -> String? {
            for p in prefixes where lower.hasPrefix(p) {
                return String(said.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        // D528
        let bare = lower.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        if ["undo", "undo that", "undo it", "cancel that", "take that back", "that was wrong"].contains(bare) {
            return Parsed(action: "undo", place: "", text: "")
        }
        // D530: David's own wording - "i completed put medication into pill box task".
        func taskWords(_ raw: String) -> String {
            var t = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". !"))
            for suffix in [" task", " to-do", " todo", " is done", " is finished", " is complete"]
                where t.lowercased().hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
            if t.lowercased().hasPrefix("the ") { t = String(t.dropFirst(4)) }
            return t.trimmingCharacters(in: .whitespaces)
        }
        if let task = after(["i'm done with ", "i am done with ", "done with ", "i finished ", "finished ",
                             "i completed ", "i've completed ", "i have completed ", "completed ", "complete ",
                             "i did ", "i've done ", "i have done ", "mark done ", "mark complete ",
                             "tick off ", "check off "]) {
            return Parsed(action: "complete_task", place: "", text: taskWords(task))
        }
        for suffix in [" is done", " is finished", " is complete"] where bare.hasSuffix(suffix) {
            return Parsed(action: "complete_task", place: "", text: taskWords(String(said.dropLast(suffix.count))))
        }
        if let place = after(["what do i need at ", "what do i need from ", "what do i have at ",
                              "what's on my list for ", "what do i need to do at "]) {
            return Parsed(action: "place_tasks", place: place.trimmingCharacters(in: CharacterSet(charactersIn: "? ")), text: "")
        }
        // History questions (D527), before everything else that starts similarly.
        if let place = after(["when was i last at ", "when was i last in ", "when did i last go to ",
                              "when was the last time i was at ", "when did i last visit "]) {
            return Parsed(action: "history_last", place: place.trimmingCharacters(in: CharacterSet(charactersIn: "?")), text: "")
        }
        if lower.hasPrefix("how many times"), let r = lower.range(of: #"(?: at | to | in )"#, options: .regularExpression) {
            var rest = String(Array(said)[lower.distance(from: lower.startIndex, to: r.upperBound)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "? "))
            var period = "all"
            for (phrase, p) in [(" this week", "week"), (" this month", "month"), (" this year", "year")]
                where rest.lowercased().hasSuffix(phrase) {
                rest = String(rest.dropLast(phrase.count)); period = p
            }
            return Parsed(action: "history_count", place: rest, text: period)
        }
        if lower.hasPrefix("where did i go") || lower.hasPrefix("where was i") {
            if let d = VisitHistory.detectDay(in: said) {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
                return Parsed(action: "history_day", place: "", text: f.string(from: d))
            }
        }
        if lower.hasPrefix("when did i ") || lower.hasPrefix("when was it that i ") || lower.hasPrefix("when was it i ")
            || lower.hasPrefix("when did we ") {
            return Parsed(action: "notes_when", place: "", text: said)
        }
        // "remind me at X to Y" / "when I get to X remind me to Y" (D526)
        for (lead, mid) in [("remind me at ", " to "), ("remind me when i get to ", " to "),
                            ("when i get to ", " remind me to "), ("at ", " remind me to ")] {
            // Offsets, not indices: an index from `lower` must not be used on `said`.
            if lower.hasPrefix(lead), said.count == lower.count,
               let r = lower.range(of: mid, range: lower.index(lower.startIndex, offsetBy: lead.count)..<lower.endIndex) {
                let a = lead.count
                let b = lower.distance(from: lower.startIndex, to: r.lowerBound)
                let c = lower.distance(from: lower.startIndex, to: r.upperBound)
                let chars = Array(said)
                let place = String(chars[a..<b]).trimmingCharacters(in: .whitespaces)
                let task = String(chars[c...]).trimmingCharacters(in: .whitespaces)
                if !place.isEmpty, !task.isEmpty {
                    return Parsed(action: "place_reminder", place: place, text: task)
                }
            }
        }
        if let place = after(["check me in at ", "check in at ", "checking in at ", "i'm at ", "i am at "]) {
            return Parsed(action: "checkin_place", place: place, text: "")
        }
        if let place = after(["add a place called ", "add a place ", "add place ", "save a place ", "save the place "]),
           !lower.hasPrefix("add a task"), !lower.hasPrefix("add a note"), !lower.hasPrefix("add to today") {
            return Parsed(action: "add_place", place: place, text: "")
        }
        if lower.hasPrefix("check in") || lower.hasPrefix("check me in") {
            return Parsed(action: "checkin_nearby", place: "", text: "")
        }
        if let task = after(["add a task to ", "add a task ", "add task ", "task ", "remind me to "]) {
            return Parsed(action: "task", place: "", text: task)
        }
        if let note = after(["note that ", "add a note ", "note ", "add to today's note "]) {
            return Parsed(action: "note", place: "", text: note)
        }
        if let term = after(["find ", "search for ", "search ", "look up "]) {
            return Parsed(action: "search", place: "", text: term)
        }
        return Parsed(action: "unknown", place: "", text: "")
    }
}

struct TellTraceSnippetIntent: SnippetIntent {
    static var title: LocalizedStringResource = "Tell Trace"

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: TellTraceCard(outcome: TellTraceOutcome.shared))
    }
}

struct TellTraceCard: View {
    let outcome: TellTraceOutcome

    /// One open task with a tick button (D528).
    private func taskRow(_ r: TellTraceTaskRow) -> some View {
        Button(intent: DayflowTellTraceCompleteIntent(taskID: r.id, title: r.title)) {
            Label(r.title, systemImage: "circle").frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        switch outcome.kind {
        case .search:
            DayflowSearchCard(draft: DayflowSearchDraft.shared)
        case .choices(let names):
            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.line).font(.subheadline)
                ForEach(names, id: \.self) { name in
                    Button(intent: DayflowCheckInAtIntent(place: name)) {
                        Label(name, systemImage: "mappin.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        case .newChoices(let options, let checkIn):
            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.line).font(.subheadline)
                ForEach(options, id: \.self) { o in
                    Button(intent: DayflowCheckInNewPlaceIntent(googleID: o.googleID, name: o.name, checkIn: checkIn)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.name)
                            Text(o.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                Text(checkIn ? "Picking one adds it to your places as Visited and checks you in."
                             : "Picking one adds it to your places as Visited.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        case .undoOffer:
            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.line).font(.subheadline)
                Button(intent: DayflowTellTraceUndoIntent()) {
                    Label("Undo", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        case .taskChoices(let rows):
            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.line).font(.subheadline)
                ForEach(rows, id: \.self) { r in
                    Button(intent: DayflowTellTraceCompleteIntent(taskID: r.id, title: r.title)) {
                        Label(r.title, systemImage: "circle").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        case .taskList(let tied, let mentions, let place):
            VStack(alignment: .leading, spacing: 6) {
                Text(outcome.line).font(.subheadline)
                if !tied.isEmpty {
                    Text("TIED TO \(place.uppercased())").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(tied, id: \.self) { r in taskRow(r) }
                }
                if !mentions.isEmpty {
                    Text("MENTIONS \(place.uppercased())").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, tied.isEmpty ? 0 : 6)
                    ForEach(mentions, id: \.self) { r in taskRow(r) }
                }
            }
            .padding()
        case .noteAnswer(let path):
            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.line).font(.subheadline)
                Button(intent: DayflowSearchOpenIntent(target: "dayflow://note?path=\(path)")) {
                    Label("Open that day's note", systemImage: "doc.text").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        case .reminderChoices(let names, let task):
            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.line).font(.subheadline)
                ForEach(names, id: \.self) { name in
                    Button(intent: DayflowPlaceReminderIntent(place: name, task: task)) {
                        Label(name, systemImage: "bell.badge")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        case .nearby:
            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.line).font(.subheadline)
                Button(intent: DayflowCheckInNearbyIntent()) {
                    Label("Open Check In", systemImage: "location.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        case .message:
            // The spoken line is already at the top; the card shows what was
            // HEARD, so a dictation slip is visible instead of a repeat (D529).
            Text("Heard: \u{201C}\(outcome.heard)\u{201D}")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

// MARK: - A place that is not saved yet (D524)
//
// David: *"What if the place I'm checking in I know isn't in my system but I
// want to add it and check in"*. Named, not saved: look it up by that name on
// Google around where he is standing, and if one result clearly is it, add it
// (Visited, D521's rule) and check in, in the same breath. Several: offer them,
// one tap each. Nothing found, no location or no signal: say so, and offer
// Check In's nearby list. The same "one clear match goes straight through"
// rule he set for saved places (D522).

enum NewPlaceCheckIn {
    enum Outcome {
        case checkedIn(String)
        case choose([TellTraceOutcome.NewPlaceChoice])
        case failed(String)
    }

    /// Where he is, waiting up to 3 s - `QuickPin.drop`'s approach, since an
    /// intent can run before the app has a fix.
    @MainActor
    static func here() async -> CLLocationCoordinate2D? {
        let lm = LocationManager.shared
        if lm.location == nil {
            lm.requestPermission()
            lm.startUpdating()
            for _ in 0..<20 where lm.location == nil {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        return lm.location?.coordinate
    }

    /// Google results for the name, PREFERRING places near him but not limited
    /// to them (D525). D524 restricted the search to 1.5 km, which assumed he
    /// was standing there; "add Bonobos in Schaumburg" from home found nothing.
    /// The town he names travels in the query and Google honours it.
    @MainActor
    static func search(_ name: String, near here: CLLocationCoordinate2D) async throws -> [GooglePlace] {
        let loc = CLLocation(latitude: here.latitude, longitude: here.longitude)
        return try await GooglePlacesService.shared.textSearch(query: name, coordinate: here)
            .sorted { loc.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                    < loc.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude)) }
    }

    /// Only a result he is standing at goes straight through; anything farther
    /// is offered, never added on its own (D398, D522's rule applied honestly).
    static let standingHereMeters: Double = 300

    @MainActor
    static func resolve(_ spoken: String, checkIn: Bool) async -> Outcome {
        guard let here = await here() else {
            return .failed("I couldn't get your location to look up \(spoken).")
        }
        let results: [GooglePlace]
        do { results = try await search(spoken, near: here) } catch {
            return .failed("I couldn't reach Google to look up \(spoken).")
        }
        guard !results.isEmpty else {
            return .failed("Google found nothing called \(spoken).")
        }
        let key = DayflowCheckInAtIntent.coreName(spoken)
        let named = results.filter {
            let n = DayflowCheckInAtIntent.normalized($0.name)
            return n.contains(key) || key.contains(n)
        }
        let loc = CLLocation(latitude: here.latitude, longitude: here.longitude)
        func meters(_ g: GooglePlace) -> Double {
            loc.distance(from: CLLocation(latitude: g.latitude, longitude: g.longitude))
        }
        if named.count == 1, meters(named[0]) <= standingHereMeters {
            do {
                let place = try await add(named[0], checkIn: checkIn)
                return .checkedIn(place.name)
            } catch {
                return .failed("Couldn't save \(named[0].name): \(error.localizedDescription)")
            }
        }
        let pool = named.isEmpty ? results : named
        return .choose(pool.prefix(5).map { g in
            let m = meters(g)
            let d = m < 1000 ? "\(Int(m.rounded())) m" : String(format: "%.1f km", m / 1000)
            return TellTraceOutcome.NewPlaceChoice(googleID: g.id, name: g.name,
                                                   detail: [g.addressWithRegion, d].filter { !$0.isEmpty }.joined(separator: " · "))
        })
    }

    /// Adds a Google result as a Visited place and checks in there - the same
    /// steps as Check In's nearby list (D521). `addPlace` returns an existing
    /// row rather than a duplicate, so a repeat press cannot make two.
    @MainActor
    static func add(_ g: GooglePlace, checkIn: Bool) async throws -> Place {
        let notion = NotionService.shared
        let newID = try await notion.addPlace(
            name: g.name, address: g.addressWithRegion, city: g.city,
            category: PlaceCategory.suggest(from: g.primaryType) ?? "Attraction",
            latitude: g.latitude, longitude: g.longitude,
            googlePlaceID: g.id, phone: g.phone, website: g.website, status: "Visited")
        // D528: undo may remove only a place this created, never one that was
        // already saved (`addPlace` hands back an existing row's ID).
        let existed = (notion.places + notion.archivedPlaces).contains { $0.id == newID }
        if !existed { TellTraceUndo.note("added \(g.name) to your places") { $0.placeID = newID } }
        await notion.fetchPlaces()
        guard let saved = notion.places.first(where: { $0.id == newID }) else {
            throw NSError(domain: "TellTrace", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "it was added but has not come back from Notion yet"])
        }
        try? await notion.enrichPlace(saved, from: g)
        if checkIn { try await DayflowCheckInAtIntent.checkIn(at: saved) }
        return saved
    }
}

/// The button behind each "which of these is it?" choice (D524). Carries the
/// Google ID and name, looks the result up again where he is, then adds it and
/// checks in.
struct DayflowCheckInNewPlaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Place and Check In"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Google ID") var googleID: String
    @Parameter(title: "Name") var name: String
    @Parameter(title: "Check In", default: true) var checkIn: Bool

    init() {}
    init(googleID: String, name: String, checkIn: Bool) {
        self.googleID = googleID; self.name = name; self.checkIn = checkIn
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let here = await NewPlaceCheckIn.here() else {
            return .result(dialog: "I couldn't get your location.")
        }
        let results = (try? await NewPlaceCheckIn.search(name, near: here)) ?? []
        guard let g = results.first(where: { $0.id == googleID }) ?? results.first(where: { $0.name == name }) else {
            return .result(dialog: "I couldn't find \(name) again. Open Check In to pick from what's nearby.")
        }
        let place = try await NewPlaceCheckIn.add(g, checkIn: checkIn)
        return .result(dialog: checkIn ? "Added \(place.name) to your places and checked in."
                                       : "Added \(place.name) to your places.")
    }
}

// MARK: - Reminders tied to a place (D526)
//
// David: *"I like reminder next."* "Remind me at CD Cleaners to pick up the
// shirts" becomes a task whose notes carry [[CD Cleaners]] - the link the
// arrival reminder already reads (D183, D507) - and switches that place's
// "Remind me on arrival" on if it was off. Arriving then shows the task.
// Nothing new fires anything: this only joins pieces that exist.
//
// Side effect, said out loud in the reply: while a place has open linked
// tasks and the reminder on, it is left out of check-in geofencing, so one
// arrival is one notification (D493's rule). Completing the task undoes it.

enum PlaceReminder {
    struct Result { var line: String; var kind: TellTraceOutcome.Kind? = nil }

    @MainActor
    static func file(_ task: String, at spokenPlace: String) async -> Result {
        var candidates = await DayflowCheckInAtIntent.matches(for: spokenPlace)
        if candidates.count > 1 {
            let key = DayflowCheckInAtIntent.coreName(spokenPlace)
            let exact = candidates.filter { DayflowCheckInAtIntent.normalized($0.name) == key }
            if exact.count == 1 { candidates = exact }
        }
        if candidates.count > 1 {
            return Result(line: "More than one place matches \(spokenPlace). Which one?",
                          kind: .reminderChoices(place: Array(candidates.prefix(5).map(\.name)), task: task))
        }
        if let place = candidates.first {
            return await file(task, at: place)
        }
        // Not saved: add it if it is clearly the one he is standing at,
        // otherwise offer the matches to add first.
        switch await NewPlaceCheckIn.resolve(spokenPlace, checkIn: false) {
        case .checkedIn(let name):
            if let place = NotionService.shared.places.first(where: { $0.name == name }) {
                return await file(task, at: place)
            }
            return Result(line: "Added \(name), but couldn't attach the reminder yet. Ask again in a moment.")
        case .choose(let options):
            return Result(line: "\(spokenPlace) isn't in your places. Add the right one, then ask again.",
                          kind: .newChoices(options, checkIn: false))
        case .failed(let why):
            return Result(line: why)
        }
    }

    @MainActor
    static func file(_ task: String, at place: Place) async -> Result {
        guard place.latitude != 0 || place.longitude != 0 else {
            return Result(line: "\(place.name) has no map location, so it can't remind you on arrival.")
        }
        let title = task.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        let id = await ReminderTaskStore.shared.addTaskReturningID(
            title: title, list: ReminderTaskStore.inboxListName, notes: "[[\(place.name)]]")
        guard id != nil else {
            return Result(line: "Couldn't save the task. Check Reminders access in iOS Settings.")
        }
        let store = DayflowPlaceAlarmStore.shared
        let wasOn = store.isEnabled(place.id)
        if !wasOn { store.toggle(place.id) }        // toggle also reschedules
        TellTraceUndo.note("added the reminder \(title) at \(place.name)") {
            $0.taskID = id
            if !wasOn { $0.alarmPlaceID = place.id }
        }
        await ReminderTaskStore.shared.refreshAll()  // so the alarm body names the new task
        await DayflowPlaceAlarms.reschedule()
        return Result(line: wasOn
            ? "I'll remind you at \(place.name): \(title)."
            : "I'll remind you at \(place.name): \(title). Arrival reminders are now on for \(place.name).")
    }
}

/// The button behind "which one?" for a place reminder (D526).
struct DayflowPlaceReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Remind Me at a Place"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Place") var place: String
    @Parameter(title: "Task") var task: String

    init() {}
    init(place: String, task: String) { self.place = place; self.task = task }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let key = DayflowCheckInAtIntent.coreName(place)
        let all = await DayflowCheckInAtIntent.matches(for: place)
        guard let p = all.first(where: { DayflowCheckInAtIntent.normalized($0.name) == key }) ?? all.first else {
            return .result(dialog: "I couldn't find \(place) in your places.")
        }
        let r = await PlaceReminder.file(task, at: p)
        return .result(dialog: "\(r.line)")
    }
}

// MARK: - Where have I been (D527)
//
// David agreed to "when was I last at Orangetheory", "where did I go last
// Tuesday", "how many times at the pool hall this month". Answered from the
// Visits database, which every check-in writes (and the app already loads in
// full, paged, for Records). Nothing is written; these only read.

enum VisitHistory {
    @MainActor
    private static func visits() async -> [Visit] {
        let notion = NotionService.shared
        if notion.visits.isEmpty { await notion.fetchVisits() }
        return notion.visits
    }

    /// Visits at the place he named: by his saved place's ID when the name
    /// resolves (exact name wins among several), otherwise by the visit's own
    /// recorded name, so a place since renamed or deleted still answers.
    @MainActor
    private static func visits(at spoken: String) async -> (name: String, list: [Visit]) {
        let all = await visits()
        let key = DayflowCheckInAtIntent.coreName(spoken)
        var matches = await DayflowCheckInAtIntent.matches(for: spoken)
        let exact = matches.filter { DayflowCheckInAtIntent.normalized($0.name) == key }
        if !exact.isEmpty { matches = exact }
        if matches.count == 1, let p = matches.first {
            return (p.name, all.filter { $0.placeID == p.id })
        }
        let byName = all.filter {
            let n = DayflowCheckInAtIntent.normalized($0.placeName)
            return !n.isEmpty && (n.contains(key) || key.contains(n))
        }
        return (byName.first?.placeName ?? spoken, byName)
    }

    private static func dayLine(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private static func ago(_ d: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<60: return "\(days) days ago"
        default:
            let months = days / 30
            return months < 24 ? "about \(months) months ago" : "over \(days / 365) years ago"
        }
    }

    @MainActor
    static func last(at spoken: String) async -> String {
        let (name, list) = await visits(at: spoken)
        guard let latest = list.max(by: { $0.date < $1.date }) else {
            return "I have no visits recorded at \(name)."
        }
        return "You were last at \(name) on \(dayLine(latest.date)), \(ago(latest.date))."
    }

    @MainActor
    static func count(at spoken: String, period: String) async -> String {
        let (name, list) = await visits(at: spoken)
        let cal = Calendar.current
        let now = Date()
        let (filtered, label): ([Visit], String) = {
            switch period.lowercased() {
            case "week":  return (list.filter { cal.isDate($0.date, equalTo: now, toGranularity: .weekOfYear) }, "this week")
            case "month": return (list.filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }, "this month")
            case "year":  return (list.filter { cal.isDate($0.date, equalTo: now, toGranularity: .year) }, "this year")
            default:      return (list, "in all")
            }
        }()
        let n = filtered.count
        let times = n == 1 ? "once" : n == 2 ? "twice" : "\(n) times"
        return n == 0 ? "No visits to \(name) \(label)." : "You've been to \(name) \(times) \(label)."
    }

    @MainActor
    static func day(_ iso: String) async -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        guard let target = f.date(from: iso) else { return "I couldn't tell which day you meant." }
        let cal = Calendar.current
        let list = await visits()
            .filter { cal.isDate($0.date, inSameDayAs: target) }
            .sorted { $0.date < $1.date }
        guard !list.isEmpty else { return "No check-ins on \(dayLine(target))." }
        var names: [String] = []
        for v in list where !names.contains(v.placeName) { names.append(v.placeName) }
        let joined = names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + ", and " + names.last!
        return "On \(dayLine(target)) you went to \(joined)."
    }

    /// A date in a spoken sentence ("last Tuesday", "yesterday", "September
    /// 20"), for the rules path when the model is not there. Never in the
    /// future: "Tuesday" means the one just gone.
    static func detectDay(in text: String) -> Date? {
        let lower = text.lowercased()
        let cal = Calendar.current
        if lower.contains("yesterday") { return cal.date(byAdding: .day, value: -1, to: Date()) }
        if lower.contains("today") { return Date() }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var d = m.date else { return nil }
        while d > Date() { d = cal.date(byAdding: .day, value: -7, to: d) ?? d }
        return d
    }
}
