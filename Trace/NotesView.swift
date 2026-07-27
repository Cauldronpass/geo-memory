import SwiftUI

// MARK: - NotesView
//
// Session 48 (Trace redesign) — trimmed from five tabs to two, per Session 47
// addendum's locked mockup (trace-redesign-mockup-v7.html, "Notes" frames).
//
//  Day   — today's Calendar/YYYY-MM-DD.md, editable inline, plus that day's
//          Visits. The collapsible calendar above it is shared with Week (see
//          calendarSection below).
//  Week  — auto-populated rollup of that week's Visits ("reframed from
//          Horizons" per the addendum — no longer a freeform note; see
//          WeekRollupTab). Same shared calendar.
//
// Removed: Projects and Places (both former NoteFileListTab tabs — the data
// they browsed still exists and is still edited directly elsewhere: Dayflow's
// DayflowProjectNoteView now owns freeform project notes, and
// PlaceDetailView's own Notes tab already edits Notes/Places/*.md directly —
// this only removed a second, now-redundant front door). Trips (retired in
// favor of the new Endeavor system, not yet built). The freeform Horizons
// week/month note editor and the Month note entirely (David doesn't use
// Month — see Dayflow-HANDOFF.md's Session 47 addendum).
//
// Docs (iOSDocumentsView) has no home in the locked mockup either — it's not
// shown in any of the six v7 frames — but Session 47's addendum doesn't say
// to remove it, and the future standalone Documents app it's slated to move
// into isn't build-ready yet (no mockup). Kept reachable via a toolbar
// button instead of a third segment, so it doesn't compromise the mockup's
// clean two-segment Day/Week design. Flagged as a judgment call in this
// session's HANDOFF addendum, not an explicit instruction either way.
//
// The calendar itself (MonthCalendarView, below) is now collapsible —
// collapsed to the single week containing `selectedDate` by default, tap the
// title to expand to the full month. Day and Week share ONE calendar/
// selection state (lifted up here) rather than each owning their own, since
// the mockup shows them as two views of the same underlying date, not two
// independent calendars.

struct NotesView: View {

    @Environment(NotionService.self) private var notion
    @State private var noteStore = NoteStore.shared
    @State private var selectedTab: NoteTab = .day
    @State private var showingSearch = false
    @State private var showingDocs = false
    @State private var showingFABDailyPicker = false
    @State private var fabDailyDate: Date = Date()

    // Shared calendar state — see header comment above.
    @State private var selectedDate: Date = Date()
    @State private var displayMonth: Date = Date()
    @State private var isCalendarExpanded: Bool = false
    @State private var datesWithNotes: Set<String> = []
    @State private var weeksWithVisits: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TraceSegmentedControl(options: NoteTab.allCases, label: { $0.title }, selection: $selectedTab)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                calendarSection
                Divider()
                tabContent
            }
            .traceBackground()
            .navigationTitle(selectedTab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingDocs = true } label: {
                        Image(systemName: "doc.richtext")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showingSearch) {
                GlobalSearchView()
            }
            .sheet(isPresented: $showingDocs) {
                NavigationStack { iOSDocumentsView() }
            }
            .sheet(isPresented: $showingFABDailyPicker) {
                FABDailyPickerSheet(selectedDate: $fabDailyDate) { date in
                    selectedTab = .day
                    selectedDate = date
                    isCalendarExpanded = false
                    NotificationCenter.default.post(
                        name: .traceNotesOpenDay,
                        object: nil,
                        userInfo: ["date": date]
                    )
                }
            }
        }
        .task {
            loadDatesWithNotes()
            loadWeeksWithVisits()
        }
        .onChange(of: notion.visits.count) { _, _ in loadWeeksWithVisits() }
        .onReceive(NotificationCenter.default.publisher(for: .traceNotesNewNote)) { _ in
            // Only "Daily Note" is left as a FAB option now (Project/Place/
            // Horizon Note dropped — see ContentView.swift's fabNotesButtons).
            fabDailyDate = Date()
            showingFABDailyPicker = true
        }
    }

    // MARK: - Shared calendar

    private var calendarSection: some View {
        MonthCalendarView(
            displayMonth: $displayMonth,
            isExpanded: $isCalendarExpanded,
            selectedDate: selectedDate,
            datesWithNotes: datesWithNotes,
            weeksWithVisits: weeksWithVisits,
            weekNumberTitle: selectedTab == .week,
            onDayCellTap: { date in
                selectedDate = date
                isCalendarExpanded = false
                selectedTab = .day
            },
            onWeekNumberTap: { weekDate in
                selectedDate = weekDate
                isCalendarExpanded = false
                selectedTab = .week
            },
            onPageWeek: { direction in
                selectedDate = Calendar.current.date(byAdding: .day, value: direction * 7, to: selectedDate) ?? selectedDate
            }
        )
        .padding(.horizontal, 8)
        .background(Color.white)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .day:
            DailyNoteTab(selectedDate: $selectedDate, onNoteExistenceChanged: loadDatesWithNotes)
        case .week:
            WeekRollupTab(selectedDate: selectedDate)
        }
    }

    // MARK: - Helpers

    private func loadDatesWithNotes() {
        Task {
            let files = (try? noteStore.listFiles(in: "Calendar")) ?? []
            // Only mark a date if the file has actual content. Empty files are left behind
            // by moveDailyNote/clearNote — they must not show a dot on the calendar.
            var dates = Set<String>()
            for file in files {
                let content = (try? noteStore.readFile("Calendar/\(file)")) ?? ""
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    dates.insert(file.replacingOccurrences(of: ".md", with: ""))
                }
            }
            await MainActor.run { datesWithNotes = dates }
        }
    }

    /// Which ISO weeks have at least one Visit — drives the CW-number orange
    /// marker in the collapsed/expanded calendar. Repurposed from the old
    /// "week note file exists" check (there's no week-note file anymore, see
    /// this file's header comment) to "Trace-native, Visit-data-driven" per
    /// the Session 47 addendum's own framing of the new Week pane.
    private func loadWeeksWithVisits() {
        var isoCal = Calendar(identifier: .iso8601)
        isoCal.locale = Locale(identifier: "en_US_POSIX")
        let weeks = notion.visits.map { visit -> String in
            let week = isoCal.component(.weekOfYear, from: visit.date)
            let year = isoCal.component(.yearForWeekOfYear, from: visit.date)
            return String(format: "%d-W%02d.md", year, week)
        }
        weeksWithVisits = Set(weeks)
    }
}

// MARK: - WikiLinkTarget
// Moved to Models.swift (2026-07-19, Dayflow Session 1) — same reasoning as
// BlockInfo's move to MarkdownTextStorage.swift: it's PersonDetailView/
// PlaceDetailView's own discriminated union, not something specific to this
// view, and it only depends on Place/Person (already in Models.swift). No
// behavior change — Trace/TraceMac already carry Models.swift.

// MARK: - NoteTab enum
// Trimmed to Day/Week per the Session 47 addendum — see this file's header
// comment for what happened to the other three (Projects/Places/Trips/Docs).

enum NoteTab: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }

    var title: String {
        switch self {
        case .day:  return "Day"
        case .week: return "Week"
        }
    }
}

// MARK: - Daily note tab

struct DailyNoteTab: View {

    @Binding var selectedDate: Date
    /// Told when a save/clear/move changes whether `selectedDate`'s file has
    /// content — lets the parent NotesView refresh the calendar's note dots
    /// (datesWithNotes is now owned there, shared with Week's calendar too).
    let onNoteExistenceChanged: () -> Void

    @Environment(NotionService.self) private var notion
    @State private var noteStore = NoteStore.shared
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedVisit: Visit? = nil
    @State private var showingMoveContent: Bool = false
    @State private var timestampTrigger: Date? = nil
    @State private var showingClearConfirm: Bool = false
    @State private var isEditorFocused: Bool = false
    // E1 — block promote
    @State private var longPressedBlock: BlockInfo? = nil
    /// Session 45 addendum 6 — set by MarkdownEditorView's onCaptureTap when a
    /// `[label](capture://open?id=ID)` marker is tapped. isPresented-Binding,
    /// same shape as other non-Identifiable sheet triggers in this file
    /// (String isn't Identifiable, so not .sheet(item:)).
    @State private var tappedCaptureID: String? = nil
    // E6b — wikilink tap navigation
    @State private var wikiLinkTarget: WikiLinkTarget? = nil

    private var visitsForDay: [Visit] {
        let cal = Calendar.current
        return notion.visits
            .filter { cal.isDate($0.date, inSameDayAs: selectedDate) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            if !noteStore.hasAccess {
                notLinkedView
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                errorView(err)
            } else {
                VStack(spacing: 0) {
                    if !visitsForDay.isEmpty {
                        visitsRow
                        Divider()
                    }
                    MarkdownEditorView(
                        text: $content,
                        onSave: { newText in save(newText) },
                        placeholder: "Nothing here yet — start writing.",
                        timestampTrigger: $timestampTrigger,
                        onFocusChange: { isEditorFocused = $0 },
                        onBlockLongPress: { info in longPressedBlock = info },
                        onWikiTap: { name in resolveWikiLink(name) },
                        wikiSuggestions: { query in wikiSuggestions(for: query) },
                        onCaptureTap: { id in tappedCaptureID = id }
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    NotificationCenter.default.post(name: .traceOpenRightDrawer, object: nil)
                } label: {
                    Image(systemName: "tray")
                }
            }
        }
        .task {
            load()
        }
        .onChange(of: selectedDate) { _, _ in
            load()
        }
        .sheet(item: $longPressedBlock) { block in
            BlockPromoteSheet(block: block) { action in
                applyBlockAction(action, block: block)
            }
            .environment(notion)
        }
        .sheet(item: $selectedVisit) { visit in
            VisitDetailView(visit: visit)
                .environment(notion)
        }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                switch target {
                case .place(let place):
                    PlaceDetailView(place: place)
                        .environment(NotionService.shared)
                        .environment(LocationManager.shared)
                case .person(let person):
                    PersonDetailView(personID: person.id, personName: person.name)
                        .environment(NotionService.shared)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { tappedCaptureID != nil },
            set: { if !$0 { tappedCaptureID = nil } }
        )) {
            if let id = tappedCaptureID {
                CaptureSummaryView(captureID: id)
                    .environment(NotionService.shared)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .traceNotesOpenDay)) { notif in
            guard let date = notif.userInfo?["date"] as? Date else { return }
            selectedDate = date
            load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { note in
            // Only reload for external writes (e.g. from capture drawer).
            // If the editor has focus the user is typing — the editor owns the
            // content and reloading would fight the keyboard and lose keystrokes.
            guard !isEditorFocused else { return }
            guard let changedPath = note.object as? String else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let currentPath = "Calendar/\(formatter.string(from: selectedDate)).md"
            guard changedPath == currentPath else { return }
            load()
        }
        .sheet(isPresented: $showingMoveContent) {
            MoveDailyContentSheet(sourceDate: selectedDate, sourceContent: content) { newContent in
                content = newContent
                onNoteExistenceChanged()
            }
        }
        .confirmationDialog(
            "Clear this note?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Note", role: .destructive) { clearNote() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The note will be erased. This cannot be undone.")
        }
    }

    // MARK: Editor header (chevrons + actions)
    // Calendar toggle button removed — the shared calendar (NotesView's
    // calendarSection) is always visible above this tab now, not a modal
    // overlay this view controlled itself. See NotesView.swift header comment.

    private var editorHeader: some View {
        HStack(spacing: 0) {
            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }

            Spacer()

            Button {
                selectedDate = Date()
            } label: {
                Text(selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }

            Button {
                showingMoveContent = true
            } label: {
                Image(systemName: "arrow.right.square")
                    .font(.subheadline)
                    .foregroundStyle(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .tertiary : .secondary)
                    .frame(width: 44, height: 44)
            }
            .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                showingClearConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(UIColor.tertiaryLabel) : Color.red.opacity(0.7))
                    .frame(width: 40, height: 44)
            }
            .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                timestampTrigger = Date()
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 40, height: 44)
            }
        }
        .padding(.horizontal, 4)
        .background(.bar)
    }

    // MARK: Visits-today row
    // New in Session 48 — always-visible (not modal, unlike the old E15
    // calendar bottom panel) so a Visit logged today is one glance away
    // without leaving the note.

    private var visitsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visitsForDay) { visit in
                    Button { selectedVisit = visit } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(visit.placeName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                            if let rating = visit.rating {
                                Text(String(repeating: "★", count: rating))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(UIColor.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    // MARK: Helpers

    private func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let raw = try noteStore.readDailyNote(date: selectedDate)
                content = stripDateHeader(raw)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Removes the `# YYYY-MM-DD` first line (and any immediately following blank line)
    /// so the date header is hidden in the editor but preserved in the file.
    private func stripDateHeader(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.hasPrefix("# "),
              first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return text }
        lines.removeFirst()
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func save(_ text: String) {
        Task {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: selectedDate)
            let path = "Calendar/\(dateStr).md"
            // Always write with the date header preserved in the raw file
            let fileContent = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "# \(dateStr)\n\n\(text)"
            try? noteStore.writeFile(path, content: fileContent)
            onNoteExistenceChanged()
        }
    }

    /// Returns autocomplete candidates for a [[wikilink]] partial name.
    /// Places (mappin icon) first, then people (person icon), max 8 total.
    private func wikiSuggestions(for query: String) -> [(name: String, isPlace: Bool)] {
        let q = query.lowercased()
        var results: [(name: String, isPlace: Bool)] = []
        // Places from Notion
        let placeMatches = notion.places
            .map { $0.name }
            .filter { q.isEmpty || $0.lowercased().contains(q) }
            .sorted()
            .map { (name: $0, isPlace: true) }
        results.append(contentsOf: placeMatches)
        // People from Notion
        let peopleMatches = notion.people
            .map { $0.name }
            .filter { name in
                (q.isEmpty || name.lowercased().contains(q)) &&
                !results.contains(where: { $0.name == name })
            }
            .sorted()
            .map { (name: $0, isPlace: false) }
        results.append(contentsOf: peopleMatches)
        return Array(results.prefix(8))
    }

    /// Resolves a tapped [[name]] to the right detail sheet.
    private func resolveWikiLink(_ name: String) {
        if let place = notion.places.first(where: { $0.name == name }) {
            wikiLinkTarget = .place(place)
        } else if let person = notion.people.first(where: { $0.name == name }) {
            wikiLinkTarget = .person(person)
        }
    }

    private func clearNote() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: selectedDate)
        // Write empty content — keeps the file to avoid iCloud sync edge cases.
        // The date header is not re-added so the file is truly blank.
        try? noteStore.writeFile("Calendar/\(dateStr).md", content: "")
        content = ""
        onNoteExistenceChanged()
    }

    // E3's week/month note helpers (weekFilename/monthFilename/weekTitle/
    // monthTitle/refreshHorizonNoteExistence) and loadDatesWithNotes were
    // removed here in Session 48 — the freeform Horizons week/month note
    // editor is gone (see this file's header comment) and datesWithNotes is
    // now owned by the parent NotesView (shared with Week's calendar), which
    // calls its own loadDatesWithNotes() via onNoteExistenceChanged().

    // MARK: - E1: Block action

    private func applyBlockAction(_ action: BlockAction, block: BlockInfo) {
        switch action {
        case .promote(let title, let destination):
            promoteBlock(block, title: title, destination: destination)
        case .move(let destination):
            if case .visit(let visit) = destination {
                // Visit append is async (Notion API call) — fire and forget, then remove block
                let text = block.text
                Task { try? await notion.appendVisitNotes(visitID: visit.id, text: text) }
                content = removeBlock(nsRange: block.nsRange, from: content)
                save(content)
            } else {
                moveBlock(block, destination: destination)
            }
        case .delete:
            content = removeBlock(nsRange: block.nsRange, from: content)
            save(content)
        }
        longPressedBlock = nil
    }

    private func promoteBlock(_ block: BlockInfo, title: String, destination: BlockDestination) {
        let path: String
        switch destination {
        case .horizons: path = "Notes/Horizons/\(title).md"
        case .projects: path = "Notes/Projects/\(title).md"
        case .day(let date):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            path = "Calendar/\(f.string(from: date)).md"
        case .visit, .place:
            // BlockPromoteSheet.DestOption.promoteOptions only ever offers
            // horizons/projects/day for Promote — visit/place are Move-only
            // (they target an existing record, not a new named note). Kept
            // here only so the switch stays exhaustive against BlockDestination.
            return
        }
        let noteContent = "# \(title)\n\n\(block.text)"
        try? noteStore.writeFile(path, content: noteContent)
        content = removeBlock(nsRange: block.nsRange, from: content)
        save(content)
    }

    private func moveBlock(_ block: BlockInfo, destination: BlockDestination) {
        let path: String
        switch destination {
        case .horizons: path = "Notes/Horizons/\(block.firstLineTitle).md"
        case .projects: path = "Notes/Projects/\(block.firstLineTitle).md"
        case .day(let date):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            path = "Calendar/\(f.string(from: date)).md"
        case .place(let place):
            path = "Notes/Places/\(place.name).md"
        case .visit:
            return  // handled async in applyBlockAction
        }
        let existing = (try? noteStore.readFile(path)) ?? ""
        let updated = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? block.text
            : existing + "\n\n" + block.text
        try? noteStore.writeFile(path, content: updated)
        content = removeBlock(nsRange: block.nsRange, from: content)
        save(content)
    }

    private func removeBlock(nsRange: NSRange, from text: String) -> String {
        let ns = text as NSString
        guard nsRange.location != NSNotFound,
              nsRange.location + nsRange.length <= ns.length else { return text }
        var result = ns.replacingCharacters(in: nsRange, with: "") as String
        // Clean up triple blank lines left by removal
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    private var notLinkedView: some View {
        ContentUnavailableView(
            "iCloud Unavailable",
            systemImage: "icloud.slash",
            description: Text("Make sure you are signed in to iCloud in Settings.")
        )
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView(
            "Couldn't Load Note",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
    }
}

// MARK: - Month calendar view

struct MonthCalendarView: View {

    @Binding var displayMonth: Date
    /// Session 48 — collapse/expand replaces the old always-full-month grid.
    /// Collapsed shows only the week row containing `selectedDate`; expanded
    /// shows the full `displayMonth` grid. Owned by the parent (NotesView) so
    /// Day and Week share one collapse state along with the rest of the
    /// shared calendar state — see this file's header comment.
    @Binding var isExpanded: Bool
    let selectedDate: Date
    let datesWithNotes: Set<String>
    /// Renamed from `existingWeekNotes` — there's no week-note file anymore,
    /// this now drives the CW-number's orange marker off Visit data instead
    /// (see NotesView.loadWeeksWithVisits).
    let weeksWithVisits: Set<String>
    /// True on the Week tab — swaps the header title from "Month Year" to
    /// "Week NN · Year" so the collapsed calendar's title matches whichever
    /// tab it's paired with. Not spelled out verbatim in the addendum;
    /// flagged as a judgment call in this session's HANDOFF addendum.
    let weekNumberTitle: Bool
    /// Tap a day cell — mockup: "jump to that day (lands back in Day,
    /// collapsed)". Replaces the old onDateSelected/onDateLongPressed pair;
    /// there's no separate "just preview" tap anymore, one tap now does what
    /// the old long-press did.
    let onDayCellTap: (Date) -> Void
    /// Tap a CW number — mockup: "jump to that week (lands in Week,
    /// collapsed)". Replaces the old onWeekNote (which opened a freeform
    /// week-note editor sheet — gone, see file header comment).
    let onWeekNumberTap: (Date) -> Void
    /// Page by one week (±1) while collapsed. Only used when !isExpanded —
    /// expanded paging still moves `displayMonth` by month, handled locally.
    let onPageWeek: (Int) -> Void

    private let cal = Calendar.current

    private var daysInMonth: [Date?] {
        guard
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth)),
            let range = cal.range(of: .day, in: .month, for: monthStart)
        else { return [] }
        let offset = cal.component(.weekday, from: monthStart) - cal.firstWeekday
        let leading = (offset + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            days.append(cal.date(byAdding: .day, value: day - 1, to: monthStart))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    /// Group flat day array into week rows of 7
    private var weeks: [[Date?]] {
        let days = daysInMonth
        var result: [[Date?]] = []
        var i = 0
        while i < days.count {
            result.append(Array(days[i..<min(i + 7, days.count)]))
            i += 7
        }
        return result
    }

    /// The 7 dates of the week containing `selectedDate`, independent of
    /// `displayMonth` — collapsed paging (onPageWeek) moves `selectedDate`,
    /// not `displayMonth`, so this must track selectedDate directly.
    private var collapsedWeek: [Date?] {
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: selectedDate)?.start else { return [] }
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        VStack(spacing: 6) {
            header

            // Column headers: blank above week-number | locale day labels
            HStack(spacing: 0) {
                Text("").font(.caption2.weight(.medium)).frame(width: 32)
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        weekRow(week)
                    }
                }
                .padding(.horizontal, 8)
            } else {
                weekRow(collapsedWeek)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                if isExpanded {
                    displayMonth = cal.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
                } else {
                    onPageWeek(-1)
                }
            } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 32)
            }

            Spacer()

            Button {
                if !isExpanded { displayMonth = selectedDate }
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(headerTitle)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                if isExpanded {
                    displayMonth = cal.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth
                } else {
                    onPageWeek(1)
                }
            } label: {
                Image(systemName: "chevron.right").frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 8)
    }

    private var headerTitle: String {
        if isExpanded {
            return displayMonth.formatted(.dateTime.month(.wide).year())
        }
        if weekNumberTitle {
            var isoCal = Calendar(identifier: .iso8601)
            isoCal.locale = Locale(identifier: "en_US_POSIX")
            let week = isoCal.component(.weekOfYear, from: selectedDate)
            let year = isoCal.component(.yearForWeekOfYear, from: selectedDate)
            return "Week \(week) · \(year)"
        }
        return selectedDate.formatted(.dateTime.month(.wide).year())
    }

    @ViewBuilder
    private func weekRow(_ week: [Date?]) -> some View {
        let dates = week.compactMap { $0 }
        // Prefer Wed (wd=4) or Thu (wd=5) — mid-ISO-week, avoids Sun/Mon boundary ambiguity
        let rep = dates.first(where: {
            let wd = cal.component(.weekday, from: $0)
            return wd == 4 || wd == 5
        }) ?? dates.first ?? displayMonth
        let wFile = weekFilename(for: rep)
        let wNum  = weekNumber(for: rep)
        let hasVisits = weeksWithVisits.contains(wFile)

        HStack(spacing: 0) {
            // Week number — left label, tappable
            Button { onWeekNumberTap(rep) } label: {
                Text("\(wNum)")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(hasVisits ? Color.orange : Color(UIColor.tertiaryLabel))
                    .frame(width: 32, alignment: .center)
            }
            .buttonStyle(.plain)

            ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                if let date = date {
                    DayCell(
                        date: date,
                        isSelected: cal.isDate(date, inSameDayAs: selectedDate),
                        isToday: cal.isDateInToday(date),
                        hasNote: datesWithNotes.contains(isoString(date)),
                        onTap: { onDayCellTap(date) }
                    )
                } else {
                    Color.clear
                        .frame(height: 40)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var weekdayLabels: [String] {
        var symbols = cal.veryShortWeekdaySymbols
        let shift = cal.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private func isoString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func weekFilename(for date: Date) -> String {
        var isoCal = Calendar(identifier: .iso8601)
        isoCal.locale = Locale(identifier: "en_US_POSIX")
        let week = isoCal.component(.weekOfYear, from: date)
        let year = isoCal.component(.yearForWeekOfYear, from: date)
        return String(format: "%d-W%02d.md", year, week)
    }

    private func weekNumber(for date: Date) -> Int {
        var isoCal = Calendar(identifier: .iso8601)
        isoCal.locale = Locale(identifier: "en_US_POSIX")
        return isoCal.component(.weekOfYear, from: date)
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let hasNote: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(.subheadline, design: .rounded).weight(isToday ? .bold : .regular))
                .foregroundStyle(labelColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(isSelected ? Color.accentColor : Color.clear))
                .overlay(
                    Circle().strokeBorder(isToday && !isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )

            Circle()
                .fill(hasNote ? dotColor : Color.clear)
                .frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .frame(maxWidth: .infinity)
    }

    private var labelColor: Color {
        if isSelected { return .white }
        if isToday { return .accentColor }
        return .primary
    }

    private var dotColor: Color {
        isSelected ? Color.white.opacity(0.8) : Color.accentColor
    }
}

// MARK: - Week rollup tab
// New in Session 48 — replaces the old freeform Horizons week-note editor.
// Per the addendum: "reframed from Horizons" — auto-populated from Visit
// data (grouped by day), read-only, no more typing a week note by hand.

struct WeekRollupTab: View {
    let selectedDate: Date

    @Environment(NotionService.self) private var notion
    @State private var selectedVisit: Visit? = nil

    private var isoCal: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var weekInterval: DateInterval? {
        Calendar.current.dateInterval(of: .weekOfYear, for: selectedDate)
    }

    private var weekLabel: String {
        let week = isoCal.component(.weekOfYear, from: selectedDate)
        let year = isoCal.component(.yearForWeekOfYear, from: selectedDate)
        return "Week \(week) · \(year)"
    }

    private var visitsThisWeek: [Visit] {
        guard let interval = weekInterval else { return [] }
        return notion.visits
            .filter { interval.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    /// Visits grouped by calendar day, in day order across the week. Only
    /// days with at least one Visit are kept (empty days aren't shown — this
    /// is a rollup of what happened, not a full 7-day skeleton).
    private var visitsByDay: [(date: Date, visits: [Visit])] {
        guard let interval = weekInterval else { return [] }
        let cal = Calendar.current
        var days: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? interval.end
        }
        return days
            .map { day in (date: day, visits: visitsThisWeek.filter { cal.isDate($0.date, inSameDayAs: day) }) }
            .filter { !$0.visits.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if visitsThisWeek.isEmpty {
                    emptyState
                } else {
                    placesVisitedSection
                }
            }
            .padding(16)
        }
        .traceBackground()
        .sheet(item: $selectedVisit) { visit in
            VisitDetailView(visit: visit)
                .environment(notion)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(weekLabel)
                .font(.headline)
            Text("Auto-populated from your Visits this week. For freeform writing, use Day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No Visits logged this week")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var placesVisitedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Places Visited")
                .traceSectionTitleStyle()

            VStack(spacing: 0) {
                ForEach(Array(visitsByDay.enumerated()), id: \.offset) { index, day in
                    dayGroup(day.date, day.visits)
                    if index != visitsByDay.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .traceCard()
        }
    }

    @ViewBuilder
    private func dayGroup(_ date: Date, _ visits: [Visit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(visits) { visit in
                Button { selectedVisit = visit } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visit.placeName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                            // Session 48 simplification — the mockup labels each
                            // row with an activity-style tag (e.g. "Dinner",
                            // "Workout"); Visit doesn't carry that field, only a
                            // linked Place, so this uses the Place's own
                            // category as the closest available stand-in.
                            // Flagged in this session's HANDOFF addendum.
                            if let category = notion.places.first(where: { $0.id == visit.placeID })?.category,
                               !category.isEmpty {
                                Text(category)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let rating = visit.rating {
                            Text(String(repeating: "★", count: rating))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - FAB Daily Date Picker Sheet

private struct FABDailyPickerSheet: View {
    @Binding var selectedDate: Date
    let onOpen: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
            }
            .navigationTitle("Open Daily Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        onOpen(selectedDate)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Note editor (full-screen or inline for a single file)
//
// When `onBack` is nil  → pushed via NavigationDestination; uses .navigationTitle + .toolbar.
// When `onBack` is set  → rendered inline (GlobalSearchView's own result-detail
//                          state, see below); shows its own header row instead.
// Session 48 — NoteFileListTab (this struct's other inline caller) was
// removed with the Projects/Places tabs; GlobalSearchView is now the only
// caller left, still self-contained and untouched otherwise.

struct NoteEditorView: View {

    let relativePath: String
    let title: String
    /// Provide this when showing inline (not pushed). Called instead of dismiss() on back/delete/rename/move.
    var onBack: (() -> Void)? = nil
    /// When set, matching tokens are highlighted in orange and the view scrolls to the first hit.
    var searchQuery: String? = nil

    @State private var noteStore = NoteStore.shared
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var showingMoveSheet = false
    @State private var showingDeleteConfirm = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingLinkedPlace: Place? = nil
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    /// Session 45 addendum 6 — set by MarkdownEditorView's onCaptureTap when a
    /// `[label](capture://open?id=ID)` marker is tapped. isPresented-Binding,
    /// same shape as other non-Identifiable sheet triggers in this file
    /// (String isn't Identifiable, so not .sheet(item:)).
    @State private var tappedCaptureID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(NotionService.self) private var notion

    private var subfolder: String {
        relativePath.components(separatedBy: "/").dropLast().joined(separator: "/")
    }
    private var filename: String {
        relativePath.components(separatedBy: "/").last ?? ""
    }
    /// If this is a Notes/Places/ note, returns the matching Place from NotionService.
    private var linkedPlace: Place? {
        guard relativePath.hasPrefix("Notes/Places/") else { return nil }
        let noteFilename = filename.replacingOccurrences(of: ".md", with: "")
        return notion.places.first {
            NoteStore.shared.placeNoteFilename(for: $0.name) == noteFilename
        }
    }

    // MARK: - Body

    var body: some View {
        editorStack
            .task { load() }
            .sheet(isPresented: $showingMoveSheet) {
                MoveNoteSheet(filename: filename, currentSubfolder: subfolder) { destSubfolder in
                    let dest = "\(destSubfolder)/\(filename)"
                    try? noteStore.moveFile(from: relativePath, to: dest)
                    showingMoveSheet = false
                    back()
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    try? noteStore.deleteFile(relativePath)
                    back()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This cannot be undone.")
            }
            .alert("Rename", isPresented: $showingRename) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newName.isEmpty, newName != title else { return }
                    let newFilename = "\(newName).md"
                    let dest = "\(subfolder)/\(newFilename)"
                    try? noteStore.moveFile(from: relativePath, to: dest)
                    back()
                }
                Button("Cancel", role: .cancel) { renameText = "" }
            }
            .sheet(item: $showingLinkedPlace) { place in
                NavigationStack {
                    PlaceDetailView(place: place)
                }
            }
            .sheet(item: $wikiLinkTarget) { target in
                NavigationStack {
                    switch target {
                    case .place(let place):
                        PlaceDetailView(place: place)
                            .environment(NotionService.shared)
                            .environment(LocationManager.shared)
                    case .person(let person):
                        PersonDetailView(personID: person.id, personName: person.name)
                            .environment(NotionService.shared)
                    }
                }
            }
    }

    @ViewBuilder
    private var editorStack: some View {
        if onBack != nil {
            // Inline mode — show manual header so the parent tab bar stays visible.
            VStack(spacing: 0) {
                inlineHeader
                Divider()
                editorBody
            }
        } else {
            // Push mode — use standard NavigationStack title + toolbar.
            editorBody
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        actionButtons
                    }
                }
        }
    }

    // Editor body shared by both modes
    private var editorBody: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownEditorView(
                    text: $content,
                    onSave: { newText in save(newText) },
                    relativePath: relativePath,
                    onWikiTap: { name in resolveWikiLink(name) },
                    wikiSuggestions: { query in wikiSuggestions(for: query) },
                    searchQuery: searchQuery,
                    onCaptureTap: { id in tappedCaptureID = id }
                )
            }
        }
    }

    // Header row used in inline mode — mimics a navigation bar
    private var inlineHeader: some View {
        HStack(spacing: 0) {
            // Back button
            Button {
                back()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Notes")
                        .font(.body)
                }
                .foregroundStyle(Color.accentColor)
            }

            Spacer()

            // Title centred
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: 160)

            Spacer()

            // Actions — same as toolbar in push mode
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // Shared action buttons (saved indicator + inbox + place link + ellipsis menu)
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if let place = linkedPlace {
                Button {
                    showingLinkedPlace = place
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
            }
            Button {
                NotificationCenter.default.post(name: .traceOpenRightDrawer, object: nil)
            } label: {
                Image(systemName: "tray")
            }
            Menu {
                Button {
                    showingMoveSheet = true
                } label: {
                    Label("Move…", systemImage: "folder.badge.arrow.right")
                }
                Button {
                    renameText = title
                    showingRename = true
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Helpers

    /// Dismisses: uses onBack closure (inline mode) or SwiftUI dismiss (push mode).
    private func back() {
        if let onBack { onBack() } else { dismiss() }
    }

    private func load() {
        Task {
            content = (try? noteStore.readFile(relativePath)) ?? ""
            isLoading = false
        }
    }

    private func save(_ text: String) {
        Task {
            try? noteStore.writeFile(relativePath, content: text)
        }
    }

    /// Returns autocomplete candidates for a [[wikilink]] partial name.
    /// Places (mappin icon) first, then people (person icon), max 8 total.
    private func wikiSuggestions(for query: String) -> [(name: String, isPlace: Bool)] {
        let q = query.lowercased()
        var results: [(name: String, isPlace: Bool)] = []
        let placeMatches = notion.places
            .map { $0.name }
            .filter { q.isEmpty || $0.lowercased().contains(q) }
            .sorted()
            .map { (name: $0, isPlace: true) }
        results.append(contentsOf: placeMatches)
        let peopleMatches = notion.people
            .map { $0.name }
            .filter { name in
                (q.isEmpty || name.lowercased().contains(q)) &&
                !results.contains(where: { $0.name == name })
            }
            .sorted()
            .map { (name: $0, isPlace: false) }
        results.append(contentsOf: peopleMatches)
        return Array(results.prefix(8))
    }

    private func resolveWikiLink(_ name: String) {
        if let place = notion.places.first(where: { $0.name == name }) {
            wikiLinkTarget = .place(place)
        } else if let person = notion.people.first(where: { $0.name == name }) {
            wikiLinkTarget = .person(person)
        }
    }

}


// MARK: - Move Daily Content Sheet

struct MoveDailyContentSheet: View {

    let sourceDate: Date
    let sourceContent: String
    /// Called after a successful move. Receives the new content of the source note (empty = fully moved).
    let onMoved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(NotionService.self) private var notion
    private var noteStore: NoteStore { NoteStore.shared }

    // MARK: - Destination type

    enum Dest: String, CaseIterable {
        case day, visit, project, horizon, place

        var label: String {
            switch self {
            case .day:     return "Another Day"
            case .visit:   return "Visit"
            case .project: return "Project"
            case .horizon: return "Horizon"
            case .place:   return "Place"
            }
        }
        var icon: String {
            switch self {
            case .day:     return "calendar"
            case .visit:   return "checkmark.circle"
            case .project: return "folder"
            case .horizon: return "square.stack"
            case .place:   return "mappin"
            }
        }
    }

    @State private var dest: Dest = .day
    @State private var targetDate: Date = Date()
    @State private var searchText = ""
    @State private var files: [String] = []          // used by project + horizon (existing files)
    @State private var selectedFile: String? = nil   // filename (with .md) for day/project/horizon
    @State private var selectedVisit: Visit? = nil
    @State private var selectedPlace: Place? = nil
    @State private var isMoving = false
    @State private var errorMessage: String? = nil

    // MARK: - Horizon helpers (mirrors HorizonsNoteTab logic)

    private static let isoCal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private var currentWeekFilename: String {
        let week = Self.isoCal.component(.weekOfYear, from: Date())
        let year = Self.isoCal.component(.yearForWeekOfYear, from: Date())
        return String(format: "%d-W%02d.md", year, week)
    }

    private var currentMonthFilename: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return "\(f.string(from: Date())).md"
    }

    private var weekLabel: String {
        let week = Self.isoCal.component(.weekOfYear, from: Date())
        let year = Self.isoCal.component(.yearForWeekOfYear, from: Date())
        return String(format: "Week %d · %d", week, year)
    }

    private var monthLabel: String {
        Date().formatted(.dateTime.month(.wide).year())
    }

    /// Past horizon files not pinned as current week/month
    private var pastHorizonFiles: [String] {
        files.filter { $0 != currentWeekFilename && $0 != currentMonthFilename }
             .sorted(by: >)
    }

    // MARK: - canMove

    private var canMove: Bool {
        switch dest {
        case .day:     return true
        case .visit:   return selectedVisit != nil
        case .place:   return selectedPlace != nil
        default:       return selectedFile != nil   // project, horizon
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                destPicker
                Divider()
                Group {
                    switch dest {
                    case .day:     dayPicker
                    case .visit:   visitList
                    case .horizon: horizonList
                    case .place:   placeList
                    case .project: projectFileList
                    }
                }
                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("Move Note To…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isMoving {
                        ProgressView()
                    } else {
                        Button("Move") {
                            Task { await performMove() }
                        }
                        .fontWeight(.semibold)
                        .disabled(!canMove)
                    }
                }
            }
        }
        .onChange(of: dest) { _, _ in
            selectedFile = nil
            selectedVisit = nil
            selectedPlace = nil
            searchText = ""
            loadFiles()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Destination picker

    private var destPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Dest.allCases, id: \.rawValue) { d in
                    Button { dest = d } label: {
                        Label(d.label, systemImage: d.icon)
                            .font(.subheadline.weight(dest == d ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(dest == d ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                            .foregroundStyle(dest == d ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Day picker

    private var dayPicker: some View {
        Form {
            Section {
                DatePicker("Move to", selection: $targetDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
            }
            Section {
                Text("Content will be appended to the selected day and cleared from the current day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Visit list

    private var filteredVisits: [Visit] {
        let sorted = notion.visits.sorted { $0.date > $1.date }
        if searchText.isEmpty { return Array(sorted.prefix(40)) }
        return sorted.filter { $0.placeName.localizedCaseInsensitiveContains(searchText) }
    }

    private var visitList: some View {
        List(filteredVisits) { visit in
            Button { selectedVisit = visit } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(visit.placeName).foregroundStyle(.primary)
                        Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedVisit?.id == visit.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search visits")
    }

    // MARK: - Horizon list (pinned current period + existing past)

    private var horizonList: some View {
        List {
            Section("This Period") {
                horizonPinnedRow(filename: currentWeekFilename,
                                 label: weekLabel,
                                 icon: "calendar.badge.clock")
                horizonPinnedRow(filename: currentMonthFilename,
                                 label: monthLabel,
                                 icon: "calendar")
            }
            if !pastHorizonFiles.isEmpty {
                Section("Past") {
                    ForEach(pastHorizonFiles, id: \.self) { file in
                        Button { selectedFile = file } label: {
                            HStack {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(file.replacingOccurrences(of: ".md", with: "")).foregroundStyle(.primary)
                                Spacer()
                                if selectedFile == file {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func horizonPinnedRow(filename: String, label: String, icon: String) -> some View {
        Button { selectedFile = filename } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(label).foregroundStyle(.primary)
                Spacer()
                if selectedFile == filename {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Place list (all Notion places, auto-creates note)

    private var filteredPlaces: [Place] {
        let sorted = notion.places.sorted { $0.name < $1.name }
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) ||
                               $0.city.localizedCaseInsensitiveContains(searchText) }
    }

    private var placeList: some View {
        Group {
            if notion.places.isEmpty {
                ContentUnavailableView(
                    "No Places",
                    systemImage: "mappin",
                    description: Text("Add places to your system first.")
                )
            } else {
                List(filteredPlaces) { place in
                    Button { selectedPlace = place } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(.primary)
                                if !place.city.isEmpty {
                                    Text(place.city).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedPlace?.id == place.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "Search places")
            }
        }
        .task {
            if notion.places.isEmpty { await notion.fetchPlaces() }
        }
    }

    // MARK: - Project file list

    private var filteredProjectFiles: [String] {
        let names = files.map { $0.replacingOccurrences(of: ".md", with: "") }
        if searchText.isEmpty { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    @ViewBuilder
    private var projectFileList: some View {
        if files.isEmpty {
            ContentUnavailableView(
                "No Project Notes",
                systemImage: "folder",
                description: Text("Create a project note first, then move content into it.")
            )
        } else {
            List(filteredProjectFiles, id: \.self) { name in
                Button { selectedFile = name + ".md" } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        if selectedFile == name + ".md" {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search project notes")
        }
    }

    // MARK: - Actions

    private func loadFiles() {
        let subfolder: String
        switch dest {
        case .project: subfolder = "Notes/Projects"
        case .horizon: subfolder = "Notes/Horizons"
        default: return
        }
        Task {
            let list = (try? noteStore.listFiles(in: subfolder)) ?? []
            await MainActor.run { files = list.filter { $0.hasSuffix(".md") } }
        }
    }

    private func performMove() async {
        isMoving = true
        errorMessage = nil
        do {
            switch dest {
            case .day:
                try noteStore.moveDailyNote(from: sourceDate, to: targetDate)
                let newContent = (try? noteStore.readDailyNote(date: sourceDate)) ?? ""
                await MainActor.run { onMoved(newContent); dismiss() }

            case .visit:
                guard let visit = selectedVisit else { return }
                try await notion.appendVisitNotes(visitID: visit.id, text: stripped(sourceContent))
                try clearSource()
                await MainActor.run { onMoved(""); dismiss() }

            case .horizon:
                guard let file = selectedFile else { return }
                try appendToNoteStoreFile(subfolder: "Notes/Horizons", filename: file,
                                          header: file.replacingOccurrences(of: ".md", with: ""))
                try clearSource()
                await MainActor.run { onMoved(""); dismiss() }

            case .place:
                guard let place = selectedPlace else { return }
                let filename = "\(place.name).md"
                try appendToNoteStoreFile(subfolder: "Notes/Places", filename: filename,
                                          header: place.name)
                try clearSource()
                await MainActor.run { onMoved(""); dismiss() }

            case .project:
                guard let file = selectedFile else { return }
                try appendToNoteStoreFile(subfolder: "Notes/Projects", filename: file,
                                          header: file.replacingOccurrences(of: ".md", with: ""))
                try clearSource()
                await MainActor.run { onMoved(""); dismiss() }
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription; isMoving = false }
        }
    }

    /// Appends stripped content to a NoteStore file, creating it with a `# Header` if it doesn't exist.
    private func appendToNoteStoreFile(subfolder: String, filename: String, header: String) throws {
        let path = "\(subfolder)/\(filename)"
        let text = stripped(sourceContent)
        let existing = (try? noteStore.readFile(path)) ?? ""
        let updated: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated = "# \(header)\n\n\(text)"
        } else {
            updated = existing + "\n\n" + text
        }
        try noteStore.writeFile(path, content: updated)
    }

    /// Clears the source daily note file.
    private func clearSource() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        try noteStore.writeFile("Calendar/\(f.string(from: sourceDate)).md", content: "")
    }

    /// Strips the leading `# YYYY-MM-DD` date header from a daily note.
    private func stripped(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first,
           first.hasPrefix("# "),
           first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Move Note Sheet

struct MoveNoteSheet: View {
    let filename: String
    let currentSubfolder: String
    let onMove: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let destinations: [(label: String, icon: String, path: String)] = [
        ("Horizons", "square.stack", "Notes/Horizons"),
        ("Projects", "folder",       "Notes/Projects"),
        ("Places",   "mappin",       "Notes/Places"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(destinations.filter { $0.path != currentSubfolder }, id: \.path) { dest in
                    Button {
                        onMove(dest.path)
                    } label: {
                        Label(dest.label, systemImage: dest.icon)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Move \"\(filename.replacingOccurrences(of: ".md", with: ""))\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - E1: Block data models
//
// BlockInfo itself moved to MarkdownTextStorage.swift (2026-07-19, Dayflow
// Session 1) — it's MarkdownEditorView's own callback type, not something
// specific to this view, and keeping it here forced Dayflow's target to
// compile all of NotesView.swift just to resolve one struct. No behavior
// change: same target (Trace/TraceMac already carry MarkdownTextStorage.swift),
// just resolved from its new home.

enum BlockAction {
    case promote(title: String, destination: BlockDestination)
    case move(destination: BlockDestination)
    case delete
}

enum BlockDestination {
    case horizons
    case projects
    case day(Date)
    case visit(Visit)
    case place(Place)
}

// MARK: - E1: Block Promote Sheet

struct BlockPromoteSheet: View {
    let block: BlockInfo
    let onAction: (BlockAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(NotionService.self) private var notion
    @State private var mode: Mode = .choose
    @State private var title: String = ""
    @State private var destOption: DestOption = .horizons
    @State private var targetDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var showingDatePicker = false
    @State private var selectedVisit: Visit? = nil
    @State private var selectedPlace: Place? = nil

    enum Mode { case choose, promote, move }
    enum DestOption: String, CaseIterable, Identifiable {
        case horizons = "Horizons"
        case projects = "Projects"
        case day      = "Another Day"
        case visit    = "Visit"
        case place    = "Place"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .horizons: return "square.stack"
            case .projects: return "folder"
            case .day:      return "calendar"
            case .visit:    return "checkmark.circle"
            case .place:    return "mappin"
            }
        }
        /// Only valid for horizons/projects/day — visit and place use selected objects.
        func toDestination(date: Date) -> BlockDestination {
            switch self {
            case .horizons: return .horizons
            case .projects: return .projects
            case .day:      return .day(date)
            default:        return .horizons  // fallback; caller guards against this
            }
        }
        /// Available in Promote mode (visit/place don't make sense as named note destinations).
        static var promoteOptions: [DestOption] { [.horizons, .projects, .day] }
    }

    /// First line of block (timestamp) shown as preview
    private var blockPreview: String {
        block.text.components(separatedBy: "\n").prefix(2).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .choose:
                    chooseView
                case .promote:
                    promoteView
                case .move:
                    moveView
                }
            }
            .navigationTitle(mode == .choose ? "Block" : (mode == .promote ? "Promote" : "Move"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if mode == .choose {
                        Button("Cancel") { dismiss() }
                    } else {
                        Button("Back") { mode = .choose }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear { title = block.firstLineTitle }
    }

    // MARK: Choose screen

    private var chooseView: some View {
        VStack(spacing: 0) {
            // Preview of block
            Text(blockPreview)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

            List {
                Button {
                    mode = .promote
                } label: {
                    Label("Promote to Named Note", systemImage: "arrow.up.doc")
                        .foregroundStyle(.primary)
                }
                Button {
                    mode = .move
                } label: {
                    Label("Move to Note", systemImage: "arrow.right.doc.on.clipboard")
                        .foregroundStyle(.primary)
                }
                Button(role: .destructive) {
                    onAction(.delete)
                    dismiss()
                } label: {
                    Label("Delete Block", systemImage: "trash")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: Promote screen (title + destination)

    private var promoteView: some View {
        Form {
            Section("Title") {
                TextField("Note title", text: $title)
            }
            Section("Destination") {
                Picker("Destination", selection: $destOption) {
                    ForEach(DestOption.promoteOptions) { opt in
                        Label(opt.rawValue, systemImage: opt.icon).tag(opt)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                if destOption == .day {
                    DatePicker("Date", selection: $targetDate, displayedComponents: .date)
                }
            }
            Section {
                Button("Promote") {
                    onAction(.promote(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Note" : title,
                                     destination: destOption.toDestination(date: targetDate)))
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: Move screen (destination only)

    private var canMove: Bool {
        switch destOption {
        case .visit: return selectedVisit != nil
        case .place: return selectedPlace != nil
        default:     return true
        }
    }

    private var moveView: some View {
        Form {
            Section("Destination") {
                Picker("Destination", selection: $destOption) {
                    ForEach(DestOption.allCases) { opt in
                        Label(opt.rawValue, systemImage: opt.icon).tag(opt)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                if destOption == .day {
                    DatePicker("Date", selection: $targetDate, displayedComponents: .date)
                }
            }

            if destOption == .visit {
                Section("Select Visit") {
                    let recent = Array(notion.visits.sorted { $0.date > $1.date }.prefix(30))
                    if recent.isEmpty {
                        Text("No visits loaded.").foregroundStyle(.secondary)
                    } else {
                        ForEach(recent) { visit in
                            Button { selectedVisit = visit } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(visit.placeName).foregroundStyle(.primary)
                                        Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedVisit?.id == visit.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if destOption == .place {
                Section("Select Place") {
                    let places = notion.places.sorted { $0.name < $1.name }
                    if places.isEmpty {
                        Text("No places loaded.").foregroundStyle(.secondary)
                    } else {
                        ForEach(places) { place in
                            Button { selectedPlace = place } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name).foregroundStyle(.primary)
                                        if !place.city.isEmpty {
                                            Text(place.city).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedPlace?.id == place.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
                .task {
                    if notion.places.isEmpty { await notion.fetchPlaces() }
                }
            }

            Section {
                Button("Move") {
                    let dest: BlockDestination
                    switch destOption {
                    case .visit:
                        guard let v = selectedVisit else { return }
                        dest = .visit(v)
                    case .place:
                        guard let p = selectedPlace else { return }
                        dest = .place(p)
                    default:
                        dest = destOption.toDestination(date: targetDate)
                    }
                    onAction(.move(destination: dest))
                    dismiss()
                }
                .disabled(!canMove)
            }
        }
    }
}

// MARK: - Global Search

private enum SearchScope: String, CaseIterable, Identifiable {
    case all      = "All"
    case daily    = "Daily"
    case horizons = "Horizons"
    case projects = "Projects"
    case places   = "Places"
    var id: String { rawValue }

    var subfolders: [(label: String, path: String)] {
        switch self {
        case .all:
            return [("Daily","Calendar"),("Horizons","Notes/Horizons"),
                    ("Projects","Notes/Projects"),("Places","Notes/Places")]
        case .daily:    return [("Daily",    "Calendar")]
        case .horizons: return [("Horizons", "Notes/Horizons")]
        case .projects: return [("Projects", "Notes/Projects")]
        case .places:   return [("Places",   "Notes/Places")]
        }
    }
}

private struct GlobalSearchResult: Identifiable {
    let id = UUID()
    let filename: String
    let subfolder: String
    let displayName: String
    let scopeLabel: String
    let snippet: String
    let content: String          // full file text — used for expand-on-tap matching lines
}

struct GlobalSearchView: View {

    @State private var searchText = ""
    @State private var scope: SearchScope = .all
    @State private var results: [GlobalSearchResult] = []
    @State private var isRunning = false
    @State private var selectedResult: GlobalSearchResult? = nil
    @State private var expandedResultID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    private let noteStore = NoteStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if let result = selectedResult {
                    NoteEditorView(
                        relativePath: "\(result.subfolder)/\(result.filename)",
                        title: result.displayName,
                        onBack: { selectedResult = nil },
                        searchQuery: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                } else {
                    VStack(spacing: 0) {
                        searchBarRow
                        scopePickerRow
                        Divider()
                        resultsBody
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: searchText) { _, _ in expandedResultID = nil; runSearch() }
        .onChange(of: scope)      { _, _ in expandedResultID = nil; runSearch() }
    }

    // MARK: - Sub-views

    private var searchBarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search notes, #tags…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var scopePickerRow: some View {
        Picker("Scope", selection: $scope) {
            ForEach(SearchScope.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var resultsBody: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRunning {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !trimmed.isEmpty && results.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("No notes match \"\(trimmed)\".")
            )
        } else {
            List(results) { result in
                resultRow(result)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Result row

    @ViewBuilder
    private func resultRow(_ result: GlobalSearchResult) -> some View {
        let isExpanded = expandedResultID == result.id
        VStack(alignment: .leading, spacing: 0) {
            // Always-visible header row
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedResultID = isExpanded ? nil : result.id
                }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(result.scopeLabel)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.75)))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expanded: matching lines + Open button
            if isExpanded {
                let terms = searchTerms(from: searchText)
                let lines = matchingLines(in: result.content, tokens: terms)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(highlighted(line, tokens: terms))
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Button {
                        selectedResult = result
                    } label: {
                        Text("Open note")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Expand helpers

    /// Lowercased token list (keeps # prefix for tag tokens).
    private func searchTerms(from query: String) -> [String] {
        query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.map { $0.lowercased() }
    }

    /// Returns all non-empty lines containing any token, capped at 6.
    private func matchingLines(in content: String, tokens: [String]) -> [String] {
        guard !tokens.isEmpty else { return [] }
        let lines = content.components(separatedBy: "\n")
        var matched: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if tokens.contains(where: { lower.contains($0) }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { matched.append(trimmed) }
            }
        }
        return Array(matched.prefix(6))
    }

    /// Returns an `AttributedString` with every token occurrence highlighted in orange.
    private func highlighted(_ text: String, tokens: [String]) -> AttributedString {
        var attr = AttributedString(text)
        for token in tokens where !token.isEmpty {
            var start = attr.startIndex
            while start < attr.endIndex {
                guard let range = attr[start...].range(of: token, options: .caseInsensitive) else { break }
                attr[range].backgroundColor = .orange.opacity(0.38)
                start = range.upperBound
            }
        }
        return attr
    }

    // MARK: - Search logic

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { results = []; return }
        isRunning = true
        Task {
            let found = await performSearch(query: query, scope: scope)
            await MainActor.run { results = found; isRunning = false }
        }
    }

    private func performSearch(query: String, scope: SearchScope) async -> [GlobalSearchResult] {
        let tokens      = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let tagTokens   = tokens.filter {  $0.hasPrefix("#") }.map { String($0.dropFirst()).lowercased() }
        let plainTokens = tokens.filter { !$0.hasPrefix("#") }.map { $0.lowercased() }

        var found: [GlobalSearchResult] = []
        for (label, path) in scope.subfolders {
            let files = (try? noteStore.listFiles(in: path)) ?? []
            for filename in files {
                guard filename.hasSuffix(".md") else { continue }
                let content      = (try? noteStore.readFile("\(path)/\(filename)")) ?? ""
                let contentLower = content.lowercased()
                let nameLower    = filename.lowercased().replacingOccurrences(of: ".md", with: "")

                let tagsMatch  = tagTokens.allSatisfy   { contentLower.contains("#\($0)") }
                let plainMatch = plainTokens.allSatisfy { nameLower.contains($0) || contentLower.contains($0) }
                guard tagsMatch && plainMatch else { continue }

                let allTerms = plainTokens + tagTokens.map { "#\($0)" }
                found.append(GlobalSearchResult(
                    filename: filename,
                    subfolder: path,
                    displayName: nameLower,
                    scopeLabel: label,
                    snippet: extractSnippet(from: content, tokens: allTerms),
                    content: content
                ))
            }
        }
        return found
    }

    private func extractSnippet(from content: String, tokens: [String]) -> String {
        let lines = content.components(separatedBy: "\n")
        for token in tokens where !token.isEmpty {
            if let line = lines.first(where: { $0.lowercased().contains(token) }) {
                return String(line.trimmingCharacters(in: .whitespaces).prefix(120))
            }
        }
        return String((lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "").prefix(120))
    }
}

