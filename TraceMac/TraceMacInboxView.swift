// TraceMacInboxView.swift
// Inbox section — quick captures from menu bar or iPhone, reviewed and cleared here.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

struct TraceMacInboxView: View {

    @Environment(NoteStore.self) private var noteStore

    @State private var files: [InboxFile] = []
    @State private var selectedFile: InboxFile? = nil
    @State private var searchText = ""
    @State private var deleteCandidate: InboxFile? = nil
    @State private var showDeleteConfirm = false

    private var filtered: [InboxFile] {
        guard !searchText.isEmpty else { return files }
        return files.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.filename.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HSplitView {
            // Left: file list
            VStack(spacing: 0) {
                TextField("Search inbox", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)

                Divider()

                if files.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 36, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("Your inbox is clear.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(filtered, selection: $selectedFile) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.title)
                                .font(.body)
                                .lineLimit(1)
                            if let date = file.created {
                                Text(date, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(file)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteCandidate = file
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, maxWidth: 280)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { createNote() } label: {
                        Label("New", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
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

            // Right: editor
            if let file = selectedFile {
                TraceMacNoteEditor(relativePath: "Notes/Inbox/\(file.filename)")
                    .environment(noteStore)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("Select an item")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await loadFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreInboxDidChange)) { note in
            // Skip reload if the change is the file we're currently editing — we caused it
            if let changed = note.object as? String,
               let sel = selectedFile,
               changed == "Notes/Inbox/\(sel.filename)" { return }
            Task { await loadFiles() }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.title ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deleteFile(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Actions

    private func loadFiles() async {
        let names = (try? noteStore.listFiles(in: "Notes/Inbox")) ?? []
        let loaded: [InboxFile] = names.compactMap { filename in
            let path = "Notes/Inbox/\(filename)"
            let content = (try? noteStore.readFile(path)) ?? ""
            let firstLine = content.components(separatedBy: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? filename
            let title = firstLine
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            let url = noteStore.resolvedURL(for: path)
            let created = url.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.creationDate] as? Date
            }
            return InboxFile(filename: filename, title: title.isEmpty ? filename : title, created: created)
        }
        // Sort newest first
        files = loaded.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    private func createNote() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "\(fmt.string(from: Date())).md"
        let path = "Notes/Inbox/\(filename)"
        try? noteStore.writeFile(path, content: "# Note\n\n")
        let newFile = InboxFile(filename: filename, title: "Note", created: Date())
        files.insert(newFile, at: 0)
        selectedFile = newFile
    }

    private func deleteFile(_ file: InboxFile) {
        try? noteStore.deleteFile("Notes/Inbox/\(file.filename)")
        files.removeAll { $0.id == file.id }
        if selectedFile?.id == file.id { selectedFile = nil }
        deleteCandidate = nil
    }
}

struct InboxFile: Identifiable, Hashable {
    var id: String { filename }
    let filename: String
    var title: String
    var created: Date?

    static func == (lhs: InboxFile, rhs: InboxFile) -> Bool { lhs.filename == rhs.filename }
    func hash(into hasher: inout Hasher) { hasher.combine(filename) }
}
