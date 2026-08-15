import SwiftUI

// MARK: - DayflowAgendaSection
//
// Dayflow-Design-Plan.md "Agenda section" (build order step 3). Ground truth
// is Dayflow-Mockup.html's #agendaSection: two columns (All day/no time left,
// Timed right) with a faint vertical divider, each independently
// vertically-scrollable, a header-right collapse/expand toggle with a
// one-line summary when collapsed, and a "+" that opens the quick-add sheet
// (already built — this just wires the real openSheetBtn location).
//
// Real data, two sources mixed into the left column exactly like the mockup:
//   - All-day EventKit events (CalendarService.fetchDayEvents(for:), added
//     alongside this file — separate from Trace's own Home-widget fetch, see
//     that file's comment) get a rounded-square marker (can't check off).
//   - No-date Things tasks get a round checkbox (can complete). For today,
//     pulled from the Mac Mini bridge's `/today` list (`ThingsService.shared.
//     tasks`); for any other date, filtered from the real `/upcoming` list
//     (`ThingsService.shared.upcomingTasks`, each task carrying its own real
//     `scheduled_date` — see `tasksForDay` below).
// The right "Timed" column is calendar events only — Things to-dos have no
// time field, matching the design plan's explicit call-out.
//
// **Revised 2026-07-20 (fourth addendum).** Previously any non-today date
// showed calendar events only, no tasks at all — David found this jumping
// Browse: Calendar to a real future date (July 25) whose scheduled task
// showed up in Browse: Upcoming but not here. Root cause: `showsRealTasks`
// gated task-fetching on `isDateInToday`, so the Agenda never even asked
// `ThingsService` for a non-today date's tasks, regardless of whether real
// data existed. Fixed by filtering `ThingsService.shared.upcomingTasks` (real
// per-day data, built in Session 6) down to the selected day for any
// non-today date. Yesterday (and any other past date) is still uncovered —
// `/upcoming` is forward-looking only, so there's no real backend source for
// past-dated tasks yet. That narrower remaining gap is unchanged from before.
//
// The mockup's one demo task shows an illustrative "Overdue" meta label —
// left out here since `ThingsTask` has no due-date field to back it with
// (logged in Dayflow-Design-Plan.md "Open questions").
//
// **Revised 2026-07-20 (Session 6, second addendum).** The round checkbox
// marker was purely decorative — David found tapping a task did nothing.
// `marker(for:isTimedColumn:)`'s task case is now a real `Button` calling
// `ThingsService.complete(taskID:)`, matching the pattern already used in
// `DayflowAnytimeView.swift` (built earlier the same session). Required
// threading the real `ThingsTask.id` through `DayflowAgendaItem` (new
// `taskID: String?` field, nil for calendar events) since the item's own
// `id` is a synthesized `"task-\(t.id)"` string, not a real Things id.
//
// **Revised 2026-07-20 (third addendum).** Tapping a task's title/meta text
// (not the checkbox) now opens DayflowTaskEditSheet to edit its title, date,
// or list — David asked for this alongside the Upcoming/Anytime real-data
// fixes. The tap target is the title/meta VStack only, kept separate from the
// checkbox `Button` beside it so completing and editing stay two distinct
// gestures.
//
// **Revised 2026-07-21 (Session 23).** Calendar events are no longer a no-op
// on tap — they now open the new read-only `DayflowEventDetailView` (title,
// time, location, notes, video-join link, attendees). Still a completely
// separate destination from the task-edit path above: events stay
// non-editable everywhere in Dayflow, this is view-only.

struct DayflowAgendaSection: View {
    let date: Date
    var onOpenQuickAdd: () -> Void
    /// Lifted to ContentView (2026-07-19, Daily Note build) — the Daily Note
    /// card's own bounded-scroll height grows when Agenda collapses (see
    /// Dayflow-Design-Plan.md "Daily Note section": "Its scroll height grows
    /// when Agenda is collapsed, so it actually uses the freed space rather
    /// than leaving a gap"), which means ContentView needs to know this
    /// section's collapse state too. Was `@State private var isCollapsed`
    /// before this change — purely a visibility change, no new behavior here.
    @Binding var isCollapsed: Bool

    @State private var dayEvents: [NextCalendarEvent] = []
    /// Tomorrow's raw events — only fetched/populated when `isToday` (see
    /// `loadDayData()`). Feeds `tomorrowFirstTimedEvent`, the "first meeting
    /// of tomorrow" preview shown once today's Timed column is otherwise
    /// empty. Added 2026-07-24, David's open-time/gap-tile ask.
    @State private var tomorrowEvents: [NextCalendarEvent] = []
    @State private var editingItem: DayflowAgendaItem? = nil
    @State private var selectedEvent: NextCalendarEvent? = nil
    @State private var openEndeavorID: String? = nil
    /// Observed so the endeavor rows can retry once iCloud is actually reachable
    /// — see the second `.task` on the body.
    @State private var noteStore = NoteStore.shared
    /// Drives the header refresh button's spin + disables it mid-fetch.
    /// **Added 2026-07-20** alongside the Browse views' pull-to-refresh — this
    /// card's two columns are only ~150pt tall and don't render a ScrollView
    /// at all when empty (see `column(label:items:isTimedColumn:)` below), so
    /// a swipe-to-refresh gesture has nowhere reliable to attach, especially
    /// in exactly the "Nothing here" case where refreshing matters most. A
    /// plain button is the reliable equivalent here.
    @State private var isRefreshing = false

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    /// True for any date strictly before today. Added 2026-07-24 alongside
    /// extending the open-time gap tiles to future dates (David: "add the
    /// time between meetings graphic for any future date... its not needed
    /// for past meetings") — `timedRows(now:)` below uses this instead of
    /// `isToday` to decide whether to run the gap/hiding logic at all, so
    /// only genuinely past dates keep the old plain-unfiltered-list
    /// behavior.
    private var isPastDate: Bool {
        Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }

    /// Things tasks scheduled for `date`. Today pulls the real `/today` list
    /// directly; any other date filters the real `/upcoming` list down to
    /// just this day. See this file's header comment (fourth addendum) for
    /// why this changed and what's still not covered (past dates).
    private var tasksForDay: [ThingsTask] {
        if isToday {
            return ThingsService.shared.tasks
        }
        let cal = Calendar.current
        return ThingsService.shared.upcomingTasks.filter { task in
            guard let taskDate = task.date else { return false }
            return cal.isDate(taskDate, inSameDayAs: date)
        }
    }

    private var noTimeItems: [DayflowAgendaItem] {
        let events = dayEvents.filter(\.isAllDay).map { ev in
            DayflowAgendaItem(id: "event-\(ev.id)", kind: .event, title: ev.title,
                              isAllDay: true, timeLabel: nil, metaLabel: "Calendar · All day",
                              taskID: nil, taskDate: nil, taskNotes: nil,
                              endeavorID: nil, event: ev)
        }
        let tasks = tasksForDay.map { t in
            DayflowAgendaItem(id: "task-\(t.id)", kind: .task, title: t.title,
                              isAllDay: true, timeLabel: nil, metaLabel: t.list,
                              taskID: t.id, taskDate: t.date, taskNotes: t.notes,
                              endeavorID: nil, event: nil)
        }
        // Endeavors FIRST. They are the day's context rather than something in
        // it, so they read as a heading for what follows rather than as one more
        // item competing with it. See `EndeavorStore.agendaEntries(on:)` for when
        // a row appears at all.
        let endeavors = EndeavorStore.shared.agendaEntries(on: date).map { entry in
            DayflowAgendaItem(id: "endeavor-\(entry.endeavor.id)", kind: .endeavor,
                              title: entry.endeavor.name,
                              isAllDay: true, timeLabel: nil, metaLabel: entry.meta,
                              taskID: nil, taskDate: nil, taskNotes: nil,
                              endeavorID: entry.endeavor.id, event: nil)
        }
        return endeavors + events + tasks
    }

    /// Reuses `rawTodayTimedEvents` (see the Timed-column section below) so
    /// the collapsed-state summary count and the expanded list can never
    /// disagree — both exclude the same placeholder/never-attend meetings
    /// (`isExcludedPlaceholderTitle(_:)`, added 2026-07-24).
    private var timedItems: [DayflowAgendaItem] {
        rawTodayTimedEvents.map { timedAgendaItem(for: $0) }
    }

    private var summaryLabel: String {
        let taskCount = noTimeItems.filter { $0.kind == .task }.count
        let eventCount = noTimeItems.filter { $0.kind == .event }.count + timedItems.count
        let taskWord = taskCount == 1 ? "task" : "tasks"
        let eventWord = eventCount == 1 ? "event" : "events"
        return "\(taskCount) \(taskWord) · \(eventCount) \(eventWord) — tap to expand"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A STALE LIST MUST SAY SO.
            //
            // David, 2026-08-14: Things had two to-dos and this showed four, one
            // of them completed days before. The cache behind that is correct —
            // an unreachable Mini should not blank the home screen — but drawing
            // it as though it were live is not, and nothing here read
            // `lastError`, which `ThingsService` had been setting all along.
            //
            // Only when `isToday`: any other date reads `upcomingTasks`, which
            // this flag does not describe.
            if isToday, ThingsService.shared.isShowingStaleTasks {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption2)
                    Text(ThingsService.shared.tasksAgeDescription.map {
                        "Tasks could not be refreshed. Showing the list from \($0)."
                    } ?? "Tasks could not be refreshed.")
                    .font(.caption2)
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
            if isCollapsed {
                Text(summaryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                grid
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, isCollapsed ? 10 : 16)
        // Skin locked 2026-07-21 (Session 29) — was a 16pt-radius background
        // + quaternary-stroke border; see DayflowSkin.swift's `dayflowCard()`.
        .dayflowCard()
        .task(id: date) { await loadDayData() }
        // ENDEAVOR ROWS, SECOND ATTEMPT.
        //
        // `EndeavorStore.reload()` opens with `guard noteStore.hasAccess`, and on
        // a cold launch the iCloud container has usually not resolved by the time
        // `loadDayData()` runs. It returns silently, the agenda draws with no
        // endeavor row, and nothing ever asks again — which is exactly what David
        // saw: "the suitcase only worked when i went to the endeavor then back
        // again." The Endeavor screen reloads on its own and repairs it.
        //
        // Keyed on `hasAccess` rather than fired once, so this runs again the
        // moment access flips. `DayflowEndeavorListSection` already keys its own
        // `.task` the same way; this screen simply never learned the lesson.
        .task(id: noteStore.hasAccess) { EndeavorStore.shared.reload() }
        .sheet(item: $editingItem) { item in
            if let taskID = item.taskID {
                DayflowTaskEditSheet(taskID: taskID, initialTitle: item.title,
                                      initialDate: item.taskDate, initialList: item.metaLabel,
                                      initialNotes: item.taskNotes) {
                    Task { await loadDayData() }
                }
            }
        }
        .sheet(item: $selectedEvent) { event in
            NavigationStack {
                DayflowEventDetailView(event: event)
            }
        }
        // Same binding shim as `DayflowEndeavorListSection` — a bare `String?`
        // cannot drive `.sheet(item:)` because `String` is not `Identifiable`.
        .sheet(item: Binding(
            get: { openEndeavorID.map(AgendaEndeavorRef.init) },
            set: { openEndeavorID = $0?.id }
        )) { ref in
            NavigationStack {
                DayflowEndeavorView(endeavorID: ref.id)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Agenda", systemImage: "calendar")
                // Skin locked 2026-07-21 (Session 29) — card titles use the
                // same serif as the date headline. See DayflowSkin.swift.
                .font(.dayflowSerif(14.5, weight: .semibold))
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isCollapsed.toggle() }
            } label: {
                // Skin locked 2026-07-21 (Session 29) — was a single chevron
                // that flipped direction (chevron.down/chevron.up) based on
                // isCollapsed. David picked the always-stacked
                // chevron.up.chevron.down look over that in the icon-review
                // round, so this no longer needs to branch on state for the
                // glyph itself — isCollapsed still drives the actual
                // expand/collapse behavior below, just not which icon shows.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand Agenda" : "Collapse Agenda")

            Button {
                guard !isRefreshing else { return }
                Task {
                    isRefreshing = true
                    await loadDayData()
                    isRefreshing = false
                }
            } label: {
                // Skin locked 2026-07-21 (Session 29) — was arrow.clockwise;
                // David picked the two-arrow sync-loop look in the icon-review
                // round. arrow.triangle.2.circlepath is the real SF Symbol
                // the mockup's hand-drawn version was approximating, so used
                // directly rather than reproducing arc geometry with no
                // simulator to verify it against. See DayflowSkin.swift.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.6), in: Circle())
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh")

            Button(action: onOpenQuickAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.blue, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quick add")
        }
    }

    // MARK: Two-column grid

    private var grid: some View {
        HStack(alignment: .top, spacing: 12) {
            column(label: "All day / no time", items: noTimeItems, isTimedColumn: false)
            Rectangle().fill(.quaternary.opacity(0.5)).frame(width: 1)
            // Timed column is its own implementation now, not the shared
            // `column(...)` below — it needs a live "now" to drive open-time
            // gaps, past-meeting hiding, and the tomorrow-preview row. See
            // `timedColumn` and its header comment further down.
            timedColumn
        }
    }

    private func column(label: String, items: [DayflowAgendaItem], isTimedColumn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.4)
                // Skin locked 2026-07-21 (Session 29) — was .secondary, which
                // David flagged as too dark against the new warm background;
                // lightened to the dedicated column-label color.
                // See DayflowSkin.swift.
                .foregroundStyle(Color.dayflowColumnLabel)

            if items.isEmpty {
                Text("Nothing here")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            } else {
                // Independently scrolling per column (not the whole page) once
                // a column exceeds a few items — matches the mockup's
                // `.agenda-list { max-height: 150px; overflow-y: auto; }`.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            row(for: item, isTimedColumn: isTimedColumn)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Timed column — live "now"-aware (open-time gaps, past-meeting
    // hiding, tomorrow's-first-meeting preview)
    //
    // Added 2026-07-24, David's ask ("show me how much time I have between
    // meetings" — backlog item 13, worked through via an HTML mockup review
    // before any of this was built). Three pieces, all driven by the same
    // `TimelineView` clock below so they update live while the app just sits
    // open, not only on the next manual refresh or date change:
    //
    //   1. Open-time gap tiles between meetings — >= 30 min only, dashed
    //      pill style (mockup "Variant A" — David picked this over a
    //      duration-scaled square and a full-width block, wanting the
    //      smallest visual footprint of the three). Runs for today AND any
    //      future date (`!isPastDate`) — extended 2026-07-24 from an
    //      initial today-only build, David wanting the same "how much time
    //      between meetings" view when browsing tomorrow or later. Past
    //      dates keep the original plain, fully-unfiltered list.
    //   2. A meeting hides once it has ENDED, not once it's started — an
    //      in-progress meeting still shows. This is naturally a no-op for a
    //      future date (nothing on a day that hasn't happened yet can have
    //      an `endDate` before "now"), so it only ever actually does
    //      anything when `isToday`. Past dates via Browse: Calendar still
    //      show every event, unfiltered, same as before this change.
    //   3. Once every one of today's meetings has ended (including the
    //      trivial case of a day with zero meetings), tomorrow's first
    //      *timed* meeting (all-day events skipped — David's call, since
    //      this preview's whole point is "when's my next timed
    //      commitment") shows as a distinct lavender-pill row (mockup
    //      "Option 2" — chosen over a dimmed/grayscale row and a same-layout
    //      warm-accent row for being unmistakable at a glance). Tapping it
    //      opens the same read-only `DayflowEventDetailView` a normal
    //      meeting row does — no separate destination. Deliberately gated
    //      on `isToday` specifically, not `!isPastDate` — this preview only
    //      makes sense chained forward from *today's* screen; a future date
    //      with zero meetings should just read as empty, not chain forward
    //      another day on top of that.
    //
    // The one genuinely tricky rule, walked through explicitly with David
    // before building: the leading gap (before the first still-visible
    // meeting) is suppressed only before the literal first meeting of the
    // entire day, when nothing has happened yet — never as a blanket "no
    // leading gap ever" rule. The moment an earlier meeting has already
    // ended and dropped off the list, the leading gap uses "now" as its
    // lower bound and DOES show — "how much time do I have right now until
    // my next meeting" is the single most useful number this feature
    // produces (today only — on a future date nothing has ever dropped off
    // the list, so `visible` always equals `all` and this rule is naturally
    // inert there too, same as point 2 above). Provably, a gap between two
    // still-VISIBLE meetings can never itself span "now": a visible meeting
    // is one whose `endDate > now` by
    // definition, so its trailing gap always starts in the future. Only the
    // leading gap (bounded below by nothing today's data can see — no
    // earlier visible meeting) can ever have "now" as its true lower bound
    // instead of a meeting's `endDate`.

    private static let minGapSeconds: TimeInterval = 30 * 60

    /// Placeholder / never-attend meetings David keeps on his calendar for
    /// other reasons (dummy blocks, office events he doesn't go to) but
    /// doesn't want driving Agenda behavior. Added 2026-07-24, alongside the
    /// gap-tile/tomorrow-preview build — David's explicit ask: "pretend they
    /// never existed," fully, everywhere a timed meeting can appear in this
    /// section (today's live view AND Browse: Calendar past/future dates) —
    /// not just excluded from the gap math while still shown as a row, which
    /// would visually contradict a gap tile spanning right through it.
    /// Case-insensitive substring match against the event title. Applied at
    /// the source (`rawTodayTimedEvents`/`tomorrowFirstTimedEvent`) so every
    /// downstream consumer — event rows, gap math, the collapsed summary
    /// count, the tomorrow preview — automatically stays in sync with no
    /// separate filter to remember.
    private static let excludedTitleKeywords = ["rehab", "bewell", "trivia", "happy hour"]

    private static func isExcludedPlaceholderTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return excludedTitleKeywords.contains { lower.contains($0) }
    }

    private enum TimedRow: Identifiable {
        case event(DayflowAgendaItem)
        /// `id` is keyed off the anchoring event ids, NOT the label text —
        /// the label's duration counts down every clock tick, but the row
        /// itself needs a stable identity across those updates so SwiftUI
        /// doesn't treat it as a new row and animate/flicker.
        case gap(id: String, label: String)
        case tomorrow(NextCalendarEvent)

        var id: String {
            switch self {
            case .event(let item): return item.id
            case .gap(let id, _): return id
            case .tomorrow(let ev): return "tomorrow-\(ev.id)"
            }
        }
    }

    private var rawTodayTimedEvents: [NextCalendarEvent] {
        dayEvents
            .filter { !$0.isAllDay }
            .filter { !Self.isExcludedPlaceholderTitle($0.title) }
            .sorted { $0.startDate < $1.startDate }
    }

    /// First non-all-day event on the day after `date` — only meaningful (and
    /// only fetched — see `loadDayData()`) when `isToday`.
    private var tomorrowFirstTimedEvent: NextCalendarEvent? {
        tomorrowEvents
            .filter { !$0.isAllDay }
            .filter { !Self.isExcludedPlaceholderTitle($0.title) }
            .min { $0.startDate < $1.startDate }
    }

    private func gapLabel(_ seconds: TimeInterval) -> String {
        let mins = max(0, Int(seconds / 60))
        if mins < 60 { return "\(mins)m open" }
        let h = mins / 60, m = mins % 60
        return m > 0 ? "\(h)h \(m)m open" : "\(h)h open"
    }

    private func timedAgendaItem(for ev: NextCalendarEvent) -> DayflowAgendaItem {
        DayflowAgendaItem(id: "event-\(ev.id)", kind: .event, title: ev.title,
                          isAllDay: false, timeLabel: ev.startTimeString, metaLabel: nil,
                          taskID: nil, taskDate: nil, taskNotes: nil,
                          endeavorID: nil, event: ev)
    }

    /// Builds the Timed column's row list for a given "now" — see this
    /// section's header comment above for the full rule set.
    private func timedRows(now: Date) -> [TimedRow] {
        let all = rawTodayTimedEvents
        guard !isPastDate else {
            // Past dates: every event, no hiding, no gap tiles — unchanged
            // from before this feature existed.
            return all.map { .event(timedAgendaItem(for: $0)) }
        }

        // Today AND any future date reach here. For a future date, `now` is
        // always before every event that day, so `visible` always equals
        // `all` — nothing gets hidden, and the leading-gap branch below
        // never fires (see this section's header comment). Gap tiles
        // between meetings still compute normally either way.
        let visible = all.filter { $0.endDate > now }
        guard let first = visible.first else {
            // Only today falls through to the tomorrow-preview — a future
            // date with zero (remaining) meetings just reads as empty, no
            // chaining forward another day on top of that.
            if isToday, let tomorrow = tomorrowFirstTimedEvent {
                return [.tomorrow(tomorrow)]
            }
            return []
        }

        var rows: [TimedRow] = []

        // Leading gap — suppressed only when `first` is the actual first
        // meeting of the entire day (nothing earlier ever existed to have
        // already ended). Otherwise it's "now until `first` starts."
        if first.startDate > now, let veryFirst = all.first, veryFirst.id != first.id {
            let remaining = first.startDate.timeIntervalSince(now)
            if remaining >= Self.minGapSeconds {
                rows.append(.gap(id: "gap-lead-\(first.id)", label: gapLabel(remaining)))
            }
        }

        for (index, event) in visible.enumerated() {
            rows.append(.event(timedAgendaItem(for: event)))
            guard index + 1 < visible.count else { continue }
            let next = visible[index + 1]
            let gap = next.startDate.timeIntervalSince(event.endDate)
            if gap >= Self.minGapSeconds {
                rows.append(.gap(id: "gap-\(event.id)-\(next.id)", label: gapLabel(gap)))
            }
        }

        return rows
    }

    private var timedColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TIMED")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(Color.dayflowColumnLabel)

            // `.periodic(from:by:)` over the sample-code-only `.everyMinute`
            // schedule — this environment can't build/run to double-check an
            // API's exact availability, so picking the one guaranteed to
            // exist. Re-evaluates `timedRows(now:)` every 60s so gap
            // countdowns, past-meeting hiding, and the tomorrow-preview
            // trigger all stay live while this card just sits on screen.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let rows = timedRows(now: context.date)
                if rows.isEmpty {
                    Text("Nothing here")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(rows) { tr in
                                timedRowView(tr)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func timedRowView(_ tr: TimedRow) -> some View {
        switch tr {
        case .event(let item):
            row(for: item, isTimedColumn: true)
        case .gap(_, let label):
            gapTile(label: label)
        case .tomorrow(let event):
            tomorrowPreviewRow(event)
        }
    }

    /// Mockup "Variant A" — small dashed pill, not a full row, so it never
    /// reads as its own meeting.
    private func gapTile(label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color.dayflowInk.opacity(0.3)).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .italic()
                .foregroundStyle(Color.dayflowInk.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.dayflowInk.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
        .background(Color.dayflowInk.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 16)
    }

    /// Mockup "Option 2" — lavender pill + "TOMORROW" tag. Tapping opens the
    /// same read-only `DayflowEventDetailView` today's meetings use; no
    /// separate destination, no navigation to tomorrow's date.
    private func tomorrowPreviewRow(_ event: NextCalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("🕒").font(.system(size: 10)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("TOMORROW")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(Color(red: 0.478, green: 0.435, blue: 0.761))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(red: 0.863, green: 0.839, blue: 0.949), in: RoundedRectangle(cornerRadius: 5))
                Text(event.startTimeString)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.357, green: 0.310, blue: 0.639))
                Text(event.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.357, green: 0.310, blue: 0.639))
                    .lineLimit(2)
            }
        }
        .padding(7)
        .background(Color(red: 0.929, green: 0.918, blue: 0.969), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color(red: 0.851, green: 0.827, blue: 0.941), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedEvent = event }
    }

    @ViewBuilder
    private func row(for item: DayflowAgendaItem, isTimedColumn: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            marker(for: item, isTimedColumn: isTimedColumn)
            VStack(alignment: .leading, spacing: 1) {
                if isTimedColumn, let timeLabel = item.timeLabel {
                    Text(timeLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                if !isTimedColumn, let meta = item.metaLabel {
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if item.kind == .task, item.taskID != nil {
                    editingItem = item
                } else if item.kind == .event, let event = item.event {
                    selectedEvent = event
                } else if item.kind == .endeavor, let id = item.endeavorID {
                    // Straight to the Endeavor. Directions, Check In and the
                    // documents live there, not on this row: an agenda row taps
                    // through to one place, and a row carrying its own action bar
                    // is how a list stops being a list.
                    openEndeavorID = id
                }
            }
        }
    }

    /// Round checkbox for a Things task (you can complete it, and now
    /// actually can — see this file's header comment), rounded-square marker
    /// for a calendar event (you can't). The Timed column's clock glyph
    /// stands in for both, since only events ever appear there.
    @ViewBuilder
    private func marker(for item: DayflowAgendaItem, isTimedColumn: Bool) -> some View {
        if isTimedColumn {
            Text("🕒").font(.system(size: 11)).padding(.top, 1)
        } else if item.kind == .task, let taskID = item.taskID {
            Button {
                Task { await ThingsService.shared.complete(taskID: taskID) }
            } label: {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.45), lineWidth: 2)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel("Complete \(item.title)")
        } else if item.kind == .endeavor {
            // Not the event marker. An endeavor is the day's context rather than
            // an appointment in it, and the checkbox/square pair already carries
            // the meaning "you can complete this" versus "you cannot" — a third
            // thing needs a third glyph rather than borrowing one.
            Image(systemName: "suitcase.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.blue.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.blue, lineWidth: 2))
                .frame(width: 16, height: 16)
                .padding(.top, 1)
        }
    }

    // MARK: Data

    /// Endeavor rows come from a store that nothing on this screen was loading.
    /// Cheap: it reads a handful of small local files, and `agendaEntries(on:)`
    /// is pure computation over what it finds.
    private func loadDayData() async {
        EndeavorStore.shared.reload()
        async let events = CalendarService.shared.fetchDayEvents(for: date)
        // Run the Things fetch concurrently with the calendar fetch above —
        // both hit the network (EventKit access + the Mac Mini bridge), no
        // reason to serialize them. Today fetches `/today`; any other date
        // fetches `/upcoming` (filtered down to the day by `tasksForDay`
        // above) — added 2026-07-20, see this file's header comment.
        if isToday {
            async let taskFetch: Void = ThingsService.shared.fetch()
            // Tomorrow's events — only needed for `tomorrowFirstTimedEvent`
            // (the "first meeting of tomorrow" preview below), so only
            // fetched when actually viewing today. Added 2026-07-24.
            async let tomorrow = CalendarService.shared.fetchDayEvents(
                for: Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date)
            dayEvents = await events
            tomorrowEvents = await tomorrow
            await taskFetch
        } else {
            async let taskFetch: Void = ThingsService.shared.fetchUpcoming()
            dayEvents = await events
            tomorrowEvents = []
            await taskFetch
        }
    }
}


/// Identifiable wrapper so an endeavor slug can drive `.sheet(item:)`.
/// `DayflowEndeavorViews` has its own private copy of this; duplicated rather
/// than shared because making that one internal would export a name whose whole
/// purpose is to be invisible.
private struct AgendaEndeavorRef: Identifiable, Hashable {
    let id: String
}
