import SwiftUI
import UIKit

// MARK: - DayflowQuickFindView
//
// Quick Find (Session 78, D159). David, with a Things screenshot: "When you
// drag down in Things you get a slight tactile feeling and the search and a
// few lists are showing. Would this be a good approach instead of the way we
// have search now... and also the hamburger in a different place."
//
// It is. One pull-down gesture on ANY tab's header opens this card, and it
// absorbs three doors that used to be scattered: the hamburger menu
// (Anytime / Settings — the menu is gone from the Today top bar), the
// Session 71 TraceSearchView cover (literal search + Ask), and the
// list-filtering question ("if i want to see just the finance list...") via
// one row per Reminders list. The Notes tab's magnifier retired in the same
// pass — this reaches notes from anywhere.
//
// Shape of the card (canvas frames "Quick Find · pulled down / the Ask row /
// answered", locked 2026-08-29 with the 18pt rounded bottom, David's own
// suggestion, mirroring the sheets that come up from below):
// - Search field, focused on arrival (the 50ms hop — same lesson as the
//   Inbox capture card).
// - Empty query: GO TO (Anytime · Someday, with counts), LISTS (one row per
//   list, Inbox and Someday excluded — they have their own doors), a quiet
//   SETTINGS row.
// - Typed: TASKS match instantly from ReminderTaskStore.allTasks (new in
//   this session — tasks were the one thing search couldn't see), then the
//   Session 71 engine's groups (notes, docs, people, places), then the
//   quiet ASK row: the existing MacAskService on a deliberate tap only,
//   never as-you-type, with tasks now in its corpus too.
//
// Routing: task rows edit in place (DayflowTaskEditSheet); GO TO and LISTS
// present their screens from inside this cover; engine results that need
// the Today screen's machinery (day notes, endeavors, people, places) hand
// their destination to DayflowQuickFindRouter.pendingDestination — the root
// switches to the Today tab and ContentView drains it through its existing
// canOpenFromSearch/openSearchDestination pair. Results with no screen
// expand in place, exactly as TraceSearchView did.

@Observable
final class DayflowQuickFindRouter {
    static let shared = DayflowQuickFindRouter()
    /// True while the Quick Find cover should be up. Set by the header
    /// pull-down gestures on all four tabs; presented by DayflowRootView.
    var show = false
    /// A tapped result that needs ContentView's routing. The root selects
    /// the Today tab on dismiss; ContentView watches and drains.
    var pendingDestination: MacSearchDestination? = nil
    private init() {}
}

struct DayflowQuickFindView: View {
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    // The Session 71 engine, unforked (TraceSearchIOS.swift's rule).
    @State private var corpus = MacSearchCorpus()
    @State private var corpusBuilt = false
    @State private var notion = NotionService.shared
    @State private var chips = TraceSatchelChipStore.shared

    @State private var asking = false
    @State private var answer: MacAskAnswer?
    @State private var askError: String?

    @State private var expanded: Set<String> = []
    @State private var previews: [String: String] = [:]

    @State private var editingTask: ThingsTask? = nil
    /// Where the card is browsing (Session 78 round 2 — David: "the animation
    /// of clicking on Finance... has the screen go all the way up... The
    /// instant would be nice. I also find the back arrow... not very joyful").
    /// A list opens INSIDE the card, instantly, with a breadcrumb home —
    /// never a pushed or covered screen.
    @State private var place: DayflowQuickFindPlace? = nil
    @State private var showSettings = false
    /// Row swipes, Today's grammar (D152): right = the When card, left =
    /// multi-select (the root's bar floats above this card).
    @State private var whenRequest: DayflowWhenRequest? = nil
    @State private var rowDragOffsets: [String: CGFloat] = [:]
    /// Every endeavor's name, loaded once per screen (D270, Session 88).
    ///
    /// **The row is handed a `Set`; it never reaches for one.**
    /// `EndeavorFile.nameIndex` walks the endeavor files, which is cheap once
    /// per screen and unaffordable once per row - the Mac's own split, and the
    /// same reasoning as `docStore` being built lazily on its task row.
    @State private var endeavorNames: Set<String> = []
    @State private var order = DayflowTaskOrder.shared

    private var store: ReminderTaskStore { ReminderTaskStore.shared }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Literal, case-insensitive, every word must appear — the engine's own
    /// contract, applied to task titles + notes.
    private var taskMatches: [ThingsTask] {
        guard !trimmedQuery.isEmpty else { return [] }
        let words = trimmedQuery.lowercased().split(separator: " ").map(String.init)
        return store.allTasks.filter { task in
            let haystack = (task.title + " " + (task.notes ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var groups: [MacSearchGroup] {
        guard !trimmedQuery.isEmpty else { return [] }
        return MacSearchEngine.grouped(
            MacSearchEngine.run(query: trimmedQuery,
                                corpus: corpus,
                                documents: chips.all,
                                people: notion.people,
                                places: notion.places))
    }

    private var stillLoading: Bool {
        !corpusBuilt
            || notion.placesLoad == .loading
            || notion.peopleLoad == .loading
    }

    /// Lists offered as browse rows, and the counts beside them — both in
    /// `DayflowTaskPools` since Session 89, when the Tasks room started
    /// showing the same rows. Two screens deciding separately which lists are
    /// "real" is how one of them quietly starts offering Someday twice.
    private var browseLists: [String] { DayflowTaskPools.browseLists }

    /// The task lists start collapsed onto one row (D480). Records had to go
    /// somewhere and the lists are what gave up the height; they are also the
    /// rows he scrolls past most, being four or five names he already knows.
    @State private var listsExpanded = false

    private func openCount(in list: String) -> Int {
        DayflowTaskPools.openCount(in: list)
    }

    private var somedayCount: Int {
        openCount(in: ReminderTaskStore.somedayListName)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                // The cap tracks the keyboard (TestFlight, 2026-08-29: the
                // keyboard overlapped the ASK row, and keyboard avoidance
                // shoved the whole card up into the status bar). geo's
                // height already excludes the keyboard's safe-area inset,
                // so the card always fits ABOVE it — nothing left for
                // avoidance to move, nothing left to cover.
                // **Inset, so it floats** (D480). It used to be welded to the
                // top edge with only its bottom corners rounded, which read as
                // part of the screen rather than a thing laid over it. David,
                // with a Things screenshot: *"The window floats."* So: 12pt of
                // air at the top and 14pt at each side, all four corners
                // rounded, over the dim it already had.
                //
                // **This does not break the skin's no-floating rule.** That
                // rule is about page furniture — a card on a page should be a
                // panel with a hairline, not a shadow. This is a transient
                // overlay on a dimmed screen, and it already carried a shadow
                // and an ink border on purpose before this change.
                card(maxHeight: min(620, geo.size.height - 32))
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }
        }
        .task { endeavorNames = Set(EndeavorFile.nameIndex(from: NoteStore.shared).keys) }
        .task {
            await store.fetch()
            await buildCorpus()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                fieldFocused = true
            }
        }
        .sheet(item: $editingTask) { task in
            DayflowTaskEditSheet(taskID: task.id, initialTitle: task.title,
                                 initialDate: task.date, initialList: task.list,
                                 initialNotes: task.notes) {
                Task { await store.fetch() }
            }
        }
        .sheet(isPresented: $showSettings) { DayflowSettingsView() }
        .sheet(item: $whenRequest) { request in
            DayflowWhenSheet(tasks: request.tasks) {
                Task { await store.fetch() }
            }
        }
    }

    // MARK: The card

    private func card(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // An open place owns the search field (Session 78 round
                    // 3, David: "add a search menu on this screen... that
                    // will only filter from that specific list... not just
                    // the title but anything in the task"). Global results
                    // only render outside a place; the breadcrumb widens.
                    if let place {
                        placeContent(place)
                    } else if !trimmedQuery.isEmpty {
                        resultsContent
                    } else {
                        browseContent
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            pullHandle
        }
        .frame(maxHeight: maxHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        // All four corners, and no `ignoresSafeArea` — the card no longer
        // runs under the status bar, because it no longer touches the top.
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.dayflowPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.dayflowInk.opacity(0.9), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.25), radius: 22, x: 0, y: 10)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
            TextField(place == nil ? "Find anything" : "Find in \(placeName(place!))",
                      text: $query)
                .font(.dayflowSerif(19, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($fieldFocused)
                .submitLabel(.search)
                .onChange(of: query) { _, _ in
                    // A new question is not an answer to the old one
                    // (TraceSearchIOS's rule, kept).
                    answer = nil
                    askError = nil
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    // Editorial ✕ (David, 2026-08-29: the filled system
                    // circle read foreign next to the app's own dismissals).
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dayflowFaint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
                .padding(.horizontal, 24)
        }
    }

    private var pullHandle: some View {
        HStack {
            Spacer()
            Capsule().fill(Color.dayflowHairline).frame(width: 36, height: 3)
            Spacer()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { close() }
        // Push up to dismiss lives HERE, not on the whole card — a card-wide
        // drag competed with the row swipes (Simulator, 2026-08-29).
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { value in
                    if value.translation.height < -40 { close() }
                }
        )
    }

    // MARK: Browse (empty query)

    // **RECORDS above TASKS** (D480). David: *"It is mostly task oriented now
    // with the lists, anytime, someday... that might actually be the right
    // move but we should think through the UI more critically."* He was right,
    // and it was not a taste problem. Every row on this card was a Reminders
    // list. The card was built when the app was tasks and notes, and nothing
    // was added to it when Records grew, so People, Places, Endeavors and
    // Notes could be reached from here only by typing their names.
    //
    // **The one card whose job is "where can I go" listed less than the app
    // held**, which is the kind of quiet wrong this vault cares about: not a
    // broken screen, a screen answering a narrower question than the one it
    // appears to answer.
    //
    // `LISTS` becomes `TASKS`, because that heading only made sense while
    // lists were the only thing here.
    private var browseContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("RECORDS")
            browseRow(icon: "person", title: "People",
                      count: notion.people.count) { goToRecords("PEOPLE") }
            browseRow(icon: "mappin.and.ellipse", title: "Places",
                      count: notion.places.count) { goToRecords("PLACES") }
            browseRow(icon: "sparkles", title: "Endeavors",
                      count: EndeavorStore.shared.endeavors.count) { goToRecords("ENDEAVORS") }
            // **No count on Notes**, deliberately. Counting them means walking
            // the notes folder, and a synchronous container read on the main
            // thread is exactly what froze this app on iOS 27 (D465). A figure
            // is not worth a stutter, or worse.
            browseRow(icon: "text.alignleft", title: "Notes",
                      count: -1) { goToRecords("NOTES") }
            // **The three rooms that had no door** (D486). `VisitsView`,
            // `FitnessView` and `BilliardsView` have been in this target since
            // D469 and reachable from nowhere; David's only way to a workout
            // or a pool session was Trace's home screen, which is the app we
            // are about to delete. Rows here rather than segments in Records:
            // five words is already what that row holds, and these are places
            // you go occasionally rather than modes you switch between.
            browseRow(icon: DayflowRecordsRoom.visits.icon, title: "Visits",
                      count: notion.visits.count) { goToRoom(.visits) }
            browseRow(icon: DayflowRecordsRoom.fitness.icon, title: "Workouts",
                      count: notion.workouts.count) { goToRoom(.fitness) }
            browseRow(icon: DayflowRecordsRoom.billiards.icon, title: "Billiards",
                      count: notion.billiardsSessions.count) { goToRoom(.billiards) }

            sectionHeader("TASKS")
            browseRow(icon: "books.vertical", title: "Anytime",
                      count: DayflowTaskPools.anytime.count) { go(.anytime) }
            browseRow(icon: "archivebox", title: "Someday",
                      count: somedayCount) {
                go(.list(ReminderTaskStore.somedayListName))
            }
            if listsExpanded {
                ForEach(browseLists, id: \.self) { name in
                    browseRow(icon: nil, title: name, count: openCount(in: name)) {
                        go(.list(name))
                    }
                }
            } else {
                // **"Lists", not the names joined together** (D487).
                //
                // D480 collapsed the task lists onto one row and drew that row
                // as every list name with a separator between them, which the
                // mockup showed fitting comfortably on one line. It showed
                // that because the mockup invented four short names. David's
                // are Personal, Trace, Birthdays & Anniversaries, Financial
                // and Work: on the phone that wrapped to three lines and read
                // as one very odd entry rather than as a group.
                //
                // Same fault as D477's top row, and from the same cause -
                // a layout judged against made-up content. A collapsed group
                // should say what it is and how many; the names are what you
                // get for opening it.
                browseRow(icon: "list.bullet",
                          title: "Lists",
                          count: browseLists.reduce(0) { $0 + openCount(in: $1) }) {
                    withAnimation(.easeInOut(duration: 0.18)) { listsExpanded = true }
                }
            }
            Button { showSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                    Text("SETTINGS")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.6)
                }
                .foregroundStyle(Color.dayflowFaint)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Color.dayflowInk)
                .padding(.top, 16)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
        }
    }

    /// Close the card and land on the Records tab at a segment (D480).
    /// `DayflowRecordsRouter` is drained by `DayflowNotesView`; the root
    /// selects the tab. Same shape as the task rows' `go`.
    private func goToRecords(_ segment: String) {
        DayflowRecordsRouter.shared.pendingSegment = segment
        close()
    }

    /// Open a whole screen rather than a Records segment (D486).
    private func goToRoom(_ room: DayflowRecordsRoom) {
        DayflowRecordsRouter.shared.pendingRoom = room
        close()
    }

    private func browseRow(icon: String?, title: String, count: Int,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.dayflowInk)
                        .frame(width: 18)
                } else {
                    Rectangle().fill(Color.dayflowInk)
                        .frame(width: 8, height: 8)
                        .frame(width: 18)
                }
                Text(title)
                    .font(.dayflowSerif(16, weight: .semibold))
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dayflowFaint)
                }
            }
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
    }

    // MARK: In-card list browsing

    /// Instant on purpose — no transition at all. Tab switches are instant
    /// and this should read as the same class of move.
    private func go(_ destination: DayflowQuickFindPlace) {
        fieldFocused = false
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { place = destination }
    }

    @ViewBuilder
    private func placeContent(_ place: DayflowQuickFindPlace) -> some View {
        let name = placeName(place)
        // Breadcrumb home, not a back arrow on a pushed screen.
        Button {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.place = nil
                query = ""  // the scoped filter belongs to the place it filtered
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text("QUICK FIND")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.8)
            }
            .foregroundStyle(Color.dayflowFaint)
            .padding(.top, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Text(name)
            .font(.dayflowSerif(24, weight: .heavy))
            .foregroundStyle(Color.dayflowInk)
            .padding(.top, 2)
        switch place {
        case .anytime:
            let pool = placeFiltered(order.sorted(DayflowTaskPools.anytime,
                                                  key: DayflowTaskPools.anytimeOrderKey))
            if pool.isEmpty {
                emptyPlace(trimmedQuery.isEmpty
                           ? "Nothing undated outside the Inbox."
                           : "Nothing in Anytime matches.")
            } else {
                sectionHeader("THE POOL")
                if trimmedQuery.isEmpty {
                    reorderableRows(pool, key: DayflowTaskPools.anytimeOrderKey) { $0.list?.uppercased() }
                } else {
                    ForEach(pool) { swipeableRow($0, meta: $0.list?.uppercased()) }
                }
            }
        case .list(let list):
            // Three buckets from `DayflowTaskPools` since Session 89, with
            // OVERDUE its own heading rather than the front of SCHEDULED: a
            // date that has passed is the one thing here that wants doing
            // today, and filing it under "Scheduled" is the screen declining
            // to say so. The Tasks room shows the same three.
            let b = DayflowTaskPools.buckets(for: list)
            let key = DayflowTaskPools.orderKey(forList: list)
            let overdue = placeFiltered(b.overdue)
            let scheduled = placeFiltered(b.scheduled)
            let undated = placeFiltered(order.sorted(b.undated, key: key))
            if overdue.isEmpty && scheduled.isEmpty && undated.isEmpty {
                emptyPlace(trimmedQuery.isEmpty
                           ? "Nothing here."
                           : "Nothing in \(list) matches.")
            }
            if !overdue.isEmpty {
                sectionHeader("OVERDUE")
                ForEach(overdue) { swipeableRow($0, meta: Self.dateLabel($0.date!)) }
            }
            if !scheduled.isEmpty {
                sectionHeader("SCHEDULED")
                ForEach(scheduled) { swipeableRow($0, meta: Self.dateLabel($0.date!)) }
            }
            if !undated.isEmpty {
                sectionHeader(list == ReminderTaskStore.somedayListName ? "SOMEDAY" : "ANYTIME")
                if trimmedQuery.isEmpty {
                    reorderableRows(undated, key: key) { _ in nil }
                } else {
                    ForEach(undated) { swipeableRow($0, meta: nil) }
                }
            }
        }
    }

    /// The scoped filter: every typed word must appear somewhere in the
    /// task — title, notes, list name. Drag-reorder pauses while a filter
    /// is on (a reorder of a filtered SUBSET would clobber the full order).
    private func placeFiltered(_ tasks: [ThingsTask]) -> [ThingsTask] {
        guard !trimmedQuery.isEmpty else { return tasks }
        let words = trimmedQuery.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return tasks.filter { task in
            let haystack = [task.title, task.notes ?? "", task.list ?? ""]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Undated rows with drag-to-reorder. Moved to `DayflowReorderableRows`
    /// in Session 89 with the row: the order is persisted under a KEY, so two
    /// screens showing one pool must agree about the key AND the drop rules or
    /// a drag in one silently re-sorts the other.
    private func reorderableRows(_ tasks: [ThingsTask], key: String,
                                 meta: @escaping (ThingsTask) -> String?) -> some View {
        DayflowReorderableRows(tasks: tasks, key: key, meta: meta,
                               endeavorNames: endeavorNames,
                               dragOffsets: $rowDragOffsets,
                               onOpen: { editingTask = $0 },
                               onWhen: { whenRequest = DayflowWhenRequest(tasks: [$0]) })
    }

    private func placeName(_ place: DayflowQuickFindPlace) -> String {
        switch place {
        case .anytime: return "Anytime"
        case .list(let name): return name
        }
    }

    private func emptyPlace(_ text: String) -> some View {
        Text(text)
            .font(.dayflowSerif(15))
            .foregroundStyle(Color.dayflowMuted)
            .padding(.top, 20)
    }

    private static func dateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInTomorrow(date) { return "TOMORROW" }
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return f.string(from: date).uppercased()
    }

    /// A task row with Today's full swipe grammar. **The row itself is
    /// `DayflowTaskPoolRow`** since Session 89, shared with the Tasks room —
    /// this method survives as the call shape the rest of this file already
    /// uses, so not one call site here changed.
    private func swipeableRow(_ task: ThingsTask, meta: String?) -> some View {
        DayflowTaskPoolRow(task: task, meta: meta,
                           endeavorNames: endeavorNames,
                           dragOffsets: $rowDragOffsets,
                           onOpen: { editingTask = $0 },
                           onWhen: { whenRequest = DayflowWhenRequest(tasks: [$0]) })
    }

    // MARK: Results (typed)

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !taskMatches.isEmpty {
                sectionHeader("TASKS")
                ForEach(taskMatches.prefix(8)) { task in
                    swipeableRow(task, meta: taskMeta(task))
                }
            }
            if !taggedDocs.isEmpty {
                // "#tax" reaches Satchel: doc tags carry no "#", so the
                // engine's literal terms can't see them — this section can
                // (David: "I do use tags in satchel and notes"). Notes with
                // the literal #tag already surface through the engine.
                sectionHeader("TAGGED IN SATCHEL")
                ForEach(taggedDocs.prefix(8), id: \.relativePath) { doc in
                    taggedDocRow(doc)
                }
            }
            ForEach(groups) { group in
                sectionHeader(group.kind.label.uppercased())
                ForEach(group.items) { result in
                    resultRow(result)
                }
            }
            if taskMatches.isEmpty && groups.isEmpty {
                Text(stillLoading
                     ? "Still reading the container…"
                     : "Nothing contains those letters.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dayflowFaint)
                    .padding(.top, 20)
            }
            askRow
        }
    }

    private func taskMeta(_ task: ThingsTask) -> String {
        var parts: [String] = []
        if let date = task.date {
            let f = DateFormatter(); f.dateFormat = "EEE MMM d"
            parts.append(f.string(from: date).uppercased())
        } else if task.list == ReminderTaskStore.inboxListName {
            parts.append("INBOX")
        } else if task.list == ReminderTaskStore.somedayListName {
            parts.append("SOMEDAY")
        } else {
            parts.append("ANYTIME")
        }
        if let list = task.list, list != ReminderTaskStore.inboxListName,
           list != ReminderTaskStore.somedayListName {
            parts.append(list.uppercased())
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Terms typed with a leading "#", bare. "#tax kearney" → ["tax"].
    private var tagTerms: [String] {
        trimmedQuery.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .map { String($0.dropFirst()) }
    }

    private var taggedDocs: [TraceMacDocument] {
        guard !tagTerms.isEmpty else { return [] }
        return chips.all.filter { doc in
            let tags = doc.tags.map { $0.lowercased() }
            return tagTerms.allSatisfy { term in
                tags.contains { $0 == term || $0.contains(term) }
            }
        }
    }

    private func taggedDocRow(_ doc: TraceMacDocument) -> some View {
        Button {
            DayflowQuickFindRouter.shared.pendingDestination = .document(doc.relativePath)
            close()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title)
                    .font(.dayflowSerif(15, weight: .semibold))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                Text(doc.tags.map { "#" + $0 }.joined(separator: " "))
                    .font(.system(size: 10.5))
                    .tracking(0.8)
                    .foregroundStyle(Color.dayflowAccent)
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
    }

    private func resultRow(_ result: MacSearchResult) -> some View {
        Button { open(result) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.dayflowSerif(15, weight: .semibold))
                    .foregroundStyle(Color.dayflowInk)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 10.5))
                    .tracking(0.8)
                    .foregroundStyle(Color.dayflowFaint)
                    .lineLimit(1)
                if let snippet = result.snippet {
                    Text(snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dayflowMuted)
                        .lineLimit(2)
                }
                if expanded.contains(result.id), let text = previews[result.id] {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dayflowMuted)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
        }
    }

    private func open(_ result: MacSearchResult) {
        if case .preview = result.destination {
            toggle(result)
            return
        }
        // Hand it to ContentView's machinery via the router; the root
        // switches to Today on dismiss. Destinations Today can't open either
        // are expanded there — same honest fallback, one decider.
        DayflowQuickFindRouter.shared.pendingDestination = result.destination
        close()
    }

    private func toggle(_ result: MacSearchResult) {
        if expanded.contains(result.id) {
            expanded.remove(result.id)
            return
        }
        expanded.insert(result.id)
        guard previews[result.id] == nil else { return }
        if let path = result.previewPath {
            previews[result.id] = (try? NoteStore.shared.readFile(path))
                ?? "This note could not be read."
        } else {
            previews[result.id] = "No screen in this app opens this record."
        }
    }

    // MARK: Ask

    @ViewBuilder
    private var askRow: some View {
        if let answer {
            sectionHeader("ANSWER")
            VStack(alignment: .leading, spacing: 10) {
                Text(answer.text)
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowInk)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                if !answer.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(answer.citations) { citation in
                            Button {
                                if case .preview = citation.destination { return }
                                DayflowQuickFindRouter.shared.pendingDestination = citation.destination
                                close()
                            } label: {
                                Text("[\(citation.number)] \(citation.title)")
                                    .font(.system(size: 11))
                                    .tracking(0.5)
                                    .foregroundStyle(Color.dayflowAccent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text(answer.receipt)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.dayflowFaint)
            }
            .padding(.top, 12)
        } else if let askError {
            Text(askError)
                .font(.system(size: 12))
                .foregroundStyle(Color.dayflowAccent)
                .padding(.top, 14)
        } else {
            Button {
                Task { await runAsk() }
            } label: {
                HStack(spacing: 12) {
                    if asking {
                        ProgressView().scaleEffect(0.8)
                        Text("Reading your notes…")
                            .font(.dayflowSerif(15, weight: .semibold))
                            .italic()
                            .foregroundStyle(Color.dayflowMuted)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.dayflowAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask about this")
                                .font(.dayflowSerif(15, weight: .semibold))
                                .italic()
                                .foregroundStyle(Color.dayflowInk)
                            Text("Reads your notes and tasks \u{00B7} answers with citations")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dayflowFaint)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(asking || stillLoading)
            .overlay(
                Rectangle().strokeBorder(Color.dayflowHairline, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.dayflowAccent).frame(width: 3)
            }
            .padding(.top, 18)
        }
    }

    private func runAsk() async {
        asking = true
        askError = nil
        defer { asking = false }
        do {
            answer = try await MacAskService.ask(trimmedQuery,
                                                 corpus: corpus,
                                                 documents: chips.all,
                                                 people: notion.people,
                                                 places: notion.places,
                                                 includeNotionRecords: true,
                                                 tasks: store.allTasks)
        } catch let error as MacAskError {
            askError = error.errorDescription ?? "Ask failed."
        } catch {
            askError = error.localizedDescription
        }
    }

    // MARK: Plumbing

    private func close() {
        fieldFocused = false
        withAnimation(.easeOut(duration: 0.22)) {
            DayflowQuickFindRouter.shared.show = false
        }
    }

    /// TraceSearchIOS's corpus build, verbatim reasoning: detached because
    /// the project pins default isolation to the main actor (D106), keyed on
    /// container access for the cold-launch race.
    private func buildCorpus() async {
        guard let url = NoteStore.shared.containerURL else { return }
        let built = await Task.detached(priority: .userInitiated) {
            MacSearchCorpus.build(containerURL: url)
        }.value
        corpus = built
        corpusBuilt = true
        await chips.refresh()
    }
}

extension View {
    /// The Quick Find pull, for tab headers (Session 78, D159): a firm
    /// downward drag — same thresholds as the Today masthead's — opens the
    /// card with a light haptic. `enabled` gates the fullScreenCover copies
    /// of the tab views, where the overlay would open invisibly underneath.
    func dayflowQuickFindPull(enabled: Bool = true) -> some View {
        modifier(DayflowQuickFindPull(enabled: enabled))
    }
}

/// The pull-down gesture (D159), as a modifier rather than a function, because
/// it needs one piece of state of its own: whether THIS drag has already
/// ticked.
private struct DayflowQuickFindPull: ViewModifier {
    let enabled: Bool
    /// True once this drag has passed the threshold and the tick has fired.
    /// Reset when the finger lifts, so one gesture gives one tick.
    @State private var crossed = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                // **The tick fires at the threshold, not on release** (D480).
                //
                // There has been a haptic here since D159 and it has never
                // felt like anything, because it fired in `onEnded` — after
                // the finger had already left the glass, at the same moment
                // the card appeared. What David is describing in Things is
                // feedback DURING the drag: the instant the pull has gone far
                // enough the phone says so, and you let go knowing it worked.
                //
                // `.rigid` rather than `.light`: a definite tick, not a nudge.
                DragGesture(minimumDistance: 30)
                    .onChanged { value in
                        guard enabled, !crossed else { return }
                        guard value.translation.height > 50,
                              value.translation.height > abs(value.translation.width) * 1.5
                        else { return }
                        crossed = true
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    }
                    .onEnded { _ in
                        let fired = crossed
                        crossed = false
                        guard enabled, fired else { return }
                        withAnimation(.spring(duration: 0.32)) {
                            DayflowQuickFindRouter.shared.show = true
                        }
                    }
            )
    }
}


// MARK: - Manual order (Session 78 round 3)
//
// David, off the TestFlight build: "Id like to be able to drag the rows to
// reorder them and have that be persistent. Possible?" Possible with one
// boundary fact: EventKit does not expose Reminders' manual sort order, so
// the order lives HERE (UserDefaults id arrays per screen) and Apple's own
// app won't mirror it. Applies to UNDATED sections only — the Anytime pool
// and a list's ANYTIME/SOMEDAY rows; SCHEDULED stays chronological, a
// hand-ordered date list is a lie about time.

@Observable
final class DayflowTaskOrder {
    static let shared = DayflowTaskOrder()
    private init() {}
    /// Bumped on every persisted move so views re-sort.
    private(set) var version = 0

    private func storageKey(_ key: String) -> String { "dayflow_task_order_" + key }

    /// Stored order first; ids the store hasn't seen keep their incoming
    /// order, after the ordered ones — the Inbox queue's resync rule.
    func sorted(_ tasks: [ThingsTask], key: String) -> [ThingsTask] {
        _ = version
        let stored = UserDefaults.standard.stringArray(forKey: storageKey(key)) ?? []
        guard !stored.isEmpty else { return tasks }
        var rank: [String: Int] = [:]
        for (index, id) in stored.enumerated() { rank[id] = index }
        return tasks.enumerated()
            .sorted { lhs, rhs in
                let l = rank[lhs.element.id] ?? (stored.count + lhs.offset)
                let r = rank[rhs.element.id] ?? (stored.count + rhs.offset)
                return l < r
            }
            .map(\.element)
    }

    /// Inserts `id` before `target` (nil = end) within `current`, persists.
    func move(id: String, before target: String?, key: String, current: [String]) {
        guard id != target else { return }
        var ids = current.filter { $0 != id }
        if let target, let idx = ids.firstIndex(of: target) {
            ids.insert(id, at: idx)
        } else {
            ids.append(id)
        }
        UserDefaults.standard.set(ids, forKey: storageKey(key))
        version += 1
    }
}

/// Where the Quick Find card can browse to, in place (Session 78 round 2 —
/// the fullScreenCover list screen lasted one Simulator pass: wrong
/// animation direction, joyless back arrow; see the card's `place` comment).
enum DayflowQuickFindPlace: Equatable {
    case anytime
    case list(String)
}
