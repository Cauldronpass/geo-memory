//  DayflowEventSnippet.swift
//  Dayflow
//
//  The event action's card: the day read top to bottom as meetings and the gaps
//  between them, each gap saying how long it is. It appears over whatever is on
//  screen when the Action Button shortcut runs, and Dayflow never comes forward.
//
//  **The day comes first and the name comes last** (D365). The first version
//  asked what the event was and then offered times, which meant there was no way
//  to press the button simply to look at Wednesday. Now the card opens on the
//  day, every gap states its length, the arrows move a day, and nothing is asked
//  of him until he has chosen where something goes.
//
//  **Three taps, each of which can be the last one.** Look. Tap a gap to open it
//  and see the block land. Press Add and name it. Backing out at any point has
//  written nothing.
//
//  **A snippet can only contain controls that fire an intent** — buttons and
//  toggles, no gestures — so the composer's drag is not available here and the
//  chips are the honest substitute (D361).
//
//  ── If interactive snippets do not work on device ─────────────────────────
//  Delete this file, remove the `AppDependencyManager` line from
//  `DayflowApp.init`, and use the two-step shortcut instead:
//  `DayflowChooseTimeIntent` → Shortcuts' own Ask for Input → 
//  `DayflowBookEventAtIntent`. Those two live in `DayflowQuickIntents.swift`,
//  depend on none of this, and use only the plain picker that was already
//  working. Same flow, no drawing.

import AppIntents
import SwiftUI

// MARK: - The day being looked at

/// What the card is showing, for as long as it is open.
///
/// **One shared instance reached through `AppDependencyManager`.** Every tap is
/// a separate intent in a separate call with no view state carried between them,
/// so the thing being looked at has to live where both the card and the buttons
/// can see it.
@MainActor
@Observable
final class DayflowEventDraft {
    static let shared = DayflowEventDraft()

    /// One line of the day: something booked, or the space after it.
    enum Line: Identifiable {
        case event(start: Int, end: Int, title: String)
        case gap(start: Int, end: Int)

        var id: String {
            switch self {
            case .event(let s, let e, let t): return "e\(s)-\(e)-\(t)"
            case .gap(let s, let e):          return "g\(s)-\(e)"
            }
        }
    }

    var day: Date = Date()
    var lines: [Line] = []
    var busy: [(start: Int, end: Int, title: String)] = []

    /// The gap he opened, if any. Nil means he is still looking at the day.
    var openGap: (start: Int, end: Int)? = nil
    /// Where the block would land inside that gap.
    var chosen: Int? = nil
    var minutes: Int = 60

    var title: String = ""
    var justAdded: String? = nil
    var failure: String? = nil

    /// The month grid, opened by tapping the date (D366). Day arrows are right
    /// for tomorrow and useless for the 17th.
    var showingMonth: Bool = false
    var monthAnchor: Date = Date()
    /// Events per day-of-month for `monthAnchor`, for the dots. Same call the
    /// composer's own grid makes.
    var monthCounts: [Int: Int] = [:]

    private init() {}

    static let windowStart = 7 * 60
    static let windowEnd   = 22 * 60

    // MARK: Reading the day

    func load(day: Date) async {
        self.day = day
        openGap = nil
        chosen = nil
        failure = nil
        await reload()
    }

    func loadMonth(_ anchor: Date) async {
        monthAnchor = anchor
        monthCounts = await CalendarService.shared.fetchMonthEventCounts(for: anchor)
    }

    func reload() async {
        busy = await DayflowOpenSlotFinder.busyBlocks(on: day)
        lines = Self.timeline(from: busy)
        // A gap that no longer exists cannot stay open — on today it can also
        // simply have passed while the card was up.
        if let openGap, !lines.contains(where: {
            if case .gap(let s, let e) = $0 { return s == openGap.start && e == openGap.end }
            return false
        }) {
            self.openGap = nil
            self.chosen = nil
        }
    }

    /// Meetings and the spaces between them, in order.
    ///
    /// **Zero-length gaps are kept and marked, not dropped.** Three meetings
    /// running into each other is a fact about the day; a list that silently
    /// omitted the joins would read as gaps he could not see.
    static func timeline(from busy: [(start: Int, end: Int, title: String)]) -> [Line] {
        let sorted = busy.sorted { $0.start < $1.start }
        var out: [Line] = []
        var cursor = windowStart
        for b in sorted {
            let blockStart = max(b.start, windowStart)
            if blockStart >= cursor {
                out.append(.gap(start: cursor, end: blockStart))
            }
            out.append(.event(start: b.start, end: b.end, title: b.title))
            cursor = max(cursor, min(b.end, windowEnd))
        }
        if cursor <= windowEnd { out.append(.gap(start: cursor, end: windowEnd)) }
        return out
    }

    /// Start times inside the opened gap.
    ///
    /// **On the hour and the half hour, and all of them** (D366). The first
    /// version snapped to quarter hours and then offered four points spread
    /// across the gap, which on a 10:00-to-1:00 opening produced 10:00, 10:45,
    /// 11:30 and 12:30 — times nobody starts a meeting at, with 10:30 and 11:00
    /// missing. David: *"I dont really need starts on the 15 min mark either or
    /// 45 minute... just 30 and on the hour is fine."*
    ///
    /// Spreading was the right answer to the wrong question. It exists because
    /// a long gap enumerated at quarter hours is thirty chips; at half hours a
    /// three-hour gap is six, which is a list worth reading. **Enumerate, and
    /// coarsen only when the count actually gets away** — past fourteen the step
    /// doubles to an hour, so a whole free afternoon stays represented end to
    /// end instead of being sampled.
    var startsInOpenGap: [Int] {
        guard let openGap else { return [] }

        func starts(step: Int) -> [Int] {
            let earliest = ((openGap.start + step - 1) / step) * step
            let latest   = ((openGap.end - minutes) / step) * step
            guard earliest <= latest else { return [] }
            return Array(stride(from: earliest, through: latest, by: step))
        }

        var out = starts(step: 30)
        if out.count > 14 { out = starts(step: 60) }

        // A gap that begins off the half hour — a meeting that ended at 10:15 —
        // can fit something exactly and still offer nothing, because the first
        // half hour is already past the end. Its own start is then the only time
        // that works, and a card saying "nothing fits" while it does would be
        // the screen stating something untrue.
        if out.isEmpty, openGap.end - openGap.start >= minutes {
            out = [openGap.start]
        }
        return out
    }

    // MARK: Writing

    func book() async {
        guard let chosen, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        guard let start = cal.date(byAdding: .minute, value: chosen, to: dayStart),
              let end = cal.date(byAdding: .minute, value: chosen + minutes, to: dayStart)
        else {
            failure = "Could not work out that time."
            return
        }
        // The same default the composer reads (D360).
        let calendarIdentifier = UserDefaults.standard.string(forKey: "default_calendar_identifier")
        let ok = await CalendarService.shared.createEvent(
            title: title, date: day, startTime: start, endTime: end,
            calendarIdentifier: calendarIdentifier
        )
        if ok {
            justAdded = title
            failure = nil
            title = ""
            openGap = nil
            self.chosen = nil
            // Re-read rather than inserting the new block by hand: the card is
            // then drawing the calendar rather than its own belief about it.
            await reload()
        } else {
            // **Reported on the card, not thrown.** A throw closes the snippet,
            // taking the picture away at the moment it has something to say.
            failure = "Calendar refused it. Check Calendar access and your Default Calendar in Dayflow Settings."
        }
    }
}

// MARK: - The snippet

struct DayflowEventSnippetIntent: SnippetIntent {
    static var title: LocalizedStringResource = "Day Card"

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        .result(view: DayflowDayCard(draft: draft))
    }
}

// MARK: - Buttons

/// The day arrows and TODAY.
struct DayflowShiftDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Change the Day"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false
    /// **Off the Shortcuts list** (D367). Every `AppIntent` in the app target
    /// shows up as a buildable action, and these nine are the card's own
    /// buttons: "Use This Gap" and "Choose a Start Time" mean nothing without a
    /// card open, and dropping one into a shortcut would do something between
    /// nothing and something confusing. They stay callable from
    /// `Button(intent:)`, which is the only caller they were ever meant to have.
    static var isDiscoverable: Bool = false

    /// Days to move. Zero means jump back to today.
    @Parameter(title: "Days")
    var delta: Int

    init() {}
    init(delta: Int) { self.delta = delta }

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.justAdded = nil
        if delta == 0 {
            await draft.load(day: Date())
        } else {
            let next = Calendar.current.date(byAdding: .day, value: delta, to: draft.day) ?? draft.day
            await draft.load(day: next)
        }
        return .result()
    }
}

/// Opening a gap. **Does not book anything** — this is the tap that turns
/// looking into choosing, and it has to be reversible.
struct DayflowOpenGapIntent: AppIntent {
    static var title: LocalizedStringResource = "Use This Gap"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Start") var start: Int
    @Parameter(title: "End")   var end: Int

    init() {}
    init(start: Int, end: Int) { self.start = start; self.end = end }

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.justAdded = nil
        draft.openGap = (start, end)
        // Longest sensible default that actually fits, so the common case needs
        // no second decision.
        if end - start < draft.minutes {
            draft.minutes = max(30, ((end - start) / 30) * 30)
        }
        draft.chosen = draft.startsInOpenGap.first
        return .result()
    }
}

/// Back to the whole day.
struct DayflowCloseGapIntent: AppIntent {
    static var title: LocalizedStringResource = "Back to the Day"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.openGap = nil
        draft.chosen = nil
        return .result()
    }
}

/// Moving the block inside the open gap.
struct DayflowPickStartIntent: AppIntent {
    static var title: LocalizedStringResource = "Choose a Start Time"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Start") var start: Int

    init() {}
    init(start: Int) { self.start = start }

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.chosen = start
        return .result()
    }
}

/// The length chips.
struct DayflowSetLengthIntent: AppIntent {
    static var title: LocalizedStringResource = "Change the Length"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Minutes") var minutes: Int

    init() {}
    init(minutes: Int) { self.minutes = minutes }

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.minutes = minutes
        // Re-spread the starts: the old ones were computed for the old length
        // and the last of them may no longer fit.
        let starts = draft.startsInOpenGap
        if let chosen = draft.chosen, !starts.contains(chosen) {
            draft.chosen = starts.first
        }
        return .result()
    }
}

/// **The only step that asks him for anything**, and it comes last.
///
/// The parameter carries no value, so pressing the button is what makes iOS ask
/// for it. A day opened only to look never reaches this intent and is therefore
/// never asked a question — which was the whole point of putting the day first.
struct DayflowNameAndAddIntent: AppIntent {
    static var title: LocalizedStringResource = "Add the Event"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Event", requestValueDialog: "What is it?")
    var eventTitle: String

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.title = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        await draft.book()
        return .result()
    }
}

/// Tapping the date itself.
///
/// **The arrows are right for tomorrow and useless for the 17th.** David hit
/// this immediately: stepping a day at a time is the only way to reach a date
/// two weeks out, and by then it is faster to open Calendar.
struct DayflowToggleMonthIntent: AppIntent {
    static var title: LocalizedStringResource = "Pick a Date"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        draft.showingMonth.toggle()
        if draft.showingMonth {
            draft.justAdded = nil
            await draft.loadMonth(draft.day)
        }
        return .result()
    }
}

struct DayflowShiftMonthIntent: AppIntent {
    static var title: LocalizedStringResource = "Change the Month"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Months") var delta: Int

    init() {}
    init(delta: Int) { self.delta = delta }

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        let next = Calendar.current.date(byAdding: .month, value: delta, to: draft.monthAnchor)
        await draft.loadMonth(next ?? draft.monthAnchor)
        return .result()
    }
}

/// One day in the grid. **Identified by its own date parts, not an offset**, so
/// a tap cannot mean a different day than the one it was drawn under if the
/// month moved between drawing and pressing.
struct DayflowPickDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Go to This Day"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Year")  var year: Int
    @Parameter(title: "Month") var month: Int
    @Parameter(title: "Day")   var day: Int

    init() {}
    init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    @Dependency private var draft: DayflowEventDraft

    @MainActor
    func perform() async throws -> some IntentResult {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let target = Calendar.current.date(from: comps) else { return .result() }
        draft.showingMonth = false
        draft.justAdded = nil
        await draft.load(day: target)
        return .result()
    }
}

// MARK: - The card

struct DayflowDayCard: View {
    let draft: DayflowEventDraft

    private static var span: Double {
        Double(DayflowEventDraft.windowEnd - DayflowEventDraft.windowStart)
    }

    private func fraction(_ minutes: Int) -> Double {
        let clamped = min(max(minutes, DayflowEventDraft.windowStart), DayflowEventDraft.windowEnd)
        return Double(clamped - DayflowEventDraft.windowStart) / Self.span
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            nav
            // The track draws the day he is looking at, so it comes down while
            // he is choosing a different one rather than describing a day the
            // rest of the card has stopped being about.
            if !draft.showingMonth {
                track.padding(.top, 11)
                ticks
            }

            if let failure = draft.failure {
                Text(failure)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dayflowAccent)
                    .padding(.top, 10)
            }

            if draft.showingMonth {
                monthGrid
            } else if draft.openGap != nil {
                placing
            } else {
                dayLines
                if let added = draft.justAdded {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Added \(added)")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
                    .padding(.top, 11)
                }
            }
        }
        .padding(14)
        .background(Color.dayflowPaper)
    }

    // MARK: Header

    private var nav: some View {
        HStack(spacing: 8) {
            Button(intent: DayflowShiftDayIntent(delta: -1)) {
                navSquare("chevron.left")
            }
            .buttonStyle(.plain)

            Button(intent: DayflowToggleMonthIntent()) {
                HStack(spacing: 5) {
                    Text(draft.day.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)))
                        .font(.dayflowSerif(16))
                        .foregroundStyle(Color.dayflowInk)
                        .lineLimit(1)
                    Image(systemName: draft.showingMonth ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.dayflowFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !Calendar.current.isDateInToday(draft.day) {
                Button(intent: DayflowShiftDayIntent(delta: 0)) {
                    Text("TODAY")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.6)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.dayflowHairline, lineWidth: 1))
                        .foregroundStyle(Color.dayflowMuted)
                }
                .buttonStyle(.plain)
            }

            Button(intent: DayflowShiftDayIntent(delta: 1)) {
                navSquare("chevron.right")
            }
            .buttonStyle(.plain)
        }
    }

    private func navSquare(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.dayflowHairline, lineWidth: 1))
            .foregroundStyle(Color.dayflowMuted)
    }

    // MARK: The drawn day

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.dayflowHairline)
                    .frame(height: 6)
                    .offset(y: 10)

                ForEach(Array(draft.busy.enumerated()), id: \.offset) { _, block in
                    let x = fraction(block.start) * width
                    let w = max(2, (fraction(block.end) - fraction(block.start)) * width)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.dayflowFaint.opacity(0.55))
                        .frame(width: w, height: 12)
                        .offset(x: x, y: 7)
                }

                if let chosen = draft.chosen, draft.openGap != nil {
                    let x = fraction(chosen) * width
                    let w = max(3, (fraction(chosen + draft.minutes) - fraction(chosen)) * width)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.dayflowAccent)
                        .frame(width: w, height: 16)
                        .offset(x: x, y: 5)
                }
            }
        }
        .frame(height: 26)
    }

    private var ticks: some View {
        HStack {
            Text("7am"); Spacer(); Text("noon"); Spacer(); Text("5pm"); Spacer(); Text("10pm")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Color.dayflowFaint)
        .padding(.top, 1)
    }

    // MARK: The month

    /// A month of buttons, with a dot under any day that has something on it.
    ///
    /// The dots come from `fetchMonthEventCounts`, the same call the composer's
    /// own grid makes — a second way of counting a day's events would eventually
    /// disagree with the day he then opens.
    private var monthGrid: some View {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: draft.monthAnchor)
        let monthStart = cal.date(from: comps) ?? draft.monthAnchor
        let days = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        // Monday-first, matching the composer.
        let leading = (cal.component(.weekday, from: monthStart) + 5) % 7
        let cells = Array(0..<(leading + days))
        let today = cal.startOfDay(for: Date())
        let selected = cal.dateComponents([.year, .month, .day], from: draft.day)

        return VStack(spacing: 8) {
            HStack {
                Button(intent: DayflowShiftMonthIntent(delta: -1)) {
                    navSquare("chevron.left")
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(monthStart.formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Color.dayflowMuted)
                Spacer(minLength: 0)
                Button(intent: DayflowShiftMonthIntent(delta: 1)) {
                    navSquare("chevron.right")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach(["M","T","W","T","F","S","S"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                      spacing: 4) {
                ForEach(cells, id: \.self) { index in
                    if index < leading {
                        Color.clear.frame(height: 34)
                    } else {
                        let dayNumber = index - leading + 1
                        let date = cal.date(byAdding: .day, value: dayNumber - 1, to: monthStart)
                        let isToday = date.map { cal.isDate($0, inSameDayAs: today) } ?? false
                        let isSelected = selected.year == comps.year
                            && selected.month == comps.month
                            && selected.day == dayNumber
                        Button(intent: DayflowPickDayIntent(year: comps.year ?? 2026,
                                                            month: comps.month ?? 1,
                                                            day: dayNumber)) {
                            VStack(spacing: 2) {
                                Text("\(dayNumber)")
                                    .font(.system(size: 13, weight: isToday ? .bold : .regular))
                                    .foregroundStyle(isSelected ? Color.white : Color.dayflowInk)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        Circle().fill(isSelected ? Color.dayflowInk : Color.clear)
                                    )
                                Circle()
                                    .fill((draft.monthCounts[dayNumber] ?? 0) > 0
                                          ? Color.dayflowFaint : Color.clear)
                                    .frame(width: 3, height: 3)
                            }
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    // MARK: Looking at the day

    private var dayLines: some View {
        VStack(spacing: 0) {
            ForEach(draft.lines) { line in
                switch line {
                case .event(let s, let e, let title):
                    eventRow(start: s, end: e, title: title)
                case .gap(let s, let e):
                    gapRow(start: s, end: e)
                }
            }
        }
        .padding(.top, 8)
    }

    /// Inert, deliberately. What is booked is context, never an offer (D361).
    private func eventRow(start: Int, end: Int, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(DayflowOpenSlotFinder.clock(start))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.dayflowFaint)
                .frame(width: 58, alignment: .leading)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.dayflowInk)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(Self.duration(end - start))
                .font(.system(size: 11))
                .foregroundStyle(Color.dayflowFaint)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 0.5)
        }
    }

    /// The answer to "how much time is between these".
    ///
    /// A gap too short for anything is drawn faded and says "back to back"
    /// rather than being left out.
    private func gapRow(start: Int, end: Int) -> some View {
        let length = end - start
        let usable = length >= 30
        return Group {
            if usable {
                Button(intent: DayflowOpenGapIntent(start: start, end: end)) {
                    gapBody(start: start, end: end, length: length, usable: true)
                }
                .buttonStyle(.plain)
            } else {
                gapBody(start: start, end: end, length: length, usable: false)
            }
        }
    }

    private func gapBody(start: Int, end: Int, length: Int, usable: Bool) -> some View {
        HStack(spacing: 9) {
            Text("\(DayflowOpenSlotFinder.clock(start)) – \(DayflowOpenSlotFinder.clock(end))")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.dayflowMuted)
                .frame(width: 104, alignment: .leading)
            Text(usable ? "\(Self.duration(length)) free" : "back to back")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
            Spacer(minLength: 0)
            if usable {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.dayflowAccent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.dayflowPanel))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.dayflowHairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .opacity(usable ? 1 : 0.5)
        .padding(.vertical, 5)
    }

    // MARK: Placing one

    private var placing: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(intent: DayflowCloseGapIntent()) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text(draft.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Color.dayflowMuted)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)

            if let gap = draft.openGap {
                gapBody(start: gap.start, end: gap.end,
                        length: gap.end - gap.start, usable: true)
                    .padding(.top, 6)
            }

            let starts = draft.startsInOpenGap
            if starts.isEmpty {
                Text("Nothing that long fits here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dayflowMuted)
                    .padding(.top, 10)
            } else {
                DayflowSnippetFlow(spacing: 7) {
                    ForEach(starts, id: \.self) { start in
                        Button(intent: DayflowPickStartIntent(start: start)) {
                            Text(DayflowOpenSlotFinder.clock(start))
                                .font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(draft.chosen == start
                                    ? Color.dayflowAccent.opacity(0.12) : Color.dayflowPanel))
                                .overlay(Capsule().stroke(draft.chosen == start
                                    ? Color.dayflowAccent : Color.dayflowHairline, lineWidth: 1))
                                .foregroundStyle(draft.chosen == start
                                    ? Color.dayflowAccent : Color.dayflowInk)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            }

            lengths

            if let chosen = draft.chosen {
                Button(intent: DayflowNameAndAddIntent()) {
                    Text("Add at \(DayflowOpenSlotFinder.label(start: chosen, minutes: draft.minutes))")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.dayflowAccent))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 11)
            }
        }
    }

    private var lengths: some View {
        HStack(spacing: 7) {
            ForEach([30, 60, 120], id: \.self) { m in
                Button(intent: DayflowSetLengthIntent(minutes: m)) {
                    Text(Self.duration(m).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(draft.minutes == m ? Color.dayflowAccent : Color.dayflowHairline,
                                    lineWidth: 1))
                        .foregroundStyle(draft.minutes == m ? Color.dayflowAccent : Color.dayflowMuted)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    static func duration(_ minutes: Int) -> String {
        if minutes <= 0 { return "0m" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

// MARK: - Chip wrapping

/// A snippet cannot borrow `SatchelFlowLayout` (different target) and chips have
/// to wrap, so this is the same idea in a few lines.
struct DayflowSnippetFlow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
