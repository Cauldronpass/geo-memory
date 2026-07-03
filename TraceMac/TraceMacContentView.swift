// TraceMacContentView.swift
// Root NavigationSplitView shell for Trace Mac.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

// MARK: - Sidebar sections

enum MacSection: String, CaseIterable, Identifiable {
    case daily     = "Daily"
    case projects  = "Projects"
    case places    = "Places"
    case horizons  = "Horizons"
    case people    = "People"
    case documents = "Documents"
    case inbox     = "Inbox"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .daily:     return "book.pages"
        case .projects:  return "folder"
        case .places:    return "mappin"
        case .horizons:  return "calendar.badge.clock"
        case .people:    return "person.2"
        case .documents: return "doc.richtext"
        case .inbox:     return "tray"
        }
    }
}

// MARK: - Root view

struct TraceMacContentView: View {

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @Binding var selectedSection: MacSection?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            async let p: ()  = notionService.fetchPlaces()
            async let pe: () = notionService.fetchPeople()
            _ = await (p, pe)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section("Journal") {
                ForEach([MacSection.daily, .projects, .places, .horizons]) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            Section("People") {
                Label(MacSection.people.rawValue, systemImage: MacSection.people.icon)
                    .tag(MacSection.people)
            }
            Section("Library") {
                Label(MacSection.documents.rawValue, systemImage: MacSection.documents.icon)
                    .tag(MacSection.documents)
                Label(MacSection.inbox.rawValue, systemImage: MacSection.inbox.icon)
                    .tag(MacSection.inbox)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Trace")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
    }

    // MARK: - Detail

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
        case .horizons:
            TraceMacJournalView(section: .horizons)
                .environment(noteStore)
                .environment(notionService)
        case .people:
            TraceMacPeopleView()
                .environment(notionService)
        case .documents:
            TraceMacDocumentsView()
                .environment(noteStore)
        case .inbox:
            TraceMacInboxView()
                .environment(noteStore)
        case nil:
            VStack(spacing: 12) {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text("Trace")
                    .font(.title2).fontWeight(.medium)
                Text("Select a section to get started")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
