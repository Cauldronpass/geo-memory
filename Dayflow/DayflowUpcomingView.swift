import SwiftUI
import UIKit

// MARK: - DayflowUpcomingView
//
// Step (e) of the task UI build (Session 77, Dayflow-Tasks-Design.md §
// Upcoming) — the last structural piece. Editorial rewrite of the old
// browse screen (see git for its Things-era history):
//
// - Two weeks starting tomorrow (Today's card owns today). Day headings
//   ONLY for days with something — the locked design dropped the empty
//   headers the old mockup kept.
// - Each day: its events (time · colour square · title, same language as
//   Today's strip) then its tasks (ink circle completes, serif title, tap
//   edits). Every task shows its list as a sub-label. The old "from Trace ·
//   yearly" special case retired with the Trace list itself (D491).
// - Footer, whole row tappable: "Nothing until <date>" — the next dated
//   reminder BEYOND the two weeks (the store already looks 60 days out) —
//   over "Open Reminders", which opens Apple's app.
//

struct DayflowUpcomingView: View {
    @Environment(\.dismiss) private var dismiss
    /// Session 77: true when hosted as the Upcoming tab in DayflowRootView —
    /// hides the chevron (there is no presentation to dismiss there).
    var isTabRoot: Bool = false

    @State private var days: [Date] = []
    @State private var eventsByDay: [Date: [NextCalendarEvent]] = [:]
    /// Session 78 — David's fold: "a small icon that would fold all the
    /// meetings away... and only show tasks". ONE global toggle (a per-day
    /// icon would be fourteen taps), persisted: a lens preference, not a
    /// transient state. Folded days keep a faint meeting count so a full
    /// day can't masquerade as an empty one while he's dating tasks into it.
    @AppStorage("dayflow_upcoming_tasks_only") private var tasksOnly = false
    /// Session 78, D173 — future-meeting prep: Upcoming's meeting rows grow
    /// the same AGENDA line Today's have (shared DayflowAgendaMatch).
    /// Folded away with the meetings under the tasks-only lens.
    @State private var expandedAgendas: Set<String> = []
    @State private var agendaNotes: [String: [NoteMention]] = [:]
    @State private var taskWikiTarget: WikiLinkTarget? = nil
    /// Session 78 evening — the FAB Upcoming never had (David: "shouldnt
    /// upcoming have a plus button for events like Today? and... no way to
    /// add a task"). Tap = the event composer; HOLD = the task capture card
    /// (routes through the quick-action pipe — the Inbox tab opens with the
    /// cursor ready, the hop automated away).
    @State private var showEventComposer = false
    @State private var fabLongPressed = false
    /// Session 78, D175 — meeting-row swipes, Today's exact pair.
    @State private var eventDragOffsets: [String: CGFloat] = [:]
    @State private var meetingTaskEvent: NextCalendarEvent? = nil
    @State private var windowEnd: Date = Date()
    /// Session 81 (D240, D195's port) — the fortnight's anchor. nil = now
    /// (start tomorrow); set by the masthead's month grid. The spread is
    /// always fourteen days; only where it STARTS moves.
    @State private var anchor: Date? = nil
    @State private var monthOpen = false
    @State private var isLoading = true
    @State private var editingTask: ThingsTask? = nil
    @State private var selectedEvent: NextCalendarEvent? = nil
    /// Session 77 — the Today card's swipe treatment, verbatim (David: "i
    /// would like the same swiping treatment as what we have in Today"):
    /// left = multi-select (RootView shows the shared bar), right = the When
    /// sheet with the calendar-glyph reveal.
    /// Every endeavor's name, loaded once per screen (D270, Session 88).
    ///
    /// **The row is handed a `Set`; it never reaches for one.**
    /// `EndeavorFile.nameIndex` walks the endeavor files, which is cheap once
    /// per screen and unaffordable once per row - the Mac's own split, and the
    /// same reasoning as `docStore` being built lazily on its task row.
    @State private var endeavorNames: Set<String> = []
    @State private var selection = DayflowTodaySelection.shared
    @State private var whenRequest: DayflowWhenRequest? = nil
    @State private var rowDragOffsets: [String: CGFloat] = [:]

    private static let windowLength = 14

    private var defaultStart: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
    }

    private var kickerText: String {
        guard let anchor else { return "NEXT TWO WEEKS" }
        let f = DateFormatter(); f.dateFormat = "MMMM d"
        return "TWO WEEKS FROM \(f.string(from: anchor).uppercased())"
    }

    /// Dated tasks in the window, grouped by day — computed straight off the
    /// live store so completions prune rows on their own.
    private var tasksByDay: [Date: [ThingsTask]] {
        let cal = Calendar.current
        var grouped: [Date: [ThingsTask]] = [:]
        // `allTasks`, not `upcomingTasks` (Session 81, D240): the store's
        // upcoming pool stops 60 days out (its own window), and an anchored
        // fortnight past that line would show the day's events and silently
        // NO tasks — a screen quietly lying about what September holds. The
        // full pool is already in memory; `daysWithContent` bounds rendering.
        for task in ReminderTaskStore.shared.allTasks {
            guard let date = task.date else { continue }
            grouped[cal.startOfDay(for: date), default: []].append(task)
        }
        return grouped
    }

    /// **Takes the grouping instead of reaching for it** (D436). `tasksByDay`
    /// walks the entire task pool to build its dictionary. As a computed
    /// property this filter called it once or twice per day, and
    /// `startsNewMonth` called this list again for every day drawn, so a
    /// fortnight cost hundreds of passes over every task on every redraw. That
    /// is what made the scroll jump. The body works both out once and hands
    /// them down.
    private func daysWithContent(_ grouped: [Date: [ThingsTask]]) -> [Date] {
        days.filter { day in
            if tasksOnly { return !(grouped[day] ?? []).isEmpty }
            return !(eventsByDay[day] ?? []).isEmpty || !(grouped[day] ?? []).isEmpty
        }
    }

    /// The next dated reminder past the two-week window — the footer's date.
    private var nextBeyondWindow: Date? {
        ReminderTaskStore.shared.allTasks
            .compactMap(\.date)
            .filter { $0 >= windowEnd }
            .min()
    }

    var body: some View {
        let grouped = tasksByDay
        return screen(grouped: grouped, visible: daysWithContent(grouped))
    }

    /// The screen, handed the grouping and the day list already worked out
    /// (D436). Nothing below this line reaches for `tasksByDay` again.
    private func screen(grouped: [Date: [ThingsTask]], visible: [Date]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isLoading && visible.isEmpty {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    // **Lazy since D436.** Every day, every meeting and every
                    // task row used to be built before the first one appeared,
                    // and since D428 each task row also carries a long-press
                    // menu. Lazily built, only the rows on screen exist.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if visible.isEmpty {
                            Text("Two clear weeks ahead.")
                                .font(.dayflowSerif(16))
                                .foregroundStyle(Color.dayflowMuted)
                                .padding(.top, 32)
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(visible, id: \.self) { day in
                                daySection(day, tasks: grouped[day] ?? [], visible: visible)
                            }
                        }
                        footer
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }
            }
        }
        .dayflowSkinBackground()
        .overlay(alignment: .bottomTrailing) {
            if isTabRoot {
                Button {
                    if fabLongPressed { fabLongPressed = false; return }
                    showEventComposer = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.dayflowPaper)
                        .frame(width: 50, height: 50)
                        .background(Color.dayflowFloatingAction, in: RoundedRectangle(cornerRadius: 2))
                        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        fabLongPressed = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        DayflowQuickActionRouter.shared.pending = "AddTask"
                    }
                )
                .padding(.trailing, 20)
                .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showEventComposer) {
            DayflowEventComposer(initialDate: Date()) { _ in
                Task { await load() }
            }
        }
        .sheet(item: $taskWikiTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target, sourceNoteText: "")
            }
        }
        .sheet(item: $meetingTaskEvent) { event in
            DayflowMeetingTaskSheet(event: event)
        }
        .task { await load() }
        .task { endeavorNames = Set(EndeavorFile.nameIndex(from: NoteStore.shared).keys) }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await ReminderTaskStore.shared.fetchUpcoming() }
            }
        }
        .sheet(item: $selectedEvent) { event in
            NavigationStack { DayflowEventDetailView(event: event) }
        }
        .sheet(item: $whenRequest) { request in
            DayflowWhenSheet(tasks: request.tasks)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isTabRoot {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            // D195's port (Session 81, D240): the kicker never silently
            // lies about what the screen shows — "NEXT TWO WEEKS" at rest,
            // "TWO WEEKS FROM <day>" while anchored, with a quiet accent way
            // home beside it.
            HStack(spacing: 10) {
                Text(kickerText)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2.2)
                    .foregroundStyle(Color.dayflowMuted)
                if anchor != nil {
                    Button {
                        anchor = nil
                        withAnimation(.easeInOut(duration: 0.18)) { monthOpen = false }
                        UISelectionFeedbackGenerator().selectionChanged()
                        Task { await load() }
                    } label: {
                        Text("BACK TO NOW")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(2.2)
                            .foregroundStyle(Color.dayflowAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(alignment: .center) {
                // The title is the door (Today's month-unfold grammar): tap
                // unfolds the same grid, and picking a day ANCHORS the
                // fortnight to start there — two weeks stays two weeks, the
                // window travels. D195: the only answer that changes nothing
                // about the screen.
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { monthOpen.toggle() }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 8) {
                        Text("Upcoming")
                            .font(.dayflowSerif(30, weight: .heavy))
                            .foregroundStyle(Color.dayflowInk)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dayflowFaint)
                            .rotationEffect(.degrees(monthOpen ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { tasksOnly.toggle() }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: tasksOnly ? "calendar.badge.minus" : "calendar")
                        .font(.system(size: 15))
                        .foregroundStyle(tasksOnly ? Color.dayflowAccent : Color.dayflowFaint)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tasksOnly ? "Show meetings" : "Hide meetings")
            }
            if monthOpen {
                DayflowMonthUnfold(selectedDate: anchor ?? defaultStart, onPick: { day in
                    anchor = Calendar.current.startOfDay(for: day)
                    withAnimation(.easeInOut(duration: 0.18)) { monthOpen = false }
                    UISelectionFeedbackGenerator().selectionChanged()
                    Task { await load() }
                }, hint: "tap a day to anchor the fortnight")
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, isTabRoot ? 22 : 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dayflowQuickFindPull(enabled: isTabRoot)
    }

    // MARK: Day sections

    /// True for the first RENDERED day of a month that isn't the first
    /// month on screen — the crossover David asked to see (2026-08-29: "when
    /// we have a cross over into a new month... I would expect the 1 Tuesday
    /// September to show up"). Named like a newspaper: a month masthead
    /// between the sections, not a longer day label.
    private func startsNewMonth(_ day: Date, in visible: [Date]) -> Bool {
        guard let idx = visible.firstIndex(of: day), idx > 0 else { return false }
        return !Calendar.current.isDate(day, equalTo: visible[idx - 1],
                                        toGranularity: .month)
    }

    private func monthLabel(_ day: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM"
        return f.string(from: day).uppercased()
    }

    private func daySection(_ day: Date, tasks: [ThingsTask], visible: [Date]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if startsNewMonth(day, in: visible) {
                HStack(spacing: 10) {
                    Text(monthLabel(day))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2.4)
                        .foregroundStyle(Color.dayflowAccent)
                    Rectangle().fill(Color.dayflowAccent).frame(height: 2)
                }
                .padding(.top, 26)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dayNumberLabel(day))
                    .font(.dayflowSerif(20, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                Text(dayNameLabel(day))
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(Color.dayflowFaint)
            }
            .padding(.top, 18)
            .padding(.bottom, 5)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)

            if tasksOnly {
                let count = (eventsByDay[day] ?? []).count
                if count > 0 {
                    Text("\(count) meeting\(count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(minHeight: 24)
                }
            } else {
                ForEach(eventsByDay[day] ?? []) { ev in
                    eventRow(ev, in: day)
                    agendaLine(for: ev)
                }
            }
            ForEach(tasks) { task in
                taskRow(task)
            }
        }
    }

    private func eventRow(_ event: NextCalendarEvent, in day: Date) -> some View {
        // NOT a Button (the swipe rule, D175): tap = detail, right = a task
        // for the meeting, left = its running project note.
        HStack(spacing: 12) {
            Text(event.startTimeString)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.dayflowMuted)
                .frame(width: 62, alignment: .leading)
            // D184: the chip speaks David's OWN color key (keyword-driven,
            // ported from his vault reference) — the calendar-source color
            // it replaces meant nothing. No keyword match renders plain.
            Rectangle()
                .fill(DayflowMeetingColor.classify(event.title, organizer: event.organizerName).chip
                      ?? Color.dayflowFaint.opacity(0.55))
                .frame(width: 8, height: 8)
            Text(event.title)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.dayflowInk)
                .lineLimit(1)
            // Session 78 — Today's gap parenthetical, same rule (open
            // time before the NEXT meeting, >=5 min, nothing after the
            // last). One grammar for a day's shape, wherever a day is
            // drawn (David: "wondering about the time available").
            if let gap = gapLabel(after: event, in: day) {
                Text("(\(gap))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dayflowFaint)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .onTapGesture { selectedEvent = event }
        .dayflowMeetingSwipes(event: event,
                              offsets: $eventDragOffsets,
                              onTask: { meetingTaskEvent = event })
    }

    /// Session 78, D173 — the prep line. Same matcher, same look as Today's;
    /// expanded tasks are this screen's own taskRows (swipes, selection).
    @ViewBuilder
    private func agendaLine(for event: NextCalendarEvent) -> some View {
        // D175 round two: title-anchored fallback, same as Today.
        let anchorName = DayflowAgendaMatch.agendaAnchor(forTitle: event.title)
        if let name = Optional(anchorName), !name.isEmpty {
            let tasks = DayflowAgendaMatch.tasks(linkedTo: name)
            // A task-less meeting whose running note exists still gets the
            // line — the note IS agenda (Session 78, the Sarah catch-up).
            let notePath = DayflowAgendaMatch.meetingNotePath(forTitle: event.title)
            if !tasks.isEmpty || notePath != nil {
                let expanded = expandedAgendas.contains(event.id)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expanded { expandedAgendas.remove(event.id) }
                        else { expandedAgendas.insert(event.id) }
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 74)
                        Text("AGENDA \u{00B7} \(tasks.count + (notePath == nil ? 0 : 1))")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.4)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color.dayflowFaint)
                    .frame(minHeight: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tasks) { task in
                            taskRow(task, agendaDay: event.startDate)
                        }
                        agendaNoteRows(for: event.id, title: event.title)
                    }
                    .padding(.leading, 28)
                    .task {
                        if agendaNotes[event.id] == nil {
                            agendaNotes[event.id] = NoteStore.shared.findWikilinkMentions(of: name)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func agendaNoteRows(for eventID: String, title: String) -> some View {
        let mentions = DayflowAgendaMatch.displayNotes(cached: agendaNotes[eventID], forTitle: title)
        if !mentions.isEmpty {
            ForEach(mentions.prefix(4)) { mention in
                let openable = mention.relativePath.hasPrefix("Calendar/")
                    || mention.relativePath.hasPrefix("Notes/Projects/")
                Button {
                    guard openable else { return }
                    DayflowQuickFindRouter.shared.pendingDestination =
                        .dailyOrProjectNote(mention.relativePath)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dayflowFaint)
                            .frame(width: 20)
                        Text(mention.title)
                            .font(.system(size: 13))
                            .foregroundStyle(openable ? Color.dayflowMuted : Color.dayflowFaint)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static func agendaShortDay(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date).uppercased()
    }

    private func gapLabel(after event: NextCalendarEvent, in day: Date) -> String? {
        let events = eventsByDay[day] ?? []
        guard let idx = events.firstIndex(where: { $0.id == event.id }),
              idx + 1 < events.count else { return nil }
        let mins = Int(events[idx + 1].startDate.timeIntervalSince(event.endDate) / 60)
        guard mins >= 5 else { return nil }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private func taskRow(_ task: ThingsTask, agendaDay: Date? = nil) -> some View {
        // **The "from Trace · yearly" sub-label is gone** (D491). It existed to
        // compensate for a list name that said nothing: a repeating reminder in a
        // list called Trace needed the row to explain itself. Birthdays now go to
        // his own Birthdays & Anniversaries, so the list name IS the explanation
        // and the row just shows it, like every other task.
        //
        // The word "yearly" went with it rather than being kept beside the new
        // name. `ThingsTask.repeats` is a Bool and does not know the frequency, so
        // saying "yearly" was only ever safe while one list held nothing but
        // annual dates written by one button. That is a claim about his data the
        // row cannot actually check.
        let selected = selection.ids.contains(task.id)
        return HStack(alignment: .center, spacing: 12) {
            Button {
                if selection.isActive {
                    if selected { selection.ids.remove(task.id) }
                    else { selection.ids.insert(task.id) }
                } else {
                    Task { await ReminderTaskStore.shared.complete(taskID: task.id) }
                }
            } label: {
                Circle()
                    .strokeBorder(Color.dayflowInk, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    // D205's latent twin — see the Today row's note.
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(task.title)")

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 14.5, design: .serif))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(2)
                if let list = task.list, !list.isEmpty {
                    Text(list)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dayflowFaint)
                }
                // Session 81 (D239) — Today's provenance chip, same scanner
                // (`ThingsTask.dayflowSource`): a shortcut runs from the row
                // face, a satchel/trace link opens its app.
                if let source = task.dayflowSource {
                    Button {
                        UIApplication.shared.open(source.url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: source.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(source.label.uppercased())
                                .font(.system(size: 11))
                                .tracking(0.8)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.dayflowAccent)
                    }
                    .buttonStyle(.plain)
                }
                DayflowTaskWikiChips(task: task) { taskWikiTarget = $0 }
            }
            Spacer(minLength: 0)
            if let agendaDay, let due = task.date {
                let after = Calendar.current.startOfDay(for: due)
                    > Calendar.current.startOfDay(for: agendaDay)
                Text(Self.agendaShortDay(due))
                    .font(.system(size: 10.5).monospacedDigit())
                    .tracking(0.6)
                    .foregroundStyle(after ? Color.dayflowAccent : Color.dayflowFaint)
            }
            if let alarm = task.alarmTimeString {
                HStack(spacing: 3) {
                    Image(systemName: "bell")
                        .font(.system(size: 9, weight: .semibold))
                    Text(alarm)
                        .font(.system(size: 11).monospacedDigit())
                }
                .foregroundStyle(Color.dayflowFaint)
            }
            // Flagged (D413/D427): the reminder's priority, in accent, first in
            // the cluster, because it is the one mark he set on purpose.
            if task.flagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
            }
            // See the note mark in DayflowTodaySection for why this reads
            // `hasNoteProse` rather than `notes`.
            if task.hasNoteProse {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
            }
            // D229's link mark — see the note in DayflowTodaySection.
            if task.hasFollowableLink {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
            }
            // **The repeat glyph now shows on every repeating task** (D491). It
            // was suppressed on the old Trace-list rows because their sub-label
            // already read "yearly"; that label is gone, so the glyph is the only
            // thing left saying a task recurs, and it should say it everywhere.
            if task.repeats {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dayflowFaint)
            }
            // **The endeavor mark** (D270). David, on the Mac: *"could you add
            // a small icon indicator when i look at the task that is in an
            // endeavor?"* - and, on the phone one session later, *"there is no
            // icon to tell me that the task I called How'd was from an
            // endeavor."*
            //
            // `flag`, because the Mac sidebar has called an endeavor a flag
            // since the room existed, so the mark needs no learning. The type
            // glyph was rejected on the Mac for a reason that holds here: an
            // airplane on a task row reads as "travel task" rather than "on a
            // trip", and five glyphs meaning one thing is five things to learn.
            //
            // **Faint, not accent.** The note and link marks are accent because
            // they say there is more to open; this is a fact about where the
            // task sits, and a passive mark should not scold.
            //
            // Placed beside `repeat`, the other faint mark, and LAST of the
            // four so it is the one that yields when a title is long. The Mac
            // caps its cluster at three; the phone now draws four in the rare
            // case where a task has prose, a link, an endeavor and a repeat,
            // and that is the row to watch if the cluster ever feels crowded.
            //
            // **No tap target here, deliberately.** Every mark in this cluster
            // is passive, and a 10pt glyph competing with the row tap on a
            // phone is a worse door than the one that already exists: the row
            // opens the task, and its Linked section names the endeavor and
            // opens it (D285, and the resolver in D282).
            // **`bookmark`, not `flag`, since D427.** On a task, `flag` now
            // means flagged (D413), drawn in accent just above; an endeavor
            // link keeps its faint mark under the Mac's new glyph.
            if EndeavorFile.linkedName(in: task.notes, among: endeavorNames) != nil {
                Image(systemName: "bookmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dayflowFaint)
            }
            if selection.isActive {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Color.dayflowAccent : Color.dayflowFaint,
                                      lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if selected {
                        Circle().fill(Color.dayflowAccent).frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dayflowPaper)
                    }
                }
            }
        }
        .frame(minHeight: 38)
        .padding(.horizontal, selection.isActive ? 6 : 0)
        .background(selected ? Color.dayflowAccent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // Long press: the task menu (D428 Flag, D429 the rest; DayflowTaskMenu).
        // Long press to flag (D428). David: *"Isnt there an easier way to flag
        // it"* — the switch was three screens deep. A menu, not a third swipe:
        // right is When and left is select, and a long press is the gesture a
        // phone already offers on every row for "more to do with this".
        .contextMenu {
            DayflowTaskMenu(task: task) { whenRequest = DayflowWhenRequest(tasks: [task]) }
        }
        .onTapGesture {
            if selection.isActive {
                if selected { selection.ids.remove(task.id) }
                else { selection.ids.insert(task.id) }
            } else {
                editingTask = task
            }
        }
        .offset(x: rowDragOffsets[task.id] ?? 0)
        .background(alignment: .leading) {
            let progress = min(max((rowDragOffsets[task.id] ?? 0) / 60, 0), 1)
            if progress > 0 {
                Image(systemName: "calendar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
                    .opacity(Double(progress))
                    .scaleEffect(0.7 + 0.3 * progress)
                    .padding(.leading, 2)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 28)
                .onChanged { value in
                    guard !selection.isActive else { return }
                    let h = value.translation.width
                    guard abs(h) > abs(value.translation.height) else { return }
                    rowDragOffsets[task.id] = h > 0 ? min(h, 80) : 0
                }
                .onEnded { value in
                    let h = value.translation.width
                    withAnimation(.spring(duration: 0.3)) { rowDragOffsets[task.id] = 0 }
                    guard !selection.isActive else { return }
                    guard abs(h) > abs(value.translation.height) * 1.5,
                          abs(h) > 40 else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if h < 0 {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection.isActive = true
                            selection.ids = [task.id]
                        }
                    } else {
                        // A short hop before presenting: a sheet presented in
                        // the same instant the drag ends inherits the tail of
                        // that gesture as ITS drag — David saw the card track
                        // the pointer downward and dismiss itself. Letting
                        // the gesture fully settle first breaks the handoff.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            whenRequest = DayflowWhenRequest(tasks: [task])
                        }
                    }
                }
        )
        .animation(.easeInOut(duration: 0.15), value: selection.isActive)
    }

    // MARK: Footer

    private var footer: some View {
        Button {
            if let url = URL(string: "x-apple-reminderkit://") {
                UIApplication.shared.open(url)
            }
        } label: {
            VStack(spacing: 3) {
                if let next = nextBeyondWindow {
                    Text("Nothing until \(footerDateLabel(next))")
                        .font(.dayflowSerif(15))
                        .foregroundStyle(Color.dayflowMuted)
                } else {
                    Text("Nothing else on the books")
                        .font(.dayflowSerif(15))
                        .foregroundStyle(Color.dayflowMuted)
                }
                Text("Open Reminders")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dayflowFaint)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 26)
    }

    private func footerDateLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func dayNumberLabel(_ day: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: day)
    }

    private func dayNameLabel(_ day: Date) -> String {
        if Calendar.current.isDateInTomorrow(day) { return "TOMORROW" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: day).uppercased()
    }

    // MARK: Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let cal = Calendar.current
        // Anchored, the fortnight starts where he pointed; at rest, tomorrow
        // (Today's card owns today) — D195's default, right ninety-nine
        // mornings in a hundred.
        let start = anchor ?? defaultStart
        let windowDays = (0..<Self.windowLength).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let end = cal.date(byAdding: .day, value: Self.windowLength, to: start) ?? start

        async let events = CalendarService.shared.fetchEvents(from: start, to: end)
        async let taskFetch: Void = ReminderTaskStore.shared.fetchUpcoming()
        let fetchedEvents = await events
        await taskFetch

        var groupedEvents: [Date: [NextCalendarEvent]] = [:]
        for ev in fetchedEvents where !ev.isAllDay {
            let dayStart = cal.startOfDay(for: ev.startDate)
            groupedEvents[dayStart, default: []].append(ev)
        }
        for (day, list) in groupedEvents {
            groupedEvents[day] = list
                .filter { !CalendarService.isExcludedPlaceholderTitle($0.title) }
                .sorted { $0.startDate < $1.startDate }
        }

        days = windowDays
        eventsByDay = groupedEvents
        windowEnd = end
    }
}
