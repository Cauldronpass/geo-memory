// TraceMacUpcomingView.swift
// The next two weeks as a spread. Sidebar destination two (D186).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 80 (2026-08-31), built from the "Trace Mac Day" canvas.
//
// ── Why a spread and not a list ──────────────────────────────────────────
//
// The phone scrolls one column of days because it has one column. A Mac can
// put fourteen day headings on screen at once, and that is the whole reason
// this screen is worth having separately from Today: you are not reading one
// day here, you are looking at the shape of two weeks.
//
// ── Every day gets a heading, including the empty ones ───────────────────
//
// David's call, Session 79: "does upcoming middle column for next week has all
// the days of next week? Right now the mockup didnt show that." The first
// mockup drew only days that had something on them, and a fortnight of six
// entries told him nothing about where the room was.
//
// So every day is drawn, and the weight says which is which: a day with
// something on it wears the 1pt INK rule and an ink numeral, an empty day
// wears a HAIRLINE and a faint one. That contrast is the readability of the
// whole spread — and the empty days are not decoration, they are the drop
// targets D191 will use.
//
// ── The rows are not this screen's ───────────────────────────────────────
//
// Meetings are `MacMeetingRow` and tasks are `MacTaskRow`, the same components
// Today uses, so a card opens here exactly as it opens there (D190). This file
// owns the SPREAD; it does not own what a row looks like, and it must not grow
// its own copy of either — that is precisely how the iOS and Mac markdown
// renderers drifted.

import SwiftUI
import AppKit

struct TraceMacUpcomingView: View {

    /// Today's day, shared with the Today screen so that clicking through from
    /// here lands somewhere sensible. Owned by `TraceMacContentView`.
    @Binding var dayInView: Date
    @Binding var selectedSection: MacSection?

    @State private var eventsByDay: [String: [NextCalendarEvent]] = [:]
    @State private var openTaskID: String? = nil
    @State private var openEventID: String? = nil
    @State private var loadToken: Int = 0

    /// Where the spread starts. Nil means tomorrow, which is the answer
    /// ninety-nine mornings in a hundred.
    ///
    /// Session 80, David's question: "Upcoming is the most logical place to
    /// look at a future date beyond 2 weeks. I like the simplicity of the two
    /// weeks though. If we built a similar view to the upcoming title and I
    /// click it where would the day i click go?" This is the answer — clicking
    /// a day in the month grid MOVES THE WINDOW to start there. Two weeks stays
    /// two weeks; it is the fortnight that travels, so nothing about the
    /// screen's shape has to change to reach October.
    @State private var anchor: Date? = nil
    @State private var monthUnfolded: Bool = false

    private var store: ReminderTaskStore { ReminderTaskStore.shared }
    private let cal = Calendar.current

    /// Fourteen days from the anchor. By default that is TOMORROW — Today has
    /// its own screen and repeating it here would make the first column lie
    /// about what is coming.
    private var days: [Date] {
        let start = anchor ?? cal.date(byAdding: .day, value: 1,
                                       to: cal.startOfDay(for: Date()))!
        return (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private var isAnchored: Bool { anchor != nil }

    private var mastheadKicker: String {
        guard let anchor else { return "Next two weeks" }
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return "Two weeks from \(f.string(from: anchor))"
    }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            spread
        }
        .background(MacEditorialColor.paper)
        .task(id: loadToken) { await load() }
    }

    // MARK: - Masthead

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialMasthead(kicker: mastheadKicker,
                                 title: "Upcoming",
                                 onTapSubject: {
                                     withAnimation(.easeInOut(duration: 0.2)) {
                                         monthUnfolded.toggle()
                                     }
                                 },
                                 unfolded: monthUnfolded)
            if monthUnfolded {
                MacEditorialMonthGrid(selected: anchorBinding)
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
            if isAnchored && !monthUnfolded {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { anchor = nil }
                    reload()
                } label: {
                    Text("Back to now")
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(MacEditorialColor.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, MacEditorialLayout.margin)
        .padding(.top, MacEditorialLayout.topMargin)
    }

    /// The grid writes straight to the anchor and folds itself away. Reading
    /// back the FIRST DAY of the spread keeps the selected cell in step with
    /// what is actually on screen.
    private var anchorBinding: Binding<Date> {
        Binding(
            get: { days.first ?? Date() },
            set: { picked in
                withAnimation(.easeInOut(duration: 0.2)) {
                    anchor = cal.startOfDay(for: picked)
                    monthUnfolded = false
                }
                reload()
            }
        )
    }

    // MARK: - Spread

    private var spread: some View {
        HStack(spacing: 0) {
            column(Array(days.prefix(7)), caption: "This week")
            Rectangle()
                .fill(MacEditorialColor.hairline)
                .frame(width: 1)
            column(Array(days.suffix(7)), caption: "Next week")
        }
    }

    private func column(_ block: [Date], caption: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .editorialGroupLabel()
                    .padding(.bottom, 8)
                ForEach(Array(block.enumerated()), id: \.element) { pair in
                    monthMasthead(for: pair.element, isFirst: pair.offset == 0)
                    day(pair.element)
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 26)
            .padding(.top, 16)
        }
    }

    /// The month name appears where the month TURNS, not at the top of every
    /// column — same as the phone. The first day of a column gets one only if
    /// it is also the first of a month, otherwise the caption above it already
    /// says where you are.
    @ViewBuilder
    private func monthMasthead(for day: Date, isFirst: Bool) -> some View {
        let turns: Bool = cal.component(.day, from: day) == 1
        if turns && !isFirst {
            VStack(alignment: .leading, spacing: 0) {
                Text(monthName(day))
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(3)
                    .foregroundStyle(MacEditorialColor.accent)
                MacEditorialRule.accent
                    .padding(.top, 3)
            }
            .padding(.top, 18)
            .padding(.bottom, 12)
        }
    }

    // MARK: A day

    private func day(_ day: Date) -> some View {
        let key: String = Self.key(day)
        let meetings: [NextCalendarEvent] = (eventsByDay[key] ?? [])
            .filter { !$0.isAllDay }
        let allDay: [NextCalendarEvent] = (eventsByDay[key] ?? []).filter { $0.isAllDay }
        let tasks: [ThingsTask] = tasksOn(day)
        let occupied: Bool = !meetings.isEmpty || !allDay.isEmpty || !tasks.isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            heading(day, occupied: occupied)
            ForEach(allDay) { event in
                Text(event.title)
                    .editorialQuietLabel()
                    .lineLimit(1)
                    .frame(height: 22)
            }
            ForEach(meetings) { event in
                MacMeetingRow(event: event,
                              isOpen: openEventID == event.id,
                              onToggle: { toggle(event) },
                              nextOwnStart: nextOwnStart(after: event, on: key))
            }
            if !meetings.isEmpty && !tasks.isEmpty {
                MacEditorialRule.hair.padding(.top, 5)
            }
            ForEach(tasks) { task in
                MacTaskRow(task: task,
                           isOpen: openTaskID == task.id,
                           onToggle: { toggle(task) },
                           onChanged: { reload() })
            }
        }
        .padding(.bottom, occupied ? 15 : 12)
    }

    /// A day with something on it wears an ink numeral over a 1pt ink rule; an
    /// empty one a faint numeral over a hairline. Tomorrow's label is in accent
    /// because it is the only day on this screen that is about to happen.
    private func heading(_ day: Date, occupied: Bool) -> some View {
        let numeralTint: Color = occupied ? MacEditorialColor.ink : MacEditorialColor.faint
        let isTomorrow: Bool = cal.isDateInTomorrow(day)
        let labelTint: Color = isTomorrow ? MacEditorialColor.accent : MacEditorialColor.faint
        let label: String = isTomorrow ? "Tomorrow" : weekdayName(day)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Text(String(cal.component(.day, from: day)))
                    .font(MacEditorialType.dayNumeral)
                    .foregroundStyle(numeralTint)
                Text(label)
                    .font(.system(size: 9.5, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(1.8)
                    .foregroundStyle(labelTint)
                Spacer(minLength: 0)
            }
            Group {
                if occupied { MacEditorialRule.ink } else { MacEditorialRule.hair }
            }
            .padding(.top, 3)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(day) }
    }

    // MARK: - Data

    private func tasksOn(_ day: Date) -> [ThingsTask] {
        store.upcomingTasks.filter { task in
            guard let due = task.date else { return false }
            return cal.isDate(due, inSameDayAs: day)
        }
    }

    /// Per-day, and his calendars only — the same rule Today uses (D194 final).
    private func nextOwnStart(after event: NextCalendarEvent, on key: String) -> Date? {
        let choices = MacCalendarChoices.shared
        return (eventsByDay[key] ?? [])
            .filter { !$0.isAllDay && !choices.isForeign($0.calendarIdentifier) }
            .sorted { $0.startDate < $1.startDate }
            .first { $0.startDate >= event.endDate }?
            .startDate
    }

    /// Fourteen day queries rather than one ranged one, deliberately:
    /// `fetchDayEvents` is where the placeholder filter and the included-
    /// calendar filter both live (Session 80), and a second ranged query here
    /// would be a second place for those rules to be forgotten.
    private func load() async {
        await MacCalendarChoices.shared.load()
        await store.refreshAll()
        var gathered: [String: [NextCalendarEvent]] = [:]
        for day in days {
            gathered[Self.key(day)] = await CalendarService.shared.fetchDayEvents(for: day)
        }
        eventsByDay = gathered
    }

    private func reload() { loadToken += 1 }

    // MARK: - Interaction

    private func toggle(_ task: ThingsTask) {
        openEventID = nil
        openTaskID = (openTaskID == task.id) ? nil : task.id
    }

    private func toggle(_ event: NextCalendarEvent) {
        openTaskID = nil
        openEventID = (openEventID == event.id) ? nil : event.id
    }

    /// Double-click a day heading to open that day on Today. The spread is for
    /// seeing the shape of two weeks; the moment you want to work inside one of
    /// them, you want the other screen.
    private func open(_ day: Date) {
        dayInView = cal.startOfDay(for: day)
        selectedSection = .today
    }

    // MARK: - Formatting

    private func weekdayName(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: day)
    }

    private func monthName(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f.string(from: day)
    }

    static func key(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }
}
