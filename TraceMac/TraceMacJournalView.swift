// TraceMacJournalView.swift
// Journal section for Trace Mac — Daily, Projects, Places.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

// MARK: - Notification for Horizons deep-link from calendar panel

extension Notification.Name {
    static let openHorizonsFile = Notification.Name("trace.openHorizonsFile")
}

// MARK: - Journal root (dispatches to the right tab)

struct TraceMacJournalView: View {
    let section: MacSection  // .daily, .projects, or .places
    var deepLinkFile: Binding<String?>? = nil   // set by TraceMacContentView for .horizons deep links

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    var body: some View {
        switch section {
        case .daily:
            TraceMacDailyView()
                .environment(noteStore)
        case .projects:
            TraceMacNoteListView(
                subfolder: "Notes/Projects",
                sectionTitle: "Projects",
                newNotePrompt: "Project name",
                emptyMessage: "No project notes yet."
            )
            .environment(noteStore)
        case .horizons:
            TraceMacNoteListView(
                subfolder: "Notes/Horizons",
                sectionTitle: "Horizons",
                newNotePrompt: "e.g. Week of July 7",
                emptyMessage: "No horizon notes yet.",
                deepLinkFile: deepLinkFile
            )
            .environment(noteStore)
        case .places:
            TraceMacPlaceNoteView()
                .environment(noteStore)
                .environment(notionService)
        default:
            EmptyView()
        }
    }
}

// MARK: - Daily notes (3-column: file list | editor | calendar panel)

struct TraceMacDailyView: View {
    @Environment(NoteStore.self) private var noteStore

    @State private var files: [String] = []     // filenames in Calendar/
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var fileListCollapsed = false
    @State private var calendarCollapsed = false

    /// Set of date strings ("2026-07-03") that have existing notes — fed to calendar panel.
    private var datesWithEntries: Set<String> {
        Set(files.map { $0.replacingOccurrences(of: ".md", with: "") })
    }

    private var filtered: [String] {
        if searchText.isEmpty { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var todayFilename: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "\(fmt.string(from: Date())).md"
    }

    private let calendarGray = Color(nsColor: .controlBackgroundColor)

    var body: some View {
        HStack(spacing: 0) {

            // Column 1: file list — white background so it's visually distinct from the
            // gray nav sidebar to its left. The 1px line in the handle separates it from
            // the white editor to its right.
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    List(filtered, id: \.self, selection: $selectedFile) { filename in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(for: filename))
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                            Text(relativeLabel(for: filename))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                        .tag(filename)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteCandidate = filename
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .frame(width: 200)
            }

            // Handle: white | 1px line | white — one separator between same-color panels
            CollapseHandle(
                isCollapsed: $fileListCollapsed,
                collapsesRight: false,
                showLine: true,
                panelColor: .clear
            )

            // Column 2: editor
            Group {
                if let file = selectedFile {
                    TraceMacNoteEditor(relativePath: "Calendar/\(file)")
                        .environment(noteStore)
                } else {
                    placeholderEditor
                }
            }
            .frame(maxWidth: .infinity)

            // Calendar collapse handle.
            // panelColor: calendarGray merges the 12px zone into the calendar panel visually.
            // The separator is pinned to the LEADING edge (white/gray boundary) — one line only.
            CollapseHandle(
                isCollapsed: $calendarCollapsed,
                collapsesRight: true,
                showLine: true,
                lineWidth: 3,
                panelColor: calendarGray
            )

            // Column 3: calendar — same gray as the handle so they merge visually
            if !calendarCollapsed {
                TraceMacCalendarPanel(
                    selectedDateFile: Binding(
                        get: { selectedFile },
                        set: { newFile in
                            guard let filename = newFile else { return }
                            openOrCreateDate(filename: filename)
                        }
                    ),
                    datesWithEntries: datesWithEntries,
                    onOpenHorizonsNote: { relativePath in
                        openHorizonsNote(at: relativePath)
                    }
                )
                .frame(width: 240)
            }
        }
        // Toolbar lives here so it persists even when file list is collapsed
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Today") { openToday() }
            }
            ToolbarItem {
                Button { openToday() } label: {
                    Label("New", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate.map { displayName(for: $0) } ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deleteNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .task { await loadFiles() }
        .onAppear { openToday() }
    }

    // MARK: - Sub-views

    private var placeholderEditor: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Select a day or tap Today")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: "Calendar")) ?? []
        files = loaded.sorted(by: >)
        if selectedFile == nil, files.contains(todayFilename) {
            selectedFile = todayFilename
        }
    }

    private func openToday() {
        openOrCreateDate(filename: todayFilename)
    }

    private func openOrCreateDate(filename: String) {
        let path = "Calendar/\(filename)"
        // Create the file if it doesn't exist
        if (try? noteStore.readFile(path)) == nil ||
            ((try? noteStore.readFile(path)) ?? "").isEmpty {
            let dateStr = filename.replacingOccurrences(of: ".md", with: "")
            let header  = "# \(dateStr)\n\n"
            try? noteStore.writeFile(path, content: header)
        }
        if !files.contains(filename) {
            files.insert(filename, at: 0)
            files.sort(by: >)
        }
        selectedFile = filename
    }

    private func openHorizonsNote(at relativePath: String) {
        // Create stub if the file doesn't exist yet
        let content = (try? noteStore.readFile(relativePath)) ?? ""
        if content.isEmpty {
            let title = (relativePath as NSString).lastPathComponent
                .replacingOccurrences(of: ".md", with: "")
            try? noteStore.writeFile(relativePath, content: "# \(title)\n\n")
        }
        // Post notification — TraceMacContentView switches to .horizons
        // and passes the filename down to TraceMacNoteListView for selection.
        let filename = (relativePath as NSString).lastPathComponent
        NotificationCenter.default.post(
            name: .openHorizonsFile,
            object: nil,
            userInfo: ["filename": filename]
        )
    }

    private func deleteNote(_ filename: String) {
        try? noteStore.deleteFile("Calendar/\(filename)")
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }

    // MARK: - Display helpers

    private func displayName(for filename: String) -> String {
        let dateStr = filename.replacingOccurrences(of: ".md", with: "")
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: dateStr) else { return dateStr }
        let display = DateFormatter(); display.dateFormat = "EEEE, MMM d"
        return display.string(from: date)
    }

    private func relativeLabel(for filename: String) -> String {
        let dateStr = filename.replacingOccurrences(of: ".md", with: "")
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: dateStr) else { return "" }
        if Calendar.current.isDateInToday(date)     { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        return "\(days) days ago"
    }
}

// MARK: - Hover-reveal collapse handle

/// A 12-wide hit zone containing a 1px separator and a hover-reveal circle button.
/// collapsesRight = true  → manages the panel to the RIGHT (e.g. calendar)
/// collapsesRight = false → manages the panel to the LEFT  (e.g. file list)
/// 12px HStack element with a hover-reveal circle collapse button.
///
/// showLine:    draw a separator at the LEADING edge of the zone (the panel boundary)
/// lineWidth:   separator width in points (default 1)
/// panelColor:  fill the zone with this color — use calendarGray on the calendar side
///              so the 12px zone merges into the 240px calendar panel visually
struct CollapseHandle: View {
    @Binding var isCollapsed: Bool
    let collapsesRight: Bool
    var showLine: Bool = true
    var lineWidth: CGFloat = 1
    var panelColor: Color = .clear

    @State private var isHovering = false

    private var icon: String {
        collapsesRight
            ? (isCollapsed ? "chevron.left"  : "chevron.right")
            : (isCollapsed ? "chevron.right" : "chevron.left")
    }

    var body: some View {
        ZStack {
            panelColor  // fills the zone — blends handle into the adjacent shaded panel

            if showLine {
                // Separator pinned to the LEADING edge of the zone so it sits exactly
                // at the panel boundary (white editor → separator → gray calendar).
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: lineWidth)
                    Spacer(minLength: 0)
                }
            }

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    isCollapsed.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.14), radius: 2, x: 0, y: 1)
                        .frame(width: 18, height: 18)
                    Image(systemName: icon)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Generic note list (Projects, custom subfolders)

struct TraceMacNoteListView: View {
    let subfolder: String
    let sectionTitle: String
    let newNotePrompt: String
    let emptyMessage: String
    var deepLinkFile: Binding<String?>? = nil   // non-nil triggers selection + clears itself

    @Environment(NoteStore.self) private var noteStore

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var fileListCollapsed = false

    private var filtered: [String] {
        if searchText.isEmpty { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: file list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)

                    if files.isEmpty {
                        Spacer()
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                        Spacer()
                    } else {
                        List(filtered, id: \.self, selection: $selectedFile) { filename in
                            Text(filename.replacingOccurrences(of: ".md", with: ""))
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                                .padding(.vertical, 4)
                                .tag(filename)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteCandidate = filename
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: 200)
            }

            CollapseHandle(
                isCollapsed: $fileListCollapsed,
                collapsesRight: false,
                showLine: true,
                panelColor: .clear
            )

            // Right: editor
            Group {
                if let file = selectedFile {
                    TraceMacNoteEditor(relativePath: "\(subfolder)/\(file)")
                        .environment(noteStore)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("Select a note or create one")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewNote = true } label: {
                    Label("New Note", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.replacingOccurrences(of: ".md", with: "") ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deleteNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingNewNote) {
            newNoteSheet
        }
        .task { await loadFiles() }
        .task(id: deepLinkFile?.wrappedValue) {
            guard let filename = deepLinkFile?.wrappedValue else { return }
            if files.isEmpty {
                let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
                files = loaded.sorted()
            }
            if !files.contains(filename) {
                files.append(filename)
                files.sort()
            }
            selectedFile = filename
            deepLinkFile?.wrappedValue = nil
        }
    }

    private var newNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New \(sectionTitle) Note")
                .font(.headline)
            TextField(newNotePrompt, text: $newNoteName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { createNote() }
            HStack {
                Button("Cancel") {
                    newNoteName = ""
                    showingNewNote = false
                }
                Button("Create") { createNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newNoteName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
        files = loaded.sorted()
    }

    private func deleteNote(_ filename: String) {
        try? noteStore.deleteFile("\(subfolder)/\(filename)")
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let filename = "\(name).md"
        let path = "\(subfolder)/\(filename)"
        try? noteStore.writeFile(path, content: "# \(name)\n\n")
        if !files.contains(filename) {
            files.append(filename)
            files.sort()
        }
        selectedFile = filename
        newNoteName = ""
        showingNewNote = false
    }
}

// MARK: - Place notes

struct TraceMacPlaceNoteView: View {
    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingPlacePicker = false
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var fileListCollapsed = false

    private var filtered: [String] {
        if searchText.isEmpty { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: file list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)

                    if files.isEmpty {
                        Spacer()
                        Text("No place notes yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        List(filtered, id: \.self, selection: $selectedFile) { filename in
                            Text(filename.replacingOccurrences(of: ".md", with: ""))
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                                .padding(.vertical, 4)
                                .tag(filename)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteCandidate = filename
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: 200)
            }

            CollapseHandle(
                isCollapsed: $fileListCollapsed,
                collapsesRight: false,
                showLine: true,
                panelColor: .clear
            )

            // Right: editor
            Group {
                if let file = selectedFile {
                    TraceMacNoteEditor(relativePath: "Notes/Places/\(file)")
                        .environment(noteStore)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("Select a place note or create one")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingPlacePicker = true } label: {
                    Label("New Place Note", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.replacingOccurrences(of: ".md", with: "") ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deletePlaceNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingPlacePicker) {
            placePickerSheet
        }
        .task { await loadFiles() }
    }

    private var placePickerSheet: some View {
        VStack(spacing: 0) {
            Text("Choose a Place")
                .font(.headline)
                .padding()

            Divider()

            if notionService.places.isEmpty {
                ProgressView("Loading places…")
                    .padding()
            } else {
                List(notionService.places.sorted { $0.name < $1.name }) { place in
                    Button(action: { createPlaceNote(for: place.name) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).foregroundStyle(.primary)
                            if !place.city.isEmpty {
                                Text(place.city).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button("Cancel") { showingPlacePicker = false }
                .padding()
        }
        .frame(width: 320, height: 420)
    }

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: "Notes/Places")) ?? []
        files = loaded.sorted()
    }

    private func deletePlaceNote(_ filename: String) {
        try? noteStore.deleteFile("Notes/Places/\(filename)")
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }

    private func createPlaceNote(for placeName: String) {
        let filename = "\(placeName).md"
        let path = "Notes/Places/\(filename)"
        if (try? noteStore.readFile(path))?.isEmpty ?? true {
            try? noteStore.writeFile(path, content: "# \(placeName)\n\n")
        }
        if !files.contains(filename) {
            files.append(filename)
            files.sort()
        }
        selectedFile = filename
        showingPlacePicker = false
    }
}

// MARK: - AppKit text editor (no scrollbar)

/// NSViewRepresentable wrapper around NSTextView that explicitly disables the vertical
/// scroller. SwiftUI's TextEditor ignores .scrollIndicators(.hidden) on macOS when the
/// system is configured to "Always show scroll bars."
private struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let tv = scrollView.documentView as! NSTextView

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = 5

        tv.isEditable        = true
        tv.isRichText        = false
        tv.allowsUndo        = true
        tv.font              = .systemFont(ofSize: 15)
        tv.textColor         = .labelColor
        tv.backgroundColor   = .clear
        tv.textContainerInset = NSSize(width: 40, height: 24)
        tv.defaultParagraphStyle = paraStyle
        tv.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 15),
            .paragraphStyle: paraStyle,
            .foregroundColor: NSColor.labelColor
        ]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.delegate = context.coordinator

        scrollView.hasVerticalScroller   = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = false
        scrollView.backgroundColor       = .clear
        scrollView.drawsBackground       = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let tv = scrollView.documentView as! NSTextView
        guard tv.string != text else { return }
        let ranges = tv.selectedRanges
        tv.string = text
        tv.selectedRanges = ranges
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if self.text.wrappedValue != tv.string { self.text.wrappedValue = tv.string }
        }
    }
}

// MARK: - Shared markdown editor

struct TraceMacNoteEditor: View {
    let relativePath: String

    @Environment(NoteStore.self) private var noteStore

    @State private var content = ""
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var lastSaved: Date? = nil

    var body: some View {
        VStack(spacing: 0) {
            MacTextEditor(text: $content)
                .onChange(of: content) { _, newValue in
                    scheduleSave(content: newValue)
                }

            // Footer
            Divider()
            HStack {
                let wordCount = content.split(separator: " ").count
                Text("\(wordCount) words")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let saved = lastSaved {
                    Text("Saved \(saved.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .task(id: relativePath) { await loadContent() }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { note in
            // Reload when iCloud delivers an external change to this file.
            // Skip if the user is actively editing (saveTask pending = local change in flight).
            guard saveTask == nil else { return }
            guard let changedPath = note.object as? String,
                  changedPath == relativePath else { return }
            Task { await loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStorePlaceNoteDidChange)) { note in
            guard saveTask == nil else { return }
            // Place notes: object is place name; relativePath is Notes/Places/<name>.md
            if let placeName = note.object as? String,
               relativePath == "Notes/Places/\(placeName).md" {
                Task { await loadContent() }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Save") { saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private func loadContent() async {
        content = (try? noteStore.readFile(relativePath)) ?? ""
    }

    private func scheduleSave(content: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
            saveTask = nil
        }
    }

    private func saveNow() {
        try? noteStore.writeFile(relativePath, content: content)
        lastSaved = Date()
    }
}
