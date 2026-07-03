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
    case billiards = "Billiards"
    case fitness   = "Fitness"
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
        case .billiards: return "circle.grid.3x3"
        case .fitness:   return "figure.run"
        case .documents: return "doc.richtext"
        case .inbox:     return "tray"
        }
    }

    var iconColor: Color {
        switch self {
        case .daily:     return .traceOrange
        case .projects:  return .blue
        case .places:    return .green
        case .horizons:  return .purple
        case .people:    return .indigo
        case .billiards: return Color(hex: "2563EB")
        case .fitness:   return Color(hex: "16A34A")
        case .documents: return Color(hex: "8B5CF6")
        case .inbox:     return .gray
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
            async let b: ()  = notionService.fetchBilliardsSessions()
            async let w: ()  = notionService.fetchWorkouts()
            _ = await (p, pe, b, w)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section("Journal") {
                ForEach([MacSection.daily, .projects, .places, .horizons]) { section in
                    coloredLabel(section).tag(section)
                }
            }
            Section("People") {
                coloredLabel(.people).tag(MacSection.people)
            }
            Section("Activity") {
                coloredLabel(.billiards).tag(MacSection.billiards)
                coloredLabel(.fitness).tag(MacSection.fitness)
            }
            Section("Library") {
                coloredLabel(.documents).tag(MacSection.documents)
                coloredLabel(.inbox).tag(MacSection.inbox)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Trace")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
    }

    private func coloredLabel(_ section: MacSection) -> some View {
        Label {
            Text(section.rawValue)
        } icon: {
            Image(systemName: section.icon)
                .foregroundStyle(section.iconColor)
        }
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
        case .billiards:
            TraceMacBilliardsView()
                .environment(notionService)
        case .fitness:
            TraceMacFitnessView()
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
