import SwiftUI

// MARK: - NotesView
//
// Four-tab notes screen backed by NoteStore (Trace iCloud container).
//
//  Daily     — today's Calendar/YYYY-MM-DD.md, editable inline
//  Horizons  — Notes/Horizons/*.md (week + month notes)
//  Projects  — Notes/Projects/*.md
//  Places    — Notes/Places/*.md (one file per place)

struct NotesView: View {

    @Environment(NotionService.self) private var notion
    @State private var noteStore = NoteStore.shared
    @State private var selectedTab: NoteTab = .daily
    @State private var showCalendar = false
    @State private var showingSearch = false
    @State private var showingFABNewNote = false
    @State private var fabNewNoteName = ""
    @State private var isCreatingFABNote = false
    @State private var fabNoteSubfolder: String = "Notes/Horizons"
    @State private var showingFABDailyPicker = false
    @State private var fabDailyDate: Date = Date()
    @State private var showingFABPlacePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                tabContent
            }
            .navigationTitle(selectedTab == .daily && showCalendar ? "Calendar" : selectedTab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showingSearch) {
                GlobalSearchView()
            }
            .sheet(isPresented: $showingFABNewNote) {
                NewNoteSheet(name: $fabNewNoteName, isCreating: isCreatingFABNote) {
                    createFABNote()
                }
            }
            .sheet(isPresented: $showingFABPlacePicker) {
                FABPlaceNoteSheet(places: notion.places) { place in
                    selectedTab = .places
                    let filename = "\(place.name).md"
                    NotificationCenter.default.post(
                        name: .traceNotesOpenPlaceNote,
                        object: nil,
                        userInfo: ["filename": filename, "placeName": place.name]
                    )
                }
            }
            .sheet(isPresented: $showingFABDailyPicker) {
                FABDailyPickerSheet(selectedDate: $fabDailyDate) { date in
                    selectedTab = .daily
                    showCalendar = false
                    NotificationCenter.default.post(
                        name: .traceNotesOpenDay,
                        object: nil,
                        userInfo: ["date": date]
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .traceNotesNewNote)) { notif in
            let type = notif.userInfo?["type"] as? String ?? "horizons"
            switch type {
            case "daily":
                fabDailyDate = Date()
                showingFABDailyPicker = true
            case "projects":
                selectedTab = .projects
                fabNoteSubfolder = "Notes/Projects"
                fabNewNoteName = ""
                showingFABNewNote = true
            case "places":
                selectedTab = .places
                showingFABPlacePicker = true
            default: // "horizons"
                selectedTab = .horizons
                fabNoteSubfolder = "Notes/Horizons"
                fabNewNoteName = ""
                showingFABNewNote = true
            }
        }
    }

    private func createFABNote() {
        let name = fabNewNoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreatingFABNote = true
        Task {
            let path = "\(fabNoteSubfolder)/\(name).md"
            try? noteStore.writeFile(path, content: "# \(name)\n")
            await MainActor.run {
                showingFABNewNote = false
                fabNewNoteName = ""
                isCreatingFABNote = false
            }
            NotificationCenter.default.post(name: .traceNotesRefresh, object: nil)
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(NoteTab.allCases) { tab in
                    Button {
                        if tab == .daily && selectedTab == .daily {
                            showCalendar.toggle()
                        } else {
                            selectedTab = tab
                            showCalendar = false
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab == .daily && selectedTab == .daily && showCalendar ? "calendar.badge.checkmark" : tab.icon)
                                .font(.system(size: 16))
                            Text(tab.title)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                    }
                }
            }
            .background(.bar)
            Divider()
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .daily:
            DailyNoteTab(showCalendar: $showCalendar)
        case .horizons:
            HorizonsNoteTab()
        case .projects:
            NoteFileListTab(subfolder: "Notes/Projects", emptyMessage: "No project notes yet.\nTap the pencil to create one.")
        case .places:
            NoteFileListTab(subfolder: "Notes/Places", emptyMessage: "No place notes yet.\nPlace notes are created automatically when you tap Notes on a place.")
        }
    }
}

// MARK: - WikiLinkTarget
// Discriminated union used by onWikiTap to present the right detail sheet.

enum WikiLinkTarget: Identifiable {
    case place(Place)
    case person(Person)
    var id: String {
        switch self {
        case .place(let p):  return "place-\(p.id)"
        case .person(let p): return "person-\(p.id)"
        }
    }
}

// MARK: - NoteTab enum

enum NoteTab: String, CaseIterable, Identifiable {
    case daily, horizons, projects, places
    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily:    return "Daily"
        case .horizons: return "Horizons"
        case .projects: return "Projects"
        case .places:   return "Places"
        }
    }

    var icon: String {
        switch self {
        case .daily:    return "calendar"
        case .horizons: return "square.stack"
        case .projects: return "folder"
        case .places:   return "mappin"
        }
    }
}

// MARK: - Daily note tab

struct DailyNoteTab: View {

    @Binding var showCalendar: Bool

    @Environment(NotionService.self) private var notion
    @State private var noteStore = NoteStore.shared
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDate: Date = Date()
    // E15 — calendar bottom panel
    @State private var panelNotePreview: String = ""
    @State private var panelIsLoading: Bool = false
    @State private var selectedPanelVisit: Visit? = nil
    @State private var displayMonth: Date = Date()
    @State private var datesWithNotes: Set<String> = []
    @State private var showingMoveContent: Bool = false
    @State private var timestampTrigger: Date? = nil
    @State private var showingClearConfirm: Bool = false
    @State private var isEditorFocused: Bool = false
    // E3 — week/month note support
    @State private var existingWeekNotes: Set<String> = []
    @State private var monthNoteExists: Bool = false
    @State private var weekNoteTargetDate: Date = Date()
    @State private var showingWeekNote: Bool = false
    @State private var showingMonthNote: Bool = false
    // E1 — block promote
    @State private var longPressedBlock: BlockInfo? = nil
    // E6b — wikilink tap navigation
    @State private var wikiLinkTarget: WikiLinkTarget? = nil

    var body: some View {
        VStack(spacing: 0) {
            if showCalendar {
                calendarHeader
                Divider()
                MonthCalendarView(
                    displayMonth: $displayMonth,
                    selectedDate: selectedDate,
                    datesWithNotes: datesWithNotes,
                    existingWeekNotes: existingWeekNotes,
                    onDateSelected: { date in
                        // E15: single tap selects date + refreshes panel — stays on calendar
                        selectedDate = date
                        displayMonth = date
                        loadPanelContent()
                    },
                    onDateLongPressed: { date in
                        // E15: long press opens the note directly
                        selectedDate = date
                        showCalendar = false
                        load()
                    },
                    onWeekNote: { weekDate in
                        weekNoteTargetDate = weekDate
                        showingWeekNote = true
                    }
                )
                calendarBottomPanel
            } else {
                editorHeader
                Divider()
                if !noteStore.hasAccess {
                    notLinkedView
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    errorView(err)
                } else {
                    MarkdownEditorView(
                        text: $content,
                        onSave: { newText in save(newText) },
                        placeholder: "Nothing here yet — start writing.",
                        timestampTrigger: $timestampTrigger,
                        onFocusChange: { isEditorFocused = $0 },
                        onBlockLongPress: { info in longPressedBlock = info },
                        onWikiTap: { name in resolveWikiLink(name) },
                        wikiSuggestions: { query in wikiSuggestions(for: query) }
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
            loadDatesWithNotes()
        }
        .onChange(of: showCalendar) { _, isOn in
            if isOn {
                displayMonth = selectedDate
                refreshHorizonNoteExistence()
                loadPanelContent()
            }
        }
        .onChange(of: displayMonth) { _, _ in
            if showCalendar { refreshHorizonNoteExistence() }
        }
        .sheet(isPresented: $showingWeekNote, onDismiss: { refreshHorizonNoteExistence() }) {
            NavigationStack {
                NoteEditorView(
                    relativePath: "Notes/Horizons/\(weekFilename(for: weekNoteTargetDate))",
                    title: weekTitle(for: weekNoteTargetDate)
                )
            }
        }
        .sheet(isPresented: $showingMonthNote, onDismiss: { refreshHorizonNoteExistence() }) {
            NavigationStack {
                NoteEditorView(
                    relativePath: "Notes/Horizons/\(monthFilename(for: displayMonth))",
                    title: monthTitle(for: displayMonth)
                )
            }
        }
        .sheet(item: $longPressedBlock) { block in
            BlockPromoteSheet(block: block) { action in
                applyBlockAction(action, block: block)
            }
        }
        .sheet(item: $selectedPanelVisit) { visit in
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
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                if newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    datesWithNotes.remove(formatter.string(from: selectedDate))
                }
                loadDatesWithNotes()
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

    // MARK: Editor header (chevrons + calendar toggle)

    private var editorHeader: some View {
        HStack(spacing: 0) {
            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                load()
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }

            Spacer()

            Button {
                selectedDate = Date()
                load()
            } label: {
                Text(selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                load()
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

    // MARK: Calendar header (month nav + tappable month title → month note)

    private var calendarHeader: some View {
        HStack(spacing: 0) {
            Button {
                displayMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }

            Spacer()

            // Tappable title — opens month note; dot if note exists
            Button {
                showingMonthNote = true
            } label: {
                HStack(spacing: 4) {
                    Text(displayMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.subheadline.weight(.semibold))
                    if monthNoteExists {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                    }
                }
                .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                displayMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth
            } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 4)
        .background(.bar)
    }

    // MARK: Calendar bottom panel (E15)

    private var calendarBottomPanel: some View {
        let cal = Calendar.current
        let visitsForDay = notion.visits
            .filter { cal.isDate($0.date, inSameDayAs: selectedDate) }
            .sorted { $0.date < $1.date }

        return VStack(spacing: 0) {
            Divider()

            // Header: date label + "Open note" button
            HStack {
                Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showCalendar = false
                    load()
                } label: {
                    HStack(spacing: 3) {
                        Text("Open note")
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Note preview
                    if panelIsLoading {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Loading…").font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(16)
                    } else if panelNotePreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "note.text").foregroundStyle(.tertiary)
                            Text("No note for this day").font(.callout).foregroundStyle(.tertiary)
                        }
                        .padding(16)
                    } else {
                        Text(panelNotePreview)
                            .font(.callout)
                            .lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }

                    // Visits for this day
                    if !visitsForDay.isEmpty {
                        Divider().padding(.horizontal, 16)

                        Label("Visits", systemImage: "mappin.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(visitsForDay) { visit in
                            Button { selectedPanelVisit = visit } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.subheadline)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(visit.placeName)
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if let notes = visit.notes, !notes.isEmpty {
                                            Text(notes)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
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
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
        }
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

    private func loadPanelContent() {
        guard showCalendar else { return }
        panelIsLoading = true
        panelNotePreview = ""
        Task {
            let raw = (try? noteStore.readDailyNote(date: selectedDate)) ?? ""
            panelNotePreview = stripDateHeader(raw)
            panelIsLoading = false
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
            datesWithNotes.insert(dateStr)
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
        datesWithNotes.remove(dateStr)
    }

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

    // MARK: - E3: Week / month note helpers

    private func weekFilename(for date: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "en_US_POSIX")
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        return String(format: "%d-W%02d.md", year, week)
    }

    private func monthFilename(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return "\(f.string(from: date)).md"
    }

    private func weekTitle(for date: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "en_US_POSIX")
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        return String(format: "Week %d · %d", week, year)
    }

    private func monthTitle(for date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    private func refreshHorizonNoteExistence() {
        Task {
            let allFiles = Set((try? noteStore.listFiles(in: "Notes/Horizons")) ?? [])
            // Week files match YYYY-Www.md
            let weekFiles = allFiles.filter {
                $0.range(of: #"^\d{4}-W\d{2}\.md$"#, options: .regularExpression) != nil
            }
            let mFile = monthFilename(for: displayMonth)
            await MainActor.run {
                existingWeekNotes = weekFiles
                monthNoteExists = allFiles.contains(mFile)
            }
        }
    }

    // MARK: - E1: Block action

    private func applyBlockAction(_ action: BlockAction, block: BlockInfo) {
        switch action {
        case .promote(let title, let destination):
            promoteBlock(block, title: title, destination: destination)
        case .move(let destination):
            moveBlock(block, destination: destination)
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
    let selectedDate: Date
    let datesWithNotes: Set<String>
    let existingWeekNotes: Set<String>
    let onDateSelected: (Date) -> Void
    var onDateLongPressed: ((Date) -> Void)? = nil
    let onWeekNote: (Date) -> Void

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

    var body: some View {
        VStack(spacing: 6) {
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

            // Week rows (7 day cells + W cell each)
            VStack(spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    weekRow(week)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 8)
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
        let hasNote = existingWeekNotes.contains(wFile)

        HStack(spacing: 0) {
            // Week number — left label, tappable
            Button { onWeekNote(rep) } label: {
                Text("\(wNum)")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(hasNote ? Color.orange : Color(UIColor.tertiaryLabel))
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
                        onTap: { onDateSelected(date) },
                        onLongPress: onDateLongPressed.map { handler in { handler(date) } }
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
    var onLongPress: (() -> Void)? = nil

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
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onLongPress?() }
        )
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

// MARK: - Note file list tab (Horizons / Projects / Places)

struct NoteFileListTab: View {

    let subfolder: String
    let emptyMessage: String

    @State private var noteStore = NoteStore.shared
    @State private var files: [String] = []
    @State private var isLoading = true
    @State private var selectedFile: String?
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var isCreating = false
    @State private var fileToMove: String? = nil
    @State private var fileContents: [String: String] = [:]
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if let filename = selectedFile {
                // Inline editor — keeps the parent Daily/Horizons/Projects/Places tab bar visible.
                NoteEditorView(
                    relativePath: "\(subfolder)/\(filename)",
                    title: filename.replacingOccurrences(of: ".md", with: ""),
                    onBack: {
                        selectedFile = nil
                        loadFiles()   // refresh list in case the note was renamed or deleted
                    }
                )
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView(
                    "No Notes",
                    systemImage: "note.text",
                    description: Text(emptyMessage)
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { newNoteButton }
                }
            } else {
                VStack(spacing: 0) {
                    if isSearching {
                        searchBar
                        Divider()
                    }
                    let shown = displayedFiles
                    if shown.isEmpty {
                        ContentUnavailableView(
                            "No Matching Notes",
                            systemImage: "magnifyingglass",
                            description: Text("No notes match your search.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(shown, id: \.self) { filename in
                            Button {
                                selectedFile = filename
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    Text(filename.replacingOccurrences(of: ".md", with: ""))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                        .font(.caption)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteFile(filename)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    fileToMove = filename
                                } label: {
                                    Label("Move", systemImage: "folder.badge.arrow.right")
                                }
                                .tint(.indigo)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { newNoteButton }
                    ToolbarItem(placement: .navigationBarTrailing) { searchToggleButton }
                }
            }
        }
        .task { loadFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .traceNotesRefresh)) { _ in loadFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .traceNotesOpenPlaceNote)) { notif in
            guard subfolder == "Notes/Places",
                  let filename = notif.userInfo?["filename"] as? String,
                  let placeName = notif.userInfo?["placeName"] as? String else { return }
            // Create file if it doesn't exist, then open it
            Task {
                if !files.contains(filename) {
                    try? noteStore.writeFile("Notes/Places/\(filename)", content: "# \(placeName)\n")
                    files = (try? noteStore.listFiles(in: subfolder)) ?? []
                }
                await MainActor.run { selectedFile = filename }
            }
        }
        .sheet(isPresented: $showingNewNote) {
            NewNoteSheet(name: $newNoteName, isCreating: isCreating) {
                createNote()
            }
        }
        .sheet(isPresented: Binding(get: { fileToMove != nil }, set: { if !$0 { fileToMove = nil } })) {
            if let filename = fileToMove {
                MoveNoteSheet(filename: filename, currentSubfolder: subfolder) { destSubfolder in
                    moveFile(filename, to: destSubfolder)
                    fileToMove = nil
                }
            }
        }
    }

    private var newNoteButton: some View {
        Button {
            newNoteName = ""
            showingNewNote = true
        } label: {
            Image(systemName: "square.and.pencil")
        }
    }

    private var searchToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSearching.toggle()
                if !isSearching { searchText = "" }
            }
        } label: {
            Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
        }
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreating = true
        Task {
            let filename = "\(name).md"
            let path = "\(subfolder)/\(filename)"
            try? noteStore.writeFile(path, content: "# \(name)\n")
            await MainActor.run {
                showingNewNote = false
                newNoteName = ""
                isCreating = false
            }
            // Reload then navigate into the new note
            files = (try? noteStore.listFiles(in: subfolder)) ?? []
            await MainActor.run { selectedFile = filename }
        }
    }

    private func deleteFile(_ filename: String) {
        try? noteStore.deleteFile("\(subfolder)/\(filename)")
        files.removeAll { $0 == filename }
    }

    private func moveFile(_ filename: String, to destSubfolder: String) {
        let source = "\(subfolder)/\(filename)"
        let dest   = "\(destSubfolder)/\(filename)"
        do {
            try noteStore.moveFile(from: source, to: dest)
            files.removeAll { $0 == filename }
        } catch {
            // silently ignore — file stays in list if move fails
        }
    }

    private func loadFiles() {
        isLoading = true
        Task {
            files = (try? noteStore.listFiles(in: subfolder)) ?? []
            isLoading = false
            loadFileContents()
        }
    }

    /// Reads every file in the current subfolder into fileContents so tag chip
    /// filtering can run synchronously against local strings.
    private func loadFileContents() {
        var contents: [String: String] = [:]
        for filename in files {
            contents[filename] = (try? noteStore.readFile("\(subfolder)/\(filename)")) ?? ""
        }
        fileContents = contents
    }

    // MARK: - Search helpers

    /// Files visible after applying the search bar text.
    /// #tag tokens require the tag in note content; plain tokens match filename or content.
    /// AND logic across all tokens.
    private var displayedFiles: [String] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }

        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let tagTokens   = tokens.filter {  $0.hasPrefix("#") }.map { $0.dropFirst().lowercased() }
        let plainTokens = tokens.filter { !$0.hasPrefix("#") }.map { $0.lowercased() }

        return files.filter { filename in
            let content     = (fileContents[filename] ?? "").lowercased()
            let nameLower   = filename.lowercased().replacingOccurrences(of: ".md", with: "")
            let tagsMatch   = tagTokens.allSatisfy   { content.contains("#\($0)") }
            let plainMatch  = plainTokens.allSatisfy { nameLower.contains($0) || content.contains($0) }
            return tagsMatch && plainMatch
        }
    }

    /// Inline search bar shown below the nav bar when isSearching is true.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            TextField("Search notes, #tags…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

// MARK: - FAB Place Note Picker Sheet

private struct FABPlaceNoteSheet: View {
    let places: [Place]
    let onSelect: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredPlaces: [Place] {
        if searchText.isEmpty { return places.sorted { $0.name < $1.name } }
        return places
            .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List(filteredPlaces, id: \.id) { place in
                Button {
                    onSelect(place)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .foregroundStyle(.primary)
                        if !place.category.isEmpty {
                            Text(place.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search places")
            .navigationTitle("Place Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - New note name sheet

private struct NewNoteSheet: View {
    @Binding var name: String
    let isCreating: Bool
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note title", text: $name)
                        .focused($focused)
                        .onSubmit { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onCreate() } }
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Create") { onCreate() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(180)])
    }
}

// MARK: - Note editor (full-screen or inline for a single file)
//
// When `onBack` is nil  → pushed via NavigationDestination; uses .navigationTitle + .toolbar.
// When `onBack` is set  → rendered inline inside NoteFileListTab; shows its own header row so
//                          the parent tab bar (Daily/Horizons/Projects/Places) stays visible above.

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
                    searchQuery: searchQuery
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

// MARK: - E3: Horizons Note Tab

struct HorizonsNoteTab: View {

    @State private var noteStore = NoteStore.shared
    @State private var files: [String] = []
    @State private var isLoading = true
    @State private var selectedFile: String? = nil
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var isCreating = false

    private let subfolder = "Notes/Horizons"

    private var isoCal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private var currentWeekFilename: String {
        let week = isoCal.component(.weekOfYear, from: Date())
        let year = isoCal.component(.yearForWeekOfYear, from: Date())
        return String(format: "%d-W%02d.md", year, week)
    }

    private var currentMonthFilename: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return "\(f.string(from: Date())).md"
    }

    /// Files not pinned (excluding current week and month)
    private var otherFiles: [String] {
        files.filter { $0 != currentWeekFilename && $0 != currentMonthFilename }
    }

    private var futureFiles: [String] {
        otherFiles.filter { isFileFuture($0) }.sorted()
    }

    private var pastFiles: [String] {
        otherFiles.filter { !isFileFuture($0) }.sorted(by: >)
    }

    /// Returns true if the filename represents a future week or month.
    private func isFileFuture(_ filename: String) -> Bool {
        let name = filename.replacingOccurrences(of: ".md", with: "")
        // Week file: YYYY-Www
        if name.range(of: #"^\d{4}-W\d{2}$"#, options: .regularExpression) != nil {
            let parts = name.components(separatedBy: "-W")
            guard parts.count == 2,
                  let year = Int(parts[0]),
                  let week = Int(parts[1]) else { return false }
            let currentWeek = isoCal.component(.weekOfYear, from: Date())
            let currentYear = isoCal.component(.yearForWeekOfYear, from: Date())
            return (year, week) > (currentYear, currentWeek)
        }
        // Month file: YYYY-MM
        if name.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
            let parts = name.components(separatedBy: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]) else { return false }
            let currentMonth = Calendar.current.component(.month, from: Date())
            let currentYear = Calendar.current.component(.year, from: Date())
            return (year, month) > (currentYear, currentMonth)
        }
        return false
    }

    var body: some View {
        Group {
            if let filename = selectedFile {
                NoteEditorView(
                    relativePath: "\(subfolder)/\(filename)",
                    title: filename.replacingOccurrences(of: ".md", with: ""),
                    onBack: {
                        selectedFile = nil
                        loadFiles()
                    }
                )
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Pinned section — current week + month always at top
                    Section("This Period") {
                        HorizonPinnedRow(
                            filename: currentWeekFilename,
                            icon: "calendar.badge.clock",
                            label: weekLabel,
                            color: .orange,
                            exists: files.contains(currentWeekFilename)
                        ) {
                            selectedFile = currentWeekFilename
                        }
                        HorizonPinnedRow(
                            filename: currentMonthFilename,
                            icon: "calendar",
                            label: monthLabel,
                            color: .blue,
                            exists: files.contains(currentMonthFilename)
                        ) {
                            selectedFile = currentMonthFilename
                        }
                    }

                    if !futureFiles.isEmpty {
                        Section("Next") {
                            ForEach(futureFiles, id: \.self) { filename in
                                horizonRow(filename)
                            }
                        }
                    }

                    if !pastFiles.isEmpty {
                        Section("Past") {
                            ForEach(pastFiles, id: \.self) { filename in
                                horizonRow(filename)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            newNoteName = ""
                            showingNewNote = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
        }
        .task { loadFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .traceNotesRefresh)) { _ in loadFiles() }
        .sheet(isPresented: $showingNewNote) {
            NewNoteSheet(name: $newNoteName, isCreating: isCreating) {
                createNote()
            }
        }
    }

    @ViewBuilder
    private func horizonRow(_ filename: String) -> some View {
        Button {
            selectedFile = filename
        } label: {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(filename.replacingOccurrences(of: ".md", with: ""))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                try? noteStore.deleteFile("\(subfolder)/\(filename)")
                files.removeAll { $0 == filename }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var weekLabel: String {
        let week = isoCal.component(.weekOfYear, from: Date())
        let year = isoCal.component(.yearForWeekOfYear, from: Date())
        return String(format: "Week %d · %d", week, year)
    }

    private var monthLabel: String {
        Date().formatted(.dateTime.month(.wide).year())
    }

    private func loadFiles() {
        isLoading = true
        Task {
            files = (try? noteStore.listFiles(in: subfolder)) ?? []
            isLoading = false
        }
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCreating = true
        Task {
            let filename = "\(name).md"
            let path = "\(subfolder)/\(filename)"
            try? noteStore.writeFile(path, content: "# \(name)\n")
            await MainActor.run {
                showingNewNote = false
                newNoteName = ""
                isCreating = false
            }
            files = (try? noteStore.listFiles(in: subfolder)) ?? []
            await MainActor.run { selectedFile = filename }
        }
    }
}

// MARK: - Horizon Pinned Row

private struct HorizonPinnedRow: View {
    let filename: String
    let icon: String
    let label: String
    let color: Color
    let exists: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(exists ? "Has content" : "Tap to create")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - E1: Block data models

struct BlockInfo: Identifiable {
    let id = UUID()
    let text: String
    let nsRange: NSRange

    /// First non-empty, non-timestamp content line — used as default title for promote.
    var firstLineTitle: String {
        let lines = text.components(separatedBy: "\n")
        for line in lines.dropFirst() {
            var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            // Strip leading markdown list/checkbox prefixes
            t = t.replacingOccurrences(of: "^[•\\-] ", with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: "^- \\[.\\] ", with: "", options: .regularExpression)
            // Strip bold wrapper
            if t.hasPrefix("**") && t.hasSuffix("**") && t.count > 4 {
                t = String(t.dropFirst(2).dropLast(2))
            }
            return t.isEmpty ? "Note" : t
        }
        return "Note"
    }
}

enum BlockAction {
    case promote(title: String, destination: BlockDestination)
    case move(destination: BlockDestination)
    case delete
}

enum BlockDestination {
    case horizons
    case projects
    case day(Date)
}

// MARK: - E1: Block Promote Sheet

struct BlockPromoteSheet: View {
    let block: BlockInfo
    let onAction: (BlockAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .choose
    @State private var title: String = ""
    @State private var destOption: DestOption = .horizons
    @State private var targetDate: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var showingDatePicker = false

    enum Mode { case choose, promote, move }
    enum DestOption: String, CaseIterable, Identifiable {
        case horizons = "Horizons"
        case projects = "Projects"
        case day      = "Another Day"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .horizons: return "square.stack"
            case .projects: return "folder"
            case .day:      return "calendar"
            }
        }
        func toDestination(date: Date) -> BlockDestination {
            switch self {
            case .horizons: return .horizons
            case .projects: return .projects
            case .day:      return .day(date)
            }
        }
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
            Section {
                Button("Move") {
                    onAction(.move(destination: destOption.toDestination(date: targetDate)))
                    dismiss()
                }
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

