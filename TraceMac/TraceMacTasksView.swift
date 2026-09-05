// TraceMacTasksView.swift
// The four task pools that have no other home. Sidebar destination three (D186).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 80 (2026-08-31). The last `MacEditorialSoon` placeholder, and the one
// that mattered most: until this screen existed, `anytimeTasks` and the Someday
// list had ZERO surface anywhere on the Mac. A task with no date was invisible
// unless it happened to sit in the Inbox queue, and anything sent to Someday
// was unreachable without opening Apple's own Reminders app. For a machine
// David called his main task manager, that is data he owns and cannot see.
//
// ── Four tabs, and why these four ────────────────────────────────────────
//
// INBOX     undated, in the Inbox list — captured, not yet decided (D158)
// ANYTIME   undated, in a topical list — decided WHERE, not WHEN
// SOMEDAY   undated, in the Someday list — decided NOT NOW
// LOGBOOK   done, last 90 days
//
// The first three are the store's own buckets, not a filter invented here, and
// the distinction between them is exactly the distinction David built the lists
// for: Inbox has made no decision, Anytime has made one, Someday has made the
// other one.
//
// **Dated tasks are deliberately absent.** They have two screens already, and a
// fifth tab duplicating Today and Upcoming would make this the place you check
// instead of them — which is how a "tasks" screen quietly becomes the whole app
// and the two better-designed screens become decoration.
//
// ── Why the task Inbox lives HERE and not in To File ─────────────────────
//
// Settled in Session 79 (D186) and worth restating because it came up again:
// "To File" is NOTE captures, the `Notes/Inbox/` folder, and it sits under
// RECORDS. A task inbox is not a record. David, Session 80: "we have to file
// within the records area...but inbox tasks is not a record per se."
//
// Two piles, two doors. To File files records; Tasks holds task pools; neither
// reaches into the other's group.
//
// ── One column, centred ──────────────────────────────────────────────────
//
// Today and Upcoming are two-column because they are about a day and about a
// fortnight — there is a second thing to show. A pool is a list and nothing
// else, and stretching it across a 1200pt window would put twenty characters of
// title in the left eighth of the screen. Measured column, centred, the way
// every reading surface in this app is.

import SwiftUI
import AppKit

struct TraceMacTasksView: View {

    @Binding var selectedSection: MacSection?
    /// A task id handed over by search. Consumed and cleared.
    @Binding var deepLinkTaskID: String?
    /// A context list chosen in the search panel's GO TO section. `nil` leaves
    /// the screen on whatever pool it was showing.
    @Binding var deepLinkList: String?
    /// Opens Today on a given day. Declared last, defaulted — the memberwise
    /// init takes declaration order and every existing call site keeps its own.
    var onGoToDay: (Date) -> Void = { _ in }

    @State private var tab: Pool = .inbox
    @State private var openTaskID: String? = nil

    /// The day a task just graduated to, for the "Moved to…" line. See
    /// `movedOffer`.
    @State private var movedTo: Date? = nil
    @State private var movedClearTask: Task<Void, Never>? = nil
    @State private var logbook: [ThingsTask] = []
    /// A context list chosen from the rail. Mutually exclusive with `tab` by
    /// construction — setting either clears the other — because the two are
    /// TWO WAYS TO MAKE ONE SELECTION, not two selections that compose.
    @State private var selectedList: String? = nil
    @State private var loadToken = 0

    private var store: ReminderTaskStore { ReminderTaskStore.shared }
    private let cal = Calendar.current

    /// How far back the Logbook looks. See `fetchCompleted(from:to:)` for why a
    /// window is the API rather than a choice.
    private let logbookDays = 90

    enum Pool: String, CaseIterable, Identifiable {
        case inbox = "Inbox"
        case anytime = "Anytime"
        case someday = "Someday"
        case logbook = "Logbook"
        var id: String { rawValue }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                masthead
                tabs
                list
            }
            Rectangle()
                .fill(MacEditorialColor.hairline)
                .frame(width: 1)
            listsRail
                .frame(width: MacEditorialLayout.railWidth)
        }
        .background(MacEditorialColor.paper)
        .task(id: loadToken) { await load() }
        .task { endeavorNames = Set(EndeavorFile.nameIndex(from: NoteStore.shared).keys) }
        .task(id: tab) { await load() }
        // **Both the id AND the store's count**, via `MacDeepLinkKey`. A link
        // arriving before the store has fetched would find nothing in
        // `allTasks`, clear itself, and land you on an arbitrary tab with no
        // explanation — the silent no-op this key type exists to prevent.
        .task(id: MacDeepLinkKey(value: deepLinkTaskID, loaded: store.allTasks.count)) {
            await reveal()
        }
        .task(id: deepLinkList) {
            guard let name = deepLinkList else { return }
            deepLinkList = nil
            openTaskID = nil
            selectedList = name
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialMasthead(kicker: kicker, title: screenTitle)
        }
        .padding(.horizontal, MacEditorialLayout.margin)
        .padding(.top, MacEditorialLayout.topMargin)
    }

    /// The kicker carries the count, so the number is stated once, at the top,
    /// rather than repeated on every tab. A tab strip wearing four counts is a
    /// dashboard, and this is a list.
    private var kicker: String {
        // Counts whatever the column is actually showing. A kicker that keeps
        // reporting the pool while the screen shows a list is a caption for a
        // different picture.
        let n: Int = selectedList.map { name in
            store.allTasks.filter { task in task.list == name }.count
        } ?? rows.count
        if n == 0 { return "Nothing here" }
        return n == 1 ? "1 task" : "\(n) tasks"
    }

    /// The screen's title follows the selection, so the masthead never says
    /// "Tasks" while the column is showing one list. A heading that does not
    /// change when the content does is a heading nobody reads twice.
    private var screenTitle: String { selectedList ?? "Tasks" }

    // MARK: - Tabs

    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(Pool.allCases) { pool in
                    tabButton(pool)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            MacEditorialRule.hair
                .padding(.top, 9)
        }
        .padding(.horizontal, MacEditorialLayout.margin)
    }

    private func tabButton(_ pool: Pool) -> some View {
        // A tab is only lit while NO list is chosen. Two lit things would claim
        // the column is showing both.
        let active: Bool = tab == pool && selectedList == nil
        let tint: Color = active ? MacEditorialColor.accent : MacEditorialColor.faint
        return VStack(spacing: 4) {
            Text(pool.rawValue)
                .font(active ? MacEditorialType.navLabelActive : MacEditorialType.navLabel)
                .textCase(.uppercase)
                .tracking(MacEditorialType.navTracking)
                .foregroundStyle(tint)
            // A 2pt accent under the live tab. The label's colour already says
            // which one it is; the bar is what makes the strip read as a strip
            // rather than as four words that happen to be near each other.
            Rectangle()
                .fill(active ? MacEditorialColor.accent : Color.clear)
                .frame(height: 2)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            openTaskID = nil
            selectedList = nil
            tab = pool
        }
    }

    // MARK: - The list

    /// Straight off the store for the three live pools. No filtering invented
    /// here: `apply(_:)` already draws these lines and a second opinion in this
    /// file is how two screens start disagreeing about what "Anytime" means.
    private var rows: [ThingsTask] {
        switch tab {
        case .inbox:   return store.inboxTasks
        case .anytime: return store.anytimeTasks
        case .someday: return store.allTasks.filter {
            $0.date == nil && $0.list == ReminderTaskStore.somedayListName
        }
        case .logbook: return logbook
        }
    }

    /// **A task dated out of the Inbox LEAVES the Inbox** (D225): the Inbox
    /// tab is `date == nil && list == Inbox`, so giving it a day makes it
    /// vanish from the pool he is looking at. Correct, and identical on screen
    /// to the silent failure it replaced unless the screen says where it went.
    ///
    /// Deliberately the same line Today already uses, down to the wording and
    /// the four seconds — David asked for that treatment once ("this would have
    /// to be subtle to work") and a second screen inventing a second answer is
    /// how one app starts feeling like two.
    @ViewBuilder
    private var movedOffer: some View {
        if let day = movedTo {
            let f = DateFormatter()
            let label: String = { f.dateFormat = "EEEE, MMM d"; return f.string(from: day) }()
            HStack(spacing: 8) {
                Text("Moved to \(label)")
                    .editorialQuietLabel()
                Button {
                    movedClearTask?.cancel()
                    movedTo = nil
                    onGoToDay(day)
                } label: {
                    Text("Go there")
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(MacEditorialColor.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .transition(.opacity)
        }
    }

    private func noteMove(to day: Date) {
        movedClearTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) { movedTo = day }
        movedClearTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) { movedTo = nil }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                movedOffer
                if let selectedList {
                    listRows(selectedList)
                } else if rows.isEmpty {
                    empty
                } else if tab == .logbook {
                    logbookRows
                } else {
                    ForEach(rows) { task in
                        MacTaskRow(task: task,
                                   isOpen: openTaskID == task.id,
                                   onToggle: { toggle(task) },
                                   onChanged: { reload() },
                                   onMoved: { day in noteMove(to: day) },
                                   endeavorNames: endeavorNames)
                        MacEditorialRule.hair
                    }
                }
                Spacer(minLength: 60)
            }
            // **Left, not centred.** David: "the Anytime, someday and logbook
            // all have the tasks centered but that looks funny to me since
            // today tasks are left justified." He is right and the original
            // reasoning was wrong: I argued a measured column should be centred
            // like a page of text, but this screen sits beside Today in the
            // same sidebar and a reader moving between them sees the list jump
            // sideways. Consistency with the neighbour beats typographic
            // instinct when the two are one click apart.
            //
            // The width cap stays — a title stretched across 1200pt is still
            // unreadable — so this now leaves deliberate room on the right,
            // which is where the LISTS rail is going.
            .frame(maxWidth: MacEditorialLayout.dayColumnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MacEditorialLayout.margin)
            .padding(.top, 16)
        }
    }

    /// Grouped by the day it was finished. A flat list of ninety days of
    /// completions answers "what have I done" with a wall; the day headings are
    /// what turn it back into a record you can read.
    @ViewBuilder
    private var logbookRows: some View {
        ForEach(logbookDays_grouped, id: \.0) { day, tasks in
            Text(dayHeading(day))
                .editorialGroupLabel()
                .padding(.top, 16)
                .padding(.bottom, 4)
            MacEditorialRule.hair
            ForEach(tasks) { task in
                MacTaskRow(task: task,
                           isOpen: false,
                           onToggle: { },
                           onChanged: { reload() },
                           completed: true,
                           endeavorNames: endeavorNames)
                MacEditorialRule.hair
            }
        }
    }

    /// Day key to tasks, newest day first. The key is the stored
    /// `completedDateString`, so grouping never re-derives a date the store has
    /// already decided.
    private var logbookDays_grouped: [(String, [ThingsTask])] {
        let groups = Dictionary(grouping: logbook) { $0.completedDateString ?? "" }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    // MARK: - The lists rail

    /// **Context, not time.** David settled the axis: "someday we can safely
    /// remove. I think of it as an indefinate list so more of a time element
    /// like anytime than a list which i treat as context."
    ///
    /// So the rail carries the CONTEXT lists only. Inbox and Someday are
    /// decision states that happen to be implemented as Reminders lists because
    /// EventKit has no tags or flags (D158) — putting them here would show the
    /// workaround to the user as though it were the model.
    ///
    /// Empty lists are hidden, his call: a column of zeros is a column you stop
    /// reading, and the count only earns its place when it is telling you
    /// something.
    private var contextLists: [(String, Int)] {
        let hidden: Set<String> = [ReminderTaskStore.inboxListName,
                                   ReminderTaskStore.somedayListName]
        // Named parameters throughout. `$0` inside a closure whose enclosing
        // closure also uses `$0` is either a compile error or, worse, silently
        // the wrong one — the count here reads from the OUTER list name, and
        // shorthand cannot say that.
        return store.listNames
            .filter { name in !hidden.contains(name) }
            .map { name -> (String, Int) in
                (name, store.allTasks.filter { task in task.list == name }.count)
            }
            .filter { pair in pair.1 > 0 }
    }

    private var listsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Lists").editorialSectionLabel()
            MacEditorialRule.ink
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(contextLists, id: \.0) { name, count in
                        railRow(name, count)
                    }
                    Spacer(minLength: 20)
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, MacEditorialLayout.topMargin)
    }

    private func railRow(_ name: String, _ count: Int) -> some View {
        let active: Bool = selectedList == name
        let tint: Color = active ? MacEditorialColor.accent : MacEditorialColor.ink
        return HStack(spacing: 8) {
            Text(name)
                .font(MacEditorialType.fieldValue)
                .foregroundStyle(tint)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(MacEditorialType.time)
                .foregroundStyle(MacEditorialColor.faint)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture {
            openTaskID = nil
            // Clicking the live list again returns you to the pools, so the
            // rail is never a one-way door with no visible way back.
            selectedList = active ? nil : name
        }
    }

    // MARK: - A list, whole

    /// Every OPEN task in the list, dated and undated, in three time buckets.
    ///
    /// Completed rows stay out. That is the Logbook's job, and a list that
    /// mixes done with undone stops answering the only question a list view is
    /// asked: what is left.
    ///
    /// Three buckets and not more. Grouping the scheduled half by individual
    /// day would rebuild Upcoming inside a screen that already links to it, and
    /// the question here is "what does Personal hold", not "what is Tuesday".
    @ViewBuilder
    private func listRows(_ name: String) -> some View {
        let all = store.allTasks.filter { task in task.list == name }
        let today = cal.startOfDay(for: Date())
        let overdue = all.filter { task in
            guard let due = task.date else { return false }
            return due < today
        }
        let scheduled = all.filter { task in
            guard let due = task.date else { return false }
            return due >= today
        }
        let anytime = all.filter { task in task.date == nil }

        if all.isEmpty {
            Text("Nothing in \(name).")
                .font(MacEditorialType.rowTitle)
                .foregroundStyle(MacEditorialColor.faint)
                .padding(.top, 30)
        } else {
            bucket("Overdue", overdue)
            bucket("Scheduled", scheduled)
            bucket("Anytime", anytime)
        }
    }

    @ViewBuilder
    private func bucket(_ label: String, _ tasks: [ThingsTask]) -> some View {
        if !tasks.isEmpty {
            Text(label)
                .editorialGroupLabel()
                .padding(.top, 16)
                .padding(.bottom, 4)
            MacEditorialRule.hair
            ForEach(tasks) { task in
                MacTaskRow(task: task,
                           isOpen: openTaskID == task.id,
                           onToggle: { toggle(task) },
                           onChanged: { reload() },
                           onMoved: { day in noteMove(to: day) },
                           trailing: .date,
                           endeavorNames: endeavorNames)
                MacEditorialRule.hair
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(emptyLine)
                .font(MacEditorialType.rowTitle)
                .foregroundStyle(MacEditorialColor.faint)
        }
        .padding(.top, 30)
    }

    /// A different sentence per pool, because "No tasks" said four times is
    /// four missed chances to say what the pool is FOR. An empty Inbox is an
    /// achievement; an empty Logbook is just a quiet quarter.
    private var emptyLine: String {
        switch tab {
        case .inbox:   return "Inbox clear."
        case .anytime: return "Nothing waiting without a date."
        case .someday: return "Nothing set aside."
        case .logbook: return "Nothing finished in the last \(logbookDays) days."
        }
    }

    // MARK: - Data

    private func load() async {
        await store.refreshAll()
        guard tab == .logbook else { return }
        let end = Date()
        guard let start = cal.date(byAdding: .day, value: -logbookDays, to: end) else { return }
        logbook = await store.fetchCompleted(from: start, to: end)
    }

    /// Every endeavor's name, for the row's endeavor flag (Session 87).
    /// Loaded once when this screen appears; `MacTaskRow` is handed the set
    /// rather than reaching for one, because rows are drawn dozens at a time.
    @State private var endeavorNames: Set<String> = []

    private func reload() { loadToken += 1 }

    /// Puts the screen where a searched-for task actually lives, then opens it.
    ///
    /// **The pool is derived, not stored.** A task does not know it is
    /// "Anytime" — that is a shape the store computes from its date and list,
    /// and asking the same question here the same way is what keeps search from
    /// landing you on a tab that does not contain the row it promised.
    ///
    /// A dated task is the interesting case: it is in no pool at all, it lives
    /// on Today or Upcoming. Rather than pick a tab that will not contain it,
    /// the jump goes to its context LIST, where dated rows do appear under
    /// SCHEDULED or OVERDUE. That is the one place on this screen that can
    /// honestly show it.
    private func reveal() async {
        guard let id = deepLinkTaskID else { return }
        guard let task = store.allTasks.first(where: { $0.id == id }) else { return }
        deepLinkTaskID = nil

        if task.date != nil {
            selectedList = task.list
        } else if task.list == ReminderTaskStore.inboxListName {
            selectedList = nil; tab = .inbox
        } else if task.list == ReminderTaskStore.somedayListName {
            selectedList = nil; tab = .someday
        } else {
            selectedList = nil; tab = .anytime
        }
        openTaskID = id
    }

    private func toggle(_ task: ThingsTask) {
        openTaskID = (openTaskID == task.id) ? nil : task.id
    }

    // MARK: - Formatting

    private func dayHeading(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: key) else { return key }
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let out = DateFormatter()
        out.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return out.string(from: day)
    }
}
