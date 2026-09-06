//
//  DayflowTasksView.swift
//  Dayflow
//
//  Session 89. The phone's Tasks room — the answer to David's question at the
//  close of Session 88: "where is the tasks tab on dayflow like we have in Mac
//  that has inbox, anytime, someday, logbook and the lists?"
//
//  ── What was actually missing ───────────────────────────────────────────
//
//  Less than it looked. Quick Find already browsed Anytime, Someday and every
//  list, with counts and with the same rows. Two things were genuinely absent:
//  the LOGBOOK, which nothing on the phone had ever asked the store for, and a
//  PLACE — somewhere you can be, rather than a card that closes and forgets
//  where you were.
//
//  So this room is not a port of `TraceMacTasksView` and not a new set of
//  filters. It is the Mac's five destinations given a phone's one control, on
//  the pools the store already publishes and this app already drew.
//
//  ── One strip, five words, one selection ────────────────────────────────
//
//  INBOX · ANYTIME · SOMEDAY · LOGBOOK · LISTS
//
//  The Mac shows four pools as tabs and the lists in a permanent 280pt rail
//  beside them, and its own comment explains that the two are "TWO WAYS TO
//  MAKE ONE SELECTION, not two selections that compose" — picking a rail list
//  clears the tab, picking a tab clears the rail. A phone has no room for two
//  controls, so it gets ONE control that makes that same one selection, with
//  LISTS as its fifth word. Tapping it swaps the column for the list index;
//  tapping a list shows that list with a breadcrumb back.
//
//  ── The Inbox word ──────────────────────────────────────────────────────
//
//  D271's shape was one word naming two different things. This is not that.
//  The Mac's Inbox pool and this phone's triage card read the SAME set —
//  undated tasks in the Inbox list — one as a list, one handed to you a card
//  at a time. A view, not a second meaning. So the triage screen is unchanged
//  and lives here as the Inbox pool's content, and the tab it used to occupy
//  is now Tasks. The cost, said out loud because it is a real one: triage went
//  from zero taps to one.
//
//  ── The Logbook is the only pool that costs a query ─────────────────────
//
//  `allTasks` has never held a completed reminder — its predicate is
//  `predicateForIncompleteReminders` and its own comment says so (warning
//  FOUR). The Logbook is a separate EventKit fetch over a window, and
//  `predicateForCompletedReminders` demands both ends, so there is no total to
//  print and no "everything" to ask for. The kicker therefore says LAST 90
//  DAYS before it says a number, and while the query is out this screen says
//  it is loading rather than saying the Logbook is empty (warning TWELVE: a
//  screen must not report an absence it cannot tell apart from ignorance).
//

import SwiftUI
import UIKit

struct DayflowTasksView: View {

    enum Pool: String, CaseIterable {
        case inbox = "Inbox"
        case anytime = "Anytime"
        case someday = "Someday"
        case logbook = "Logbook"
    }

    /// The one selection. A pool, or the lists.
    enum Segment: Hashable, Identifiable {
        case pool(Pool)
        case lists
        var id: String {
            switch self {
            case .pool(let p): return p.rawValue
            case .lists: return "Lists"
            }
        }
        var label: String { id }
    }

    private static let segments: [Segment] =
        Pool.allCases.map { Segment.pool($0) } + [.lists]

    @State private var segment: Segment = .pool(.inbox)
    /// A list chosen from the index. Only meaningful while `segment == .lists`,
    /// and cleared by every strip tap — the strip and the index are one
    /// selection, so nothing can be lit in two places at once.
    @State private var selectedList: String? = nil

    @State private var logbook: [ThingsTask] = []
    @State private var logbookState: LoadState = .idle
    @State private var logbookReload = 0

    /// **One sheet host, always** (D283 / D287). A new destination is a case
    /// here, never a second `.sheet` modifier: two on one view is a coin flip
    /// and the later one wins silently.
    @State private var sheet: SheetRequest? = nil
    @State private var dragOffsets: [String: CGFloat] = [:]
    @State private var endeavorNames: Set<String> = []
    @State private var order = DayflowTaskOrder.shared
    @State private var quickActions = DayflowQuickActionRouter.shared

    private var store: ReminderTaskStore { ReminderTaskStore.shared }
    private let cal = Calendar.current

    private enum LoadState { case idle, loading, loaded }

    private struct SheetRequest: Identifiable {
        let id = UUID()
        let kind: Kind
        enum Kind {
            case edit(ThingsTask)
            case when([ThingsTask])
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            strip
            content
        }
        .dayflowSkinBackground()
        .task {
            await store.refreshAll()
            endeavorNames = Set(EndeavorFile.nameIndex(from: NoteStore.shared).keys)
            consumeQuickAction()
            await loadLogbookIfShowing()
        }
        .task(id: segment) { await loadLogbookIfShowing() }
        .task(id: logbookReload) { await loadLogbookIfShowing() }
        .onChange(of: quickActions.pending) { _, _ in consumeQuickAction() }
        .sheet(item: $sheet) { request in
            switch request.kind {
            case .edit(let task):
                DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                     initialDate: task.date, initialList: task.list,
                                     initialNotes: task.notes) {
                    Task { await store.refreshAll() }
                }
            case .when(let tasks):
                DayflowWhenSheet(tasks: tasks) {
                    Task { await store.refreshAll() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let selectedList {
                // Breadcrumb home, not a back arrow — the same move Quick
                // Find's in-card browsing makes, and for the same reason:
                // this is a selection changing, not a screen being popped.
                Button {
                    self.selectedList = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("LISTS")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(1.8)
                    }
                    .foregroundStyle(Color.dayflowFaint)
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(kicker)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2.2)
                    .foregroundStyle(Color.dayflowMuted)
                Text(selectedList)
                    .font(.dayflowSerif(30, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
            } else {
                Text(kicker)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2.2)
                    .foregroundStyle(Color.dayflowMuted)
                Text("Tasks")
                    .font(.dayflowSerif(30, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dayflowQuickFindPull(enabled: true)
    }

    /// The count of whatever the column is actually showing.
    ///
    /// The Mac states the number once, at the top, rather than hanging one off
    /// every tab: "a tab strip wearing four counts is a dashboard, and this is
    /// a list." Same here, with one exception the Mac does not have to make —
    /// the Logbook leads with its WINDOW, because a bare number there would
    /// read as a total and there is no total to be had.
    private var kicker: String {
        if let selectedList {
            return count(DayflowTaskPools.openCount(in: selectedList))
        }
        switch segment {
        case .pool(.inbox):   return count(store.inboxTasks.count)
        case .pool(.anytime): return count(DayflowTaskPools.anytime.count)
        case .pool(.someday): return count(DayflowTaskPools.someday.count)
        case .pool(.logbook):
            let window = "LAST \(DayflowTaskPools.logbookDays) DAYS"
            guard logbookState == .loaded else { return window }
            return logbook.isEmpty ? window : "\(window) · \(logbook.count) FINISHED"
        case .lists:
            let n = listIndex.count
            if n == 0 { return "NO LISTS" }
            return n == 1 ? "1 LIST" : "\(n) LISTS"
        }
    }

    private func count(_ n: Int) -> String {
        if n == 0 { return "NOTHING HERE" }
        return n == 1 ? "1 TASK" : "\(n) TASKS"
    }

    // MARK: - The strip

    /// Scrolls sideways rather than shrinking. Five words of tracked caps fit
    /// on a large phone and do not on a small one, and a label that truncates
    /// to "SOMEDA…" is a control that has stopped saying what it does.
    private var strip: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(Self.segments) { seg in
                        stripButton(seg)
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
        .padding(.top, 6)
    }

    private func stripButton(_ seg: Segment) -> some View {
        // Lit only when it is the selection AND no list is open beneath it,
        // so LISTS never stays lit while the column shows one list's tasks.
        let active: Bool = segment == seg && (seg != .lists || selectedList == nil)
        return VStack(spacing: 5) {
            Text(seg.label.uppercased())
                .font(.system(size: 11, weight: active ? .bold : .medium))
                .tracking(1.6)
                .foregroundStyle(active ? Color.dayflowAccent : Color.dayflowFaint)
            Rectangle()
                .fill(active ? Color.dayflowAccent : Color.clear)
                .frame(height: 2)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            guard segment != seg || selectedList != nil else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            selectedList = nil
            segment = seg
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .pool(.inbox):
            // The triage card, unchanged, minus its own masthead — this room
            // already said "Tasks" and the strip already said "Inbox".
            DayflowInboxView(isTabRoot: true, showsHeader: false)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    poolContent
                    Spacer(minLength: 60)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var poolContent: some View {
        switch segment {
        case .pool(.inbox):
            EmptyView()
        case .pool(.anytime):
            let pool = order.sorted(DayflowTaskPools.anytime,
                                    key: DayflowTaskPools.anytimeOrderKey)
            if pool.isEmpty {
                empty("Nothing waiting without a date.")
            } else {
                reorderable(pool, key: DayflowTaskPools.anytimeOrderKey) {
                    $0.list?.uppercased()
                }
            }
        case .pool(.someday):
            let key = DayflowTaskPools.orderKey(forList: ReminderTaskStore.somedayListName)
            let pool = order.sorted(DayflowTaskPools.someday, key: key)
            if pool.isEmpty {
                empty("Nothing set aside.")
            } else {
                reorderable(pool, key: key) { _ in nil }
            }
        case .pool(.logbook):
            logbookContent
        case .lists:
            if let selectedList {
                listContent(selectedList)
            } else {
                listIndexContent
            }
        }
    }

    // MARK: Logbook

    @ViewBuilder
    private var logbookContent: some View {
        switch logbookState {
        case .idle, .loading:
            // **Not an empty state.** The query has not answered yet, and a
            // screen that prints "nothing finished" while it waits is
            // reporting an absence it cannot tell apart from ignorance.
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.top, 40)
        case .loaded:
            if logbook.isEmpty {
                empty("Nothing finished in the last \(DayflowTaskPools.logbookDays) days.")
            } else {
                ForEach(logbookDays, id: \.0) { day, tasks in
                    sectionHeader(dayHeading(day))
                    ForEach(tasks) { task in
                        DayflowTaskLogRow(task: task,
                                          onOpen: { open($0) },
                                          onChanged: { logbookReload += 1 })
                    }
                }
            }
        }
    }

    /// Day key to tasks, newest day first. The key is the stored
    /// `completedDateString`, so grouping never re-derives a date the store
    /// has already decided — the Mac room's rule, kept.
    private var logbookDays: [(String, [ThingsTask])] {
        let groups = Dictionary(grouping: logbook) { $0.completedDateString ?? "" }
        return groups.keys.sorted(by: >).map { key in (key, groups[key] ?? []) }
    }

    // MARK: Lists

    /// Name and count, empty lists hidden.
    ///
    /// David's call on the Mac and it holds here: a column of zeros is a
    /// column you stop reading, and the count only earns its place when it is
    /// telling you something.
    private var listIndex: [(String, Int)] {
        DayflowTaskPools.browseLists
            .map { name -> (String, Int) in (name, DayflowTaskPools.openCount(in: name)) }
            .filter { pair in pair.1 > 0 }
    }

    @ViewBuilder
    private var listIndexContent: some View {
        if listIndex.isEmpty {
            empty("No lists with anything in them.")
        } else {
            ForEach(listIndex, id: \.0) { name, n in
                Button {
                    selectedList = name
                } label: {
                    HStack(spacing: 10) {
                        Rectangle().fill(Color.dayflowInk)
                            .frame(width: 8, height: 8)
                            .frame(width: 18)
                        Text(name)
                            .font(.dayflowSerif(16, weight: .semibold))
                            .foregroundStyle(Color.dayflowInk)
                        Spacer()
                        Text("\(n)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dayflowFaint)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                }
            }
        }
    }

    /// One list, whole: everything open in it, dated and undated.
    ///
    /// Completed rows stay out — that is the Logbook's job, and a list that
    /// mixes done with undone stops answering the only question a list is
    /// asked: what is left.
    @ViewBuilder
    private func listContent(_ name: String) -> some View {
        let b = DayflowTaskPools.buckets(for: name)
        if b.overdue.isEmpty && b.scheduled.isEmpty && b.undated.isEmpty {
            empty("Nothing in \(name).")
        } else {
            if !b.overdue.isEmpty {
                sectionHeader("OVERDUE")
                ForEach(b.overdue) { task in
                    row(task, meta: Self.dateLabel(task.date))
                }
            }
            if !b.scheduled.isEmpty {
                sectionHeader("SCHEDULED")
                ForEach(b.scheduled) { task in
                    row(task, meta: Self.dateLabel(task.date))
                }
            }
            if !b.undated.isEmpty {
                sectionHeader("ANYTIME")
                let key = DayflowTaskPools.orderKey(forList: name)
                reorderable(order.sorted(b.undated, key: key), key: key) { _ in nil }
            }
        }
    }

    // MARK: - Row plumbing

    private func row(_ task: ThingsTask, meta: String?) -> some View {
        DayflowTaskPoolRow(task: task, meta: meta,
                           endeavorNames: endeavorNames,
                           dragOffsets: $dragOffsets,
                           onOpen: { open($0) },
                           onWhen: { when($0) })
    }

    private func reorderable(_ tasks: [ThingsTask], key: String,
                             meta: @escaping (ThingsTask) -> String?) -> some View {
        DayflowReorderableRows(tasks: tasks, key: key, meta: meta,
                               endeavorNames: endeavorNames,
                               dragOffsets: $dragOffsets,
                               onOpen: { open($0) },
                               onWhen: { when($0) })
    }

    private func open(_ task: ThingsTask) {
        sheet = SheetRequest(kind: .edit(task))
    }

    private func when(_ task: ThingsTask) {
        sheet = SheetRequest(kind: .when([task]))
    }

    private func sectionHeader(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Color.dayflowInk)
                .padding(.top, 18)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
        }
    }

    /// A different sentence per pool. "No tasks" said five times is five
    /// missed chances to say what the pool is FOR — an empty Inbox is an
    /// achievement, an empty Logbook is just a quiet quarter.
    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.dayflowSerif(15))
            .foregroundStyle(Color.dayflowMuted)
            .padding(.top, 24)
    }

    // MARK: - Data

    private func loadLogbookIfShowing() async {
        guard segment == .pool(.logbook) else { return }
        logbookState = .loading
        let end = Date()
        guard let start = cal.date(byAdding: .day,
                                   value: -DayflowTaskPools.logbookDays,
                                   to: end) else {
            logbookState = .loaded
            return
        }
        logbook = await store.fetchCompleted(from: start, to: end)
        logbookState = .loaded
    }

    /// The Home Screen "Add Task" action and the widget's "+" both land on
    /// this tab. They open the CAPTURE CARD, which lives in the triage screen,
    /// so the room has to be showing the Inbox pool before that screen exists
    /// to consume the pending value — it drains it in its own `.task`, which
    /// only runs once it is on screen.
    private func consumeQuickAction() {
        guard quickActions.pending == "AddTask" else { return }
        selectedList = nil
        segment = .pool(.inbox)
    }

    // MARK: - Formatting

    private static func dateLabel(_ date: Date?) -> String? {
        guard let date else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInTomorrow(date) { return "TOMORROW" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "EEE MMM d" : "EEE MMM d yyyy"
        return f.string(from: date).uppercased()
    }

    private func dayHeading(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: key) else { return key }
        if cal.isDateInToday(day) { return "TODAY" }
        if cal.isDateInYesterday(day) { return "YESTERDAY" }
        let out = DateFormatter()
        out.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return out.string(from: day).uppercased()
    }
}
