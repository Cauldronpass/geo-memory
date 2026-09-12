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

    var justAdded: String? = nil
    var justAddedToTodoist = false
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

    func save(title raw: String) async {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        failure = nil

        if destination.isTodoist {
            await sendToTodoist(title)
        } else {
            await fileInReminders(title)
        }
    }

    private func fileInReminders(_ title: String) async {
        // Someday is a list, not a date — that is what "not now" means here.
        let list = when == .someday ? ReminderTaskStore.somedayListName : destination.listName
        let ok = await ReminderTaskStore.shared.addTask(
            title: title, date: when.date, list: list
        )
        if ok {
            justAdded = title
            justAddedToTodoist = false
            reset()
        } else {
            failure = "Could not save the task. Check Reminders access in iOS Settings."
        }
    }

    /// **Nothing is written locally first.** The Mac's hand-off has to send,
    /// note, then tick off a reminder that already existed; capturing straight
    /// to Todoist has none of that, so a failed send leaves nothing behind and
    /// nothing lives in two systems — which was D348's point, reached by a
    /// shorter road.
    private func sendToTodoist(_ title: String) async {
        do {
            _ = try await TodoistService.send(title: title, notes: nil, due: when.date)
            logToDayNote(title)
            justAdded = title
            justAddedToTodoist = true
            reset()
        } catch {
            // **No queue.** A task he believed had reached work, sitting in a
            // retry buffer, is the failure this design exists to avoid. The
            // send either happened or it plainly did not.
            failure = error.localizedDescription
        }
    }

    /// `☑ <title> → Todoist` under `## Work Items`, the same line the Mac writes
    /// (D348, corrected to the glyph in D352). Same event, same sentence,
    /// wherever it was captured.
    private func logToDayNote(_ title: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let path = "\(NoteStore.dailyFolder)/\(f.string(from: Date())).md"
        let existing = (try? NoteStore.shared.readFile(path)) ?? ""
        let line = "\u{2611} \(title) → Todoist"
        guard !existing.contains(line) else { return }
        try? NoteStore.shared.writeFile(path,
                                        content: EndeavorFile.appending(line, under: "Work Items",
                                                                        in: existing))
    }
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
        draft.justAdded = nil
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
        draft.justAdded = nil
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
        draft.justAdded = nil
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
        return .result()
    }
}

// MARK: - The card

struct DayflowTaskCard: View {
    let draft: DayflowTaskDraft

    private var isWork: Bool { draft.destination.isTodoist }
    private var tint: Color { isWork ? Color.dayflowTodoist : Color.dayflowAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New task")
                .font(.dayflowSerif(16))
                .foregroundStyle(Color.dayflowInk)

            if draft.showingMonth {
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

            if let added = draft.justAdded {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("“\(added)” \(draft.justAddedToTodoist ? "sent to Todoist" : "added to \(draft.destination.label)")")
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(draft.justAddedToTodoist ? Color.dayflowTodoist : Color.dayflowAccent)
                .padding(.top, 11)
            } else if draft.tokenMissing {
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
                Button(intent: DayflowNameTaskIntent()) {
                    Text(isWork ? "Name it and send" : "Name it and add")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(tint))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 11)
            }
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
                            Text("\(dayNumber)")
                                .font(.system(size: 13, weight: isToday ? .bold : .regular))
                                .foregroundStyle(isSelected ? Color.white : Color.dayflowInk)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(isSelected ? Color.dayflowInk : Color.clear))
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
