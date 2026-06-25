import SwiftUI

// MARK: - NotesView
//
// Four-tab notes screen backed by NotePlan via NotePlanService.
//
//  Daily     — today's Calendar/YYYY-MM-DD.md, editable inline
//  Buckets   — Notes/Buckets/*.md (This Week, Next Week, etc.)
//  Projects  — Notes/Projects/*.md
//  Places    — Notes/Places/*.md (one file per place)

struct NotesView: View {

    @State private var notePlan = NotePlanService.shared
    @State private var selectedTab: NoteTab = .daily

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                tabContent
            }
            .navigationTitle(selectedTab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !notePlan.hasAccess {
                        Label("Not linked", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
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
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
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
            DailyNoteTab()
        case .buckets:
            NoteFileListTab(subfolder: "Notes/Buckets", emptyMessage: "No bucket notes yet.\nCreate one in NotePlan under Notes/Buckets.")
        case .projects:
            NoteFileListTab(subfolder: "Notes/Projects", emptyMessage: "No project notes yet.\nCreate one in NotePlan under Notes/Projects.")
        case .places:
            NoteFileListTab(subfolder: "Notes/Places", emptyMessage: "No place notes yet.\nPlace notes are created automatically when you tap 'Notes' on a place.")
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

    @State private var notePlan = NotePlanService.shared
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDate: Date = Date()
    @State private var showDatePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Date header
            HStack {
                Button {
                    selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                    load()
                } label: {
                    Image(systemName: "chevron.left")
                }

                Spacer()

                Button {
                    showDatePicker.toggle()
                } label: {
                    Text(selectedDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline.weight(.medium))
                }

                Spacer()

                Button {
                    selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                    load()
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if !notePlan.hasAccess {
                notLinkedView
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                errorView(err)
            } else {
                MarkdownEditorView(
                    text: $content,
                    onSave: { newText in
                        save(newText)
                    },
                    placeholder: "Nothing here yet — start writing."
                )
            }
        }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(date: $selectedDate) { load() }
        }
        .task { load() }
        .onChange(of: selectedDate) { load() }
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                content = try notePlan.readDailyNote(date: selectedDate)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func save(_ text: String) {
        Task {
            do {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let path = "Calendar/\(formatter.string(from: selectedDate)).md"
                try notePlan.writeFile(path, content: text)
            } catch {
                // Silent — auto-save failure shouldn't interrupt the user
            }
        }
    }

    private var notLinkedView: some View {
        ContentUnavailableView(
            "NotePlan Not Linked",
            systemImage: "folder.badge.questionmark",
            description: Text("Go to Settings → NotePlan to link your folder.")
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

// MARK: - Note file list tab (Buckets / Projects / Places)

struct NoteFileListTab: View {

    let subfolder: String
    let emptyMessage: String

    @State private var notePlan = NotePlanService.shared
    @State private var files: [String] = []
    @State private var isLoading = true
    @State private var selectedFile: String?
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var isCreating = false

    var body: some View {
        Group {
            if !notePlan.hasAccess {
                ContentUnavailableView(
                    "NotePlan Not Linked",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Go to Settings → NotePlan to link your folder.")
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
                    ToolbarItem(placement: .navigationBarTrailing) {
                        newNoteButton
                    }
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
                }
                .listStyle(.plain)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        newNoteButton
                    }
                }
            }
        }
        .task { loadFiles() }
        .navigationDestination(item: $selectedFile) { filename in
            NoteEditorView(relativePath: "\(subfolder)/\(filename)",
                           title: filename.replacingOccurrences(of: ".md", with: ""))
        }
        .sheet(isPresented: $showingNewNote) {
            NewNoteSheet(name: $newNoteName, isCreating: isCreating) {
                createNote()
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
            try? notePlan.writeFile(path, content: "# \(name)\n")
            await MainActor.run {
                showingNewNote = false
                newNoteName = ""
                isCreating = false
            }
            // Reload then navigate into the new note
            files = (try? notePlan.listFiles(in: subfolder)) ?? []
            await MainActor.run { selectedFile = filename }
        }
    }

    private func deleteFile(_ filename: String) {
        try? notePlan.deleteFile("\(subfolder)/\(filename)")
        files.removeAll { $0 == filename }
    }

    private func loadFiles() {
        isLoading = true
        Task {
            files = (try? notePlan.listFiles(in: subfolder)) ?? []
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

// MARK: - Note editor (full-screen for a single file)

struct NoteEditorView: View {

    let relativePath: String
    let title: String

    @State private var notePlan = NotePlanService.shared
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var savedIndicator = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                MarkdownEditorView(
                    text: $content,
                    onSave: { newText in
                        save(newText)
                    }
                )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if savedIndicator {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .task { load() }
    }

    private func load() {
        Task {
            content = (try? notePlan.readFile(relativePath)) ?? ""
            isLoading = false
        }
    }

    private func save(_ text: String) {
        Task {
            try? notePlan.writeFile(relativePath, content: text)
            withAnimation {
                savedIndicator = true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation {
                savedIndicator = false
            }
        }
    }
}

// MARK: - Date picker sheet

private struct DatePickerSheet: View {
    @Binding var date: Date
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DatePicker("Select date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Jump to Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onChange()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}
