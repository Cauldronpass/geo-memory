import SwiftUI

// MARK: - NotesView
//
// Four-tab notes screen backed by NoteStore (Trace iCloud container).
//
//  Daily     — today's Calendar/YYYY-MM-DD.md, editable inline
//  Buckets   — Notes/Buckets/*.md (This Week, Next Week, etc.)
//  Projects  — Notes/Projects/*.md
//  Places    — Notes/Places/*.md (one file per place)

struct NotesView: View {

    @State private var noteStore = NoteStore.shared
    @State private var selectedTab: NoteTab = .daily
    @State private var showCalendar = false

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
                    EmptyView()
                }
            }
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
        case .buckets:
            NoteFileListTab(subfolder: "Notes/Buckets", emptyMessage: "No bucket notes yet.\nTap the pencil to create one.")
        case .projects:
            NoteFileListTab(subfolder: "Notes/Projects", emptyMessage: "No project notes yet.\nTap the pencil to create one.")
        case .places:
            NoteFileListTab(subfolder: "Notes/Places", emptyMessage: "No place notes yet.\nPlace notes are created automatically when you tap Notes on a place.")
        }
    }
}

// MARK: - NoteTab enum

enum NoteTab: String, CaseIterable, Identifiable {
    case daily, buckets, projects, places
    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily:    return "Daily"
        case .buckets:  return "Buckets"
        case .projects: return "Projects"
        case .places:   return "Places"
        }
    }

    var icon: String {
        switch self {
        case .daily:    return "calendar"
        case .buckets:  return "tray.2"
        case .projects: return "folder"
        case .places:   return "mappin"
        }
    }
}

// MARK: - Daily note tab

struct DailyNoteTab: View {

    @Binding var showCalendar: Bool

    @State private var noteStore = NoteStore.shared
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDate: Date = Date()
    @State private var displayMonth: Date = Date()
    @State private var datesWithNotes: Set<String> = []
    @State private var showingMoveDaily: Bool = false
    @State private var moveTargetDate: Date = Date()
    @State private var timestampTrigger: Date? = nil
    @State private var showingClearConfirm: Bool = false
    @State private var isEditorFocused: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if showCalendar {
                calendarHeader
                Divider()
                MonthCalendarView(
                    displayMonth: $displayMonth,
                    selectedDate: selectedDate,
                    datesWithNotes: datesWithNotes
                ) { date in
                    selectedDate = date
                    displayMonth = date
                    showCalendar = false
                    load()
                }
                Spacer()
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
                        onFocusChange: { isEditorFocused = $0 }
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
            if isOn { displayMonth = selectedDate }
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
        .sheet(isPresented: $showingMoveDaily) {
            MoveDailyNoteSheet(targetDate: $moveTargetDate) {
                Task {
                    try? noteStore.moveDailyNote(from: selectedDate, to: moveTargetDate)
                    content = (try? noteStore.readDailyNote(date: selectedDate)) ?? ""
                    showingMoveDaily = false
                    // Remove dot if note is now empty
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        datesWithNotes.remove(formatter.string(from: selectedDate))
                    }
                    datesWithNotes.insert(formatter.string(from: moveTargetDate))
                }
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
                moveTargetDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                showingMoveDaily = true
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

    // MARK: Calendar header (month nav only — Daily tab button toggles back)

    private var calendarHeader: some View {
        HStack(spacing: 0) {
            Button {
                displayMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }

            Spacer()

            Text(displayMonth.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline.weight(.semibold))

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
            datesWithNotes.insert(dateStr)
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
    let onDateSelected: (Date) -> Void

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible()), count: 7)

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

    var body: some View {
        VStack(spacing: 6) {
            // Weekday headers
            HStack(spacing: 0) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)

            // Day grid
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, date in
                    if let date = date {
                        DayCell(
                            date: date,
                            isSelected: cal.isDate(date, inSameDayAs: selectedDate),
                            isToday: cal.isDateInToday(date),
                            hasNote: datesWithNotes.contains(isoString(date))
                        ) {
                            onDateSelected(date)
                        }
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 8)
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
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let hasNote: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
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
        }
        .buttonStyle(.plain)
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

// MARK: - Note file list tab (Buckets / Projects / Places)

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

    var body: some View {
        Group {
            if let filename = selectedFile {
                // Inline editor — keeps the parent Daily/Buckets/Projects/Places tab bar visible.
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
                List(files, id: \.self) { filename in
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
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { newNoteButton }
                }
            }
        }
        .task { loadFiles() }
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
        }
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
//                          the parent tab bar (Daily/Buckets/Projects/Places) stays visible above.

struct NoteEditorView: View {

    let relativePath: String
    let title: String
    /// Provide this when showing inline (not pushed). Called instead of dismiss() on back/delete/rename/move.
    var onBack: (() -> Void)? = nil

    @State private var noteStore = NoteStore.shared
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var savedIndicator = false
    @State private var showingMoveSheet = false
    @State private var showingDeleteConfirm = false
    @State private var showingRename = false
    @State private var renameText = ""
    @Environment(\.dismiss) private var dismiss

    private var subfolder: String {
        relativePath.components(separatedBy: "/").dropLast().joined(separator: "/")
    }
    private var filename: String {
        relativePath.components(separatedBy: "/").last ?? ""
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
                    onSave: { newText in save(newText) }
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

    // Shared action buttons (saved indicator + inbox + ellipsis menu)
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if savedIndicator {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.opacity)
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
            withAnimation { savedIndicator = true }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { savedIndicator = false }
        }
    }
}

// MARK: - Quick Append Sheet (long-press from Home to add a line to today's note)

struct QuickAppendSheet: View {
    let onAppend: (String) -> Void
    @State private var text: String = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Add to today's note…", text: $text, axis: .vertical)
                        .lineLimit(4, reservesSpace: false)
                        .focused($focused)
                        .onSubmit {
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                onAppend(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                        }
                }
            }
            .navigationTitle("Today's Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onAppend(trimmed)
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Move Daily Note Sheet (move a date's note content to another date)

struct MoveDailyNoteSheet: View {
    @Binding var targetDate: Date
    let onMove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Move to",
                        selection: $targetDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                }
                Section {
                    Text("The note's content will be appended to the selected day and cleared from the current day.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Move Note to Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        onMove()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Move Note Sheet

struct MoveNoteSheet: View {
    let filename: String
    let currentSubfolder: String
    let onMove: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let destinations: [(label: String, icon: String, path: String)] = [
        ("Buckets",  "tray.2",  "Notes/Buckets"),
        ("Projects", "folder",  "Notes/Projects"),
        ("Places",   "mappin",  "Notes/Places"),
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

