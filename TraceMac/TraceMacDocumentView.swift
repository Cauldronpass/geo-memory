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
                || (categoryFilter == "Other" && !["Inbox","Project","Place"].contains(doc.category))
            return matchesSearch && matchesTag && matchesCategory
        }
    }

    private var allTags: [String] {
        guard let store else { return [] }
        let tags = store.documents.flatMap { $0.tags }
        return Array(Set(tags)).sorted()
    }

    var body: some View {
        HSplitView {
            leftColumn
            rightColumn
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
            }
        }
        .frame(minWidth: 220, maxWidth: 300)
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
                DocMetadataPanel(doc: doc, store: store!) { updated in
                    // Refresh the selected doc after sidecar save
                    Task { await store?.reload() }
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

    @State private var title: String = ""
    @State private var tagsText: String = ""
    @State private var linkedNote: String = ""
    @State private var isSaving = false
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Metadata", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Title").frame(width: 70, alignment: .trailing).foregroundStyle(.secondary).font(.caption)
                    TextField("Document title", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Tags").frame(width: 70, alignment: .trailing).foregroundStyle(.secondary).font(.caption)
                    TextField("comma, separated, tags", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Linked note").frame(width: 70, alignment: .trailing).foregroundStyle(.secondary).font(.caption)
                    TextField("Notes/Projects/...", text: $linkedNote)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Spacer()
                    Button("Save Metadata") { saveSidecar() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isSaving)
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { loadFromDoc() }
        .onChange(of: doc.id) { _, _ in loadFromDoc() }
    }

    private func loadFromDoc() {
        title = doc.title
        tagsText = doc.tags.joined(separator: ", ")
        linkedNote = doc.linkedNote ?? ""
    }

    private func saveSidecar() {
        isSaving = true
        let tags = tagsText.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let note = linkedNote.trimmingCharacters(in: .whitespaces)
        try? store.saveSidecar(
            for: doc,
            title: title.trimmingCharacters(in: .whitespaces),
            tags: tags,
            linkedNote: note.isEmpty ? nil : note
        )
        isSaving = false
        onSave(doc)
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
