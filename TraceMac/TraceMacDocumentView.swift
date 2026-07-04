// TraceMacDocumentsView.swift
// Browse, search, filter, and view documents stored in Trace's iCloud container.
// PDFs render inline via PDFKit. Images display inline. Tags via sidecar .md files.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import PDFKit
import AppKit

// MARK: - Main view

struct TraceMacDocumentsView: View {

    @Environment(NoteStore.self) private var noteStore

    @State private var store: TraceMacDocumentStore? = nil
    @State private var selectedDoc: TraceMacDocument? = nil
    @State private var searchText = ""
    @State private var activeTag: String? = nil
    @State private var categoryFilter = "All"
    @State private var listCollapsed = false

    private let categories = ["All", "Inbox", "Project", "Place", "Other"]

    private var filtered: [TraceMacDocument] {
        guard let store else { return [] }
        return store.documents.filter { doc in
            let matchesSearch = searchText.isEmpty
                || doc.title.localizedCaseInsensitiveContains(searchText)
                || doc.filename.localizedCaseInsensitiveContains(searchText)
                || doc.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            let matchesTag = activeTag == nil || doc.tags.contains(activeTag!)
            let matchesCategory = categoryFilter == "All"
                || doc.category.localizedCaseInsensitiveContains(categoryFilter)
                || (categoryFilter == "Other" && !["Inbox","Project","Place","Archive"].contains(doc.category))
            let notArchived = doc.category != "Archive"
            return matchesSearch && matchesTag && matchesCategory && notArchived
        }
    }

    private var allTags: [String] {
        guard let store else { return [] }
        let tags = store.documents.flatMap { $0.tags }
        return Array(Set(tags)).sorted()
    }

    var body: some View {
        HStack(spacing: 0) {
            if !listCollapsed { leftColumn }
            CollapseHandle(isCollapsed: $listCollapsed, collapsesRight: false, showLine: true, panelColor: .clear)
            rightColumn.frame(maxWidth: .infinity)
        }
        .task {
            if store == nil {
                store = TraceMacDocumentStore(noteStore: noteStore)
            }
            await store?.reload()
        }
        .toolbar {
            ToolbarItem {
                Button { importDocument() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
            if let doc = selectedDoc, let url = noteStore.resolvedURL(for: doc.relativePath) {
                ToolbarItem {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Open", systemImage: "arrow.up.forward.square")
                    }
                }
                ToolbarItem {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
            }
        }
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(spacing: 0) {
            // Search
            TextField("Search documents", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(10)

            // Category filter
            HStack(spacing: 0) {
                ForEach(categories, id: \.self) { cat in
                    Button(cat) { categoryFilter = cat }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(categoryFilter == cat ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundStyle(categoryFilter == cat ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            // Tag chips
            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tagChip("All", isActive: activeTag == nil) { activeTag = nil }
                        ForEach(allTags, id: \.self) { tag in
                            tagChip(tag, isActive: activeTag == tag) {
                                activeTag = activeTag == tag ? nil : tag
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }

            Divider()

            // Document list
            if let store, store.isLoading {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text(store?.documents.isEmpty == true
                         ? "No documents yet.\nImport one or add from iPhone."
                         : "No matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List(filtered, selection: $selectedDoc) { doc in
                    DocListRow(doc: doc)
                        .tag(doc)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: 240)
    }

    private func tagChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right column

    @ViewBuilder
    private var rightColumn: some View {
        if let doc = selectedDoc {
            VStack(spacing: 0) {
                docViewer(for: doc)
                Divider()
                DocMetadataPanel(doc: doc, store: store!) { movedDoc in
                    Task {
                        await store?.reload()
                        // Re-select by filename after move; nil after delete (no match found)
                        selectedDoc = store?.documents.first { $0.filename == movedDoc.filename }
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("Select a document")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func docViewer(for doc: TraceMacDocument) -> some View {
        if doc.isPDF, let url = noteStore.resolvedURL(for: doc.relativePath) {
            PDFViewRepresentable(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if doc.isImage, let url = noteStore.resolvedURL(for: doc.relativePath),
                  let nsImage = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = noteStore.resolvedURL(for: doc.relativePath) {
            VStack(spacing: 16) {
                Image(systemName: "doc")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text(doc.filename)
                    .font(.headline)
                if let size = fileSize(at: url) {
                    Text(size)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Button("Open in Default App") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Import

    private func importDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? store?.importDocument(from: url)
            Task { await store?.reload() }
        }
    }

    private func fileSize(at url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - List row

struct DocListRow: View {
    let doc: TraceMacDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: doc.isPDF ? "doc.fill" : doc.isImage ? "photo" : "doc.text")
                    .foregroundStyle(doc.isPDF ? .red : doc.isImage ? .blue : .secondary)
                    .font(.caption)
                Text(doc.title)
                    .font(.body)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(doc.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let date = doc.created {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !doc.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(doc.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Metadata panel

struct DocMetadataPanel: View {
    let doc: TraceMacDocument
    let store: TraceMacDocumentStore
    let onSave: (TraceMacDocument) -> Void

    @Environment(NotionService.self) private var notion
    @Environment(NoteStore.self) private var noteStore

    @State private var title: String = ""
    @State private var tags: [String] = []
    @State private var linkedNote: String = ""
    @State private var people: [String] = []
    @State private var isSaving = false
    @State private var isMoving = false
    @State private var isExpanded = true
    @State private var showingTagPopover = false
    @State private var newTagText = ""
    @State private var showingNotePicker = false
    @State private var showingPeoplePicker = false
    @State private var showingProjectMover = false
    @State private var showingPlaceMover = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        DisclosureGroup("Metadata", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                categoryRow
                titleRow
                tagsRow
                linkedNoteRow
                peopleRow
                HStack {
                    Button("Delete", role: .destructive) { showingDeleteConfirm = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .controlSize(.small)
                    Spacer()
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isSaving)
                }
                .confirmationDialog("Delete \"\(doc.title)\"?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { delete() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This permanently removes the file from iCloud.")
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { load() }
        .onChange(of: doc.id) { _, _ in load() }
        .sheet(isPresented: $showingNotePicker) {
            LinkedNotePickerSheet(current: linkedNote) { picked in
                linkedNote = picked
            }
            .environment(noteStore)
        }
        .sheet(isPresented: $showingPeoplePicker) {
            DocPersonPickerSheet(current: people) { picked in
                if !people.contains(picked) { people.append(picked) }
            }
            .environment(notion)
        }
    }

    // MARK: - Category + Move

    private var categoryRow: some View {
        HStack(spacing: 8) {
            fieldLabel("Category")
            Text(doc.category)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            Spacer()
            Menu {
                if doc.category != "Inbox"   { Button("Move to Inbox")      { move(to: "Inbox") } }
                if doc.category != "Project" { Button("Move to Project…")   { showingProjectMover = true } }
                if doc.category != "Place"   { Button("Move to Place…")     { showingPlaceMover  = true } }
                if doc.category != "Other"   { Button("Move to Other")      { move(to: "Other") } }
                Divider()
                if doc.category != "Archive" { Button("Archive")            { move(to: "Archive") } }
            } label: {
                HStack(spacing: 4) {
                    if isMoving { ProgressView().controlSize(.mini) }
                    Text("Move to…").font(.caption)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.1))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isMoving)
        }
        .sheet(isPresented: $showingProjectMover) {
            LinkedNotePickerSheet(current: linkedNote, filterFolders: ["Notes/Projects"]) { picked in
                linkedNote = picked
                move(to: "Project")
            }
            .environment(noteStore)
        }
        .sheet(isPresented: $showingPlaceMover) {
            LinkedNotePickerSheet(current: linkedNote, filterFolders: ["Notes/Places"]) { picked in
                linkedNote = picked
                move(to: "Place")
            }
            .environment(noteStore)
        }
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack {
            fieldLabel("Title")
            TextField("Document title", text: $title)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Tags

    private var tagsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            fieldLabel("Tags").padding(.top, 4)
            DocChipsEditor(
                chips: $tags,
                allSuggestions: existingTags,
                placeholder: "Add tag…",
                color: .accentColor
            )
        }
    }

    private var existingTags: [String] {
        let all = store.documents.flatMap { $0.tags }
        return Array(Set(all)).sorted()
    }

    // MARK: - Linked note

    private var linkedNoteRow: some View {
        HStack(spacing: 6) {
            fieldLabel("Linked")
            Group {
                if linkedNote.isEmpty {
                    Text("None").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text(linkedNote.components(separatedBy: "/").last?.replacingOccurrences(of: ".md", with: "") ?? linkedNote)
                        .font(.caption).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(linkedNote.isEmpty ? "Pick…" : "Change") { showingNotePicker = true }
                .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .fixedSize()
            if !linkedNote.isEmpty {
                Button { linkedNote = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - People

    private var peopleRow: some View {
        HStack(alignment: .top, spacing: 0) {
            fieldLabel("People").padding(.top, 4)
            DocChipsEditor(
                chips: $people,
                allSuggestions: [],
                placeholder: "Add person…",
                color: .purple,
                onAddTap: { showingPeoplePicker = true }
            )
        }
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .frame(width: 60, alignment: .trailing)
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(.trailing, 8)
    }

    private func load() {
        title = doc.title
        tags = doc.tags
        linkedNote = doc.linkedNote ?? ""
        people = doc.people
    }

    private func move(to category: String) {
        isMoving = true
        Task {
            do { try store.moveDocument(doc, to: category) }
            catch {
                await MainActor.run { isMoving = false }
                return
            }
            // Build a synthetic doc at the new path so we can write the sidecar there
            let newPath = "Documents/\(category)/\(doc.filename)"
            let newSidecarBase = newPath.hasSuffix(".\(doc.fileExtension)")
                ? String(newPath.dropLast(doc.fileExtension.count + 1))
                : newPath
            let movedDoc = TraceMacDocument(
                relativePath: newPath,
                filename: doc.filename,
                category: category,
                fileExtension: doc.fileExtension,
                title: title.trimmingCharacters(in: .whitespaces),
                tags: tags,
                created: doc.created,
                linkedNote: linkedNote.isEmpty ? nil : linkedNote,
                people: people
            )
            try? store.saveSidecar(
                for: movedDoc,
                title: movedDoc.title,
                tags: movedDoc.tags,
                linkedNote: movedDoc.linkedNote,
                people: movedDoc.people
            )
            // Delete old sidecar if it was at a different path
            let oldSidecar = doc.sidecarPath
            let newSidecar = "\(newSidecarBase).md"
            if oldSidecar != newSidecar {
                try? noteStore.deleteFile(oldSidecar)
            }
            await MainActor.run { isMoving = false; onSave(movedDoc) }
        }
    }

    private func save() {
        isSaving = true
        try? store.saveSidecar(
            for: doc,
            title: title.trimmingCharacters(in: .whitespaces),
            tags: tags,
            linkedNote: linkedNote.trimmingCharacters(in: .whitespaces).isEmpty ? nil : linkedNote,
            people: people
        )
        isSaving = false
        onSave(doc)
    }

    private func delete() {
        Task {
            try? noteStore.deleteFile(doc.relativePath)
            try? noteStore.deleteFile(doc.sidecarPath)
            await MainActor.run {
                // Pass a sentinel with empty filename so parent clears selection
                var deleted = doc
                onSave(deleted)
            }
        }
    }
}

// MARK: - Chips editor
// Reusable tag/people chip list with inline add-by-typing or custom add action.

struct DocChipsEditor: View {
    @Binding var chips: [String]
    let allSuggestions: [String]
    let placeholder: String
    let color: Color
    var onAddTap: (() -> Void)? = nil   // if set, "+" opens this instead of the text popover

    @State private var showingPopover = false
    @State private var newText = ""

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(chips, id: \.self) { chip in
                chipView(chip)
            }
            Button {
                if let tap = onAddTap { tap() }
                else { showingPopover.toggle() }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption).foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                suggestionsPopover
            }
        }
    }

    private func chipView(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text).font(.caption)
            Button { chips.removeAll { $0 == text } } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private var suggestionsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(placeholder, text: $newText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit { commit() }
                Button("Add") { commit() }
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let available = allSuggestions.filter { !chips.contains($0) }
            if !available.isEmpty {
                Divider()
                Text("Existing").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 4) {
                    ForEach(available, id: \.self) { s in
                        Button(s) { chips.append(s); showingPopover = false }
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(color.opacity(0.1))
                            .foregroundStyle(color)
                            .clipShape(Capsule())
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 190)
    }

    private func commit() {
        let t = newText.trimmingCharacters(in: .whitespaces).lowercased()
        if !t.isEmpty && !chips.contains(t) { chips.append(t) }
        newText = ""
        showingPopover = false
    }
}

// MARK: - Linked note picker

struct LinkedNotePickerSheet: View {
    let current: String
    var filterFolders: [String]? = nil   // nil = show all; set to restrict to specific subfolders
    let onSelect: (String) -> Void

    @Environment(NoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [(folder: String, path: String, name: String)] = []
    @State private var searchText = ""

    private let allFolders = ["Notes/Projects", "Notes/Places", "Notes/Horizons"]
    private var folders: [String] { filterFolders ?? allFolders }

    private var filtered: [(folder: String, path: String, name: String)] {
        searchText.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders, id: \.self) { folder in
                    let group = filtered.filter { $0.folder == folder }
                    if !group.isEmpty {
                        Section(folder.components(separatedBy: "/").last ?? folder) {
                            ForEach(group, id: \.path) { item in
                                Button {
                                    onSelect(item.path)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(item.name).foregroundStyle(.primary)
                                        Spacer()
                                        if item.path == current {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search notes")
            .navigationTitle("Link to Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .frame(minWidth: 320, minHeight: 400)
        .task { loadItems() }
    }

    private func loadItems() {
        var result: [(folder: String, path: String, name: String)] = []
        for folder in folders {
            let files = (try? noteStore.listFiles(in: folder)) ?? []
            for file in files {
                let path = "\(folder)/\(file)"
                let name = file.replacingOccurrences(of: ".md", with: "")
                result.append((folder: folder, path: path, name: name))
            }
        }
        items = result
    }
}

// MARK: - Person picker (documents)

struct DocPersonPickerSheet: View {
    let current: [String]
    let onSelect: (String) -> Void

    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [Person] {
        let sorted = notion.people.sorted { $0.name < $1.name }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.id) { person in
                Button {
                    onSelect(person.name)
                    dismiss()
                } label: {
                    HStack {
                        Text(person.name).foregroundStyle(.primary)
                        Spacer()
                        if current.contains(person.name) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "Search people")
            .navigationTitle("Add Person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .frame(minWidth: 280, minHeight: 380)
    }
}

// MARK: - PDF viewer (Mac)

struct PDFViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
