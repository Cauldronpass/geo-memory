//  DayflowTaskCard.swift
//  Dayflow
//
//  The task action's card: a list, a when, and the name asked at the end.
//  Same grammar as the day card — chips, one commit, nothing typed until you
//  have decided where it goes.
//
//  **One screen rather than a walk** (D368). The day card earns its steps
//  because placing a block in a day is spatial. A task is three small choices,
//  and three screens for three chips would be worse than the text box it
//  replaces.
//
//  **Four lists, fixed, not every list you own.** Same reasoning as the Mac's
//  Todoist project menu (D349): a live menu would put every Reminders list ever
//  shared with him on the Action Button. The four are still resolved against the
//  real lists, so a renamed one refuses out loud instead of filing somewhere
//  quiet.
//
//  **Work is not like the other three, and the card never pretends otherwise.**
//  Three of them file a reminder; Work posts to Todoist and Reminders never sees
//  it. Different tint, different verb, different sentence when it lands.

import AppIntents
import SwiftUI

// MARK: - What is being captured

@MainActor
@Observable
final class DayflowTaskDraft {
    static let shared = DayflowTaskDraft()

    enum Destination: String, CaseIterable {
        case inbox, personal, work, financial

        var label: String {
            switch self {
            case .inbox:     return "Inbox"
            case .personal:  return "Personal"
            case .work:      return "Work"
            case .financial: return "Financial"
            }
        }

        /// The Reminders list this files to. Nil for Work, which files nowhere
        /// local — the distinction the whole card is built around.
        var listName: String? {
            switch self {
            case .inbox:     return ReminderTaskStore.inboxListName
            case .personal:  return ReminderTaskStore.personalListName
            case .work:      return nil
            case .financial: return "Financial"
            }
        }

        var isTodoist: Bool { self == .work }
    }

    enum When: Equatable {
        case anytime
        case today
        case tomorrow
        case on(Date)
        case someday

        var label: String {
            switch self {
            case .anytime:  return "Anytime"
            case .today:    return "Today"
            case .tomorrow: return "Tomorrow"
            case .someday:  return "Someday"
            case .on(let d): return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            }
        }

        /// The actual due date, if this when has one.
        var date: Date? {
            let cal = Calendar.current
            switch self {
            case .anytime, .someday: return nil
            case .today:    return cal.startOfDay(for: Date())
            case .tomorrow: return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
            case .on(let d): return cal.startOfDay(for: d)
            }
        }

        var isDated: Bool { date != nil }
    }

    var destination: Destination = .inbox
    var when: When = .anytime

    /// Set when the card had to override a choice, so it can say why rather
    /// than doing it quietly. Cleared by the next deliberate tap.
    var correction: String? = nil

    /// The paperclip, armed before the name is asked (D369).
    ///
    /// **Armed beforehand rather than offered afterwards, and that follows from
    /// the card closing on success.** The first design put a Link button on a
    /// confirmation, which meant keeping a confirmation card up after every
    /// capture to hold a control used maybe one time in twenty. David: *"why do
    /// i want the same card to reappear at all... isnt that confirmation a step
    /// that adds friction itself?"* Once the card closes, there is no afterwards
    /// to decide in, so the decision moves to the only place left — and that is
    /// the right trade, because it costs one glyph on a card he is already
    /// looking at rather than a screen after every task.
    var wantsLink = false

    /// What was just created, so the picker can attach to it without looking
    /// anything up.
    var createdTaskID: String? = nil
    var createdTaskTitle: String? = nil
    /// True while the document and note picker is showing.
    var linking = false
    var linked: String? = nil

    /// Set when a capture finished and nothing more is wanted. The card draws
    /// almost nothing in this state, so if iOS keeps the overlay up rather than
    /// dismissing it, what remains is one line and not a whole card.
    var finished = false

    var justAddedToTodoist = false
    /// What was filed and where, for the one line the card leaves behind.
    ///
    /// **It exists for dictation** (D378). Typed, he knows what he typed. Spoken,
    /// the two things worth checking are whether it heard the words and whether
    /// it found the date — and "Added" answers neither. Cheap enough to show on
    /// every route rather than only the voice one, and a second confirmation
    /// shape for one entry method would be a second thing to maintain.
    var landedLine: String? = nil
    var failure: String? = nil

    /// The month grid, shared in spirit with the day card's.
    var showingMonth = false
    var monthAnchor = Date()

    private init() {}

    func reset() {
        destination = .inbox
        when = .anytime
        correction = nil
        failure = nil
        showingMonth = false
        wantsLink = false
        landedLine = nil
        linking = false
        linked = nil
        finished = false
        createdTaskID = nil
        createdTaskTitle = nil
    }

    // MARK: The two rules the card teaches

    /// **Inbox and Someday hold no dates** (D210/D262), so choosing a date while
    /// one of them is selected moves the task to Personal. The store already
    /// does this; doing it here as well, visibly, is the difference between a
    /// rule learned once and a task discovered later in a list he did not pick.
    ///
    /// **Todoist has no Someday**, so Work and Someday cannot both be true. That
    /// is the same shape of conflict and gets the same treatment.
    func applyRules(changed: String) {
        if destination.isTodoist, when == .someday {
            when = .anytime
            correction = "Todoist has no Someday, so this has no due date."
            return
        }
        if !destination.isTodoist, when.isDated,
           ReminderTaskStore.listRefusesDates(destination.listName) {
            let was = destination.label
            destination = .personal
            correction = "\(was) holds no dates, so this moved to Personal."
            return
        }
        correction = changed.isEmpty ? correction : nil
    }

    // MARK: What the card claims will happen

    var destinationLine: String {
        if destination.isTodoist {
            return when.isDated
                ? "Goes to Todoist Inbox, \(when.label.lowercased())."
                : "Goes to Todoist Inbox, no due date."
        }
        if when == .someday {
            return "Goes to Someday."
        }
        return when.isDated
            ? "Goes to \(destination.label), \(when.label.lowercased())."
            : "Goes to \(destination.label), no date."
    }

    var tokenMissing: Bool { destination.isTodoist && !TodoistKeyStore.hasKey }

    // MARK: Writing

    /// **The words are read for a date, on every route** (D377).
    ///
    /// `TaskLineParser` already does this for the app's own quick add: a trailing
    /// date phrase becomes a due day, "at 3pm" becomes an alarm, and `//` splits
    /// off a note. Reusing it means typing and dictating behave identically, and
    /// it means Siri — "add a task to Dayflow", then speak — lands a dated task
    /// without this card ever being on screen.
    ///
    /// **The date has to be at the END, and that is the parser's rule, not a
    /// limitation to apologise for.** Todoist parses a date anywhere, which is
    /// why "monday sync notes" there gives you a task called "sync notes". This
    /// one fails by doing nothing rather than by eating a word.
    ///
    /// **An explicit tap always beats the words.** The parsed date is applied
    /// only when he has not chosen a when himself — otherwise saying "Friday"
    /// while Tomorrow is lit would make one of the two silently lose, and it
    /// would be the one he pressed.
    func save(title raw: String) async {
        let parsed = TaskLineParser.parse(raw)
        // The parser cleans the title it cuts from a date phrase; a line with no
        // date never goes through that path, so a dictated "Buy toothpaste."
        // would keep its full stop. Same trim, same reason (D379).
        let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?;,"))
        let title = parsed.title.isEmpty ? fallback : parsed.title
        guard !title.isEmpty else { return }
        failure = nil

        if let spoken = parsed.date, when == .anytime {
            when = .on(spoken)
            // The store's own rule then moves it: a dated capture cannot sit in
            // Inbox, so it graduates to Personal (D262/D225). David asked for
            // exactly that behaviour without knowing it already existed.
            applyRules(changed: "when")
        }

        if destination.isTodoist {
            await sendToTodoist(title, notes: parsed.note)
        } else {
            await fileInReminders(title, notes: parsed.note, remindAt: parsed.remindAt)
        }
    }

    private func fileInReminders(_ title: String, notes: String? = nil,
                                 remindAt: Date? = nil) async {
        // Someday is a list, not a date — that is what "not now" means here.
        let list = when == .someday ? ReminderTaskStore.somedayListName : destination.listName
        let id = await ReminderTaskStore.shared.addTaskReturningID(
            title: title, date: when.date, list: list, notes: notes,
            // Only when the phrase actually carried a time. "friday" is a due
            // date; "friday at 3pm" is a due date and an alarm.
            remindAt: remindAt
        )
        guard let id else {
            failure = "Could not save the task. Check Reminders access in iOS Settings."
            return
        }
        let landed = "\(title) — \(destination.label)\(when.isDated ? ", " + when.label : "")"
        let wanted = wantsLink
        // The chip store loads lazily and the picker is about to read it. Asked
        // for here rather than in the view, because a view that fetches while
        // drawing is how a list comes up empty on the one run that matters.
        if wanted { await TraceSatchelChipStore.shared.refresh() }
        reset()
        createdTaskID = id
        createdTaskTitle = title
        landedLine = landed
        justAddedToTodoist = false
        // Armed, so the picker opens on the task just made. Not armed, so this
        // is over and the card says so in one line and goes away.
        linking = wanted
        finished = !wanted
    }

    /// Writes the link into the task's notes.
    ///
    /// **One marker line, the same one Satchel and the Mac already read**
    /// (D227): `satchel:doc:<relativePath>` for a document, `[[Name]]` for a
    /// note. Nothing is written to the document or the note — the link lives in
    /// exactly one place, which is why the panels that show it can never
    /// disagree with each other.
    func link(marker: String, label: String) async {
        guard let id = createdTaskID, let title = createdTaskTitle else { return }
        let store = ReminderTaskStore.shared
        let existing = store.allTasks.first { $0.id == id }?.notes ?? ""
        guard !existing.contains(marker) else {
            linked = label
            return
        }
        let merged = existing.isEmpty ? marker : existing + "\n" + marker
        let ok = await store.update(taskID: id, title: title, date: when.date,
                                    clearDate: false, list: nil, notes: merged)
        if ok {
            linked = label
        } else {
            failure = "Could not attach that."
        }
    }

    /// **Nothing is written locally first.** The Mac's hand-off has to send,
    /// note, then tick off a reminder that already existed; capturing straight
    /// to Todoist has none of that, so a failed send leaves nothing behind and
    /// nothing lives in two systems — which was D348's point, reached by a
    /// shorter road.
    private func sendToTodoist(_ title: String, notes: String? = nil) async {
        do {
            _ = try await TodoistService.send(title: title, notes: notes, due: when.date)
            DayflowWorkHandoff.logToDayNote(title)
            let landed = "\(title) — Todoist\(when.isDated ? ", " + when.label : "")"
            reset()
            createdTaskTitle = title
            landedLine = landed
            justAddedToTodoist = true
            // **No link step for Work.** It went to Todoist and Reminders never
            // saw it, so there is nothing on this phone to attach a document to.
            finished = true
        } catch {
            // **No queue.** A task he believed had reached work, sitting in a
            // retry buffer, is the failure this design exists to avoid. The
            // send either happened or it plainly did not.
            failure = error.localizedDescription
        }
    }

    // The day-note line moved to `DayflowWorkHandoff` (D489), so the card
    // and the task edit sheet write the same sentence. It was private here and
    // a second copy in the sheet would have been two versions of the one line
    // the day note promises to say the same way wherever a task was captured.
}

// MARK: - The snippet

struct DayflowTaskSnippetIntent: SnippetIntent {
    static var title: LocalizedStringResource = "Task Card"

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: DayflowTaskCard(draft: draft))
    }
}

// MARK: - Buttons

struct DayflowPickListIntent: AppIntent {
    static var title: LocalizedStringResource = "Choose a List"
    static var openAppWhenRun: Bool = false
    /// Card buttons are not Shortcuts actions (D367).
    static var isDiscoverable: Bool = false

    @Parameter(title: "List") var list: String

    init() {}
    init(list: String) { self.list = list }

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let d = DayflowTaskDraft.Destination(rawValue: list) else { return .result() }
        draft.finished = false
        draft.correction = nil
        draft.destination = d
        draft.applyRules(changed: "list")
        return .result()
    }
}

struct DayflowPickWhenIntent: AppIntent {
    static var title: LocalizedStringResource = "Choose When"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    /// "anytime" / "today" / "tomorrow" / "someday"
    @Parameter(title: "When") var when: String

    init() {}
    init(when: String) { self.when = when }

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.finished = false
        draft.correction = nil
        switch when {
        case "today":    draft.when = .today
        case "tomorrow": draft.when = .tomorrow
        case "someday":  draft.when = .someday
        default:         draft.when = .anytime
        }
        draft.applyRules(changed: "when")
        return .result()
    }
}

struct DayflowTaskMonthIntent: AppIntent {
    static var title: LocalizedStringResource = "Pick a Date"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.finished = false
        draft.showingMonth.toggle()
        if draft.showingMonth { draft.monthAnchor = draft.when.date ?? Date() }
        return .result()
    }
}

struct DayflowTaskShiftMonthIntent: AppIntent {
    static var title: LocalizedStringResource = "Change the Month"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Months") var delta: Int

    init() {}
    init(delta: Int) { self.delta = delta }

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.monthAnchor = Calendar.current.date(byAdding: .month, value: delta,
                                                  to: draft.monthAnchor) ?? draft.monthAnchor
        return .result()
    }
}

struct DayflowTaskPickDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Use This Date"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Year")  var year: Int
    @Parameter(title: "Month") var month: Int
    @Parameter(title: "Day")   var day: Int

    init() {}
    init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let target = Calendar.current.date(from: comps) else { return .result() }
        draft.correction = nil
        draft.when = .on(target)
        draft.showingMonth = false
        draft.applyRules(changed: "when")
        return .result()
    }
}

/// Arming the paperclip.
struct DayflowToggleLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Attach Something"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.wantsLink.toggle()
        return .result()
    }
}

/// Attaching one document or note to the task just made.
struct DayflowLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Attach This"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Marker") var marker: String
    @Parameter(title: "Label")  var label: String

    init() {}
    init(marker: String, label: String) { self.marker = marker; self.label = label }

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        await draft.link(marker: marker, label: label)
        return .result()
    }
}

/// Closing the picker.
struct DayflowDoneLinkingIntent: AppIntent {
    static var title: LocalizedStringResource = "Done"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.linking = false
        draft.finished = true
        return .result()
    }
}

/// What there is to attach.
///
/// **Six of each, newest first.** Enough that the thing he was just looking at
/// is there, few enough that it is a glance rather than a list. Both read the
/// stores the apps already keep, so nothing here is a second index that can
/// drift from what Satchel and Dayflow show.
enum DayflowLinkables {

    struct Doc { let path: String; let title: String }

    @MainActor
    static func recentDocuments(limit: Int = 6) -> [Doc] {
        TraceSatchelChipStore.shared.all
            .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
            .prefix(limit)
            .map { Doc(path: $0.relativePath, title: $0.title) }
    }

    /// Standing notes, not daily ones: a task linked to "2026-09-12" says
    /// nothing a due date does not already say.
    static func recentNotes(limit: Int = 6) -> [String] {
        let names = (try? NoteStore.shared.listFiles(in: NoteStore.projectsFolder)) ?? []
        return names
            .map { $0.replacingOccurrences(of: ".md", with: "") }
            .sorted { lhs, rhs in
                let l = NoteStore.shared.fileModifiedDate("\(NoteStore.projectsFolder)/\(lhs).md") ?? .distantPast
                let r = NoteStore.shared.fileModifiedDate("\(NoteStore.projectsFolder)/\(rhs).md") ?? .distantPast
                return l > r
            }
            .prefix(limit)
            .map { $0 }
    }
}

/// The only step that asks him for anything, and it comes last.
struct DayflowNameTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Save the Task"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task", requestValueDialog: "What is the task?")
    var taskTitle: String

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        await draft.save(title: taskTitle)
        // Ends without a snippet, which dismisses the card. See the note below
        // on why this had to be split into two intents.
        return .result()
    }
}

/// The same save, but it leaves the card up on the link picker.
///
/// **Two intents for one button, because of a return type** (D372). Ending
/// without a snippet is what dismisses the card, and that is a property of the
/// TYPE `perform` returns, not of a value it chooses at runtime. A single intent
/// that returned a snippet only when the paperclip was armed cannot be written:
/// Swift needs one return type, and `some IntentResult` and
/// `some IntentResult & ShowsSnippetIntent` are different ones.
///
/// So the decision moves up a level, to which intent the button carries. The
/// card already knows whether the paperclip is armed at the moment it draws the
/// button, which is exactly when it has to choose.
struct DayflowNameAndLinkTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Save and Attach"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task", requestValueDialog: "What is the task?")
    var taskTitle: String

    @Dependency private var draft: DayflowTaskDraft

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        await draft.save(title: taskTitle)
        return .result(snippetIntent: DayflowTaskSnippetIntent())
    }
}

// MARK: - Why there is no confirmation card
//
// David: *"why do i want the same card to reappear at all... isnt that
// confirmation a step that adds friction itself?"* He is right. He chose the
// list, chose the when and typed the name; "added to Inbox" tells him something
// he already knows while making him dismiss a card to be rid of it, several
// times a day.
//
// So on success this intent simply ends. A failure still draws, because that is
// the only case with something to say, and an armed paperclip still draws,
// because he asked for the next step.
//
// **The order of that reasoning is worth keeping.** The confirmation card was
// not defended on its own merits — it survived because the Link button needed
// somewhere to live, and the button was then justified by the card being there.
// Two weak things holding each other up. Removing the card is what moved the
// paperclip to where it belongs.

// MARK: - The card

struct DayflowTaskCard: View {
    let draft: DayflowTaskDraft

    private var isWork: Bool { draft.destination.isTodoist }
    private var tint: Color { isWork ? Color.dayflowTodoist : Color.dayflowAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !draft.finished {
                Text(draft.linking ? "Link something" : "New task")
                    .font(.dayflowSerif(16))
                    .foregroundStyle(Color.dayflowInk)
            }

            if draft.finished {
                finishedLine
            } else if draft.linking {
                linkPicker
            } else if draft.showingMonth {
                monthGrid
            } else {
                label("LIST")
                listChips
                label("WHEN")
                whenChips
                footer
            }
        }
        .padding(14)
        .background(Color.dayflowPaper)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Color.dayflowFaint)
            .padding(.top, 12)
            .padding(.bottom, 7)
    }

    // MARK: Chips

    private var listChips: some View {
        DayflowSnippetFlow(spacing: 6) {
            ForEach(DayflowTaskDraft.Destination.allCases, id: \.self) { d in
                Button(intent: DayflowPickListIntent(list: d.rawValue)) {
                    chip(d.label,
                         selected: draft.destination == d,
                         // **Work wears Todoist's colour before it is chosen**,
                         // not only once pressed: that it leaves the phone is
                         // the most useful thing to know about this row.
                         accent: d.isTodoist ? Color.dayflowTodoist : Color.dayflowAccent,
                         faded: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var whenChips: some View {
        DayflowSnippetFlow(spacing: 6) {
            ForEach(["anytime", "today", "tomorrow"], id: \.self) { key in
                Button(intent: DayflowPickWhenIntent(when: key)) {
                    chip(key.capitalized, selected: matches(key), accent: tint, faded: false)
                }
                .buttonStyle(.plain)
            }

            Button(intent: DayflowTaskMonthIntent()) {
                chip(pickerLabel, selected: isPickedDate, accent: tint, faded: false)
            }
            .buttonStyle(.plain)

            // Someday stays on the card when Work is chosen, faded rather than
            // removed: a chip that vanishes is a control he has to remember the
            // absence of, and the reason is one line below anyway.
            Button(intent: DayflowPickWhenIntent(when: "someday")) {
                chip("Someday", selected: draft.when == .someday,
                     accent: tint, faded: isWork)
            }
            .buttonStyle(.plain)
            .disabled(isWork)
        }
    }

    private func matches(_ key: String) -> Bool {
        switch key {
        case "today":    return draft.when == .today
        case "tomorrow": return draft.when == .tomorrow
        default:         return draft.when == .anytime
        }
    }

    private var isPickedDate: Bool {
        if case .on = draft.when { return true }
        return false
    }

    private var pickerLabel: String {
        if case .on(let d) = draft.when {
            return d.formatted(.dateTime.day().month(.abbreviated))
        }
        return "Pick a date…"
    }

    private func chip(_ text: String, selected: Bool, accent: Color, faded: Bool) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? accent.opacity(0.12) : Color.dayflowPanel))
            .overlay(Capsule().stroke(selected ? accent : Color.dayflowHairline, lineWidth: 1))
            .foregroundStyle(selected ? accent : Color.dayflowInk)
            .opacity(faded ? 0.35 : 1)
    }

    // MARK: The claim, and the button

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.dayflowHairline).padding(.top, 13)

            if draft.tokenMissing {
                // Said before he types a name, not after the send fails.
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Todoist token on this iPhone.")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dayflowInk)
                    Text("Tokens are stored per device — the one on your Mac does not carry over. Add one in Dayflow Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.dayflowTodoist)
                }
                .padding(.top, 11)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.destinationLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.dayflowMuted)
                    if let correction = draft.correction {
                        Text(correction)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.dayflowAccent)
                    }
                    if let failure = draft.failure {
                        Text(failure)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.dayflowAccent)
                    }
                }
                .padding(.top, 11)
            }

            if !draft.tokenMissing {
                HStack(spacing: 9) {
                    // **Which intent, decided here.** Dismissal is a property of
                    // the return type, so the choice cannot live inside one
                    // intent — see `DayflowNameAndLinkTaskIntent`.
                    if draft.wantsLink && !isWork {
                        Button(intent: DayflowNameAndLinkTaskIntent()) {
                            saveLabel
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(intent: DayflowNameTaskIntent()) {
                            saveLabel
                        }
                        .buttonStyle(.plain)
                    }

                    // **A glyph, not a button, and only for Reminders tasks.**
                    // This is used perhaps one capture in twenty; anything
                    // wider would make a rare thing look like a step. Work has
                    // no paperclip at all because nothing local exists to
                    // attach to, which is better than one that fails.
                    if !isWork {
                        Button(intent: DayflowToggleLinkIntent()) {
                            Image(systemName: draft.wantsLink ? "paperclip.circle.fill" : "paperclip")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(draft.wantsLink ? tint : Color.dayflowHairline, lineWidth: 1))
                                .foregroundStyle(draft.wantsLink ? tint : Color.dayflowMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 11)

                if draft.wantsLink && !isWork {
                    HStack(spacing: 5) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10, weight: .semibold))
                        Text("You will be asked what to attach.")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .padding(.top, 7)
                }
            }
        }
    }

    private var saveLabel: some View {
        Text(isWork ? "Name it and send" : "Name it and add")
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint))
            .foregroundStyle(Color.white)
    }

    // MARK: Finished

    /// **One line, because the card is supposed to be gone.**
    ///
    /// On success the naming intent ends without returning a snippet, which
    /// should dismiss the overlay. If iOS keeps it up anyway, this is what
    /// stays: a sentence, not a card that has to be dismissed. Belt and braces
    /// for a behaviour that cannot be tested anywhere but on the phone.
    private var finishedLine: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
            Text(draft.landedLine ?? (draft.justAddedToTodoist ? "Sent to Todoist" : "Added"))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(draft.justAddedToTodoist ? Color.dayflowTodoist : Color.dayflowAccent)
    }

    // MARK: Linking

    /// Recent documents and recent notes, as chips.
    ///
    /// **Recent rather than searchable, deliberately.** A card cannot hold a
    /// text field, so a searchable version would mean the system asking him to
    /// type, then a list of matches — three screens to do what the app does in
    /// two taps, and a weaker copy of a picker that already exists. The case
    /// this serves is the thing he was just looking at, and recency answers that
    /// exactly.
    private var linkPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.createdTaskTitle ?? "")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dayflowMuted)
                .lineLimit(1)
                .padding(.top, 4)

            if let linked = draft.linked {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("\(linked) linked")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.dayflowAccent)
                .padding(.top, 11)
            }

            if let failure = draft.failure {
                Text(failure)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dayflowAccent)
                    .padding(.top, 9)
            }

            let documents = DayflowLinkables.recentDocuments()
            if !documents.isEmpty {
                label("DOCUMENTS")
                DayflowSnippetFlow(spacing: 6) {
                    ForEach(documents, id: \.path) { doc in
                        Button(intent: DayflowLinkIntent(marker: ThingsTask.documentMarkerPrefix + doc.path,
                                                         label: doc.title)) {
                            chip(doc.title, selected: false,
                                 accent: Color.dayflowAccent, faded: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            let notes = DayflowLinkables.recentNotes()
            if !notes.isEmpty {
                label("NOTES")
                DayflowSnippetFlow(spacing: 6) {
                    ForEach(notes, id: \.self) { name in
                        Button(intent: DayflowLinkIntent(marker: "[[\(name)]]", label: name)) {
                            chip(name, selected: false,
                                 accent: Color.dayflowAccent, faded: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if documents.isEmpty && notes.isEmpty {
                Text("Nothing recent to attach.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dayflowMuted)
                    .padding(.top, 11)
            }

            Button(intent: DayflowDoneLinkingIntent()) {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.dayflowPanel))
                    .foregroundStyle(Color.dayflowInk)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    // MARK: The month

    /// The day card's grid without the event dots: those answer a question about
    /// meetings, and this is not one.
    private var monthGrid: some View {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: draft.monthAnchor)
        let monthStart = cal.date(from: comps) ?? draft.monthAnchor
        let days = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let leading = (cal.component(.weekday, from: monthStart) + 5) % 7
        let today = cal.startOfDay(for: Date())

        return VStack(spacing: 8) {
            Button(intent: DayflowTaskMonthIntent()) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text("New task")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Color.dayflowMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)

            HStack {
                Button(intent: DayflowTaskShiftMonthIntent(delta: -1)) { monthSquare("chevron.left") }
                    .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(monthStart.formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Color.dayflowMuted)
                Spacer(minLength: 0)
                Button(intent: DayflowTaskShiftMonthIntent(delta: 1)) { monthSquare("chevron.right") }
                    .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach(Array(["M","T","W","T","F","S","S"].enumerated()), id: \.offset) { _, d in
                    Text(d)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                      spacing: 4) {
                ForEach(0..<(leading + days), id: \.self) { index in
                    if index < leading {
                        Color.clear.frame(height: 30)
                    } else {
                        let dayNumber = index - leading + 1
                        let date = cal.date(byAdding: .day, value: dayNumber - 1, to: monthStart)
                        let isToday = date.map { cal.isDate($0, inSameDayAs: today) } ?? false
                        let isSelected = draft.when.date.map { d in
                            date.map { cal.isDate($0, inSameDayAs: d) } ?? false
                        } ?? false
                        Button(intent: DayflowTaskPickDayIntent(year: comps.year ?? 2026,
                                                                month: comps.month ?? 1,
                                                                day: dayNumber)) {
                            // **Today is the accent; the chosen day is the
                            // filled circle** (D375). Bold alone was the only
                            // mark today had, and next to thirty other numerals
                            // a weight change is not a landmark — which is what
                            // today is for in a month grid: the thing every
                            // other date is judged against. When today IS the
                            // chosen day the circle fills with the accent
                            // instead of ink, so one square never has to carry
                            // two different meanings in the same colour.
                            Text("\(dayNumber)")
                                .font(.system(size: 13,
                                              weight: isToday || isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.white
                                                 : (isToday ? Color.dayflowAccent : Color.dayflowInk))
                                .frame(width: 26, height: 26)
                                .background(
                                    Circle().fill(isSelected
                                                  ? (isToday ? Color.dayflowAccent : Color.dayflowInk)
                                                  : Color.clear)
                                )
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func monthSquare(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 24)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.dayflowHairline, lineWidth: 1))
            .foregroundStyle(Color.dayflowMuted)
    }
}
