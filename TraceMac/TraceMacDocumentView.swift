// TraceMacDocumentsView.swift
// Browse, search, filter, and view documents stored in Trace's iCloud container.
// PDFs render inline via PDFKit. Images display inline. Tags via sidecar .md files.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - Main view

struct TraceMacDocumentsView: View {

    @Environment(NoteStore.self) private var noteStore

    @State private var store: TraceMacDocumentStore? = nil
    @State private var selectedDoc: TraceMacDocument? = nil
    @State private var searchText = ""
    @State private var activeTag: String? = nil
    @State private var activeProject: String? = nil
    @State private var filterYear: Int? = nil
    @State private var filterMonth: Int? = nil
    @State private var categoryFilter = "All"
    @State private var listCollapsed = false
    @State private var isDropTargeted = false

    // Filter popover visibility
    @State private var showingTagFilter = false
    @State private var showingProjectFilter = false
    @State private var showingDateFilter = false

    // Standard tabs always shown; any non-standard subfolder (e.g. "Receipts") gets its own tab.
    private var categories: [String] {
        let standard = ["Inbox", "Project", "Place", "Trip"]
        let standardSet = Set(standard + ["Archive"])
        let extras = Array(Set(store?.documents.map(\.category) ?? []).subtracting(standardSet)).sorted()
        return ["All"] + standard + extras
    }

    private var filtered: [TraceMacDocument] {
        guard let store else { return [] }
        let cal = Calendar.current
        return store.documents.filter { doc in
            let matchesSearch = searchText.isEmpty
                || doc.title.localizedCaseInsensitiveContains(searchText)
                || doc.filename.localizedCaseInsensitiveContains(searchText)
                || doc.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            let matchesTag = activeTag == nil || doc.tags.contains(activeTag!)
            let matchesCategory = categoryFilter == "All"
                || doc.category.localizedCaseInsensitiveCompare(categoryFilter) == .orderedSame
            let matchesProject = activeProject == nil || doc.linkedNote == activeProject
            let matchesYear = filterYear == nil || {
                guard let d = doc.created else { return false }
                return cal.component(.year, from: d) == filterYear!
            }()
            let matchesMonth = filterMonth == nil || {
                guard let d = doc.created else { return false }
                return cal.component(.month, from: d) == filterMonth!
            }()
            let notArchived = doc.category != "Archive"
            return matchesSearch && matchesTag && matchesCategory && matchesProject
                && matchesYear && matchesMonth && notArchived
        }
    }

    /// Unique (year, month) pairs across all docs, newest first.
    private var availableDates: [(year: Int, month: Int)] {
        guard let store else { return [] }
        let cal = Calendar.current
        var seen = Set<String>()
        var result: [(year: Int, month: Int)] = []
        for doc in store.documents {
            guard let d = doc.created else { continue }
            let y = cal.component(.year, from: d)
            let m = cal.component(.month, from: d)
            let key = "\(y)-\(m)"
            if !seen.contains(key) { seen.insert(key); result.append((y, m)) }
        }
        return result.sorted { $0.year != $1.year ? $0.year > $1.year : $0.month > $1.month }
    }

    private var availableYears: [Int] {
        Array(Set(availableDates.map(\.year))).sorted(by: >)
    }

    /// All unique project note paths used by docs in the Project category.
    private var projectList: [(path: String, name: String)] {
        guard let store else { return [] }
        var seen = Set<String>()
        var result: [(path: String, name: String)] = []
        for doc in store.documents where doc.category == "Project" {
            if let note = doc.linkedNote, !note.isEmpty, !seen.contains(note) {
                seen.insert(note)
                let name = note.components(separatedBy: "/").last?
                    .replacingOccurrences(of: ".md", with: "") ?? note
                result.append((path: note, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private var allTags: [String] {
        guard let store else { return [] }
        return Array(Set(store.documents.flatMap { $0.tags })).sorted()
    }

    // Human-readable label for the active date filter
    private var dateFilterLabel: String? {
        guard filterYear != nil || filterMonth != nil else { return nil }
        let monthName = filterMonth.map {
            DateFormatter().monthSymbols[$0 - 1]
        }
        switch (filterYear, monthName) {
        case (let y?, let m?): return "\(m) \(y)"
        case (let y?, nil):    return "\(y)"
        case (nil, let m?):    return m
        default:               return nil
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .selectDocument)) { note in
            guard let path = note.userInfo?["relativePath"] as? String,
                  note.userInfo?["internal"] as? Bool == true else { return }
            selectedDoc = store?.documents.first { $0.relativePath == path }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDocuments)) { _ in
            Task { await store?.reload() }
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

            // Category filter — scrollable so labels never wrap
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(categories, id: \.self) { cat in
                        Button(cat) { categoryFilter = cat; if cat != "Project" { activeProject = nil } }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .fixedSize()                          // never truncate or wrap
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                categoryFilter == cat
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .foregroundStyle(
                                categoryFilter == cat ? Color.accentColor : Color.secondary
                            )
                            .overlay(
                                // Underline indicator for selected tab
                                Rectangle()
                                    .frame(height: 2)
                                    .foregroundStyle(categoryFilter == cat ? Color.accentColor : Color.clear)
                                    .padding(.horizontal, 6),
                                alignment: .bottom
                            )
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.bottom, 2)

            Divider()

            // Filter bar — Tag, Project (when in Project tab), Date
            filterBar
            Divider()

            // Document list + drop zone
            ZStack {
                if let store, store.isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Loading…")
                        Spacer()
                    }
                } else if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 32, weight: .thin))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                        Text(store?.documents.isEmpty == true
                             ? "No documents yet.\nDrag files here or use Import."
                             : "No matches.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                Group {
                    if isDropTargeted {
                        ZStack {
                            Color.accentColor.opacity(0.08)
                            VStack(spacing: 10) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 36, weight: .thin))
                                    .foregroundStyle(Color.accentColor)
                                Text("Drop to import")
                                    .font(.subheadline).fontWeight(.medium)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(3)
                        )
                        .allowsHitTesting(false)
                    }
                }
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
        .frame(width: 240)
    }

    // MARK: - Drop handler

    @discardableResult
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard error == nil,
                      let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue,
                      !url.lastPathComponent.hasPrefix(".") else { return }
                let ext = url.pathExtension.lowercased()
                guard !["txt", "md", "markdown", "text"].contains(ext) else { return }
                do {
                    try store?.importDocument(from: url)
                    Task { @MainActor in
                        await store?.reload()
                        categoryFilter = "All"
                    }
                } catch { }
            }
            handled = true
        }
        return handled
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Tag filter pill
                filterPill(
                    icon: "tag",
                    label: activeTag ?? "Tags",
                    isActive: activeTag != nil,
                    onClear: { activeTag = nil }
                ) {
                    showingTagFilter = true
                }
                .popover(isPresented: $showingTagFilter, arrowEdge: .bottom) {
                    DocFilterPickerPopover(
                        title: "Filter by Tag",
                        items: allTags,
                        selected: activeTag,
                        onSelect: { activeTag = $0; showingTagFilter = false }
                    )
                }

                // Project filter pill — only when in Project category
                if categoryFilter == "Project" {
                    filterPill(
                        icon: "folder",
                        label: activeProject.flatMap { p in
                            projectList.first { $0.path == p }?.name
                        } ?? "Project",
                        isActive: activeProject != nil,
                        onClear: { activeProject = nil }
                    ) {
                        showingProjectFilter = true
                    }
                    .popover(isPresented: $showingProjectFilter, arrowEdge: .bottom) {
                        DocFilterPickerPopover(
                            title: "Filter by Project",
                            items: projectList.map(\.name),
                            selected: activeProject.flatMap { p in projectList.first { $0.path == p }?.name },
                            onSelect: { name in
                                activeProject = projectList.first { $0.name == name }?.path
                                showingProjectFilter = false
                            }
                        )
                    }
                }

                // Date filter pill
                filterPill(
                    icon: "calendar",
                    label: dateFilterLabel ?? "Date",
                    isActive: filterYear != nil || filterMonth != nil,
                    onClear: { filterYear = nil; filterMonth = nil }
                ) {
                    showingDateFilter = true
                }
                .popover(isPresented: $showingDateFilter, arrowEdge: .bottom) {
                    DocDateFilterPopover(
                        availableYears: availableYears,
                        availableDates: availableDates,
                        selectedYear: $filterYear,
                        selectedMonth: $filterMonth
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    /// A compact pill button with optional clear (×) badge.
    private func filterPill(
        icon: String,
        label: String,
        isActive: Bool,
        onClear: @escaping () -> Void,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 3) {
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 9))
                    Text(label).font(.caption).lineLimit(1)
                    if !isActive {
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.09))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if isActive {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
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

    @State private var docDetailTab: DocDetailTab = .preview

    @ViewBuilder
    private var rightColumn: some View {
        if let doc = selectedDoc {
            VStack(spacing: 0) {
                // Tab bar
                HStack(spacing: 0) {
                    ForEach(DocDetailTab.allCases, id: \.self) { tab in
                        Button {
                            docDetailTab = tab
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.icon).font(.caption)
                                Text(tab.label).font(.caption)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(docDetailTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear)
                            .foregroundStyle(docDetailTab == tab
                                ? Color.accentColor
                                : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()

                // Tab content
                switch docDetailTab {
                case .preview:
                    VStack(spacing: 0) {
                        docViewer(for: doc)
                        Divider()
                        DocMetadataPanel(doc: doc, store: store!) { movedDoc in
                            Task {
                                await store?.reload()
                                selectedDoc = store?.documents.first { $0.filename == movedDoc.filename }
                            }
                        }
                    }
                case .note:
                    DocNotePanel(doc: doc, store: store!)
                        .id(doc.id)
                }
            }
            .onChange(of: selectedDoc) { _, _ in docDetailTab = .preview }
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

    enum DocDetailTab: CaseIterable {
        case preview, note
        var label: String { switch self { case .preview: "Preview"; case .note: "Note" } }
        var icon: String  { switch self { case .preview: "doc.fill"; case .note: "note.text" } }
    }

    @ViewBuilder
    private func docViewer(for doc: TraceMacDocument) -> some View {
        if doc.isPDF, let url = noteStore.resolvedURL(for: doc.relativePath) {
            PDFViewRepresentable(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if doc.isImage, let url = noteStore.resolvedURL(for: doc.relativePath),
                  let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .padding(16)
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
                // For Project/Place/Trip, show the linked note name as a subtitle
                if let note = doc.linkedNote, !note.isEmpty {
                    let noteName = note.components(separatedBy: "/").last?
                        .replacingOccurrences(of: ".md", with: "") ?? note
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(noteName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let date = doc.created {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(date, format: .dateTime.month(.abbreviated).year())
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

// MARK: - Note tab panel

struct DocNotePanel: View {
    let doc: TraceMacDocument
    let store: TraceMacDocumentStore

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notion

    @State private var linkedNote: String = ""
    @State private var showingNotePicker = false
    @State private var showingHub = false

    var body: some View {
        Group {
            noteContent
        }
        .onAppear { load() }
        .onChange(of: doc.id) { _, _ in load() }
    }

    @ViewBuilder
    private var noteContent: some View {
        if linkedNote.isEmpty {
            // Empty state — no project note linked yet
            VStack(spacing: 16) {
                Image(systemName: "note.text.badge.plus")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("No project note linked")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Link this document to a project to start writing notes that are shared across all documents in that project.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                HStack(spacing: 12) {
                    Button("Link to project…") {
                        showingNotePicker = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showingNotePicker) {
                LinkedNotePickerSheet(
                    current: linkedNote,
                    filterFolders: ["Notes/Projects"],
                    allowCreate: true
                ) { picked in
                    linkedNote = picked
                    saveLinkedNote(picked)
                }
                .environment(noteStore)
            }
        } else {
            // Note is linked — show editor + project header
            VStack(spacing: 0) {
                // Project name header bar
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    // Tappable project name → opens hub view
                    Button {
                        showingHub = true
                    } label: {
                        Text(noteName(from: linkedNote))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // Hub button — "see everything in this project"
                    Button {
                        showingHub = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open project hub")
                    Button {
                        showingNotePicker = true
                    } label: {
                        Text("Change")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.06))

                Divider()

                TraceMacNoteEditor(relativePath: linkedNote)
            }
            .sheet(isPresented: $showingHub) {
                MacProjectNoteDetailView(notePath: linkedNote, store: store)
                    .environment(noteStore)
                    .environment(notion)
            }
            .sheet(isPresented: $showingNotePicker) {
                LinkedNotePickerSheet(
                    current: linkedNote,
                    filterFolders: ["Notes/Projects"],
                    allowCreate: true
                ) { picked in
                    linkedNote = picked
                    saveLinkedNote(picked)
                }
                .environment(noteStore)
            }
        }
    }

    private func noteName(from path: String) -> String {
        path.components(separatedBy: "/").last?.replacingOccurrences(of: ".md", with: "") ?? path
    }

    private func saveLinkedNote(_ path: String) {
        try? store.saveSidecar(
            for: doc,
            title: doc.title,
            tags: doc.tags,
            linkedNote: path.isEmpty ? nil : path,
            people: doc.people,
            description: doc.description
        )
    }

    private func load() {
        linkedNote = doc.linkedNote ?? ""
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
    @State private var description: String = ""
    @State private var docDate: Date = Date()
    @State private var showingDatePicker = false
    @State private var isSaving = false
    @State private var isMoving = false
    @State private var isScanning = false
    @State private var scanError: String? = nil
    @State private var userContext: String = ""
    @State private var isExpanded = true
    @State private var showingTagPopover = false
    @State private var newTagText = ""
    @State private var showingPeoplePicker = false
    @State private var showingProjectMover = false
    @State private var showingPlaceMover = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        DisclosureGroup("Metadata", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                categoryRow
                titleRow
                dateRow
                tagsRow
                peopleRow
                descriptionRow
                if let err = scanError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
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
                if doc.category != "Trip"    { Button("Move to Trip")       { move(to: "Trip") } }
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

    // MARK: - Date

    private var dateRow: some View {
        HStack(spacing: 0) {
            fieldLabel("Date")
            Button {
                showingDatePicker = true
            } label: {
                Text(docDate, format: .dateTime.month(.abbreviated).year())
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .foregroundStyle(.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
                MonthYearPickerPopover(selected: $docDate) {
                    showingDatePicker = false
                }
            }
            Spacer()
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

    // MARK: - Description + AI scan

    private var descriptionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Context hint field — user types optional context before hitting sparkle
            HStack(alignment: .center, spacing: 0) {
                fieldLabel("Context")
                ZStack(alignment: .leading) {
                    TextField("", text: $userContext)
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if userContext.isEmpty {
                        Text("Optional hint for AI (who, what, when…)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                    }
                }
            }

            // Description + sparkle button
            HStack(alignment: .top, spacing: 0) {
                fieldLabel("About").padding(.top, 6)
                ZStack(alignment: .topTrailing) {
                    TextEditor(text: $description)
                        .font(.caption)
                        .frame(minHeight: 50, maxHeight: 90)
                        .scrollContentBackground(.hidden)
                        .background(Color.secondary.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            Group {
                                if description.isEmpty {
                                    Text("AI will fill this in, or type a note…")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(6)
                                        .allowsHitTesting(false)
                                }
                            },
                            alignment: .topLeading
                        )
                    // AI sparkle button — top-right corner of the text editor
                    Button {
                        runScan()
                    } label: {
                        Group {
                            if isScanning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Circle())
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .padding(4)
                    .help("Auto-fill tags and description using AI")
                }
            }
        }
    }

    private func runScan() {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        let currentTags = existingTags
        let context = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let result = try await DocumentScanService.scan(
                    doc: doc,
                    noteStore: noteStore,
                    existingTags: currentTags,
                    userContext: context
                )
                await MainActor.run {
                    // Merge new tags — preserve what's already selected, append new
                    let merged = Array(Set(tags + result.tags)).sorted()
                    tags = merged
                    if !result.description.isEmpty {
                        description = result.description
                    }
                    // Apply suggested title only if Claude flagged the filename as nonsensical
                    if let suggestedTitle = result.title {
                        title = suggestedTitle
                    }
                    isScanning = false
                    // Auto-save so the list reflects the AI-generated title immediately
                    save()
                }
            } catch {
                await MainActor.run {
                    scanError = error.localizedDescription
                    isScanning = false
                }
            }
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
        description = doc.description
        docDate = doc.created ?? Date()

        // Auto-scan if this looks like a freshly imported doc with no metadata yet
        let noMetadata = doc.tags.isEmpty && doc.description.isEmpty
        let scannable = doc.isPDF || doc.isImage
        if noMetadata && scannable && !isScanning {
            runScan()
        }
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
                created: docDate,
                linkedNote: linkedNote.isEmpty ? nil : linkedNote,
                people: people,
                description: description
            )
            try? store.saveSidecar(
                for: movedDoc,
                title: movedDoc.title,
                tags: movedDoc.tags,
                linkedNote: movedDoc.linkedNote,
                people: movedDoc.people,
                description: movedDoc.description,
                date: docDate
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
            people: people,
            description: description,
            date: docDate
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
    var allowCreate: Bool = false         // when true, show "New project…" creation row
    let onSelect: (String) -> Void

    @Environment(NoteStore.self) private var noteStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [(folder: String, path: String, name: String)] = []
    @State private var searchText = ""
    @State private var newProjectName = ""
    @State private var isCreating = false
    @State private var createError: String? = nil

    private let allFolders = ["Notes/Projects", "Notes/Places", "Notes/Horizons"]
    private var folders: [String] { filterFolders ?? allFolders }

    // Folder shown in the "New project…" row — first filtered folder, or "Notes/Projects"
    private var createFolder: String { folders.first ?? "Notes/Projects" }

    private var filtered: [(folder: String, path: String, name: String)] {
        searchText.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Create new row — shown at top when allowCreate and showing a single folder (Projects)
                if allowCreate && folders.count == 1 {
                    Section("New project") {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(.body)
                            TextField("Project name…", text: $newProjectName)
                                .textFieldStyle(.plain)
                                .onSubmit { createAndSelect() }
                            if isCreating {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button("Create") { createAndSelect() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        if let err = createError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                // Existing notes
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

    private func createAndSelect() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        createError = nil
        let filename = name.replacingOccurrences(of: "/", with: "-") + ".md"
        let path = "\(createFolder)/\(filename)"
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
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
        do {
            try noteStore.writeFile(path, content: content)
            onSelect(path)
            dismiss()
        } catch {
            createError = "Could not create note: \(error.localizedDescription)"
            isCreating = false
        }
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

// MARK: - Project hub tab enum (shared)

enum ProjectHubTab: CaseIterable {
    case documents, people, places
    var label: String {
        switch self { case .documents: "Documents"; case .people: "People"; case .places: "Places" }
    }
    var icon: String {
        switch self {
        case .documents: "doc.fill"
        case .people:    "person.2.fill"
        case .places:    "mappin.circle.fill"
        }
    }
}

// MARK: - Project hub entity panel (reusable right-side tab column)

/// The Documents / People / Places tab column used in both the inline Projects view
/// and the MacProjectNoteDetailView sheet.
struct MacProjectHubSidebar: View {
    let notePath: String
    let store: TraceMacDocumentStore

    @Environment(NoteStore.self) private var noteStore

    @State private var selectedTab: ProjectHubTab = .documents
    @State private var linkedDocs: [TraceMacDocument] = []
    @State private var frontmatterPeople: [String] = []
    @State private var frontmatterPlaces: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(ProjectHubTab.allCases, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon).font(.caption)
                            Text(tab.label).font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab
                            ? Color.accentColor.opacity(0.12) : Color.clear)
                        .foregroundStyle(selectedTab == tab
                            ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .documents:
                        if linkedDocs.isEmpty {
                            hubEmptyState("No documents linked to this project yet.",
                                          icon: "doc.badge.plus")
                        } else {
                            ForEach(linkedDocs) { doc in
                                hubDocRow(doc)
                                Divider().padding(.leading, 36)
                            }
                        }
                    case .people:
                        if frontmatterPeople.isEmpty {
                            hubEmptyState("No people added to this project.",
                                          icon: "person.badge.plus")
                        } else {
                            ForEach(frontmatterPeople, id: \.self) { name in
                                hubPersonRow(name)
                                Divider().padding(.leading, 36)
                            }
                        }
                    case .places:
                        if frontmatterPlaces.isEmpty {
                            hubEmptyState("No places linked to this project.",
                                          icon: "mappin.badge.plus")
                        } else {
                            ForEach(frontmatterPlaces, id: \.self) { name in
                                hubPlaceRow(name)
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { load() }
        .onChange(of: notePath) { _, _ in load() }
    }

    // MARK: - Row helpers

    private func hubDocRow(_ doc: TraceMacDocument) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .selectDocument, object: nil,
                userInfo: ["relativePath": doc.relativePath]
            )
        } label: {
            HStack(spacing: 10) {
                Image(systemName: doc.isPDF ? "doc.fill" : doc.isImage ? "photo" : "doc.text")
                    .foregroundStyle(doc.isPDF ? .red : doc.isImage ? .blue : .secondary)
                    .font(.body).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title).font(.body).lineLimit(1).foregroundStyle(.primary)
                    if let date = doc.created {
                        Text(date, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hubPersonRow(_ name: String) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .openWikilink, object: nil,
                userInfo: ["name": name]
            )
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.purple.opacity(0.15)).frame(width: 28, height: 28)
                    Text(name.prefix(1).uppercased())
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.purple)
                }
                Text(name).font(.body).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hubPlaceRow(_ name: String) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .openWikilink, object: nil,
                userInfo: ["name": name]
            )
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.orange).font(.body).frame(width: 20)
                Text(name).font(.body).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hubEmptyState(_ message: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .thin)).foregroundStyle(.tertiary)
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 180)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    // MARK: - Load

    private func load() {
        linkedDocs = store.documents.filter { $0.linkedNote == notePath }
        parseFrontmatter()
    }

    private func parseFrontmatter() {
        guard let raw = try? noteStore.readFile(notePath), !raw.isEmpty else { return }
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return }
        var yamlLines: [String] = []
        var inYAML = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if inYAML { break } else { inYAML = true; continue }
            }
            if inYAML { yamlLines.append(line) }
        }
        frontmatterPeople = parseYAMLArray(key: "people", from: yamlLines)
        frontmatterPlaces = parseYAMLArray(key: "places", from: yamlLines)
    }

    private func parseYAMLArray(key: String, from lines: [String]) -> [String] {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let rest = trimmed.dropFirst("\(key):".count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("[") {
                let inner = rest.dropFirst().dropLast()
                return inner.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces)
                              .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    .filter { !$0.isEmpty }
            }
            var values: [String] = []
            var j = i + 1
            while j < lines.count {
                let next = lines[j].trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("- ") {
                    values.append(String(next.dropFirst(2))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
                } else if next.contains(":") || next == "---" { break }
                j += 1
            }
            return values
        }
        return []
    }
}

// MARK: - Project note hub sheet

/// Sheet wrapper — opened from DocNotePanel header. Fixed size, has dismiss button.
struct MacProjectNoteDetailView: View {
    let notePath: String
    let store: TraceMacDocumentStore

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss)          private var dismiss

    private var projectName: String {
        notePath.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".md", with: "") ?? notePath
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left — editor
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text(projectName).font(.headline)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary).font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.accentColor.opacity(0.06))
                Divider()
                TraceMacNoteEditor(relativePath: notePath)
            }
            .frame(minWidth: 420)

            Divider()

            // Right — hub sidebar
            MacProjectHubSidebar(notePath: notePath, store: store)
                .frame(width: 280)
        }
        .frame(width: 760, height: 560)
    }
}

// MARK: - Month/year picker

struct MonthYearPickerPopover: View {
    @Binding var selected: Date
    let onPick: () -> Void

    @State private var displayYear: Int = Calendar.current.component(.year, from: Date())

    private let months = Calendar.current.shortMonthSymbols   // Jan–Dec

    var body: some View {
        VStack(spacing: 12) {
            // Year navigation
            HStack {
                Button { displayYear -= 1 } label: {
                    Image(systemName: "chevron.left").font(.caption)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(String(displayYear))
                    .font(.caption).fontWeight(.semibold)
                Spacer()
                Button { displayYear += 1 } label: {
                    Image(systemName: "chevron.right").font(.caption)
                }
                .buttonStyle(.plain)
            }

            // Month grid — 3 columns × 4 rows
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(0..<12, id: \.self) { idx in
                    let isSelected = selectedMonth == idx + 1 && selectedYear == displayYear
                    Button(months[idx]) {
                        // Set to 1st of chosen month/year, preserve day if in same month
                        var comps = DateComponents()
                        comps.year = displayYear
                        comps.month = idx + 1
                        comps.day = 1
                        if let d = Calendar.current.date(from: comps) {
                            selected = d
                        }
                        onPick()
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 200)
        .onAppear {
            displayYear = Calendar.current.component(.year, from: selected)
        }
    }

    private var selectedMonth: Int { Calendar.current.component(.month, from: selected) }
    private var selectedYear:  Int { Calendar.current.component(.year,  from: selected) }
}

// MARK: - Filter popovers

/// Generic searchable single-select list popover used for Tag and Project filters.
struct DocFilterPickerPopover: View {
    let title: String
    let items: [String]
    let selected: String?
    let onSelect: (String) -> Void

    @State private var search = ""

    private var filtered: [String] {
        search.isEmpty ? items : items.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            TextField("Search…", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack {
                                Text(item)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if item == selected {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 220)
    }
}

/// Date filter popover — pick a year, a month, or both.
struct DocDateFilterPopover: View {
    let availableYears: [Int]
    let availableDates: [(year: Int, month: Int)]
    @Binding var selectedYear: Int?
    @Binding var selectedMonth: Int?

    private let monthNames = Calendar.current.shortMonthSymbols   // Jan–Dec

    /// Months available given the selected year (or all months if no year selected).
    private var availableMonths: [Int] {
        let filtered = selectedYear == nil
            ? availableDates
            : availableDates.filter { $0.year == selectedYear }
        return Array(Set(filtered.map(\.month))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Date Filter")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                if selectedYear != nil || selectedMonth != nil {
                    Button("Clear") { selectedYear = nil; selectedMonth = nil }
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)
                }
            }

            // Year picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Year").font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    ForEach(availableYears, id: \.self) { year in
                        Button(String(year)) {
                            if selectedYear == year { selectedYear = nil }
                            else { selectedYear = year; selectedMonth = nil }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selectedYear == year ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.09))
                        .foregroundStyle(selectedYear == year ? Color.accentColor : Color.secondary)
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                    }
                }
            }

            // Month picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Month").font(.caption2).foregroundStyle(.tertiary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                    ForEach(availableMonths, id: \.self) { month in
                        Button(monthNames[month - 1]) {
                            selectedMonth = selectedMonth == month ? nil : month
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selectedMonth == month ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.09))
                        .foregroundStyle(selectedMonth == month ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 230)
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
