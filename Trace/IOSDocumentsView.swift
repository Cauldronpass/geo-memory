// iOSDocumentsView.swift
// Document browser for the Docs tab in NotesView.
// Reads the same iCloud Documents/ folder as the Mac.
// iOS-only — do not add to Mac target.

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Main view

struct iOSDocumentsView: View {

    @State private var store = iOSDocumentStore()
    @State private var selectedDoc: TraceMacDocument? = nil
    @State private var searchText = ""
    @State private var categoryFilter = "All"
    @State private var activeTag: String? = nil
    @State private var showingImport = false
    @State private var showingDetail = false
    @State private var docToDelete: TraceMacDocument? = nil

    private var categories: [String] {
        let standard = ["Inbox", "Project", "Place", "Trip"]
        let standardSet = Set(standard + ["Archive"])
        let extras = Array(Set(store.documents.map(\.category)).subtracting(standardSet)).sorted()
        return ["All"] + standard + extras
    }

    private var allTags: [String] {
        Array(Set(store.documents.flatMap(\.tags))).sorted()
    }

    private var filtered: [TraceMacDocument] {
        store.documents.filter { doc in
            let matchesSearch = searchText.isEmpty
                || doc.title.localizedCaseInsensitiveContains(searchText)
                || doc.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            let matchesCategory = categoryFilter == "All"
                || doc.category.localizedCaseInsensitiveCompare(categoryFilter) == .orderedSame
            let matchesTag = activeTag == nil || doc.tags.contains(activeTag!)
            let notArchived = doc.category != "Archive"
            return matchesSearch && matchesCategory && matchesTag && notArchived
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search documents", text: $searchText)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Category chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { cat in
                        Button(cat) { categoryFilter = cat }
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(categoryFilter == cat ? Color.accentColor : Color(.systemGray5))
                            .foregroundStyle(categoryFilter == cat ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 4)

            // Tag filter chips (when tags exist)
            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(allTags, id: \.self) { tag in
                            Button {
                                activeTag = activeTag == tag ? nil : tag
                            } label: {
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(activeTag == tag ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
                                    .foregroundStyle(activeTag == tag ? Color.accentColor : .secondary)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule().strokeBorder(
                                            activeTag == tag ? Color.accentColor.opacity(0.4) : Color.clear,
                                            lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 4)
            }

            Divider()

            // Document list
            if store.isLoading {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text(store.documents.isEmpty
                         ? "No documents yet.\nTap + to import."
                         : "No matches.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List {
                    ForEach(filtered) { doc in
                        Button {
                            selectedDoc = doc
                            showingDetail = true
                        } label: {
                            iOSDocListRow(doc: doc)
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                docToDelete = doc
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                archive(doc)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.orange)
                            Button {
                                selectedDoc = doc
                                showingDetail = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            await store.reload()
        }
        .sheet(isPresented: $showingImport) {
            AddDocumentView()
        }
        .confirmationDialog(
            "Delete \"\(docToDelete?.title ?? "document")\"?",
            isPresented: Binding(get: { docToDelete != nil }, set: { if !$0 { docToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let doc = docToDelete {
                    try? store.deleteDocument(doc)
                    Task { await store.reload() }
                }
                docToDelete = nil
            }
            Button("Cancel", role: .cancel) { docToDelete = nil }
        }
        .sheet(isPresented: $showingDetail) {
            if let doc = selectedDoc {
                iOSDocDetailSheet(doc: doc, store: store) {
                    Task { await store.reload() }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingImport = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .traceDocumentsReload)) { _ in
            Task { await store.reload() }
        }
    }

    private func archive(_ doc: TraceMacDocument) {
        Task {
            try? store.moveDocument(doc, to: "Archive")
            await store.reload()
        }
    }
}

// MARK: - List row

struct iOSDocListRow: View {
    let doc: TraceMacDocument

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: doc.isPDF ? "doc.fill" : doc.isImage ? "photo.fill" : "doc.text.fill")
                .font(.title3)
                .foregroundStyle(doc.isPDF ? .red : doc.isImage ? .blue : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(doc.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note = doc.linkedNote, !note.isEmpty {
                        let name = note.components(separatedBy: "/").last?
                            .replacingOccurrences(of: ".md", with: "") ?? note
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let date = doc.created {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(date, format: .dateTime.month(.abbreviated).year())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !doc.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(doc.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail sheet

struct iOSDocDetailSheet: View {
    let doc: TraceMacDocument
    let store: iOSDocumentStore
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var noteStore = NoteStore.shared
    @State private var title: String = ""
    @State private var tags: [String] = []
    @State private var description: String = ""
    @State private var userContext: String = ""
    @State private var linkedNote: String = ""
    @State private var people: [String] = []
    @State private var docDate: Date = Date()
    @State private var selectedCategory: String = "Inbox"
    @State private var isScanning = false
    @State private var scanError: String? = nil
    @State private var isSaving = false

    // Sheet flags
    @State private var showingPreview = false
    @State private var showingTagEditor = false
    @State private var showingDatePicker = false
    @State private var showingNotePicker = false
    @State private var showingPeopleEditor = false

    private let movableCategories = ["Inbox", "Project", "Place", "Trip", "Other", "Archive"]

    // Friendly display name for a linked note path
    private var linkedNoteName: String {
        guard !linkedNote.isEmpty else { return "" }
        return linkedNote.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".md", with: "") ?? linkedNote
    }

    var body: some View {
        NavigationStack {
            List {
                // Preview button
                Section {
                    Button {
                        showingPreview = true
                    } label: {
                        HStack {
                            Image(systemName: doc.isPDF ? "doc.fill" : doc.isImage ? "photo.fill" : "doc.text.fill")
                                .foregroundStyle(doc.isPDF ? .red : doc.isImage ? .blue : .secondary)
                            Text("Preview \(doc.isPDF ? "PDF" : "Image")")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }

                // Metadata
                Section("Metadata") {
                    // Title
                    HStack {
                        Text("Title").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        TextField("Document title", text: $title)
                    }

                    // Category / Move To
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(movableCategories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }

                    // Date (tappable)
                    Button {
                        showingDatePicker = true
                    } label: {
                        HStack {
                            Text("Date").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            Text(docDate, format: .dateTime.month(.wide).year())
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                        }
                    }
                    .foregroundStyle(.primary)

                    // Tags
                    Button {
                        showingTagEditor = true
                    } label: {
                        HStack(alignment: .center) {
                            Text("Tags").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            if tags.isEmpty {
                                Text("None").foregroundStyle(.tertiary)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 4) {
                                        ForEach(tags, id: \.self) { tag in
                                            Text(tag)
                                                .font(.caption2)
                                                .padding(.horizontal, 8).padding(.vertical, 3)
                                                .background(Color.accentColor.opacity(0.12))
                                                .foregroundStyle(Color.accentColor)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                        }
                    }
                    .foregroundStyle(.primary)

                    // Linked Note
                    Button {
                        showingNotePicker = true
                    } label: {
                        HStack {
                            Text("Note").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            if linkedNote.isEmpty {
                                Text("None").foregroundStyle(.tertiary)
                            } else {
                                Text(linkedNoteName)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                        }
                    }
                    .foregroundStyle(.primary)

                    // People
                    Button {
                        showingPeopleEditor = true
                    } label: {
                        HStack(alignment: .center) {
                            Text("People").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            if people.isEmpty {
                                Text("None").foregroundStyle(.tertiary)
                            } else {
                                Text(people.joined(separator: ", "))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                // AI section
                Section("AI") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Context hint").foregroundStyle(.secondary).font(.caption)
                        TextField("Optional: who, what, when…", text: $userContext, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description").foregroundStyle(.secondary).font(.caption)
                        if description.isEmpty {
                            Text("Tap ✦ to generate with AI")
                                .foregroundStyle(.tertiary)
                                .font(.subheadline)
                        } else {
                            Text(description)
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 2)

                    Button {
                        runScan()
                    } label: {
                        HStack {
                            if isScanning {
                                ProgressView().controlSize(.small)
                                Text("Scanning…")
                            } else {
                                Image(systemName: "sparkles")
                                Text(description.isEmpty ? "Scan with AI" : "Re-scan with AI")
                            }
                        }
                    }
                    .disabled(isScanning)

                    if let err = scanError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Document")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Scanning with AI…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: isScanning)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                }
            }
        }
        .onAppear { load() }
        .sheet(isPresented: $showingPreview) {
            iOSDocPreviewSheet(doc: doc)
        }
        .sheet(isPresented: $showingTagEditor) {
            iOSTagEditorSheet(tags: $tags)
        }
        .sheet(isPresented: $showingDatePicker) {
            iOSMonthYearSheet(date: $docDate)
        }
        .sheet(isPresented: $showingNotePicker) {
            iOSLinkedNotePickerSheet(current: linkedNote) { picked in
                linkedNote = picked
            }
        }
        .sheet(isPresented: $showingPeopleEditor) {
            iOSPeopleEditorSheet(people: $people)
        }
    }

    // MARK: - Load

    private func load() {
        title = doc.title
        tags = doc.tags
        description = doc.description
        selectedCategory = doc.category
        linkedNote = doc.linkedNote ?? ""
        people = doc.people
        docDate = doc.created ?? Date()

        if doc.tags.isEmpty && doc.description.isEmpty && (doc.isPDF || doc.isImage) {
            runScan()
        }
    }

    // MARK: - AI scan

    private func runScan() {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        let existingTags = Array(Set(store.documents.flatMap(\.tags))).sorted()
        let context = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let result = try await iOSDocumentScanService.scan(
                    doc: doc,
                    noteStore: noteStore,
                    existingTags: existingTags,
                    userContext: context
                )
                await MainActor.run {
                    tags = Array(Set(tags + result.tags)).sorted()
                    if !result.description.isEmpty { description = result.description }
                    if let suggestedTitle = result.title { title = suggestedTitle }
                    isScanning = false
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

    // MARK: - Save

    private func save() {
        isSaving = true
        if selectedCategory != doc.category {
            try? store.moveDocument(doc, to: selectedCategory)
        }
        let targetPath = selectedCategory != doc.category
            ? "Documents/\(selectedCategory)/\(doc.filename)"
            : doc.relativePath
        let ext = doc.fileExtension
        let targetDoc = TraceMacDocument(
            relativePath: targetPath,
            filename: doc.filename,
            category: selectedCategory,
            fileExtension: ext,
            title: title.trimmingCharacters(in: .whitespaces),
            tags: tags,
            created: docDate,
            linkedNote: linkedNote.isEmpty ? nil : linkedNote,
            people: people,
            description: description
        )
        try? store.saveSidecar(
            for: targetDoc,
            title: targetDoc.title,
            tags: targetDoc.tags,
            linkedNote: targetDoc.linkedNote,
            people: targetDoc.people,
            description: description,
            date: docDate
        )
        isSaving = false
        onSave()
        dismiss()
    }
}

// MARK: - Preview sheet

struct iOSDocPreviewSheet: View {
    let doc: TraceMacDocument
    @Environment(\.dismiss) private var dismiss
    @State private var noteStore = NoteStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if doc.isPDF, let url = noteStore.resolvedURL(for: doc.relativePath) {
                    iOSPDFView(url: url)
                } else if doc.isImage {
                    AsyncImagePreview(url: noteStore.resolvedURL(for: doc.relativePath))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc").font(.system(size: 48, weight: .thin)).foregroundStyle(.tertiary)
                        Text(doc.filename).font(.headline)
                        Text("Preview not available").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(doc.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Async image loader (iCloud-aware)

struct AsyncImagePreview: View {
    let url: URL?
    @State private var uiImage: UIImage? = nil
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading image…")
                    Spacer()
                }
            } else if let img = uiImage {
                ScrollView {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("Image not available").font(.headline)
                    Text("It may still be downloading from iCloud.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .task { await loadImage() }
    }

    private func loadImage() async {
        guard let url else { isLoading = false; return }
        // Trigger iCloud download if the file is a remote placeholder
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        // Read file data on a background thread to avoid blocking the main actor
        let loadedImage: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        uiImage = loadedImage
        isLoading = false
    }
}

// MARK: - PDF viewer

struct iOSPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - Tag editor sheet

struct iOSTagEditorSheet: View {
    @Binding var tags: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""

    var body: some View {
        NavigationStack {
            List {
                if !tags.isEmpty {
                    Section("Current Tags") {
                        ForEach(tags, id: \.self) { tag in
                            HStack {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.caption)
                                Text(tag)
                                Spacer()
                                Button {
                                    tags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Add Tag") {
                    HStack {
                        TextField("New tag…", text: $newTag)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .onSubmit { addTag() }
                        if !newTag.isEmpty {
                            Button("Add") { addTag() }
                                .fontWeight(.medium)
                        }
                    }
                }
            }
            .navigationTitle("Edit Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !t.isEmpty && !tags.contains(t) { tags.append(t) }
        newTag = ""
    }
}

// MARK: - Month/year date picker sheet

struct iOSMonthYearSheet: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMonth: Int
    @State private var selectedYear: Int

    private let months = Calendar.current.monthSymbols
    private let years: [Int] = Array((2000...2035))

    init(date: Binding<Date>) {
        self._date = date
        let cal = Calendar.current
        self._selectedMonth = State(initialValue: cal.component(.month, from: date.wrappedValue) - 1)
        self._selectedYear  = State(initialValue: cal.component(.year,  from: date.wrappedValue))
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("Month", selection: $selectedMonth) {
                    ForEach(0..<12, id: \.self) { idx in
                        Text(months[idx]).tag(idx)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("Year", selection: $selectedYear) {
                    ForEach(years, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("Select Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var comps = DateComponents()
                        comps.year  = selectedYear
                        comps.month = selectedMonth + 1
                        comps.day   = 1
                        if let newDate = Calendar.current.date(from: comps) {
                            date = newDate
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Linked note picker sheet

struct iOSLinkedNotePickerSheet: View {
    let current: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var noteStore = NoteStore.shared
    @State private var searchText = ""
    @State private var notes: [(path: String, name: String, folder: String)] = []

    private var filtered: [(path: String, name: String, folder: String)] {
        searchText.isEmpty ? notes : notes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Clear option
                if !current.isEmpty {
                    Section {
                        Button("Remove link") {
                            onSelect("")
                            dismiss()
                        }
                        .foregroundStyle(.red)
                    }
                }

                if filtered.isEmpty && !notes.isEmpty {
                    Section {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                } else {
                    let grouped = Dictionary(grouping: filtered, by: \.folder)
                    let folderOrder = ["Projects", "Places", "Trips"]
                    ForEach(folderOrder, id: \.self) { folder in
                        if let items = grouped[folder], !items.isEmpty {
                            Section(folder) {
                                ForEach(items, id: \.path) { note in
                                    Button {
                                        onSelect(note.path)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            Text(note.name)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            if note.path == current {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(Color.accentColor)
                                                    .font(.caption)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search notes")
            .navigationTitle("Link Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadNotes() }
        }
    }

    private func loadNotes() async {
        guard let base = noteStore.containerURL else { return }
        let scanFolders: [(subfolder: String, label: String)] = [
            ("Notes/Projects", "Projects"),
            ("Notes/Places",   "Places"),
            ("Trips",          "Trips")
        ]
        var result: [(path: String, name: String, folder: String)] = []

        for entry in scanFolders {
            let folderURL = base.appendingPathComponent(entry.subfolder)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }

            for fileURL in files where fileURL.pathExtension == "md" {
                let filename = fileURL.lastPathComponent
                let name = String(filename.dropLast(3))
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                let path = "\(entry.subfolder)/\(fileURL.lastPathComponent)"
                result.append((path: path, name: name, folder: entry.label))
            }
        }

        await MainActor.run {
            notes = result.sorted { $0.name < $1.name }
        }
    }
}

// MARK: - People editor sheet

struct iOSPeopleEditorSheet: View {
    @Binding var people: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var newPerson = ""

    var body: some View {
        NavigationStack {
            List {
                if !people.isEmpty {
                    Section("People") {
                        ForEach(people, id: \.self) { person in
                            HStack {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(person)
                                Spacer()
                                Button {
                                    people.removeAll { $0 == person }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Add Person") {
                    HStack {
                        TextField("Name…", text: $newPerson)
                            .autocorrectionDisabled()
                            .onSubmit { addPerson() }
                        if !newPerson.isEmpty {
                            Button("Add") { addPerson() }
                                .fontWeight(.medium)
                        }
                    }
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func addPerson() {
        let p = newPerson.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty && !people.contains(p) { people.append(p) }
        newPerson = ""
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let traceDocumentsReload = Notification.Name("trace.documentsReload")
}
