import SwiftUI
import UIKit

// MARK: - DayflowDayBlocksView
//
// The day laid out against the clock (Session 103). Pick a date on the month
// grid, see it as proportional blocks, with the day's tasks in a band at the
// foot of the screen.
//
// **What this is not.** It does not replace THE DAY on the home screen. That
// section is a list on purpose, settled over six rounds on the Skin canvas in
// Session 77: no cards, hairline rules, gap time as a parenthetical, finished
// meetings folded away. The two answer different questions — home answers
// "what is next", this answers "what does that day look like" — and a screen
// that tried to be both would lose the argument twice.
//
// **Almost nothing here is new, and that is deliberate.**
//   - The month grid is `DayflowMonthGridView`, the same one the when-picker
//     and Browse use, dots and all.
//   - The colours are `DayflowMeetingColors`, which already sorts the calendar
//     by keyword and already carries a `block` shade for exactly this. Its own
//     header notes that colouring blocks by meaning was wanted and unbuilt.
//   - A tap on empty time opens `DayflowEventComposer` at that minute — the
//     same composer behind Today's plus, with its own drag track, snapping,
//     buffers and overlap warning. Nothing about creating an event was
//     reinvented here.
//   - The task band hosts `DayflowTodaySection` in its `todoOnly` mode, so the
//     rows are the real ones: staged completion, the two-second undo, the
//     swipes, the edit sheet.
//
// The genuinely new part is the vertical layout: minutes to points, the
// overlap columns, and the now line.
//
// **Read-only about TIME** (David's call, Session 103: "view first"). Checking
// a task off writes, because that is what a task row does everywhere in this
// app; creating an event writes, because the composer already did. What this
// screen does not do is let a task be dragged onto the clock to give it a
// time. That is the planner, it is a much larger build, and it needs its own
// decision about whether a dropped block is a calendar event, a dated task, or
// a third thing only Dayflow knows about — which is how two systems start
// disagreeing about his day.
//
// `Dayflow/` is a buildable folder, so this file needs no `project.pbxproj`
// edit.

struct DayflowDayBlocksView: View {

    var onBack: () -> Void = { }

    @State private var selectedDate: Date
    @State private var monthCursor: Date
    @State private var monthOpen = true
    @State private var events: [NextCalendarEvent] = []
    @State private var noteDates: Set<Date> = []
    @State private var loaded = false
    @State private var bandOpen = false
    @State private var selectedEvent: NextCalendarEvent?
    @State private var compose: ComposeRequest?
    /// "Now" as of the last load. Deliberately not a ticking clock: the line
    /// moves on load, on a date change and on every scene activation, which is
    /// the same contract `DayflowTodaySection.nowTick` already keeps. A timer
    /// redrawing a full day of blocks every minute buys a pixel.
    @State private var nowTick = Date()
    @Environment(\.scenePhase) private var scenePhase

    init(date: Date = Date(), onBack: @escaping () -> Void = { }) {
        self.onBack = onBack
        _selectedDate = State(initialValue: Calendar.current.startOfDay(for: date))
        _monthCursor = State(initialValue: Calendar.current.startOfDay(for: date))
    }

    // MARK: Geometry
    //
    // One point per minute, so an hour is 60 and a half-hour block is legible
    // without a special case. The whole 24 hours are drawn and scrolled rather
    // than a 7-to-10 window: the empty stretches are the part of this picture
    // that says where the room is, and a window that clipped a 6am rehab would
    // be lying about the morning.

    private static let minuteHeight: CGFloat = 1.0
    private static let gutter: CGFloat = 52
    private static let dayMinutes = 24 * 60

    private var cal: Calendar { Calendar.current }
    private var isToday: Bool { cal.isDateInToday(selectedDate) }

    private func minutes(_ date: Date) -> Int {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func y(_ minute: Int) -> CGFloat { CGFloat(minute) * Self.minuteHeight }

    // MARK: Data

    private var timed: [NextCalendarEvent] {
        events
            .filter { !$0.isAllDay }
            .filter { !CalendarService.isExcludedPlaceholderTitle($0.title) }
            .sorted { $0.startDate < $1.startDate }
    }

    private var allDay: [NextCalendarEvent] {
        events
            .filter { $0.isAllDay }
            .filter { !CalendarService.isExcludedPlaceholderTitle($0.title) }
    }

    private var dayTasks: [ThingsTask] { DayflowTodaySection.tasks(for: selectedDate) }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            picker
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
            if !allDay.isEmpty { allDayBand }
            timeline
        }
        .background(Color.dayflowPaper.ignoresSafeArea())
        .overlay(alignment: .bottom) { taskBand }
        .task(id: dayKey) { await load() }
        .task(id: monthKey) { await loadNoteDates() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await load() }
        }
        // Same reason as the home section's (D399): a calendar unticked in
        // Settings has to reach this screen without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: .dayflowIncludedCalendarsDidChange)) { _ in
            Task { await load() }
        }
        .sheet(item: $selectedEvent) { event in
            NavigationStack { DayflowEventDetailView(event: event) }
        }
        .sheet(item: $compose) { request in
            DayflowEventComposer(initialDate: request.day,
                                 initialStartMinutes: request.startMinutes) { saved in
                selectedDate = Calendar.current.startOfDay(for: saved)
                Task { await load() }
            }
        }
    }

    private var dayKey: String { Self.key(selectedDate) }
    private var monthKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: monthCursor)
    }
    private static func key(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.dayflowInk).frame(height: 3)
            HStack(alignment: .center, spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Color.dayflowAccent)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DAY")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(Color.dayflowAccent)
                    Text(titleLabel)
                        .font(.dayflowSerif(21, weight: .heavy))
                        .foregroundStyle(Color.dayflowInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                if !isToday {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedDate = cal.startOfDay(for: Date())
                            monthCursor = selectedDate
                        }
                    } label: {
                        Text("TODAY")
                            .font(.system(size: 10.5, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(Color.dayflowAccent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .overlay(Capsule().stroke(Color.dayflowAccent, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 7)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
        }
    }

    private var titleLabel: String {
        let f = DateFormatter()
        f.dateFormat = cal.isDate(selectedDate, equalTo: Date(), toGranularity: .year)
            ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return f.string(from: selectedDate)
    }

    // MARK: The date picker — month, folding to its week

    @ViewBuilder
    private var picker: some View {
        if monthOpen {
            VStack(spacing: 0) {
                DayflowMonthGridView(monthCursor: $monthCursor,
                                     selectedDate: selectedDate,
                                     datesWithNotes: noteDates) { day in
                    UISelectionFeedbackGenerator().selectionChanged()
                    selectedDate = cal.startOfDay(for: day)
                    // **Pick a day and the month gets out of the way.** The
                    // same rule `DayflowMonthUnfold` states for the home
                    // screen: "tap a day = fold + go there". Left open, the
                    // grid and the all-day band between them owned the screen
                    // and the day itself had one visible hour.
                    withAnimation(.easeInOut(duration: 0.22)) { monthOpen = false }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { monthOpen = false }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(spacing: 0) {
                weekStrip
                // **The way back, and it has to be a control.**
                //
                // The first version put `.onTapGesture` on the strip itself and
                // that was unreachable: every day in the row is a Button with
                // `frame(maxWidth: .infinity)`, so the seven of them cover the
                // whole strip and the gesture had nowhere left to fire. David
                // found it the only way anyone finds this class of thing —
                // *"there is no way i can tell to get that one row back to a
                // month view unless i exit to the main dayflow screen then go
                // back."*
                //
                // A chevron, in the same place and the same size as the one
                // that folded it, pointing the other way. A control that closes
                // something and no control that opens it is half a control.
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { monthOpen = true }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the month")
            }
        }
    }

    /// The selected day's week, Monday first — the same week definition the
    /// rest of the app uses (`NoteStore.weekStart`), never a second one.
    private var weekStrip: some View {
        let start = NoteStore.weekStart(for: selectedDate)
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let letter = DateFormatter()
        letter.dateFormat = "EEEEE"
        return HStack(spacing: 0) {
            ForEach(days, id: \.timeIntervalSince1970) { day in
                let isSel = cal.isDate(day, inSameDayAs: selectedDate)
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    selectedDate = cal.startOfDay(for: day)
                } label: {
                    VStack(spacing: 3) {
                        Text(letter.string(from: day).uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Color.dayflowFaint)
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 14.5, weight: isSel ? .bold : .regular))
                            .foregroundStyle(isSel ? Color.dayflowPaper : Color.dayflowInk)
                            .frame(width: 26, height: 26)
                            .background(isSel ? Color.dayflowAccent : .clear, in: Circle())
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }

    // MARK: All-day

    private var allDayBand: some View {
        VStack(spacing: 0) {
            ForEach(allDay, id: \.id) { ev in
                Button { selectedEvent = ev } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DayflowMeetingColor.classify(ev.title, organizer: ev.organizerName).block
                                  ?? Color.dayflowFaint)
                            .frame(width: 3, height: 13)
                        Text(ev.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.dayflowMuted)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
    }

    // MARK: The timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    tapLayer
                    hourRules
                    blocks
                    if isToday { nowLine }
                }
                .frame(height: y(Self.dayMinutes) + 24)
                .padding(.bottom, 96)   // room for the collapsed task band
            }
            .scrollIndicators(.hidden)
            .onChange(of: dayKey) { _, _ in scroll(proxy, animated: true) }
            .onChange(of: loaded) { _, isLoaded in
                if isLoaded { scroll(proxy, animated: false) }
            }
        }
    }

    /// Where the day opens. Today lands on now; any other day on its first
    /// meeting; a day with nothing on it lands at 8am rather than at midnight,
    /// which is three screens of nothing.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        let hour: Int = {
            if isToday { return max(0, cal.component(.hour, from: Date()) - 1) }
            if let first = timed.first { return max(0, cal.component(.hour, from: first.startDate) - 1) }
            return 8
        }()
        let go = { proxy.scrollTo("hour-\(hour)", anchor: .top) }
        if animated { withAnimation(.easeInOut(duration: 0.25)) { go() } } else { go() }
    }

    /// **The empty stretches are a control, not a background.** Tapping one
    /// opens the composer at that half hour — the "put something in the gap"
    /// half of the Shortcuts card, which is why this screen needs no event
    /// editor of its own.
    ///
    /// It sits UNDER the blocks in the `ZStack` on purpose: a tap that lands
    /// on a meeting has to open that meeting, and a transparent layer over the
    /// top would swallow it.
    ///
    /// **One view that reads where the finger landed, not 48 stacked targets.**
    /// The first version laid a clear rectangle over every half hour: 48 views
    /// and 48 gestures, on a screen already drawing 24 rules and a day of
    /// blocks, all inside a ScrollView. `SpatialTapGesture` hands over the
    /// y-coordinate, so the arithmetic that was encoded in a stack of views is
    /// just arithmetic again.
    private var tapLayer: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    let minute = Int((value.location.y - 10) / Self.minuteHeight)
                    openComposer(atMinute: max(0, min(minute, Self.dayMinutes - 60)))
                }
            )
    }

    private var hourRules: some View {
        ForEach(0..<24, id: \.self) { hour in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.dayflowHairline)
                    .frame(height: 1)
                    .padding(.leading, Self.gutter)
                Text(hourLabel(hour))
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Color.dayflowFaint)
                    .frame(width: Self.gutter - 8, alignment: .trailing)
                    .offset(y: -6)
            }
            .id("hour-\(hour)")
            .offset(y: y(hour * 60) + 10)
            .allowsHitTesting(false)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12 AM"
        case 12: return "NOON"
        case 1...11:  return "\(hour) AM"
        default: return "\(hour - 12) PM"
        }
    }

    private var blocks: some View {
        GeometryReader { geo in
            let lane = geo.size.width - Self.gutter - 14
            ForEach(laidOut, id: \.event.id) { placed in
                let width = lane / CGFloat(placed.columns)
                Button { selectedEvent = placed.event } label: {
                    blockBody(placed)
                }
                .buttonStyle(.plain)
                .frame(width: max(40, width - 4),
                       height: max(20, placed.height),
                       alignment: .topLeading)
                .offset(x: Self.gutter + width * CGFloat(placed.column),
                        y: placed.top + 10)
            }
        }
    }

    private func blockBody(_ placed: PlacedEvent) -> some View {
        let colour = DayflowMeetingColor.classify(placed.event.title,
                                                   organizer: placed.event.organizerName).block
            ?? Color.dayflowFaint
        return VStack(alignment: .leading, spacing: 2) {
            Text(placed.event.title)
                .font(.system(size: placed.height < 34 ? 11.5 : 12.5, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
                .lineLimit(placed.height < 34 ? 1 : 2)
            // Under about 34 points there is room for a title and nothing
            // else, and a clipped second line reads as a rendering fault.
            if placed.height >= 34, let sub = subtitle(placed.event) {
                Text(sub)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.dayflowMuted)
                    .lineLimit(placed.height >= 56 ? 2 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(colour.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle().fill(colour).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .contentShape(Rectangle())
    }

    private func subtitle(_ ev: NextCalendarEvent) -> String? {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        var parts = [f.string(from: ev.startDate)]
        if let place = ev.location?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            parts.append(place)
        }
        return parts.joined(separator: " · ")
    }

    private var nowLine: some View {
        let m = minutes(nowTick)
        let f = DateFormatter(); f.dateFormat = "h:mm"
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.dayflowAccent)
                .frame(height: 1.5)
                .padding(.leading, Self.gutter - 8)
            Circle()
                .fill(Color.dayflowAccent)
                .frame(width: 7, height: 7)
                .offset(x: Self.gutter - 11.5, y: -3)
            Text(f.string(from: nowTick))
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(Color.dayflowAccent)
                .frame(width: Self.gutter - 16, alignment: .trailing)
                .offset(y: -6)
        }
        .offset(y: y(m) + 10)
        .allowsHitTesting(false)
    }

    // MARK: The task band

    private var taskBand: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    bandOpen.toggle()
                    // Two expanded things leave no day. The same argument
                    // `daysButton` makes on the home screen: a month grid and
                    // something else claiming the screen at once is two
                    // controls answering one question.
                    if bandOpen { monthOpen = false }
                }
            } label: {
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.dayflowHairline)
                        .frame(width: 34, height: 4)
                        .padding(.top, 7)
                        .padding(.bottom, 6)
                    HStack(spacing: 9) {
                        // **Only when closed.** Open, `DayflowTodaySection`
                        // draws its own TO DO rule an inch below this one, and
                        // two identical labels that close together read as a
                        // rendering fault rather than a heading.
                        if !bandOpen {
                            Text("TO DO")
                                .font(.system(size: 10, weight: .heavy))
                                .tracking(1.6)
                                .foregroundStyle(Color.dayflowAccent)
                            // Collapsed, it is a count and the next thing — the
                            // shape David chose for Satchel on Coming Up (D391).
                            Text(collapsedSummary)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.dayflowInk)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: bandOpen ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dayflowFaint)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, bandOpen ? 8 : 20)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if bandOpen {
                // The REAL rows, not a copy: `todoOnly` leaves THE DAY out, so
                // the meetings are not drawn twice on one screen.
                //
                // **The horizontal padding is not decoration.** This section is
                // written for a parent that pads it — `ContentView` wraps it in
                // a `.padding()` VStack — so hosted bare it ran its rows to
                // both edges and clipped its own "n remain" off the right.
                ScrollView {
                    DayflowTodaySection(date: selectedDate, todoOnly: true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .frame(maxHeight: 260)
            }
        }
        .background(Color.dayflowPanel)
        .overlay(alignment: .top) { Rectangle().fill(Color.dayflowHairline).frame(height: 1) }
        .shadow(color: .black.opacity(0.10), radius: 10, y: -4)
    }

    private var collapsedSummary: String {
        let tasks = dayTasks
        guard let next = tasks.first else { return "Nothing due" }
        return "\(tasks.count) \(isToday ? "today" : "this day") · \(next.title)"
    }

    // MARK: Composer

    private struct ComposeRequest: Identifiable {
        let day: Date
        let startMinutes: Int
        var id: String { "\(day.timeIntervalSinceReferenceDate)-\(startMinutes)" }
    }

    private func openComposer(atMinute minute: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        compose = ComposeRequest(day: selectedDate, startMinutes: (minute / 15) * 15)
    }

    // MARK: Load

    private func load() async {
        nowTick = Date()
        events = await CalendarService.shared.fetchDayEvents(for: selectedDate)
        loaded = true
    }

    /// The grid's dots mean the same thing here as they do in Browse: a day
    /// with a day note behind it. Meetings deliberately do not drive them —
    /// one dot channel, one meaning, or the dot stops telling you anything.
    private func loadNoteDates() async {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let names = (try? NoteStore.shared.listFiles(in: "Calendar")) ?? []
        let dates = names.compactMap { name -> Date? in
            let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            return f.date(from: stem)
        }
        noteDates = Set(dates.map { Calendar.current.startOfDay(for: $0) })
    }

    // MARK: Overlap layout

    /// One event, positioned.
    private struct PlacedEvent {
        let event: NextCalendarEvent
        let top: CGFloat
        let height: CGFloat
        /// Which column of its overlapping cluster, and how many there are.
        let column: Int
        let columns: Int
    }

    /// Events split into clusters that overlap transitively, each cluster's
    /// members given the first column free at their start time.
    ///
    /// **Transitively is the word that matters.** A 9-to-11 and a 10-to-12 do
    /// not overlap a 11:30-to-12:30, but all three belong in one cluster: if
    /// the third were laid out on its own it would be drawn full width across
    /// the second. Columns are counted per cluster, so a day with one clash at
    /// 10am does not draw every other meeting at half width.
    private var laidOut: [PlacedEvent] {
        let sorted = timed
        guard !sorted.isEmpty else { return [] }

        var out: [PlacedEvent] = []
        var cluster: [NextCalendarEvent] = []
        var clusterEnd = Date.distantPast

        func flush() {
            guard !cluster.isEmpty else { return }
            var columnEnds: [Date] = []
            var assigned: [(NextCalendarEvent, Int)] = []
            for ev in cluster {
                var placed = false
                for (i, end) in columnEnds.enumerated() where end <= ev.startDate {
                    columnEnds[i] = ev.endDate
                    assigned.append((ev, i))
                    placed = true
                    break
                }
                if !placed {
                    columnEnds.append(ev.endDate)
                    assigned.append((ev, columnEnds.count - 1))
                }
            }
            let columns = max(1, columnEnds.count)
            for (ev, column) in assigned {
                let s = minutes(ev.startDate)
                // An event running past midnight is clamped to the end of the
                // day rather than drawn off the bottom of a 24-hour canvas.
                let rawEnd = cal.isDate(ev.endDate, inSameDayAs: ev.startDate)
                    ? minutes(ev.endDate) : Self.dayMinutes
                let e = max(s + 15, rawEnd)   // a zero-length event still has to be visible
                out.append(PlacedEvent(event: ev,
                                       top: y(s),
                                       height: y(e - s),
                                       column: column,
                                       columns: columns))
            }
            cluster = []
            clusterEnd = .distantPast
        }

        for ev in sorted {
            if cluster.isEmpty || ev.startDate < clusterEnd {
                cluster.append(ev)
                clusterEnd = max(clusterEnd, ev.endDate)
            } else {
                flush()
                cluster = [ev]
                clusterEnd = ev.endDate
            }
        }
        flush()
        return out
    }
}
