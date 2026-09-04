// TraceMacInboxView.swift
// To File — quick captures from the menu bar or the phone, reviewed and
// cleared here. Sidebar row "To File" (D186); the case stays `inbox`.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// Session 83, D260: the Editorial chrome. The grey section header, the
// rounded search box, the system list rows and the window-toolbar buttons
// were the old wallpaper; the masthead, the search line, the row grammar
// (title in serif, where it came from beneath, date at right) and the `+`
// square are what every other room now wears. What the screen DOES is
// unchanged: a list of captures, the shared editor, delete with a
// confirmation. This was the first of the four RECORDS rooms to get the
// pass, chosen because it is the smallest — a plain list on which the row
// grammar can be judged before it goes onto Satchel.

import SwiftUI

struct TraceMacInboxView: View {

    /// Bare filename, set by global search. This view owns its list, so it is
    /// handed a name and resolves it itself, and it clears the binding when done.
    var deepLinkFile: Binding<String?>? = nil

    @Environment(NoteStore.self) private var noteStore

    @State private var files: [InboxFile] = []
    @State private var selectedFile: InboxFile? = nil
    @State private var searchText = ""
    @State private var deleteCandidate: InboxFile? = nil
    @State private var showDeleteConfirm = false

    private var filtered: [InboxFile] {
        guard !searchText.isEmpty else { return files }
        return files.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.filename.localizedCaseInsensitiveContains(searchText)
                || ($0.preview?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var kicker: String {
        let n = files.count
        if n == 0 { return "Nothing to file" }
        return n == 1 ? "1 to file" : "\(n) to file"
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: MacEditorialLayout.listColumnWidth)
            Rectangle().fill(MacEditorialColor.hairline).frame(width: 1)
            Group {
                if let file = selectedFile {
                    TraceMacNoteEditor(relativePath: "Notes/Inbox/\(file.filename)",
                                       heading: "To file note")
                        .environment(noteStore)
                } else {
                    Text(files.isEmpty ? "Nothing here. Captures from the phone and the menu bar land in this list."
                                       : "Select a capture")
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, MacEditorialLayout.margin)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(MacEditorialColor.paper)
        .task { await loadFiles() }
        // Deliberately keyed on the pair. `loadFiles` is async, so a deep link
        // arriving with the view can land before there is a list to select
        // from; re-running when `files` fills catches that. Selecting a file
        // that is not in the list would silently do nothing, which is the whole
        // failure mode this pattern exists to avoid.
        .task(id: MacDeepLinkKey(value: deepLinkFile?.wrappedValue, loaded: files.count)) {
            guard let name = deepLinkFile?.wrappedValue else { return }
            guard let match = files.first(where: { $0.filename == name }) else { return }
            selectedFile = match
            deepLinkFile?.wrappedValue = nil
        }
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

    // MARK: - The list

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialMasthead(kicker: kicker, title: "To File")
                .padding(.horizontal, MacEditorialLayout.margin)
                .padding(.top, MacEditorialLayout.topMargin)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.ink)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { MacEditorialRule.hair }
                .padding(.horizontal, MacEditorialLayout.margin)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filtered.isEmpty {
                        Text(files.isEmpty ? "Your inbox is clear." : "Nothing matches.")
                            .font(MacEditorialType.meta)
                            .foregroundStyle(MacEditorialColor.faint)
                            .padding(.top, 18)
                    } else {
                        ForEach(filtered) { file in row(file) }
                    }
                    Spacer(minLength: MacEditorialLayout.plusSize + MacEditorialLayout.plusInset * 2)
                }
                .padding(.horizontal, MacEditorialLayout.margin)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            MacEditorialPlus { createNote() }
        }
    }

    /// Title in serif with when it was captured at the right; beneath it, the
    /// first line of the body after the title, or the capture time when the
    /// body is empty. Delete is in the context menu (was a swipe and a
    /// toolbar button).
    private func row(_ file: InboxFile) -> some View {
        let isSelected: Bool = selectedFile == file
        let wash: Color = isSelected ? MacEditorialColor.canvas : Color.clear
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(file.title)
                    .font(MacEditorialType.rowTitle)
                    .foregroundStyle(MacEditorialColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(dateText(file.created))
                    .editorialListLabel()
            }
            if let preview = file.preview, !preview.isEmpty {
                Text(preview)
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let created = file.created {
                Text("Captured " + created.formatted(date: .omitted, time: .shortened))
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.faint)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, MacEditorialLayout.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash)
        .contentShape(Rectangle())
        .onTapGesture { selectedFile = file }
        .padding(.horizontal, -MacEditorialLayout.margin)
        .overlay(alignment: .bottom) { MacEditorialRule.hair }
        .contextMenu {
            Button(role: .destructive) {
                deleteCandidate = file
                showDeleteConfirm = true
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// "Today", "Yesterday", "1 Sep", "12 Aug 2025".
    private func dateText(_ d: Date?) -> String {
        guard let d else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d)     { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }

    // MARK: - Actions

    private func loadFiles() async {
        let names = (try? noteStore.listFiles(in: "Notes/Inbox")) ?? []
        let loaded: [InboxFile] = names.compactMap { filename in
            let path = "Notes/Inbox/\(filename)"
            let content = (try? noteStore.readFile(path)) ?? ""
            let lines = content.components(separatedBy: "\n")
            let firstIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let firstLine = firstIndex.map { lines[$0] } ?? filename
            let title = firstLine
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            // The row's second line: the body after the title, scanned the
            // way the Days and Projects lists scan theirs, so one rule.
            let rest = firstIndex.map { lines.dropFirst($0 + 1).joined(separator: "\n") } ?? ""
            let preview: String? = {
                switch MacDayScan.firstMeaningfulLine(of: rest) {
                case .prose(let t), .override(let t): return t
                case .none: return nil
                }
            }()
            let url = noteStore.resolvedURL(for: path)
            let created = url.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.creationDate] as? Date
            }
            return InboxFile(filename: filename, title: title.isEmpty ? filename : title,
                             created: created, preview: preview)
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
        let newFile = InboxFile(filename: filename, title: "Note", created: Date(), preview: nil)
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
    /// The first meaningful line after the title, for the row. Session 83.
    var preview: String? = nil

    static func == (lhs: InboxFile, rhs: InboxFile) -> Bool { lhs.filename == rhs.filename }
    func hash(into hasher: inout Hasher) { hasher.combine(filename) }
}
