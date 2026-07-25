import SwiftUI

// MARK: - DayflowBacklinksView
//
// Reached by tapping the "link" icon on a DayflowNotesView search result
// (Session 22, 2026-07-21 — backlog item, search result metadata + sorting).
// Shows every OTHER note in the vault that contains a `[[<name>]]` wikilink
// pointing at the tapped note — the inbound-mentions direction of
// NoteStore.findWikilinkMentions(of:excluding:), the exact same call already
// powering the "Mentioned In" section on Person/Place cards
// (DayflowWikiSummaryView.mentionedInSection), just surfaced as its own full
// screen here instead of an inline card section.
//
// Deliberately lazy, not eager: David chose this over showing an inbound
// count on every search result inline, because that would mean running this
// same whole-vault scan once per result on every keystroke while typing a
// search — real, felt lag once there are more than a handful of results.
// One tap, one scan, scoped to the one note you actually asked about.
//
// Rows are tappable (David's explicit call) — a generalized version of
// DayflowNotesView.openResult's own dispatch-by-relativePath-prefix logic,
// widened to also handle Notes/People/ (which DayflowNotesView's own search
// scope never surfaces, but this screen's whole-vault scan can and does
// return as a mentioning note) and to no-op on Notes/Horizons/ (no Dayflow
// destination exists for that Trace-only concept, same rule as everywhere
// else in this build).

struct DayflowBacklinksView: View {
    /// Shown in the count line ("N notes link to <noteTitle>").
    let noteTitle: String
    /// What's actually matched against `[[...]]`. Usually == noteTitle,
    /// except for a Places result: DayflowNotesView's SearchResult.displayName
    /// there is the filesystem-sanitized note filename (NoteStore.
    /// placeNoteFilename), not necessarily the place's real display name that
    /// wikilinks elsewhere in the vault actually use.
    let lookupName: String
    let excludePath: String
    @Binding var selectedDate: Date

    @Environment(\.dismiss) private var dismiss
    @State private var mentions: [NoteMention] = []
    @State private var isLoading = true
    @State private var sortOrder: DayflowNoteSortOrder = .newest

    // Same three onward-navigation destinations DayflowNotesView.openResult
    // already dispatches to, plus Person (see header comment above).
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    @State private var showDailyNote = false
    @State private var selectedProjectTitle: String? = nil

    private var sortedMentions: [NoteMention] {
        switch sortOrder {
        case .newest: return mentions.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .oldest: return mentions.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        case .name:   return mentions.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        Group {
            if let title = selectedProjectTitle {
                DayflowProjectNoteView(title: title, onBack: { selectedProjectTitle = nil })
            } else {
                mainBody
            }
        }
        .fullScreenCover(isPresented: $showDailyNote) {
            DayflowNoteFullPageView(selectedDate: $selectedDate)
        }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target)
            }
        }
        .task {
            // Task, not onAppear — runs once per presentation, matches the
            // "compute only when this screen is actually opened" intent the
            // whole feature exists for.
            mentions = NoteStore.shared.findWikilinkMentions(of: lookupName, excluding: excludePath)
            isLoading = false
        }
    }

    private var mainBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.top, 40)
            } else if mentions.isEmpty {
                Text("Nothing else in the vault links to \u{201C}\(noteTitle)\u{201D} yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
                    .padding(.horizontal, 16)
            } else {
                countAndSortRow
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sortedMentions) { mention in
                            mentionRow(mention)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: Header — matches DayflowNotesView's own header layout

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Spacer()
            // Skin fix 2026-07-22 (Session 32) — was .custom("Georgia", ...),
            // same fix applied across the rest of the skin. Font only this
            // pass — background/pill consistency not yet done on this
            // screen, see Dayflow-HANDOFF.md Session 32. See DayflowSkin.swift.
            Text("Backlinks").font(.dayflowSerif(20))
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var countAndSortRow: some View {
        HStack {
            Text("\(mentions.count) note\(mentions.count == 1 ? "" : "s") link\(mentions.count == 1 ? "s" : "") to \u{201C}\(noteTitle)\u{201D}")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            sortMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(DayflowNoteSortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    if sortOrder == order {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(sortOrder.rawValue)
                Image(systemName: "chevron.up.chevron.down")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func mentionRow(_ mention: NoteMention) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(mention.title).font(.system(size: 13.5)).foregroundStyle(.primary)
                Text(mentionTypeLabel(for: mention.relativePath))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let modified = mention.modified {
                Text(modified.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if isOpenable(mention) {
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { openMention(mention) }
        Divider()
    }

    // Same folder-prefix → label mapping DayflowWikiSummaryView.mentionLabel
    // already uses for its own Mentioned In section — independent copy, same
    // "small helper duplicated per file" convention this codebase already
    // follows (see DayflowVisitDetailView.swift's interactionIcon precedent,
    // Session 20) rather than threading one shared method across files.
    private func mentionTypeLabel(for relativePath: String) -> String {
        if relativePath.hasPrefix("Calendar/") { return "Daily Note" }
        if relativePath.hasPrefix("Notes/Projects/") { return "Project" }
        if relativePath.hasPrefix("Notes/Places/") { return "Place" }
        if relativePath.hasPrefix("Notes/People/") { return "Person" }
        if relativePath.hasPrefix("Notes/Horizons/") { return "Horizon" }
        return "Note"
    }

    private func isOpenable(_ mention: NoteMention) -> Bool {
        !mention.relativePath.hasPrefix("Notes/Horizons/")
    }

    /// Generalized version of DayflowNotesView.openResult's dispatch — same
    /// three cases (Projects/Calendar/Places), plus Person (this screen's
    /// whole-vault scan can surface a Notes/People/ file as a mentioning note
    /// even though DayflowNotesView's own search never searches that folder).
    /// Horizons has no Dayflow destination — same silent no-op rule as
    /// everywhere else in this build; nothing in the row implies a
    /// destination exists in that case (see `isOpenable` above).
    private func openMention(_ mention: NoteMention) {
        let path = mention.relativePath
        if path.hasPrefix("Notes/Projects/") {
            selectedProjectTitle = mention.title
        } else if path.hasPrefix("Calendar/") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: mention.title) {
                selectedDate = parsed
                showDailyNote = true
            }
        } else if path.hasPrefix("Notes/Places/") {
            if let place = NotionService.shared.places.first(where: {
                NoteStore.shared.placeNoteFilename(for: $0.name) == mention.title
            }) {
                wikiLinkTarget = .place(place)
            }
        } else if path.hasPrefix("Notes/People/") {
            if let person = NotionService.shared.people.first(where: { $0.name == mention.title }) {
                wikiLinkTarget = .person(person)
            }
        }
        // Notes/Horizons/ and anything else: no Dayflow destination, silent no-op.
    }
}
