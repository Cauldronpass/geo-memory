// TraceMacContentView.swift
// Root NavigationSplitView shell for Trace Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

// MARK: - Sidebar sections

enum MacSection: String, CaseIterable, Identifiable {
    case daily     = "Daily"
    case projects  = "Projects"
    case places    = "Places"
    case people    = "People"
    case documents = "Documents"
    case inbox     = "Inbox"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .daily:     return "calendar"
        case .projects:  return "folder"
        case .places:    return "mappin"
        case .people:    return "person.2"
        case .documents: return "doc.richtext"
        case .inbox:     return "tray"
        }
    }
}

// MARK: - Root view

struct TraceMacContentView: View {

    @Environment(NoteStore.self)    private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var selectedSection: MacSection? = .daily

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            // Kick off Notion fetch as soon as the window appears.
            async let p: () = notionService.fetchPlaces()
            async let pe: () = notionService.fetchPeople()
            _ = await (p, pe)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(MacSection.allCases, selection: $selectedSection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .tag(section)
        }
        .listStyle(.sidebar)
        .navigationTitle("Trace")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }

    // MARK: - Detail placeholder

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .daily:
            TraceMacJournalView(section: .daily)
                .environment(noteStore)
                .environment(notionService)
        case .projects:
            TraceMacJournalView(section: .projects)
                .environment(noteStore)
                .environment(notionService)
        case .places:
            TraceMacJournalView(section: .places)
                .environment(noteStore)
                .environment(notionService)
        case .people:
            placeholderView(icon: "person.2",    title: "People",       note: "Coming in M4")
        case .documents:
            placeholderView(icon: "doc.richtext", title: "Documents",   note: "Coming in M3")
        case .inbox:
            placeholderView(icon: "tray",        title: "Inbox",        note: "Coming in M6")
        case nil:
            placeholderView(icon: "sidebar.left", title: "Trace",       note: "Select a section")
        }
    }

    private func placeholderView(icon: String, title: String, note: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2)
                .fontWeight(.medium)
            Text(note)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // iCloud connection status
            if !noteStore.hasAccess {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to iCloud…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
