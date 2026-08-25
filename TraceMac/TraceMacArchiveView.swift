// TraceMacArchiveView.swift
// Tabbed view showing archived People and Notes (Projects / Places / Horizons).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

struct TraceMacArchiveView: View {

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    /// Session 63 (2026-08-01): the Documents tab is gone.
    ///
    /// David: *"I don't use it. It's a relic."*
    ///
    /// It predated Endeavors and Kit. Documents are filed by `endeavor`,
    /// `linked_note`, `tags` and `pinned` now, and iOS has no archive concept
    /// for documents at all — an old one simply falls down the list. The tab
    /// read `Documents/Archive/`, a folder that does not exist in the container
    /// and that only TraceMac could ever have created, through a "Move to
    /// Archive" menu item removed in the same change.
    ///
    /// People and Notes archiving stay, and are unrelated: person archiving is
    /// a Notion `isArchived` flag with a live toggle in the People view, and
    /// note archiving is the `Notes/Projects/Archive` subfolder built for
    /// Dayflow.
    enum ArchiveTab: String, CaseIterable {
        case people = "People"
        case notes  = "Notes"
    }

    @State private var selectedTab: ArchiveTab = .people

    var body: some View {
        VStack(spacing: 0) {
            // Was h20 / v10 with the picker's "Archive section" label left
            // visible, against h16 / v8 and `.labelsHidden()` on every other
            // section — the top-left of this screen sat four points right and
            // two points down from the one before it, with a stray label in it.
            MacSectionHeader("Archive") {
                MacTabStrip(options: ArchiveTab.allCases,
                            selection: $selectedTab) { $0.rawValue }
            }

            Group {
                switch selectedTab {
                case .people:
                    ArchivedPeopleView()
                        .environment(notionService)
                case .notes:
                    ArchivedNotesView()
                        .environment(noteStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // No `.navigationTitle`. This was the only section that set one, so the
        // window renamed itself from "TraceMac" to "Archive" on this screen and
        // nowhere else — the section name belongs in the header row now, where
        // every section puts it.
        .task {
            // The TraceMacDocumentStore that used to be built here went with the
            // Documents tab. Neither remaining tab reads documents, so this
            // screen no longer scans the container on appear.
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
    /// Remembered across launches, and shared with every other resizable
    /// column through `MacColumnResizer`.
    @AppStorage("tracemac.column.archive.people") private var peopleWidth: Double = 200
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
            .frame(width: peopleWidth)
            MacColumnResizer(width: $peopleWidth)

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
                        // Session 73. The second `MacInfoTab` call site, and
                        // the one that broke the build when the People view's
                        // copy gained this parameter — Archive reuses the same
                        // struct, which is exactly why it was worth reusing and
                        // exactly why a grep of one file was not an
                        // exhaustiveness check.
                        MacInfoTab(
                            detail: d,
                            notionService: notionService,
                            onDeletePerson: { showDeleteConfirm = true },
                            onTagsChanged: { await reloadDetail(id: d.id) }
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

    /// Re-read one person after a tag write.
    ///
    /// Written out here rather than shared with `TraceMacPeopleView`'s copy: the
    /// two views own their own `detail` state and neither can see the other's.
    /// Lifting it would mean a store, which is a larger change than this bug
    /// deserves — but the duplication is real and both copies must clear the
    /// cache, so it is named here rather than left to be discovered.
    private func reloadDetail(id: String) async {
        notionService.personDetailCache.removeValue(forKey: id)
        detail = try? await notionService.fetchPersonDetail(id: id)
    }

    // Lightweight header — no photo upload, just display
    private func archivePersonHeader(_ d: PersonDetail) -> some View {
        HStack(spacing: 16) {
            MacAvatar(name: d.name, size: .header, tint: .purple)

            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(MacType.title)
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
    /// Remembered across launches, and shared with every other resizable
    /// column through `MacColumnResizer`.
    @AppStorage("tracemac.column.archive.notes") private var notesWidth: Double = 220
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
                .frame(width: notesWidth)
                .onChange(of: subTab) { _, _ in selectedFilename = nil; searchText = "" }
                MacColumnResizer(width: $notesWidth)

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
