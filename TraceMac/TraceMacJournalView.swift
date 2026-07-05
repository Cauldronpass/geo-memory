// TraceMacJournalView.swift
// Journal section for Trace Mac — Daily, Projects, Places.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import AppKit

// MARK: - Notification for Horizons deep-link from calendar panel

extension Notification.Name {
    static let openHorizonsFile = Notification.Name("trace.openHorizonsFile")
    static let openWikilink     = Notification.Name("trace.openWikilink")
    static let selectPerson     = Notification.Name("trace.selectPerson")
    static let selectPlace      = Notification.Name("trace.selectPlace")
    static let selectDocument   = Notification.Name("trace.selectDocument")
    static let reloadDocuments  = Notification.Name("trace.reloadDocuments")
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
            TraceMacProjectsView()
                .environment(noteStore)
                .environment(notionService)
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
    @State private var fileListCollapsed  = true
    @State private var calendarCollapsed  = false
    @State private var selectedTags: Set<String> = []
    @State private var allTags: [String] = []
    @State private var fileContents: [String: String] = [:]

    /// Set of date strings ("2026-07-03") that have existing notes — fed to calendar panel.
    private var datesWithEntries: Set<String> {
        Set(files.map { $0.replacingOccurrences(of: ".md", with: "") })
    }

    private var filtered: [String] {
        let base = searchText.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(searchText) }
        guard !selectedTags.isEmpty else { return base }
        return base.filter { filename in
            let content = fileContents[filename] ?? ""
            return selectedTags.allSatisfy { content.range(of: "#\($0)", options: .caseInsensitive) != nil }
        }
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
                    MacTagChipRow(tags: allTags, selected: $selectedTags)
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
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        fileListCollapsed.toggle()
                    }
                } label: {
                    Label("Toggle List", systemImage: "sidebar.leading")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Toggle note list (⌘⇧L)")
            }
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
        await loadTagIndex(subfolder: "Calendar")
    }

    private func loadTagIndex(subfolder: String) async {
        let filesToScan = files
        var contents: [String: String] = [:]
        var tagSet = Set<String>()
        let regex = try? NSRegularExpression(pattern: #"(?<![&\w])#([a-zA-Z][a-zA-Z0-9_]*)"#)
        for filename in filesToScan {
            let content = (try? noteStore.readFile("\(subfolder)/\(filename)")) ?? ""
            contents[filename] = content
            guard let regex else { continue }
            let ns = content as NSString
            regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: content) {
                    tagSet.insert(String(content[r]).lowercased())
                }
            }
        }
        fileContents = contents
        allTags = tagSet.sorted()
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
    @State private var renameCandidate: String? = nil
    @State private var showRenameSheet = false
    @State private var renameDraft = ""
    @State private var fileListCollapsed = false
    @State private var selectedTags: Set<String> = []
    @State private var allTags: [String] = []
    @State private var fileContents: [String: String] = [:]

    private var filtered: [String] {
        let base = searchText.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(searchText) }
        guard !selectedTags.isEmpty else { return base }
        return base.filter { filename in
            let content = fileContents[filename] ?? ""
            return selectedTags.allSatisfy { content.range(of: "#\($0)", options: .caseInsensitive) != nil }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: file list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    MacTagChipRow(tags: allTags, selected: $selectedTags)

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
                                    Button {
                                        renameCandidate = filename
                                        renameDraft = filename.replacingOccurrences(of: ".md", with: "")
                                        showRenameSheet = true
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Divider()
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

            // Right: editor (with optional horizon calendar header)
            Group {
                if let file = selectedFile {
                    VStack(spacing: 0) {
                        if let kind = HorizonKind(filename: file) {
                            HorizonCalendarHeader(kind: kind)
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                                .padding(.bottom, 12)
                            Divider()
                        }
                        TraceMacNoteEditor(relativePath: "\(subfolder)/\(file)")
                            .environment(noteStore)
                    }
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
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
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

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Note")
                .font(.headline)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { renameNote() }
            HStack {
                Button("Cancel") {
                    showRenameSheet = false
                    renameCandidate = nil
                }
                Button("Rename") { renameNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
        files = loaded.sorted()
        let sf = subfolder
        var contents: [String: String] = [:]
        var tagSet = Set<String>()
        let regex = try? NSRegularExpression(pattern: #"(?<![&\w])#([a-zA-Z][a-zA-Z0-9_]*)"#)
        for filename in files {
            let content = (try? noteStore.readFile("\(sf)/\(filename)")) ?? ""
            contents[filename] = content
            guard let regex else { continue }
            let ns = content as NSString
            regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: content) {
                    tagSet.insert(String(content[r]).lowercased())
                }
            }
        }
        fileContents = contents
        allTags = tagSet.sorted()
    }

    private func renameNote() {
        guard let old = renameCandidate else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let newFilename = newName + ".md"
        guard newFilename != old else {
            showRenameSheet = false; renameCandidate = nil; return
        }
        try? noteStore.moveFile(from: "\(subfolder)/\(old)", to: "\(subfolder)/\(newFilename)")
        if let idx = files.firstIndex(of: old) {
            files[idx] = newFilename
            files.sort()
        }
        if selectedFile == old { selectedFile = newFilename }
        showRenameSheet = false
        renameCandidate = nil
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

// MARK: - Projects view (hub layout: editor + Documents/People/Places tabs)

struct TraceMacProjectsView: View {
    private let subfolder = "Notes/Projects"

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var renameCandidate: String? = nil
    @State private var showRenameSheet = false
    @State private var renameDraft = ""
    @State private var fileListCollapsed = false
    @State private var docStore: TraceMacDocumentStore? = nil
    @State private var selectedTags: Set<String> = []
    @State private var allTags: [String] = []
    @State private var fileContents: [String: String] = [:]

    private var filtered: [String] {
        let base = searchText.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(searchText) }
        guard !selectedTags.isEmpty else { return base }
        return base.filter { filename in
            let content = fileContents[filename] ?? ""
            return selectedTags.allSatisfy { content.range(of: "#\($0)", options: .caseInsensitive) != nil }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: project list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    MacTagChipRow(tags: allTags, selected: $selectedTags)

                    if files.isEmpty {
                        Spacer()
                        Text("No projects yet.")
                            .font(.caption).foregroundStyle(.secondary).padding()
                        Spacer()
                    } else {
                        List(filtered, id: \.self, selection: $selectedFile) { filename in
                            Label(
                                filename.replacingOccurrences(of: ".md", with: ""),
                                systemImage: "folder.fill"
                            )
                            .font(.system(.callout, weight: .medium))
                            .lineLimit(1)
                            .padding(.vertical, 4)
                            .tag(filename)
                            .contextMenu {
                                Button {
                                    renameCandidate = filename
                                    renameDraft = filename.replacingOccurrences(of: ".md", with: "")
                                    showRenameSheet = true
                                } label: { Label("Rename", systemImage: "pencil") }
                                Divider()
                                Button(role: .destructive) {
                                    deleteCandidate = filename
                                    showDeleteConfirm = true
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: 200)
            }

            CollapseHandle(isCollapsed: $fileListCollapsed, collapsesRight: false,
                           showLine: true, panelColor: .clear)

            // Right: hub (editor + entity sidebar)
            Group {
                if let file = selectedFile, let store = docStore {
                    let notePath = "\(subfolder)/\(file)"
                    HStack(spacing: 0) {
                        TraceMacNoteEditor(relativePath: notePath)
                            .frame(maxWidth: .infinity)
                        Divider()
                        MacProjectHubSidebar(notePath: notePath, store: store)
                            .frame(width: 260)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 40, weight: .thin)).foregroundStyle(.tertiary)
                        Text("Select a project or create one")
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
                    Label("New Project", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.replacingOccurrences(of: ".md", with: "") ?? "")\"?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deleteNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingNewNote) { newNoteSheet }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .task {
            await loadFiles()
            if docStore == nil {
                docStore = TraceMacDocumentStore(noteStore: noteStore)
            }
            await docStore?.reload()
        }
    }

    // MARK: - Sheets

    private var newNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New Project").font(.headline)
            TextField("Project name", text: $newNoteName)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { createNote() }
            HStack {
                Button("Cancel") { newNoteName = ""; showingNewNote = false }
                Button("Create") { createNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newNoteName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Project").font(.headline)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { renameNote() }
            HStack {
                Button("Cancel") { showRenameSheet = false; renameCandidate = nil }
                Button("Rename") { renameNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Actions

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
        files = loaded.sorted()
        var contents: [String: String] = [:]
        var tagSet = Set<String>()
        let regex = try? NSRegularExpression(pattern: #"(?<![&\w])#([a-zA-Z][a-zA-Z0-9_]*)"#)
        for filename in files {
            let content = (try? noteStore.readFile("\(subfolder)/\(filename)")) ?? ""
            contents[filename] = content
            guard let regex else { continue }
            let ns = content as NSString
            regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: content) {
                    tagSet.insert(String(content[r]).lowercased())
                }
            }
        }
        fileContents = contents
        allTags = tagSet.sorted()
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let filename = "\(name).md"
        let path = "\(subfolder)/\(filename)"
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let content = """
        ---
        title: \(name)
        type: project
        created: \(today)
        people: []
        places: []
        tags: []
        linked_notes: []
        ---

        """
        try? noteStore.writeFile(path, content: content)
        if !files.contains(filename) { files.append(filename); files.sort() }
        selectedFile = filename
        newNoteName = ""
        showingNewNote = false
        Task { await docStore?.reload() }
    }

    private func renameNote() {
        guard let old = renameCandidate else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let newFilename = newName + ".md"
        guard newFilename != old else { showRenameSheet = false; renameCandidate = nil; return }
        try? noteStore.moveFile(from: "\(subfolder)/\(old)", to: "\(subfolder)/\(newFilename)")
        if let idx = files.firstIndex(of: old) { files[idx] = newFilename; files.sort() }
        if selectedFile == old { selectedFile = newFilename }
        showRenameSheet = false; renameCandidate = nil
    }

    private func deleteNote(_ filename: String) {
        try? noteStore.deleteFile("\(subfolder)/\(filename)")
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
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

// MARK: - Horizon file classification

/// Parses a Horizons filename into a week or month kind.
/// "2026-W27.md" → .week(2026, 27)
/// "2026-07.md"  → .month(2026, 7)
/// Anything else → nil (no header shown)
private enum HorizonKind {
    case week(year: Int, week: Int)
    case month(year: Int, month: Int)

    init?(filename: String) {
        let name = filename.replacingOccurrences(of: ".md", with: "")
        // Weekly: "YYYY-Www"
        if let wRange = name.range(of: "-W") {
            let yearStr = String(name[name.startIndex ..< wRange.lowerBound])
            let weekStr = String(name[wRange.upperBound...])
            if let y = Int(yearStr), let w = Int(weekStr), w >= 1, w <= 53 {
                self = .week(year: y, week: w)
                return
            }
        }
        // Monthly: exactly "YYYY-MM"
        let parts = name.split(separator: "-").map(String.init)
        if parts.count == 2, parts[0].count == 4, parts[1].count == 2,
           let y = Int(parts[0]), let m = Int(parts[1]), m >= 1, m <= 12 {
            self = .month(year: y, month: m)
            return
        }
        return nil
    }
}

// MARK: - Horizon calendar header

private struct HorizonCalendarHeader: View {

    let kind: HorizonKind

    private var isoCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale.current
        return cal
    }

    var body: some View {
        switch kind {
        case .week(let year, let week):   weekView(year: year, week: week)
        case .month(let year, let month): monthView(year: year, month: month)
        }
    }

    // MARK: Weekly header

    private func weekDates(year: Int, week: Int) -> [Date] {
        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = week
        comps.weekday = 2   // Monday = first day in ISO week
        guard let monday = isoCalendar.date(from: comps) else { return [] }
        return (0..<7).compactMap { isoCalendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private func weekRangeLabel(_ dates: [Date]) -> String {
        guard let first = dates.first, let last = dates.last else { return "" }
        let mFmt = DateFormatter(); mFmt.dateFormat = "MMMM"
        let dFmt = DateFormatter(); dFmt.dateFormat = "d"
        let yFmt = DateFormatter(); yFmt.dateFormat = "yyyy"
        let firstMonth = isoCalendar.component(.month, from: first)
        let lastMonth  = isoCalendar.component(.month, from: last)
        let year = yFmt.string(from: last)
        if firstMonth == lastMonth {
            return "\(mFmt.string(from: first)) \(dFmt.string(from: first))–\(dFmt.string(from: last)), \(year)"
        } else {
            return "\(mFmt.string(from: first)) \(dFmt.string(from: first)) – \(mFmt.string(from: last)) \(dFmt.string(from: last)), \(year)"
        }
    }

    @ViewBuilder
    private func weekView(year: Int, week: Int) -> some View {
        let dates    = weekDates(year: year, week: week)
        let abbrevs  = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        VStack(alignment: .leading, spacing: 8) {
            Text(weekRangeLabel(dates))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(Array(zip(abbrevs, dates)), id: \.0) { abbrev, date in
                    let dayNum    = isoCalendar.component(.day, from: date)
                    let isWeekend = abbrev == "Sat" || abbrev == "Sun"

                    VStack(spacing: 5) {
                        Text(abbrev)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isWeekend ? .secondary : .primary)

                        Text("\(dayNum)")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(isWeekend ? .secondary : .primary)
                            .frame(width: 28, height: 28)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Monthly header

    private func monthDates(year: Int, month: Int) -> [Date?] {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = 1
        guard let firstDay = isoCalendar.date(from: comps) else { return [] }
        guard let range = isoCalendar.range(of: .day, in: .month, for: firstDay) else { return [] }
        let weekday = isoCalendar.component(.weekday, from: firstDay)
        let offset  = (weekday + 5) % 7   // Mon=0 … Sun=6
        var result: [Date?] = Array(repeating: nil, count: offset)
        for d in range {
            var dc = comps; dc.day = d
            result.append(isoCalendar.date(from: dc))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private func monthHeaderLabel(year: Int, month: Int) -> String {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = 1
        guard let date = isoCalendar.date(from: comps) else { return "" }
        let fmt = DateFormatter(); fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: date)
    }

    @ViewBuilder
    private func monthView(year: Int, month: Int) -> some View {
        let dates   = monthDates(year: year, month: month)
        let rows    = stride(from: 0, to: dates.count, by: 7).map {
            Array(dates[$0 ..< min($0 + 7, dates.count)])
        }
        let headers = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let label   = monthHeaderLabel(year: year, month: month)

        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            // Column headers
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                    Text(h)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(idx >= 5 ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Date rows
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, date in
                        if let date = date {
                            let dayNum    = isoCalendar.component(.day, from: date)
                            let isWeekend = colIdx >= 5
                            Text("\(dayNum)")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(isWeekend ? .secondary : .primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 26)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - AppKit text editor (no scrollbar)

// MARK: - Editor command enum

enum MacEditorCommand: Equatable {
    case bold, italic, strike, highlight
    case heading, bullet, checkbox
    case indent, outdent
    case link, date
    case undo, redo
    case applyWikiSuggestion(String)
}

// MARK: - NSTextView subclass: checkbox click detection

/// Intercepts mouseDown to toggle ☐/☑ when the user clicks the checkbox glyph.
/// Also rejects file-URL drags so they propagate up to the Documents drop zone
/// instead of being pasted as text paths.
private final class MarkdownNSTextView: NSTextView {

    // Refuse file-URL drags — let the Documents left-column .onDrop handle them.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let fileTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        ]
        if fileTypes.contains(where: { sender.draggingPasteboard.types?.contains($0) == true }) {
            return []
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let fileTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        ]
        if fileTypes.contains(where: { sender.draggingPasteboard.types?.contains($0) == true }) {
            return false
        }
        return super.prepareForDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let adj = NSPoint(x: point.x - textContainerInset.width,
                          y: point.y - textContainerInset.height)
        if let lm = layoutManager, let tc = textContainer {
            let glyphIdx = lm.glyphIndex(for: adj, in: tc,
                                          fractionOfDistanceThroughGlyph: nil)
            let charIdx  = lm.characterIndexForGlyph(at: glyphIdx)
            if charIdx < (textStorage?.length ?? 0) {
                // Click on [[wikilink]] → navigate to record.
                // Single-click navigates and places cursor; Cmd+click navigates without moving cursor.
                if let target = textStorage?.attribute(.macWikiTarget, at: charIdx,
                                                       effectiveRange: nil) as? String {
                    NotificationCenter.default.post(name: .openWikilink, object: nil,
                                                    userInfo: ["name": target])
                    if event.modifierFlags.contains(.command) { return }
                    // Fall through to super so cursor is placed at the click position
                }
                // Click on checkbox → toggle
                if textStorage?.attribute(.macCheckboxState, at: charIdx,
                                          effectiveRange: nil) != nil {
                    let ns = (textStorage?.string ?? "") as NSString
                    let lineRange = ns.lineRange(for: NSRange(location: charIdx, length: 0))
                    let line = ns.substring(with: lineRange)
                    if line.hasPrefix("☐ ") {
                        textStorage?.replaceCharacters(in: lineRange,
                                                       with: "☑ " + String(line.dropFirst(2)))
                    } else if line.hasPrefix("☑ ") {
                        textStorage?.replaceCharacters(in: lineRange,
                                                       with: "☐ " + String(line.dropFirst(2)))
                    }
                    didChangeText()
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

// MARK: - MacEditorActions (direct command channel — bypasses SwiftUI binding timing)

/// Shared by TraceMacNoteEditor and MacTextEditor. Toolbar buttons call execute(_:) directly;
/// MacTextEditor wires it to the coordinator in makeNSView. No binding timing issues.
final class MacEditorActions {
    var execute: (MacEditorCommand) -> Void = { _ in }
}

// MARK: - MacTextEditor (NSViewRepresentable)

/// NSTextView backed by MacMarkdownTextStorage with live markdown rendering.
private struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    let actions: MacEditorActions
    /// Called when the cursor enters/exits a [[...]] span. Receives the partial name or nil.
    var onWikilinkQuery: ((String?) -> Void)? = nil
    /// Called when the user presses Return while a wikilink suggestion is active.
    var onWikilinkAccept: (() -> Void)? = nil

    // MARK: makeNSView

    func makeNSView(context: Context) -> NSScrollView {
        let storage   = MacMarkdownTextStorage()
        let manager   = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let tv = MarkdownNSTextView(frame: .zero, textContainer: container)
        let paraStyle = MacMarkdownTextStorage.baseParagraphStyle

        tv.isEditable              = true
        tv.isRichText              = false
        tv.allowsUndo              = true
        tv.backgroundColor         = NSColor.clear
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask        = [.width]
        tv.minSize                 = NSSize(width: 0, height: 0)
        tv.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset      = NSSize(width: 40, height: 24)
        tv.defaultParagraphStyle = paraStyle as? NSMutableParagraphStyle
        tv.typingAttributes = [
            NSAttributedString.Key.font:            MacMarkdownTextStorage.bodyFont,
            NSAttributedString.Key.foregroundColor: MacMarkdownTextStorage.textColor,
            NSAttributedString.Key.paragraphStyle:  paraStyle
        ] as [NSAttributedString.Key: Any]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled  = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.delegate = context.coordinator
        context.coordinator.textView = tv

        // Wire toolbar actions directly to coordinator — no SwiftUI binding round-trip.
        let coord = context.coordinator
        actions.execute = { [weak coord] cmd in
            guard let c = coord, let tv = c.textView else { return }
            c.execute(cmd, in: tv)
        }
        coord.onWikilinkQuery  = onWikilinkQuery
        coord.onWikilinkAccept = onWikilinkAccept

        let scrollView = NSScrollView()
        scrollView.documentView          = tv
        scrollView.hasVerticalScroller   = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = false
        scrollView.backgroundColor       = NSColor.clear
        scrollView.drawsBackground       = false

        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            DispatchQueue.main.async { [weak coord] in
                guard let c = coord, let tv = c.textView else { return }
                c.refreshHorizontalRules(in: tv)
            }
        }

        return scrollView
    }

    // MARK: updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Re-wire on every update so the closure always reaches the live coordinator.
        let coord = context.coordinator
        actions.execute = { [weak coord] cmd in
            guard let c = coord, let tv = c.textView else { return }
            c.execute(cmd, in: tv)
        }
        coord.onWikilinkQuery  = onWikilinkQuery
        coord.onWikilinkAccept = onWikilinkAccept
        guard let tv = scrollView.documentView as? MarkdownNSTextView else { return }
        guard tv.string != text else { return }
        let savedRange = tv.selectedRange()
        tv.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: tv.textStorage?.length ?? 0),
            with: text)
        let newLen = tv.textStorage?.length ?? 0
        tv.setSelectedRange(NSRange(location: min(savedRange.location, newLen), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: MarkdownNSTextView?
        /// Last known selection — stored here so commands can use it even after focus leaves the text view.
        var lastSelection = NSRange(location: 0, length: 0)
        /// Called when cursor enters/exits a [[...]] span.
        var onWikilinkQuery: ((String?) -> Void)?
        /// Called when user presses Return while a suggestion is active.
        var onWikilinkAccept: (() -> Void)?
        /// Character position of the opening [[ in the active wikilink session.
        private var wikilinkOpenLoc: Int? = nil
        /// Marker subclass for thin NSView separators overlaid on `---` lines.
        private final class HROverlay: NSView {}

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Reset typing attributes so new text never inherits markdown styles (bold, color, etc.)
            tv.typingAttributes = [
                NSAttributedString.Key.font:            MacMarkdownTextStorage.bodyFont,
                NSAttributedString.Key.foregroundColor: MacMarkdownTextStorage.textColor,
                NSAttributedString.Key.paragraphStyle:  MacMarkdownTextStorage.baseParagraphStyle
            ] as [NSAttributedString.Key: Any]
            if text.wrappedValue != tv.string { text.wrappedValue = tv.string }
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.refreshHorizontalRules(in: tv)
                self.checkForWikilink(in: tv)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            lastSelection = tv.selectedRange()
            checkForWikilink(in: tv)
        }

        // MARK: - Horizontal rule overlay

        func refreshHorizontalRules(in tv: NSTextView) {
            tv.subviews
                .compactMap { $0 as? HROverlay }
                .forEach { $0.removeFromSuperview() }

            guard tv.string.contains("---"),
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)

            let ns = tv.string as NSString
            var pos = 0
            while pos < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
                guard lineRange.length > 0 else { break }
                let line = ns.substring(with: lineRange)
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                    let glyphRange = lm.glyphRange(forCharacterRange: lineRange,
                                                   actualCharacterRange: nil)
                    let lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                    let insetW = tv.textContainerInset.width
                    let insetH = tv.textContainerInset.height
                    let midY   = lineRect.origin.y + lineRect.height / 2 + insetH
                    let xLeft  = insetW + 16
                    let xRight = tv.bounds.width - insetW - 16

                    let rule = HROverlay(frame: NSRect(x: xLeft, y: midY - 0.5,
                                                       width: max(0, xRight - xLeft), height: 1.0))
                    rule.wantsLayer = true
                    rule.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
                    tv.addSubview(rule)
                }
                pos = lineRange.location + lineRange.length
            }
        }

        // MARK: - Wikilink autocomplete detection

        private func checkForWikilink(in tv: NSTextView) {
            let cursorLoc = tv.selectedRange().location
            let ns = tv.string as NSString

            // Only check within the current line
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            let lineStart = lineRange.location
            guard cursorLoc > lineStart + 1 else {
                endWikilinkSession()
                return
            }

            // Scan backward from cursor on this line for [[
            let beforeCursor = ns.substring(with: NSRange(location: lineStart,
                                                          length: cursorLoc - lineStart))
            let bns = beforeCursor as NSString

            var scanIdx = bns.length - 2
            var found: (openLoc: Int, partial: String)? = nil
            while scanIdx >= 0 {
                if bns.character(at: scanIdx)     == 91 &&   // '['
                   bns.character(at: scanIdx + 1) == 91 {   // '['
                    let partial = bns.substring(from: scanIdx + 2)
                    if !partial.contains("]]") && !partial.contains("\n") {
                        found = (lineStart + scanIdx, partial)
                    }
                    break
                }
                scanIdx -= 1
            }

            if let ctx = found {
                wikilinkOpenLoc = ctx.openLoc
                onWikilinkQuery?(ctx.partial)
            } else {
                endWikilinkSession()
            }
        }

        private func endWikilinkSession() {
            guard wikilinkOpenLoc != nil else { return }
            wikilinkOpenLoc = nil
            onWikilinkQuery?(nil)
        }

        private func applyWikiSuggestion(_ name: String, in tv: NSTextView) {
            let cursorLoc = tv.selectedRange().location
            guard let openLoc = wikilinkOpenLoc, openLoc <= cursorLoc else { return }
            let replaceRange = NSRange(location: openLoc, length: cursorLoc - openLoc)
            let replacement  = "[[\(name)]]"
            tv.textStorage?.replaceCharacters(in: replaceRange, with: replacement)
            tv.didChangeText()
            let newLoc = openLoc + (replacement as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            text.wrappedValue = tv.string
            wikilinkOpenLoc = nil
            onWikilinkQuery?(nil)
        }

        // MARK: Smart keyboard — auto-list continuation and dash-to-bullet conversion

        func textView(_ tv: NSTextView,
                      shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString replacement: String?) -> Bool {
            guard let replacement else { return true }
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            // ── Typing third "-" to complete "---" → create HR and move cursor below ──
            let lineWithoutNewline0 = line.hasSuffix("\n") ? String(line.dropLast()) : line
            if replacement == "-" && lineWithoutNewline0 == "--" {
                tv.textStorage?.replaceCharacters(in: affectedCharRange, with: "-\n")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: affectedCharRange.location + 2, length: 0))
                text.wrappedValue = tv.string
                return false
            }

            // ── Tab: indent line ──────────────────────────────────────────────────
            if replacement == "\t" {
                tv.textStorage?.replaceCharacters(in: lineRange, with: "  " + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: affectedCharRange.location + 2, length: 0))
                return false
            }

            // ── Space after lone "-" at line start → bullet ───────────────────────
            // Checks the character immediately before the cursor is "-" and everything
            // before it on the line is spaces. Handles both mid-doc and last-line cases.
            if replacement == " " && affectedCharRange.location > 0 {
                let dashPos = affectedCharRange.location - 1
                let charBefore = ns.character(at: dashPos)
                if charBefore == UInt16(UnicodeScalar("-").value) {
                    let lineStart = lineRange.location
                    if dashPos >= lineStart {
                        let prefix = ns.substring(with: NSRange(location: lineStart,
                                                                length: dashPos - lineStart))
                        if prefix.allSatisfy({ $0 == " " }) {
                            tv.textStorage?.replaceCharacters(
                                in: NSRange(location: dashPos, length: 1), with: "\u{2022}")
                            tv.didChangeText()
                            return true   // let the space insert normally
                        }
                    }
                }
            }

            // ── Return while wikilink session active → accept top suggestion ──────
            if replacement == "\n" && wikilinkOpenLoc != nil {
                onWikilinkAccept?()
                return false
            }

            // ── Return key: continue or exit list ─────────────────────────────────
            guard replacement == "\n" else { return true }

            let lineWithoutNewline = line.hasSuffix("\n") ? String(line.dropLast()) : line

            // Bullet continuation
            let bulletPrefix = "\u{2022} "
            if let bulletRange = lineWithoutNewline.range(of: bulletPrefix) {
                let indent = String(lineWithoutNewline[lineWithoutNewline.startIndex..<bulletRange.lowerBound])
                let afterBullet = lineWithoutNewline[bulletRange.upperBound...]
                if afterBullet.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Empty bullet — exit list
                    tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                } else {
                    // Continue bullet
                    let insert = "\n" + indent + bulletPrefix
                    tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                length: 0))
                }
                text.wrappedValue = tv.string
                return false
            }

            // Dash list continuation ("- item")
            if let dashRange = lineWithoutNewline.range(of: "- ") {
                let prefixSlice = lineWithoutNewline[lineWithoutNewline.startIndex..<dashRange.lowerBound]
                guard prefixSlice.allSatisfy({ $0 == " " }) else { return true }
                let indent = String(prefixSlice)
                let afterDash = lineWithoutNewline[dashRange.upperBound...]
                if afterDash.trimmingCharacters(in: .whitespaces).isEmpty {
                    tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                } else {
                    let insert = "\n" + indent + "- "
                    tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                length: 0))
                }
                text.wrappedValue = tv.string
                return false
            }

            // Checkbox continuation
            let checkPrefixes = ["☐ ", "☑ "]
            for prefix in checkPrefixes {
                if lineWithoutNewline.hasPrefix(prefix) {
                    let afterCheck = lineWithoutNewline.dropFirst(prefix.count)
                    if afterCheck.trimmingCharacters(in: .whitespaces).isEmpty {
                        tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    } else {
                        let insert = "\n☐ "
                        tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                    length: 0))
                    }
                    text.wrappedValue = tv.string
                    return false
                }
            }

            return true
        }

        // MARK: Command execution

        func execute(_ command: MacEditorCommand, in tv: NSTextView) {
            switch command {
            case .bold:      wrapSelection("**", in: tv)
            case .italic:    wrapSelection("*", in: tv)
            case .strike:    wrapSelection("~~", in: tv)
            case .highlight: wrapSelection("==", in: tv)
            case .link:      wrapSelection("[[", closing: "]]", in: tv)
            case .heading:   toggleLinePrefix("## ", in: tv)
            case .bullet:    toggleBullet(in: tv)
            case .checkbox:  toggleCheckbox(in: tv)
            case .indent:    indentLine(in: tv)
            case .outdent:   outdentLine(in: tv)
            case .date:      insertDate(in: tv)
            case .undo:      tv.undoManager?.undo()
            case .redo:      tv.undoManager?.redo()
            case .applyWikiSuggestion(let name): applyWikiSuggestion(name, in: tv)
            }
        }

        private func wrapSelection(_ marker: String, closing: String? = nil, in tv: NSTextView) {
            let close   = closing ?? marker
            let range   = lastSelection
            guard let storage = tv.textStorage else { return }
            if range.length == 0 {
                let pair = marker + close
                storage.replaceCharacters(in: range, with: pair)
                tv.didChangeText()
                let newLoc = range.location + (marker as NSString).length
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else if let swiftRange = Range(range, in: storage.string) {
                let selected = String(storage.string[swiftRange])
                storage.replaceCharacters(in: range, with: marker + selected + close)
                tv.didChangeText()
            }
            text.wrappedValue = storage.string
        }

        private func toggleLinePrefix(_ prefix: String, in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            if line.hasPrefix(prefix) {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(prefix.count)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - (prefix as NSString).length)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: prefix + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + (prefix as NSString).length,
                                            length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func toggleBullet(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            let bullet    = "\u{2022} "
            if line.hasPrefix(bullet) {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(2)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: bullet + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func toggleCheckbox(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            if line.hasPrefix("☑ ") {
                storage.replaceCharacters(in: lineRange, with: "☐ " + String(line.dropFirst(2)))
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location, length: 0))
            } else if line.hasPrefix("☐ ") {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(2)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: "☐ " + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func indentLine(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            storage.replaceCharacters(in: lineRange, with: "  " + line)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            text.wrappedValue = storage.string
        }

        private func outdentLine(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            let toRemove  = line.hasPrefix("  ") ? 2 : (line.hasPrefix(" ") ? 1 : 0)
            guard toRemove > 0 else { return }
            storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(toRemove)))
            tv.didChangeText()
            let newLoc = max(lineRange.location, lastSelection.location - toRemove)
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            text.wrappedValue = storage.string
        }

        private func insertDate(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "MMMM d, yyyy"
            let str   = fmt.string(from: Date()) + " "
            let range = lastSelection
            storage.replaceCharacters(in: range, with: str)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + (str as NSString).length, length: 0))
            text.wrappedValue = storage.string
        }
    }
}

// MARK: - Shared markdown editor

struct TraceMacNoteEditor: View {
    let relativePath: String

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var content        = ""
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var lastSaved: Date? = nil
    // @State keeps the same MacEditorActions instance across re-renders; makeNSView wires it once.
    @State private var editorActions  = MacEditorActions()
    // Wikilink autocomplete state
    @State private var wikiQuery:       String? = nil
    @State private var wikiSuggestions: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            MacTextEditor(text: $content, actions: editorActions,
                          onWikilinkQuery: { query in
                              wikiQuery = query
                              // Read directly from NotionService at query time — avoids the
                              // load-once race where people/places aren't yet fetched.
                              if let q = query, !q.isEmpty {
                                  let people = notionService.people
                                      .filter { !$0.isArchived }
                                      .map(\.name)
                                  let places = notionService.places.map(\.name)
                                  wikiSuggestions = Array((people + places)
                                      .filter { $0.localizedCaseInsensitiveContains(q) }
                                      .sorted()
                                      .prefix(8))
                              } else {
                                  wikiSuggestions = []
                              }
                          },
                          onWikilinkAccept: {
                              if let first = wikiSuggestions.first {
                                  editorActions.execute(.applyWikiSuggestion(first))
                              }
                          })
                .onChange(of: content) { _, newValue in
                    scheduleSave(content: newValue)
                }

            // Wikilink suggestion pills — shown only when cursor is inside [[...]]
            if !wikiSuggestions.isEmpty {
                Divider()
                wikiSuggestionBar
            }

            // Formatting toolbar
            Divider()
            formattingToolbar

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
            guard saveTask == nil else { return }
            guard let changedPath = note.object as? String,
                  changedPath == relativePath else { return }
            Task { await loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStorePlaceNoteDidChange)) { note in
            guard saveTask == nil else { return }
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

    // MARK: - Wiki suggestion bar

    private var wikiSuggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(wikiSuggestions, id: \.self) { name in
                    Button {
                        editorActions.execute(.applyWikiSuggestion(name))
                    } label: {
                        Text(name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.13))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Formatting toolbar

    private var formattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                fmtButton("bold",            .bold,      "Bold (**)")
                    .keyboardShortcut("b", modifiers: .command)
                fmtButton("italic",          .italic,    "Italic (*)")
                    .keyboardShortcut("i", modifiers: .command)
                fmtButton("strikethrough",   .strike,    "Strikethrough (~~)")
                fmtButton("highlighter",     .highlight, "Highlight (==)")

                toolbarDivider()

                fmtButton("number",          .heading,   "Heading (##)")
                fmtButton("list.bullet",     .bullet,    "Bullet (•)")
                fmtButton("checkmark.square",.checkbox,  "Checkbox (☐)")

                toolbarDivider()

                fmtButton("decrease.indent", .outdent,   "Outdent")
                fmtButton("increase.indent", .indent,    "Indent")

                toolbarDivider()

                fmtButton("link",            .link,      "Wikilink [[]]")
                fmtButton("calendar",        .date,      "Insert date")

                toolbarDivider()

                fmtButton("arrow.uturn.backward", .undo, "Undo")
                    .keyboardShortcut("z", modifiers: .command)
                fmtButton("arrow.uturn.forward",  .redo, "Redo")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func fmtButton(_ icon: String, _ command: MacEditorCommand, _ tip: String) -> some View {
        Button { editorActions.execute(command) } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(tip)
    }

    private func toolbarDivider() -> some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 4)
    }

    // MARK: - Helpers

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

// MARK: - MacTagChipRow

/// Horizontally scrolling `#tag` filter chips for note list views.
/// Shows only when `tags` is non-empty. Selected chips AND-filter the list.
struct MacTagChipRow: View {
    let tags: [String]
    @Binding var selected: Set<String>

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(tags, id: \.self) { tag in
                        let on = selected.contains(tag)
                        Button {
                            if on { selected.remove(tag) }
                            else  { selected.insert(tag) }
                        } label: {
                            Text("#\(tag)")
                                .font(.system(size: 10, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    on ? Color.accentColor : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }
}
