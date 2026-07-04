// TraceMacArchiveView.swift
// Tabbed view showing archived People, Documents, and Notes (Projects / Places / Horizons).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

struct TraceMacArchiveView: View {

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    enum ArchiveTab: String, CaseIterable {
        case people    = "People"
        case documents = "Documents"
        case notes     = "Notes"
    }

    @State private var selectedTab: ArchiveTab = .people
    @State private var docStore: TraceMacDocumentStore? = nil

    var body: some View {
        VStack(spacing: 0) {
            Picker("Archive section", selection: $selectedTab) {
                ForEach(ArchiveTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch selectedTab {
                case .people:
                    ArchivedPeopleView()
                        .environment(notionService)
                case .documents:
                    ArchivedDocumentsView(store: docStore)
                        .environment(noteStore)
                        .environment(notionService)
                case .notes:
                    ArchivedNotesView()
                        .environment(noteStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Archive")
        .task {
            if docStore == nil { docStore = TraceMacDocumentStore(noteStore: noteStore) }
            await docStore?.reload()
            if notionService.people.isEmpty { await notionService.fetchPeople() }
        }
    }
}

// MARK: - Archived People

private struct ArchivedPeopleView: View {

    @Environment(NotionService.self) private var notionService

    enum DetailTab: String, CaseIterable {
        case info     = "Info"
        case activity = "Activity"
        case log      = "Log"
        case notes    = "Notes"
    }

    @State private var selectedID: String? = nil
    @State private var detail: PersonDetail? = nil
    @State private var interactions: [Interaction] = []
    @State private var isLoading = false
    @State private var selectedTab: DetailTab = .info
    @State private var showDeleteConfirm = false
    @State private var searchText = ""

    private var archivedPeople: [Person] {
        notionService.people
            .filter { $0.isArchived }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 0) {
            // List
            VStack(spacing: 0) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                Divider()
                if archivedPeople.isEmpty {
                    Spacer()
                    Text("No archived people.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(archivedPeople, selection: $selectedID) { person in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name).font(.system(.body, weight: .medium))
                            if let rel = person.relationship {
                                Text(rel.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(person.id)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 200)

            Divider()

            // Full detail panel
            if isLoading {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let d = detail {
                VStack(spacing: 0) {
                    // Compact header
                    archivePersonHeader(d)
                    Divider()

                    // Tab picker
                    Picker("Tab", selection: $selectedTab) {
                        ForEach(DetailTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    Divider()

                    // Tab content — reusing the same structs as the main People section
                    switch selectedTab {
                    case .info:
                        MacInfoTab(
                            detail: d,
                            notionService: notionService,
                            onDeletePerson: { showDeleteConfirm = true }
                        )
                    case .activity:
                        MacActivityTab(
                            personID: d.id,
                            detail: d,
                            notionService: notionService
                        )
                    case .log:
                        MacLogTab(
                            detail: d,
                            interactions: $interactions,
                            notionService: notionService
                        )
                    case .notes:
                        NotesTab(personName: d.name)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .confirmationDialog("Delete \"\(d.name)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        Task {
                            try? await notionService.deletePerson(id: d.id)
                            detail = nil; selectedID = nil; interactions = []
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will archive the person in Notion.")
                }
            } else {
                Text("Select a person")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selectedID) { _, id in
            guard let id else { detail = nil; interactions = []; return }
            selectedTab = .info
            Task {
                isLoading = true
                async let d = notionService.fetchPersonDetail(id: id)
                async let ix = notionService.fetchInteractions(personID: id)
                detail = try? await d
                interactions = (try? await ix) ?? []
                isLoading = false
            }
        }
        // Auto-deselect when the person is unarchived and disappears from the list
        .onChange(of: archivedPeople.map(\.id)) { _, ids in
            if let id = selectedID, !ids.contains(id) {
                detail = nil; selectedID = nil; interactions = []
            }
        }
    }

    // Lightweight header — no photo upload, just display
    private func archivePersonHeader(_ d: PersonDetail) -> some View {
        HStack(spacing: 16) {
            // Initials circle
            let parts = d.name.split(separator: " ")
            let initials = parts.count >= 2
                ? String(parts[0].prefix(1)) + String(parts[1].prefix(1))
                : String(d.name.prefix(2)).uppercased()
            Circle()
                .fill(Color.purple.opacity(0.15))
                .frame(width: 52, height: 52)
                .overlay(
                    Text(initials)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.purple)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(.system(size: 18, weight: .semibold))
                if let rel = d.relationship {
                    Text(rel.capitalized).font(.subheadline).foregroundStyle(.secondary)
                }
                if let co = d.companyContext, !co.isEmpty {
                    Text(co).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Archived Documents

private struct ArchivedDocumentsView: View {

    let store: TraceMacDocumentStore?

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notion

    @State private var selectedDoc: TraceMacDocument? = nil
    @State private var searchText = ""

    private var archivedDocs: [TraceMacDocument] {
        (store?.documents ?? [])
            .filter { $0.category == "Archive" }
            .filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            // List
            VStack(spacing: 0) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                Divider()
                if archivedDocs.isEmpty {
                    Spacer()
                    Text("No archived documents.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(archivedDocs, selection: $selectedDoc) { doc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title).font(.system(.body, weight: .medium)).lineLimit(2)
                            Text(doc.fileExtension.uppercased())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(doc)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 220)

            Divider()

            // Preview + metadata panel
            if let doc = selectedDoc, let s = store {
                VStack(spacing: 0) {
                    DocPreviewView(doc: doc)
                        .environment(noteStore)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 260)

                    Divider()

                    ScrollView {
                        DocMetadataPanel(doc: doc, store: s) { movedDoc in
                            Task {
                                await s.reload()
                                selectedDoc = movedDoc.category != "Archive"
                                    ? nil
                                    : s.documents.first { $0.filename == movedDoc.filename }
                            }
                        }
                        .environment(noteStore)
                        .environment(notion)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a document")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Document preview helper (mirrors docViewer in TraceMacDocumentsView)

struct DocPreviewView: View {
    let doc: TraceMacDocument
    @Environment(NoteStore.self) private var noteStore

    var body: some View {
        if doc.isPDF, let url = noteStore.resolvedURL(for: doc.relativePath) {
            PDFViewRepresentable(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if doc.isImage,
                  let url = noteStore.resolvedURL(for: doc.relativePath),
                  let nsImage = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = noteStore.resolvedURL(for: doc.relativePath) {
            VStack(spacing: 12) {
                Image(systemName: "doc")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text(doc.filename).font(.callout)
                Button("Open in Default App") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Archived Notes

private struct ArchivedNotesView: View {

    @Environment(NoteStore.self) private var noteStore

    enum NoteSubTab: String, CaseIterable {
        case projects = "Projects"
        case places   = "Places"
        case horizons = "Horizons"
    }

    @State private var subTab: NoteSubTab = .projects
    @State private var selectedFilename: String? = nil
    @State private var searchText = ""
    @State private var isMoveError = false

    private var archiveFolder: String {
        switch subTab {
        case .projects: return "Notes/Archive/Projects"
        case .places:   return "Notes/Archive/Places"
        case .horizons: return "Notes/Archive/Horizons"
        }
    }

    private var destinationFolder: String {
        switch subTab {
        case .projects: return "Notes/Projects"
        case .places:   return "Notes/Places"
        case .horizons: return "Notes/Horizons"
        }
    }

    private var archivedFiles: [String] {
        let files = (try? noteStore.listFiles(in: archiveFolder)) ?? []
        return files
            .filter { $0.hasSuffix(".md") }
            .filter { searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText) }
            .sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $subTab) {
                ForEach(NoteSubTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 0) {
                // File list
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    Divider()
                    if archivedFiles.isEmpty {
                        Spacer()
                        Text("No archived \(subTab.rawValue.lowercased()).")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        List(archivedFiles, id: \.self, selection: $selectedFilename) { filename in
                            Text(filename.replacingOccurrences(of: ".md", with: ""))
                                .font(.system(.body, weight: .medium))
                                .padding(.vertical, 3)
                                .tag(filename)
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(width: 220)
                .onChange(of: subTab) { _, _ in selectedFilename = nil; searchText = "" }

                Divider()

                // Note editor + restore bar
                if let filename = selectedFilename {
                    let relativePath = "\(archiveFolder)/\(filename)"
                    VStack(spacing: 0) {
                        // Restore bar
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(filename.replacingOccurrences(of: ".md", with: ""))
                                    .font(.subheadline.weight(.medium))
                                Text("Archived \(subTab.rawValue.lowercased())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Move back to \(subTab.rawValue)") {
                                moveBack(filename: filename)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor))

                        Divider()

                        TraceMacNoteEditor(relativePath: relativePath)
                            .environment(noteStore)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Select a note")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func moveBack(filename: String) {
        let src = "\(archiveFolder)/\(filename)"
        let dst = "\(destinationFolder)/\(filename)"
        do {
            try noteStore.moveItem(from: src, to: dst)
            selectedFilename = nil
        } catch {
            isMoveError = true
        }
    }
}
