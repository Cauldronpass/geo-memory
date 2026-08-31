//
//  DayflowTodaySection.swift
//  Dayflow
//
//  Steps (b) + the Editorial skin (Session 77, Dayflow-Tasks-Design.md and
//  the "Dayflow Skin" canvas, both locked 2026-08-28): the TO DO and THE DAY
//  sections of the Today sheet. Editorial reads as label + rule on paper —
//  no cards, hairline separators, serif task titles, one accent.
//
//  Behavior (unchanged from the structure round):
//  - Rows are 44pt: circle completes, anywhere else opens the edit sheet.
//  - Completion is staged: tap fills and strikes, the row holds ~2s (tap
//    again to undo, nothing written), then the EventKit write lands and the
//    row slides out. Last one gone: "That's the day."
//  - "Add for today" is an inline text field; return writes to Reminders.
//  - "n done ▾" expands the day's completed reminders; tap unticks.
//  - A task whose notes carry a satchel://, trace://, dayflow:// or
//    shortcuts:// link gets a source chip (bolt for shortcuts).
//
//  New with the skin (David's calls on the canvas, rounds 2-6):
//  - Gap time as a light parenthetical on the meeting title — "(30m)" is the
//    open time before the NEXT meeting (endDate → next startDate, hidden
//    under 5 minutes). No word "free", no extra rows. His reversal to the
//    simple row (no time range) is deliberate — do not re-add the range.
//  - Finished meetings fold: on today, meetings already over collapse into a
//    small italic "n earlier ▾" line so the day note comes back above the
//    fold by afternoon (the old agenda's past-meeting hiding, reborn).
//

import SwiftUI
import UIKit

struct DayflowTodaySection: View {
    let date: Date

    @State private var dayEvents: [NextCalendarEvent] = []
    @State private var completedToday: [ThingsTask] = []
    @State private var editingTask: ThingsTask? = nil
    @State private var selectedEvent: NextCalendarEvent? = nil
    @State private var completingIDs: Set<String> = []
    @State private var completionTimers: [String: Task<Void, Never>] = [:]
    @State private var showDone = false
    @State private var showEarlier = false
    @State private var addingTitle: String? = nil
    /// Session 81 (D235) — remembers "this exact parse was declined" by its
    /// signature, so editing the words re-arms the parse on its own.
    @State private var addDeclinedSignature: String? = nil
    /// "Now" as of the last load — drives the earlier-meetings fold. Not a
    /// ticking clock; refreshed by load(), which reruns on date change and
    /// on every scene activation (ContentView refreshes the store then).
    @State private var nowTick = Date()
    @State private var selection = DayflowTodaySelection.shared
    @State private var whenRequest: DayflowWhenRequest? = nil
    /// Session 78, D166 — a [[wikilink]] chip on a task row was tapped;
    /// presents the same person/place summary sheet the notes' wikilinks use.
    @State private var taskWikiTarget: WikiLinkTarget? = nil
    /// Session 78, D171 — 1:1 agendas: meeting rows whose AGENDA line is
    /// expanded (event ids). Nothing persisted; the day is re-matched on
    /// every draw.
    @State private var expandedAgendas: Set<String> = []
    /// Session 78 evening — notes mentioning the agenda's person/place,
    /// keyed by event id, scanned lazily on first expansion.
    @State private var agendaNotes: [String: [NoteMention]] = [:]
    /// Session 78, D175 — meeting-row swipes: right = a task for the
    /// meeting (pre-linked), left = the meeting's running project note.
    @State private var eventDragOffsets: [String: CGFloat] = [:]
    @State private var meetingTaskEvent: NextCalendarEvent? = nil
    /// Live rightward slide per row — the calendar glyph reveal.
    @State private var rowDragOffsets: [String: CGFloat] = [:]
    @FocusState private var addFieldFocused: Bool

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private var tasksForDay: [ThingsTask] {
        if isToday { return ReminderTaskStore.shared.tasks }
        let cal = Calendar.current
        return ReminderTaskStore.shared.upcomingTasks.filter { task in
            guard let d = task.date else { return false }
            return cal.isDate(d, inSameDayAs: date)
        }
    }

    private var doneCount: Int { completedToday.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            todoSection
            if !timedEvents.isEmpty { daySection }
        }
        .task(id: dayKey) { await load() }
        .onChange(of: dayKey) { _, _ in selection.exit() }
        .sheet(item: $whenRequest) { request in
            DayflowWhenSheet(tasks: request.tasks)
        }
        .sheet(item: $meetingTaskEvent) { event in
            DayflowMeetingTaskSheet(event: event)
        }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await ReminderTaskStore.shared.refreshAll() }
            }
        }
        .sheet(item: $selectedEvent) { event in
            NavigationStack { DayflowEventDetailView(event: event) }
        }
        .sheet(item: $taskWikiTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target, sourceNoteText: "")
            }
        }
    }

    private var dayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Editorial furniture

    private func sectionLabel(_ text: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Color.dayflowInk)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dayflowFaint)
            }
        }
        .padding(.bottom, 6)
    }

    private var hairline: some View {
        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
    }

    private var inkRule: some View {
        Rectangle().fill(Color.dayflowInk).frame(height: 1)
    }

    // MARK: - TO DO

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("TO DO", trailing: tasksForDay.isEmpty ? nil : "\(tasksForDay.count) remain")

            if tasksForDay.isEmpty {
                emptyState
            } else {
                ForEach(tasksForDay) { task in
                    taskRow(task)
                    hairline
                }
            }

            HStack(alignment: .center) {
                addRow
                Spacer()
                if doneCount > 0 { doneToggle }
            }

            if showDone && doneCount > 0 { doneList }
        }
    }

    private var emptyState: some View {
        Group {
            if doneCount > 0 {
                Text("That's the day.")
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowMuted)
            } else {
                Text(isToday ? "Nothing for today yet." : "Nothing here yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.dayflowMuted)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: 1:1 agendas (Session 78, D171)
    //
    // The day view as the prep sheet: a meeting whose TITLE names a person
    // from the People records grows a quiet AGENDA · N line when that
    // person has open linked tasks; tapping expands them inline — the same
    // taskRow as TO DO, swipes and all. Matching is at draw time, in
    // memory, against the calendar David already keeps: full name first,
    // then a bare first name ONLY when exactly one person carries it (two
    // Brendas = no match rather than the wrong agenda — his question,
    // answered by design). Nothing is ever written to the event.

    private func agendaName(for event: NextCalendarEvent) -> String? {
        // D175 round two: every meeting anchors an agenda — the matched
        // person/place when there is one, its own title when not (the
        // Brewers @Cubs case).
        DayflowAgendaMatch.agendaAnchor(forTitle: event.title)
    }

    private func agendaTasks(linkedTo name: String) -> [ThingsTask] {
        DayflowAgendaMatch.tasks(linkedTo: name)
    }

    @ViewBuilder
    private func agendaLine(for event: NextCalendarEvent) -> some View {
        if let name = agendaName(for: event) {
            let tasks = agendaTasks(linkedTo: name)
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
                        Spacer().frame(width: 78)
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
                    .padding(.leading, 32)
                    .task { loadAgendaNotes(eventID: event.id, name: name) }
                }
            }
        }
    }

    /// Notes mentioning the person/place, under the tasks with their own
    /// glyph (David: "notes tagged with Bryan... could have a different icon
    /// within agenda"). Same scan as Backlinks/Mentioned In, run once per
    /// expansion. Day and project notes tap through to their screens.
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

    private func loadAgendaNotes(eventID: String, name: String) {
        guard agendaNotes[eventID] == nil else { return }
        Task {
            // Backlinks' own call, same lazy once-per-open intent.
            agendaNotes[eventID] = NoteStore.shared.findWikilinkMentions(of: name)
        }
    }

    private static func shortDay(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date).uppercased()
    }

    private func taskRow(_ task: ThingsTask, agendaDay: Date? = nil) -> some View {
        let completing = completingIDs.contains(task.id)
        let selected = selection.ids.contains(task.id)
        // Carried over from an earlier day (still open, dated before today).
        // David wants to KNOW it followed him, not from when — a small
        // u-turn arrow beside the title, never a date, never a yield sign
        // (a warning glyph would make the card scold). 2026-08-28.
        let carried = isToday && (task.date.map {
            $0 < Calendar.current.startOfDay(for: Date())
        } ?? false)
        return HStack(alignment: .center, spacing: 14) {
            Button {
                // In select mode the left circle selects too — completing
                // from a half-entered multi-select is how accidents happen.
                if selection.isActive {
                    if selected { selection.ids.remove(task.id) }
                    else { selection.ids.insert(task.id) }
                } else {
                    toggleCompletion(task)
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.dayflowInk, lineWidth: 1.6)
                        .frame(width: 20, height: 20)
                    if completing {
                        Circle().fill(Color.dayflowInk).frame(width: 20, height: 20)
                            .transition(.scale)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dayflowPaper)
                    }
                }
                // D205's latent twin (Session 81): `strokeBorder` hit-tests
                // only its 1.6pt ring, so a tap in the MIDDLE fell through to
                // the row and opened the card instead of completing. A finger
                // is forgiving enough that it may never have surfaced — same
                // bug the Mac's cursor found in one click.
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(completing ? "Undo complete" : "Complete")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(task.title)
                        .font(.system(size: 16, design: .serif))
                        .strikethrough(completing)
                        .foregroundStyle(completing ? Color.dayflowFaint : Color.dayflowInk)
                    if carried {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dayflowFaint)
                    }
                }
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
                // Session 78, D166 — [[Name]] chips (shared view since the
                // Upcoming rows joined, round 2026-08-29 evening).
                DayflowTaskWikiChips(task: task) { taskWikiTarget = $0 }
            }

            Spacer(minLength: 0)

            // Agenda context (Session 78 evening, David: the Sep 4 task
            // under an Aug 31 meeting should SAY so): the task's own day,
            // accent when it lands AFTER the meeting.
            if let agendaDay, let due = task.date {
                let after = Calendar.current.startOfDay(for: due)
                    > Calendar.current.startOfDay(for: agendaDay)
                Text(Self.shortDay(due))
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
            // Session 80. David: "the tasks on the screen of the app that
            // have notes have no indication of that fact. This is true for IOS
            // as well." A note you cannot see is a note you will not open.
            //
            // `hasNoteProse`, not `notes != nil`: a task whose whole note is a
            // Shortcuts URL or a single `[[link]]` is already represented, and
            // marking those too would make the glyph mean "this row has
            // SOMETHING", which is a mark you learn to stop reading.
            if task.hasNoteProse {
                // Muted rather than faint — see the Mac note in
                // TraceMacTaskCard: in faint it sat at the same weight as the
                // list label beside it and read as one blob.
                // Accent, matching the Mac (Session 80). The two were unified
                // in D199 and they stay unified — a mark that means "there is
                // more here" should not be more visible on one device.
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
            }
            // D229's second mark (Session 81): the task points at something
            // openable — a web URL or a Satchel document. Accent for the same
            // reason as the note mark beside it: a mark cannot win attention
            // by being quieter than the furniture next to it. One glyph for
            // both kinds; the Mac's tooltip tells them apart, and here the
            // tap that opens the card answers the same question.
            if task.hasFollowableLink {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
            }
            if task.repeats {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dayflowFaint)
            }

            if selection.isActive {
                // Things puts the selection circles on the RIGHT; so do we.
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
        .frame(minHeight: 46)
        .padding(.horizontal, selection.isActive ? 6 : 0)
        .background(selected ? Color.dayflowAccent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.isActive {
                if selected { selection.ids.remove(task.id) }
                else { selection.ids.insert(task.id) }
            } else if !completing {
                editingTask = task
            }
        }
        // Swipe left = select mode (Things), swipe right = the When sheet —
        // and the row slides right revealing the calendar glyph behind it
        // (David: "The joy in swiping right is that there is a little yellow
        // calendar icon" — ours wears the accent). `.offset` is visual only,
        // so the `.background` applied AFTER it keeps the original layout
        // frame and the glyph stays put while the row slides. Dominance-
        // guarded so vertical scrolling stays untouched; inert while
        // selecting.
        .offset(x: rowDragOffsets[task.id] ?? 0)
        .background(alignment: .leading) {
            let progress = min(max((rowDragOffsets[task.id] ?? 0) / 60, 0), 1)
            if progress > 0 {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dayflowAccent)
                    .opacity(Double(progress))
                    .scaleEffect(0.7 + 0.3 * progress)
                    .padding(.leading, 2)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 28)
                .onChanged { value in
                    guard !selection.isActive, !completing else { return }
                    let h = value.translation.width
                    guard abs(h) > abs(value.translation.height) else { return }
                    // Rightward slides and reveals; leftward stays put (the
                    // select flip happens on release).
                    rowDragOffsets[task.id] = h > 0 ? min(h, 80) : 0
                }
                .onEnded { value in
                    let h = value.translation.width
                    withAnimation(.spring(duration: 0.3)) { rowDragOffsets[task.id] = 0 }
                    guard !selection.isActive, !completing else { return }
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
        .opacity(completing ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.18), value: completing)
        .animation(.easeInOut(duration: 0.15), value: selection.isActive)
    }

    // Session 81 (D235): the add row understands the capture line — a
    // trailing date, "tomorrow at 3pm", `// note` — with the hint and the
    // parsed-date chip beneath the field. See DayflowCaptureParse.
    private var addParsed: ParsedTaskLine { TaskLineParser.parse(addingTitle ?? "") }
    private var addParsedEffective: ParsedTaskLine {
        addDeclinedSignature == addParsed.signature ? addParsed.withoutDate() : addParsed
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Circle()
                    .strokeBorder(Color.dayflowFaint,
                                  style: StrokeStyle(lineWidth: 1.3, dash: [3, 2.5]))
                    .frame(width: 20, height: 20)
                if addingTitle != nil {
                    TextField(isToday ? "Add for today" : "Add for this day",
                              text: Binding(get: { addingTitle ?? "" },
                                            set: { addingTitle = $0 }))
                        .font(.system(size: 14))
                        .focused($addFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { commitAdd() }
                } else {
                    Text(isToday ? "Add for today" : "Add for this day")
                        .font(.system(size: 13.5))
                        .italic()
                        .foregroundStyle(Color.dayflowFaint)
                }
            }
            .frame(minHeight: 40)
            if addingTitle != nil {
                HStack(spacing: 8) {
                    if let label = addParsedEffective.dateLabel {
                        DayflowParsedDateChip(label: label) {
                            addDeclinedSignature = addParsed.signature
                        }
                    }
                    if let note = addParsedEffective.note, !note.isEmpty {
                        Text("// \(note)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dayflowFaint)
                            .lineLimit(1)
                    }
                    if !addParsedEffective.hasDate && !addParsedEffective.hasNote {
                        Text(DayflowCaptureParse.hint)
                            .font(.system(size: 11))
                            .italic()
                            .foregroundStyle(Color.dayflowFaint)
                    }
                }
                .padding(.leading, 34)
                .padding(.bottom, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if addingTitle == nil { addingTitle = "" }
            addFieldFocused = true
        }
    }

    private var doneToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showDone.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("\(doneCount) done")
                Image(systemName: showDone ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.dayflowFaint)
        }
        .buttonStyle(.plain)
    }

    private var doneList: some View {
        ForEach(completedToday) { task in
            HStack(spacing: 14) {
                Button { untick(task) } label: {
                    ZStack {
                        Circle().fill(Color.dayflowFaint)
                            .frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.dayflowPaper)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark not done")
                Text(task.title)
                    .font(.system(size: 15, design: .serif))
                    .strikethrough()
                    .foregroundStyle(Color.dayflowMuted)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 38)
        }
    }

    // MARK: - THE DAY

    private var timedEvents: [NextCalendarEvent] {
        dayEvents
            .filter { !$0.isAllDay }
            // Session 78 — the placeholder filter Session 77's rewrite lost
            // (rehab et al.); one source, so the rows, the gaps and the day
            // track all agree.
            .filter { !CalendarService.isExcludedPlaceholderTitle($0.title) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Meetings already over — folded behind "n earlier ▾" on today only.
    private var earlierEvents: [NextCalendarEvent] {
        guard isToday else { return [] }
        return timedEvents.filter { $0.endDate <= nowTick }
    }

    private var remainingEvents: [NextCalendarEvent] {
        guard isToday else { return timedEvents }
        return timedEvents.filter { $0.endDate > nowTick }
    }

    /// Open time between this meeting's end and the next one's start, over
    /// the FULL day list (a folded meeting never changes the math). Hidden
    /// under 5 minutes; nothing after the last meeting.
    private func gapLabel(after event: NextCalendarEvent) -> String? {
        guard let idx = timedEvents.firstIndex(where: { $0.id == event.id }),
              idx + 1 < timedEvents.count else { return nil }
        let next = timedEvents[idx + 1]
        let mins = Int(next.startDate.timeIntervalSince(event.endDate) / 60)
        guard mins >= 5 else { return nil }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("THE DAY")
                .padding(.top, 16)
            inkRule
            if !timedEvents.isEmpty {
                dayTrack
                    .padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !earlierEvents.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showEarlier.toggle() }
                    } label: {
                        HStack(spacing: 12) {
                            Spacer().frame(width: 62)
                            Text("\(earlierEvents.count) earlier")
                                .font(.system(size: 11))
                                .italic()
                            Image(systemName: showEarlier ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showEarlier {
                        ForEach(earlierEvents) { event in
                            eventRow(event, faded: true)
                            agendaLine(for: event)
                        }
                    }
                }
                ForEach(remainingEvents) { event in
                    eventRow(event, faded: false)
                    agendaLine(for: event)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: The day track (Session 78, D161)
    //
    // The composer's slider, read-only, on the face of the day — David's
    // hairdresser test: "i had to do a lot of math to figure out the
    // available time slots... It was real easy when i hit the plus sign
    // however due to the slider." Same window (7:00–22:00), same visual
    // vocabulary (hairline channel, dayflowNoteText blocks, 3pt radii) as
    // DayflowEventComposer's track, plus an accent NOW tick on today and
    // positioned hour labels. His duration-color idea was talked through
    // and set aside: it spends the meeting-TYPE color channel he has
    // planned, needs a legend, and still doesn't show WHERE the gap is.
    // When meeting colors build, these blocks are where they land.

    private static let trackStart = 7 * 60
    private static let trackEnd = 22 * 60

    private func minutesOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func clampTrack(_ minutes: Int) -> Int {
        min(max(minutes, Self.trackStart), Self.trackEnd)
    }

    private var dayTrack: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let width = geo.size.width
                let span = CGFloat(Self.trackEnd - Self.trackStart)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.dayflowHairline.opacity(0.7))
                        .frame(height: 6)
                        .offset(y: 5)
                    ForEach(timedEvents, id: \.id) { ev in
                        let start = clampTrack(minutesOfDay(ev.startDate))
                        let end = clampTrack(minutesOfDay(ev.endDate))
                        if end > start {
                            // D184: the track blocks wear the plan's own
                            // pastels — what David asked for when the track
                            // was built ("we would lose my idea of the color
                            // being used for the type of meeting"... not any
                            // more). One flag reverts to ink if the color
                            // proves distracting (his stated reservation).
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DayflowMeetingColor.tintTrackBlocks
                                      ? (DayflowMeetingColor.classify(ev.title, organizer: ev.organizerName).block
                                         ?? Color.dayflowNoteText)
                                      : Color.dayflowNoteText)
                                .frame(width: max(4, width * CGFloat(end - start) / span), height: 6)
                                .offset(x: width * CGFloat(start - Self.trackStart) / span, y: 5)
                        }
                    }
                    if isToday {
                        let now = clampTrack(minutesOfDay(nowTick))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.dayflowAccent)
                            .frame(width: 2, height: 12)
                            .offset(x: width * CGFloat(now - Self.trackStart) / span - 1, y: 2)
                    }
                }
            }
            .frame(height: 16)
            GeometryReader { geo in
                let width = geo.size.width
                let span = CGFloat(Self.trackEnd - Self.trackStart)
                ZStack(alignment: .topLeading) {
                    ForEach([7, 9, 11, 13, 15, 17, 19, 21], id: \.self) { hour in
                        Text("\(hour > 12 ? hour - 12 : hour)")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Color.dayflowFaint)
                            .frame(width: 20)
                            .offset(x: width * CGFloat(hour * 60 - Self.trackStart) / span - 10)
                    }
                }
            }
            .frame(height: 12)
        }
    }

    private func eventRow(_ event: NextCalendarEvent, faded: Bool) -> some View {
        // NOT a Button (the swipe rule): tap = detail, swipe right = a task
        // for this meeting, swipe left = its running project note (D175).
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
            if let gap = gapLabel(after: event) {
                Text("(\(gap))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dayflowFaint)
            }
            Spacer(minLength: 0)
        }
        .opacity(faded ? 0.5 : 1)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .onTapGesture { selectedEvent = event }
        .dayflowMeetingSwipes(event: event,
                              offsets: $eventDragOffsets,
                              onTask: { meetingTaskEvent = event })
    }

    // MARK: - Actions

    private func toggleCompletion(_ task: ThingsTask) {
        if completingIDs.contains(task.id) {
            completionTimers[task.id]?.cancel()
            completionTimers[task.id] = nil
            withAnimation { _ = completingIDs.remove(task.id) }
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { _ = completingIDs.insert(task.id) }
        completionTimers[task.id] = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await ReminderTaskStore.shared.complete(taskID: task.id)
            completedToday = await ReminderTaskStore.shared.fetchCompleted(on: date)
            _ = withAnimation(.easeInOut(duration: 0.25)) { completingIDs.remove(task.id) }
            completionTimers[task.id] = nil
        }
    }

    private func untick(_ task: ThingsTask) {
        Task {
            guard await ReminderTaskStore.shared.uncomplete(taskID: task.id) else { return }
            completedToday = await ReminderTaskStore.shared.fetchCompleted(on: date)
        }
    }

    private func commitAdd() {
        let parsed = addParsedEffective
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        addingTitle = nil
        addDeclinedSignature = nil
        addFieldFocused = false
        guard !title.isEmpty else { return }
        Task {
            if let day = parsed.date {
                // A typed day beats the row's own day — the composer's
                // precedence (D208 family): words are more explicit than the
                // screen's context. The chip said so before the submit.
                _ = await ReminderTaskStore.shared.addTask(
                    title: title,
                    date: day,
                    notes: parsed.note,
                    remindAt: parsed.remindAt)
            } else {
                _ = await ReminderTaskStore.shared.addTask(
                    title: title,
                    toToday: isToday,
                    date: isToday ? nil : date,
                    notes: parsed.note)
            }
        }
    }

    private func load() async {
        nowTick = Date()
        async let events = CalendarService.shared.fetchDayEvents(for: date)
        async let completed = ReminderTaskStore.shared.fetchCompleted(on: date)
        if isToday { await ReminderTaskStore.shared.fetch() }
        else { await ReminderTaskStore.shared.fetchUpcoming() }
        dayEvents = await events
        completedToday = await completed
    }

    // MARK: - Provenance
    // `sourceLink(for:)` moved to `ThingsTask.dayflowSource` in
    // DayflowModels.swift (Session 81, D239), so Upcoming and the pool rows
    // could stop being the surfaces where a shortcut task says nothing.

}

// MARK: - Agenda matching (Session 78, D171/D172/D173)
//
// ONE matcher for every surface that grows an AGENDA line (Today and, since
// D173, Upcoming) — extracted so the two can never drift. Draw-time, in
// memory, never written anywhere. People: full multi-word name first, then a
// bare first name only while unique. Places: every word of the name present,
// unambiguous. Person wins over place.

enum DayflowAgendaMatch {

    static func titleWords(_ title: String) -> Set<String> {
        Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    static func name(forTitle title: String) -> String? {
        let words = titleWords(title)
        guard !words.isEmpty else { return nil }
        let people = NotionService.shared.people.filter { !$0.isArchived }
        if let full = people.first(where: { person in
            let nameWords = person.name.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init)
            return nameWords.count > 1 && Set(nameWords).isSubset(of: words)
        }) { return full.name }
        let firstMatches = people.filter { person in
            guard let first = person.name.lowercased()
                .split(whereSeparator: { !$0.isLetter }).first else { return false }
            return words.contains(String(first))
        }
        if firstMatches.count == 1 { return firstMatches[0].name }
        guard firstMatches.isEmpty else { return nil }
        let placeMatches = NotionService.shared.places.filter { place in
            let nameWords = place.name.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init)
            return !nameWords.isEmpty && Set(nameWords).isSubset(of: words)
        }
        return placeMatches.count == 1 ? placeMatches[0].name : nil
    }

    static func tasks(linkedTo name: String) -> [ThingsTask] {
        ReminderTaskStore.shared.allTasks.filter {
            ($0.notes ?? "").contains("[[\(name)]]")
        }
    }

    /// The agenda anchor for ANY meeting: the matched person/place, else the
    /// meeting's own title (D175 round two — "Brewers @Cubs" matches nobody,
    /// but a ticket task linked [[Brewers @Cubs]] still belongs under it).
    static func agendaAnchor(forTitle title: String) -> String {
        name(forTitle: title) ?? title.trimmingCharacters(in: .whitespaces)
    }

    /// The meeting's own running note ("Notes/Projects/<stem>.md"), when the
    /// file exists. Found by PATH, not wikilink — an unmatched meeting's note
    /// carries no [[anchor]] mention of itself ("Sarah <> David Catch up"
    /// matches nobody when Sarah and David are both people, two candidates =
    /// no match), so the wikilink scan alone left it off the agenda entirely.
    /// David, Session 78: "I added a project note for Sarah and it never made
    /// it to the agenda."
    static func meetingNotePath(forTitle title: String) -> String? {
        let stem = DayflowMeetingActions.noteStem(title)
        guard !stem.isEmpty, let root = NoteStore.shared.containerURL else { return nil }
        let path = "Notes/Projects/\(stem).md"
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        else { return nil }
        return path
    }

    /// The note rows an expanded agenda shows: the meeting's own running note
    /// first (by path, per meetingNotePath above), then the cached wikilink
    /// mentions, deduped against it. Draw-time, so a note created seconds ago
    /// by the left swipe shows without invalidating the once-per-open
    /// mention cache.
    static func displayNotes(cached: [NoteMention]?, forTitle title: String) -> [NoteMention] {
        var out = cached ?? []
        if let path = meetingNotePath(forTitle: title) {
            out.removeAll { $0.relativePath == path }
            out.insert(NoteMention(relativePath: path,
                                   title: title.trimmingCharacters(in: .whitespaces),
                                   modified: nil), at: 0)
        }
        return out
    }
}

// MARK: - Meeting swipes (Session 78, D175)
//
// Right = a task FOR the meeting (a compact capture sheet, pre-linked to the
// matched person/place, undated when linked — the agenda line is its home;
// dated to the meeting's day when nothing matches). Left = the meeting's
// RUNNING PROJECT NOTE — David's call over per-day sections: "a 1:1 with
// Bryan" is an installment in a relationship, so one note per meeting title
// accumulates dated headings, carries the person's [[wikilink]] (backlinks,
// the record's mentions, and the agenda note rows all get it for free), and
// the day page grows nothing. Same modifier on Today and Upcoming.

extension View {
    func dayflowMeetingSwipes(event: NextCalendarEvent,
                              offsets: Binding<[String: CGFloat]>,
                              onTask: @escaping () -> Void) -> some View {
        let offset = offsets.wrappedValue[event.id] ?? 0
        return self
            .offset(x: offset)
            .background(alignment: .leading) {
                if offset > 8 {
                    Image(systemName: "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dayflowAccent)
                        .opacity(Double(min(offset / 60, 1)))
                        .padding(.leading, 2)
                }
            }
            .background(alignment: .trailing) {
                if offset < -8 {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dayflowAccent)
                        .opacity(Double(min(-offset / 60, 1)))
                        .padding(.trailing, 2)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 25)
                    .onChanged { value in
                        let h = value.translation.width
                        guard abs(h) > abs(value.translation.height) else { return }
                        offsets.wrappedValue[event.id] = max(-80, min(h, 80))
                    }
                    .onEnded { value in
                        let h = value.translation.width
                        withAnimation(.spring(duration: 0.3)) {
                            offsets.wrappedValue[event.id] = 0
                        }
                        guard abs(h) > abs(value.translation.height) * 1.5,
                              abs(h) > 40 else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if h > 0 {
                            // The settled-gesture hop, as ever.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                onTask()
                            }
                        } else {
                            DayflowMeetingActions.openMeetingNote(for: event)
                        }
                    }
            )
    }
}

enum DayflowMeetingActions {
    /// Filesystem-safe stem for "Notes/Projects/<title>.md".
    static func noteStem(_ title: String) -> String {
        title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Opens (creating on first use) the meeting's running note and appends
    /// this occurrence's dated heading; routing rides the same pending-
    /// destination pipe the agenda note rows use.
    static func openMeetingNote(for event: NextCalendarEvent) {
        let stem = noteStem(event.title)
        guard !stem.isEmpty else { return }
        let path = "Notes/Projects/\(stem).md"
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d yyyy"
        let heading = "## \(f.string(from: event.startDate))"
        if let existing = try? NoteStore.shared.readFile(path) {
            if !existing.contains(heading) {
                let grown = existing.hasSuffix("\n")
                    ? existing + "\n\(heading)\n\n"
                    : existing + "\n\n\(heading)\n\n"
                try? NoteStore.shared.writeFile(path, content: grown)
            }
        } else {
            var body = "# \(event.title)\n"
            if let name = DayflowAgendaMatch.name(forTitle: event.title) {
                body += "\n[[\(name)]]\n"
            }
            body += "\n\(heading)\n\n"
            try? NoteStore.shared.writeFile(path, content: body)
        }
        DayflowQuickFindRouter.shared.pendingDestination = .dailyOrProjectNote(path)
    }
}

// MARK: - The meeting task sheet (D175's right swipe)

struct DayflowMeetingTaskSheet: View {
    let event: NextCalendarEvent
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var armed = false
    /// D175 round two — David: "It did not let me change the list away from
    /// Personal (is that a bug?)". It was a gap; the label is a menu now.
    @State private var list: String = ReminderTaskStore.personalListName
    @FocusState private var focused: Bool

    private var matchedName: String? {
        DayflowAgendaMatch.name(forTitle: event.title)
    }

    /// Unmatched meetings link the task to the MEETING TITLE itself, so the
    /// Brewers game gets an agenda too (round two). Matched ones link the
    /// person/place as before.
    private var linkName: String {
        matchedName ?? event.title.trimmingCharacters(in: .whitespaces)
    }

    private var destinationLabel: String {
        if matchedName != nil {
            return "LINKED TO \(linkName.uppercased()) \u{00B7} \(list.uppercased())"
        }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return "LINKED \u{00B7} \(f.string(from: event.startDate).uppercased()) \u{00B7} \(list.uppercased())"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TASK FOR")
                .font(.system(size: 11, weight: .medium))
                .tracking(2.2)
                .foregroundStyle(Color.dayflowMuted)
            Text(event.title)
                .font(.dayflowSerif(20, weight: .heavy))
                .foregroundStyle(Color.dayflowInk)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Circle()
                    .strokeBorder(Color.dayflowFaint, lineWidth: 1.6)
                    .frame(width: 20, height: 20)
                TextField("New to-do", text: $title)
                    .font(.dayflowSerif(19, weight: .semibold))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save() }
            }
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
            HStack {
                Menu {
                    ForEach(ReminderTaskStore.shared.listNames.filter {
                        $0 != ReminderTaskStore.inboxListName
                    }, id: \.self) { name in
                        Button(name) { list = name }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(destinationLabel)
                            .tracking(1.5)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dayflowFaint)
                    .contentShape(Rectangle())
                }
                Spacer()
                Button { save() } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dayflowPaper)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(title.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.dayflowFaint : Color.dayflowInk,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.height(230)])
        .presentationBackground(Color.dayflowPaper)
        .interactiveDismissDisabled(!armed)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { armed = true }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let matched = matchedName != nil
        let link = linkName
        let destination = list
        focused = false
        dismiss()
        Task {
            // Matched → undated (the agenda line is its home, it follows the
            // person). Unmatched → dated to the meeting's day AND linked to
            // the title, so it sits under the meeting AND in the day's list —
            // the double appearance is the design: commitment + context.
            _ = await ReminderTaskStore.shared.addTask(
                title: trimmed,
                date: matched ? nil : Calendar.current.startOfDay(for: event.startDate),
                list: destination,
                notes: "[[\(link)]]")
        }
    }
}

// MARK: - Wiki chips (Session 78, D166; shared since Upcoming joined)

struct DayflowTaskWikiChips: View {
    let task: ThingsTask
    var onOpen: (WikiLinkTarget) -> Void

    private var chips: [(name: String, icon: String, target: WikiLinkTarget)] {
        guard let notes = task.notes, notes.contains("[[") else { return [] }
        var seen = Set<String>()
        var out: [(String, String, WikiLinkTarget)] = []
        var rest = Substring(notes)
        while out.count < 2,
              let open = rest.range(of: "[["), let close = rest.range(of: "]]"),
              open.upperBound <= close.lowerBound {
            let name = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            rest = rest[close.upperBound...]
            guard !name.isEmpty, !name.hasPrefix("visit:"), seen.insert(name).inserted else { continue }
            if let person = NotionService.shared.people.first(where: { $0.name == name }) {
                out.append((name, "person", .person(person)))
            } else if let place = NotionService.shared.places.first(where: { $0.name == name }) {
                out.append((name, "mappin.and.ellipse", .place(place)))
            }
        }
        return out
    }

    var body: some View {
        let items = chips
        if !items.isEmpty {
            HStack(spacing: 10) {
                ForEach(items, id: \.name) { chip in
                    Button {
                        onOpen(chip.target)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: chip.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(chip.name.uppercased())
                                .font(.system(size: 11))
                                .tracking(0.8)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.dayflowAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Multi-select + When (Session 77, David's Things-style swipes)
//
// Swipe LEFT on a Today task row → select mode: the row highlights, selection
// circles appear on the RIGHT, and ContentView shows the action bar (When /
// Move / Done / Delete) in an ink capsule above the tab bar. Swipe RIGHT →
// the When sheet for just that task (Today / Tomorrow / Pick a day / Clear).
// Shared object because the rows live in this section while the bar has to
// be screen-fixed, which only ContentView can do.

@MainActor
@Observable
final class DayflowTodaySelection {
    static let shared = DayflowTodaySelection()
    var isActive = false
    var ids: Set<String> = []
    private init() {}
    func exit() { isActive = false; ids.removeAll() }
}

struct DayflowWhenRequest: Identifiable {
    let id = UUID()
    let tasks: [ThingsTask]
}

/// Things' "When?" dialog, Editorial-dressed: Today, Tomorrow, an expanding
/// calendar, Clear date. Applies to one task (row swipe-right) or the whole
/// selection (the action bar's When).
struct DayflowWhenSheet: View {
    let tasks: [ThingsTask]
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    /// Seeded in init, NEVER set programmatically after: the calendar's
    /// `.onChange(of: picked)` means "the user tapped a day" and applies
    /// immediately. Setting it in onAppear (2026-08-28, attempt 2's bonus
    /// fix) fired that watcher on arrival — the card applied its own seed
    /// and dismissed itself. Initial State values don't fire onChange.
    @State private var picked: Date

    init(tasks: [ThingsTask], onDone: @escaping () -> Void = {}) {
        self.tasks = tasks
        self.onDone = onDone
        _picked = State(initialValue: tasks.first?.date ?? Date())
    }
    /// Drag-dismiss stays OFF for the card's first moments. The 0.12s
    /// presentation hop was not enough: a swipe the outer ScrollView cancels
    /// mid-press fires the row gesture's onEnded with the button still down,
    /// and the continuing drag lands on the fresh sheet as ITS dismiss drag
    /// (David: "the window follows the mouse and it closes", twice). Arming
    /// dismissal after 0.6s puts the card beyond the stray gesture's reach;
    /// after that it dismisses normally.
    @State private var armed = false
    /// REMIND (Session 77, David: "It might need to be a toggle which when
    /// switched on asks for the day and time"). Off: day taps apply
    /// instantly, the fast path. On: day taps SELECT, the time chips show,
    /// and Set commits day + time as a real EKAlarm.
    @State private var remindOn = false
    @State private var remindMinutes = 9 * 60
    /// Days BEFORE the due day the alarm rings (David, 2026-08-28: "cant i
    /// add a reminder a few days before?"). 0 = on the day.
    @State private var remindLeadDays = 0
    @State private var showCustomLead = false
    @State private var showCustomTime = false
    @State private var pendingDay: Date? = nil

    var body: some View {
        // Scrolls: REMIND's rows grew the card past the sheet height, and a
        // clipped VStack showed a stray sliver of the header rule (David's
        // catch, 2026-08-28).
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            Text(tasks.count == 1 ? "WHEN" : "WHEN \u{00B7} \(tasks.count) TASKS")
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Color.dayflowInk)
                .padding(.bottom, 6)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
            // Sun and sunrise, not Things' star and moon — David asked for
            // different icons, and there is no Evening in a one-date system.
            whenRow("Today", systemImage: "sun.max") { choose(Date()) }
            hairline
            whenRow("Tomorrow", systemImage: "sunrise") {
                choose(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            }
            hairline
            // The calendar is always in view (the part of Things' When card
            // David called out) — a day tap applies instantly unless REMIND
            // is on, where it selects and Set commits.
            DatePicker("Day", selection: $picked, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Color.dayflowAccent)
                .onChange(of: picked) { _, newValue in choose(newValue) }
            hairline
            remindSection
            if remindOn { setButton }
            hairline
            whenRow("Clear date", systemImage: "slash.circle",
                    tint: Color.dayflowAccent) { apply(day: nil, remindAt: nil) }
            Spacer(minLength: 0)
        }
        .padding(20)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.height(640), .large])
        .presentationBackground(Color.dayflowPaper)
        .interactiveDismissDisabled(!armed)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { armed = true }
        }
    }

    /// A day was tapped — apply on the fast path, select when REMIND is on.
    private func choose(_ day: Date) {
        if remindOn {
            pendingDay = Calendar.current.startOfDay(for: day)
            picked = day
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            apply(day: day, remindAt: nil)
        }
    }

    private var remindSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                timeChip("REMIND", active: remindOn) {
                    withAnimation(.easeInOut(duration: 0.15)) { remindOn.toggle() }
                }
                if remindOn {
                    timeChip("8 AM", active: remindMinutes == 480 && !showCustomTime) {
                        remindMinutes = 480; showCustomTime = false
                    }
                    timeChip("NOON", active: remindMinutes == 720 && !showCustomTime) {
                        remindMinutes = 720; showCustomTime = false
                    }
                    timeChip("5 PM", active: remindMinutes == 1020 && !showCustomTime) {
                        remindMinutes = 1020; showCustomTime = false
                    }
                    timeChip("CUSTOM", active: showCustomTime) {
                        withAnimation(.easeInOut(duration: 0.15)) { showCustomTime.toggle() }
                    }
                }
                Spacer(minLength: 0)
            }
            if remindOn && showCustomTime {
                Picker("Time", selection: $remindMinutes) {
                    ForEach(Array(stride(from: 0, to: 24 * 60, by: 15)), id: \.self) { m in
                        Text(minuteLabel(m)).tag(m)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 96)
            }
            if remindOn {
                HStack(spacing: 8) {
                    timeChip("ON THE DAY", active: remindLeadDays == 0 && !showCustomLead) {
                        remindLeadDays = 0; showCustomLead = false
                    }
                    timeChip("1D", active: remindLeadDays == 1 && !showCustomLead) {
                        remindLeadDays = 1; showCustomLead = false
                    }
                    timeChip("3D", active: remindLeadDays == 3 && !showCustomLead) {
                        remindLeadDays = 3; showCustomLead = false
                    }
                    timeChip("1W", active: remindLeadDays == 7 && !showCustomLead) {
                        remindLeadDays = 7; showCustomLead = false
                    }
                    timeChip("CUSTOM", active: showCustomLead) {
                        withAnimation(.easeInOut(duration: 0.15)) { showCustomLead.toggle() }
                    }
                    Spacer(minLength: 0)
                }
                if showCustomLead {
                    Picker("Days before", selection: $remindLeadDays) {
                        ForEach(0...30, id: \.self) { d in
                            Text(d == 0 ? "On the day"
                                 : d == 1 ? "1 day before"
                                 : "\(d) days before").tag(d)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 96)
                }
                Text("Rings \(ringSummary)")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(Color.dayflowFaint)
            }
        }
        .padding(.vertical, 8)
    }

    /// The committed due day before Set is tapped.
    private var chosenDueDay: Date {
        pendingDay ?? tasks.first?.date.map { Calendar.current.startOfDay(for: $0) }
            ?? Calendar.current.startOfDay(for: Date())
    }

    private var ringMoment: Date? {
        let cal = Calendar.current
        guard let alarmDay = cal.date(byAdding: .day, value: -remindLeadDays, to: chosenDueDay)
        else { return nil }
        return cal.date(byAdding: .minute, value: remindMinutes, to: alarmDay)
    }

    private var ringSummary: String {
        guard let moment = ringMoment else { return "" }
        let f = DateFormatter(); f.dateFormat = "EEEE MMM d"
        let time = DateFormatter.localizedString(from: moment, dateStyle: .none, timeStyle: .short)
        return "\(f.string(from: moment)), \(time)"
    }

    private var setButton: some View {
        Button {
            apply(day: chosenDueDay, remindAt: ringMoment)
        } label: {
            Text("Set reminder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.dayflowPaper)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Color.dayflowInk, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    private func timeChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: active ? .bold : .regular))
                .tracking(0.5)
                .foregroundStyle(active ? Color.dayflowAccent : Color.dayflowMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? Color.dayflowAccent : Color.dayflowHairline,
                                  lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func minuteLabel(_ minutes: Int) -> String {
        var comps = DateComponents()
        comps.hour = minutes / 60; comps.minute = minutes % 60
        let d = Calendar.current.date(from: comps) ?? Date()
        return DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
    }

    private var hairline: some View {
        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
    }

    private func whenRow(_ label: String, systemImage: String,
                         tint: Color = .dayflowInk,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.dayflowAccent)
                    .frame(width: 22)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                Spacer()
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// day nil = clear date AND alarm; remindAt non-nil = date + ringing
    /// alarm at that moment.
    private func apply(day: Date?, remindAt: Date?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let targets = tasks
        Task { @MainActor in
            for t in targets {
                _ = await ReminderTaskStore.shared.update(
                    taskID: t.id, title: t.title,
                    date: day, clearDate: day == nil,
                    list: nil, notes: t.notes,
                    remindAt: remindAt)
            }
            dismiss()
            onDone()
        }
    }
}
