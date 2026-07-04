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
    case archive   = "Archive"

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
        case .archive:   return "archivebox"
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
        case .archive:   return Color(hex: "92400E")
        }
    }
}

// MARK: - Root view

struct TraceMacContentView: View {

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @Binding var selectedSection: MacSection?
    @State private var pendingHorizonsFile: String? = nil

    var body: some View {
        // Plain HStack instead of NavigationSplitView — eliminates NSSplitView resize
        // arrows entirely. Sidebar is fixed at 200px; detail fills the rest.
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHorizonsFile)) { note in
            if let filename = note.userInfo?["filename"] as? String {
                selectedSection = .horizons
                pendingHorizonsFile = filename
            }
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
            Section("Archive") {
                coloredLabel(.archive).tag(MacSection.archive)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 200)
    }

    private func coloredLabel(_ section: MacSection) -> some View {
        Label {
            Text(section.rawValue)
        } icon: {
            if section == .billiards {
                BilliardsRackIcon(color: section.iconColor)
            } else {
                Image(systemName: section.icon)
                    .foregroundStyle(section.iconColor)
            }
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
            TraceMacJournalView(section: .horizons, deepLinkFile: $pendingHorizonsFile)
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
        case .archive:
            TraceMacArchiveView()
                .environment(noteStore)
                .environment(notionService)
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

// MARK: - Custom billiards rack icon (triangle of circles)

struct BilliardsRackIcon: View {
    var color: Color = .purple

    var body: some View {
        Canvas { ctx, size in
            let d: CGFloat = 3.6          // ball diameter
            let hStep: CGFloat = 4.8      // horizontal center-to-center
            let vStep: CGFloat = hStep * 0.866  // equilateral triangle row height

            // Rack: 3 rows — 1 ball (top), 2 balls, 3 balls (bottom)
            let rows: [(count: Int, indent: CGFloat)] = [
                (1, hStep),        // top
                (2, hStep / 2),    // middle
                (3, 0),            // bottom
            ]

            let rackWidth  = 2 * hStep + d
            let rackHeight = 2 * vStep + d
            let ox = (size.width  - rackWidth)  / 2
            let oy = (size.height - rackHeight) / 2

            for (rowIdx, row) in rows.enumerated() {
                let y = oy + CGFloat(rowIdx) * vStep
                for col in 0..<row.count {
                    let x = ox + row.indent + CGFloat(col) * hStep
                    let rect = CGRect(x: x, y: y, width: d, height: d)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .frame(width: 18, height: 18)
    }
}
