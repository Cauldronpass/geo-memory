// TraceMacJournalView.swift
// Journal section for Trace Mac — Daily, Projects, Places.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

// MARK: - Journal root (dispatches to the right tab)

struct TraceMacJournalView: View {
    let section: MacSection  // .daily, .projects, or .places

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
        case .places:
            TraceMacPlaceNoteView()
                .environment(noteStore)
                .environment(notionService)
        default:
            EmptyView()
        }
    }
}

// MARK: - Daily notes

struct TraceMacDailyView: View {
    @Environment(NoteStore.self) private var noteStore

    @State private var files: [String] = []         // filenames in Calendar/
    @State private var selectedFile: String? = nil
    @State private var searchText = ""

    private var filtered: [String] {
        if searchText.isEmpty { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var todayFilename: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "\(fmt.string(from: Date())).md"
    }

    var body: some View {
        HSplitView {
            // Left: file list
            VStack(spacing: 0) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)

                List(filtered, id: \.self, selection: $selectedFile) { filename in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: filename))
                            .font(.body)
                        Text(filename.replacingOccurrences(of: ".md", with: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(filename)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 200, maxWidth: 260)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Today") { openToday() }
                }
                ToolbarItem {
                    Button { openToday() } label: {
                        Label("New", systemImage: "plus")
                    }
                }
            }

            // Right: editor
            if let file = selectedFile {
                TraceMacNoteEditor(relativePath: "Calendar/\(file)")
                    .environment(noteStore)
            } else {
                placeholderEditor
            }
        }
        .task { await loadFiles() }
        .onAppear { openToday() }
    }

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

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: "Calendar")) ?? []
        // Sort newest first
        files = loaded.sorted(by: >)
        if selectedFile == nil, files.contains(todayFilename) {
            selectedFile = todayFilename
        }
    }

    private func openToday() {
        let filename = todayFilename
        let path = "Calendar/\(filename)"
        // Create today's file if it doesn't exist
        if (try? noteStore.readFile(path))?.isEmpty ?? true {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let header = "# \(fmt.string(from: Date()))\n\n"
            try? noteStore.writeFile(path, content: header)
        }
        if !files.contains(filename) {
            files.insert(filename, at: 0)
        }
        selectedFile = filename
    }

    private func displayName(for filename: String) -> String {
        let dateStr = filename.replacingOccurrences(of: ".md", with: "")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: dateStr) else { return dateStr }
        let display = DateFormatter()
        display.dateFormat = "EEEE, MMM d"
        let result = display.string(from: date)
        // Mark today
        if Calendar.current.isDateInToday(date) { return "Today — \(result)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday — \(result)" }
        return result
    }
}

// MARK: - Generic note list (Projects, custom subfolders)

struct TraceMacNoteListView: View {
    let subfolder: String
    let sectionTitle: String
    let newNotePrompt: String
    let emptyMessage: String

    @Environment(NoteStore.self) private var noteStore

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingNewNote = false
    @State private var newNoteName = ""

    private var filtered: [String] {
        if searchText.isEmpty { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HSplitView {
            // Left: file list
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
                            .tag(filename)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, maxWidth: 260)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewNote = true } label: {
                        Label("New Note", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewNote) {
                newNoteSheet
            }

            // Right: editor
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
        .task { await loadFiles() }
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

    private var filtered: [String] {
        if searchText.isEmpty { return files }
        return files.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HSplitView {
            // Left: file list
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
                            .tag(filename)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, maxWidth: 260)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingPlacePicker = true } label: {
                        Label("New Place Note", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingPlacePicker) {
                placePickerSheet
            }

            // Right: editor
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

// MARK: - Shared markdown editor

struct TraceMacNoteEditor: View {
    let relativePath: String

    @Environment(NoteStore.self) private var noteStore

    @State private var content = ""
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var lastSaved: Date? = nil

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $content)
                .font(.system(size: 15))
                .lineSpacing(4)
                .padding(16)
                .onChange(of: content) { _, newValue in
                    scheduleSave(content: newValue)
                }

            // Footer
            HStack {
                Spacer()
                if let saved = lastSaved {
                    Text("Saved \(saved.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 12)
                        .padding(.bottom, 6)
                }
            }
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
