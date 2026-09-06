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
    @State private var showingSort = false
    @State private var sortOrder: DayflowNoteSortOrder = .newest

    // Same three onward-navigation destinations DayflowNotesView.openResult
    // already dispatches to, plus Person (see header comment above).
    @State private var wikiLinkTarget: WikiLinkTarget? = nil
    @State private var showDailyNote = false
    @State private var selectedProjectTitle: String? = nil
    @State private var selectedEndeavorID: String? = nil

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
            } else if let id = selectedEndeavorID {
                DayflowEndeavorView(endeavorID: id)
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

    /// A dialog, not a menu (D283). This view is only ever presented as a
    /// sheet, and a `Menu` inside one does not present in this app.
    ///
    /// The current order moves into the dialog's TITLE rather than being a
    /// checkmark on a row: an action sheet has no checked state, and a tick
    /// drawn with `Label` there would be a control mimicking one it is not.
    private var sortMenu: some View {
        Button { showingSort = true } label: {
            HStack(spacing: 3) {
                Text(sortOrder.rawValue)
                Image(systemName: "chevron.up.chevron.down")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog("Sort \u{00B7} \(sortOrder.rawValue)",
                            isPresented: $showingSort, titleVisibility: .visible) {
            ForEach(DayflowNoteSortOrder.allCases) { order in
                Button(order.rawValue) { sortOrder = order }
            }
            Button("Cancel", role: .cancel) { }
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

    /// **Was "anything except Horizons"**, which drew an arrow on rows the
    /// tap could not open - an endeavor row above all. Derived from the same
    /// answer the tap uses now.
    private func isOpenable(_ mention: NoteMention) -> Bool {
        DayflowMention.isOpenable(mention)
    }

    /// Generalized version of DayflowNotesView.openResult's dispatch — same
    /// three cases (Projects/Calendar/Places), plus Person (this screen's
    /// whole-vault scan can surface a Notes/People/ file as a mentioning note
    /// even though DayflowNotesView's own search never searches that folder).
    /// Horizons has no Dayflow destination — same silent no-op rule as
    /// everywhere else in this build; nothing in the row implies a
    /// destination exists in that case (see `isOpenable` above).
    /// One classifier, two screens (Session 88). This screen swaps its own
    /// body for a note or an endeavor, which keeps the excursion inside the
    /// backlinks sheet; the wiki summary presents instead. That difference is
    /// real and stays local - what a row POINTS AT does not.
    private func openMention(_ mention: NoteMention) {
        switch DayflowMention.target(for: mention) {
        case .projectNote(let title):
            selectedProjectTitle = title
        case .dailyNote(let day):
            selectedDate = day
            showDailyNote = true
        case .place(let place):
            wikiLinkTarget = .place(place)
        case .person(let person):
            wikiLinkTarget = .person(person)
        case .endeavor(let id, _):
            // Body swap, like the project note above, rather than a third
            // `.sheet` on this view. Done inside the endeavor closes the whole
            // backlinks excursion and lands back on the note, which is where
            // the trip started.
            selectedEndeavorID = id
        case .none:
            break
        }
    }
}
