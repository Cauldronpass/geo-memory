import SwiftUI

// MARK: - PeopleView
//
// Session 48 (Trace redesign) — People, promoted from a segment inside the
// retired Life tab (`LifePeopleView`, formerly in LifeView.swift) to its own
// top-level tab, per Session 47 addendum's locked mockup
// (trace-redesign-mockup-v7.html, "People — Interactions" / "People — List"
// frames). Renamed LifePeopleView → PeopleView to match its sibling tabs
// (PlacesView, NotesView) now that it's a first-class tab, not a Life
// sub-screen. Behavior carried over unchanged except:
//   - Interactions is now the default segment (was People) — mockup's
//     explicit "feed-first" call.
//   - Segment order flipped to match the mockup: Interactions | People.
//   - Interactions now loads on first appearance, not just on switching to
//     it — the old code only fetched on `.onChange(of: selectedTab)`, which
//     never fires for the tab that's already selected by default.
//   - Blue "something queued" dot and an orange "Dormant" staleness cue
//     added to People-tab rows (mockup's badge-dot / orange-subtitle
//     treatment) — both built from data already on `Person` (agenda,
//     relationshipStrength). The mockup's "last seen N ago" text is
//     explicitly flagged there as illustrative only ("today's manual
//     dormant label" — real per-person last-interaction-date isn't part of
//     the lightweight Person model), so this shows "Dormant" rather than a
//     fabricated recency string.
//   - `.lifeJumpMenu()` dropped — Life is retired, there's nothing left to
//     jump to.
//   - Styling routed through TraceSkin (traceBackground/traceCard/
//     traceSectionTitleStyle/TraceSegmentedControl) instead of the plain
//     system-grouped-background look LifePeopleView had.

private enum PeopleFilter: Equatable {
    case all
    case agenda
    case relationship(String)

    var label: String {
        switch self {
        case .all:                return "All"
        case .agenda:             return "Agenda"
        case .relationship(let r): return r.capitalized
        }
    }
}

enum PeopleTab: String, CaseIterable {
    case interactions = "Interactions"
    case people       = "People"
}

struct PeopleView: View {
    @Environment(NotionService.self) private var notion
    @State private var searchText = ""
    @State private var activeFilter: PeopleFilter = .all
    @State private var showingFilter = false
    @State private var selectedPerson: Person? = nil
    @State private var showAddPerson = false
    @State private var selectedTab: PeopleTab = .interactions
    @State private var hasLoadedInteractions = false
    @State private var isLoadingInteractions = false
    /// Which row is currently peeled open. **One at a time** — two half-open rows
    /// read as a rendering fault rather than as a state.
    @State private var openSwipeID: String? = nil
    /// Set by the revealed Delete button; drives the confirmation.
    @State private var pendingDelete: Person? = nil

    // MARK: - People tab computed

    private var relationshipTypes: [String] {
        Array(Set(notion.people.compactMap { $0.relationship })).sorted()
    }

    private var filtered: [Person] {
        notion.people.filter { person in
            let matchesSearch = searchText.isEmpty
                || person.name.localizedCaseInsensitiveContains(searchText)
            let matchesFilter: Bool
            switch activeFilter {
            case .all:
                matchesFilter = true
            case .agenda:
                matchesFilter = !(person.agenda ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .relationship(let r):
                matchesFilter = person.relationship == r
            }
            return matchesSearch && matchesFilter
        }
    }

    // MARK: - Interactions tab computed

    private var agendaPeople: [(person: Person, items: [String])] {
        notion.people
            .compactMap { person -> (Person, [String])? in
                guard let agenda = person.agenda,
                      !agenda.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                // Displayed text, not the stored line. Since 2026-08-01 a line
                // can carry a leading `yyyy-MM-dd`, and showing that raw would put
                // a date stamp in front of every agenda item on this tab.
                let items = AgendaLine.items(from: agenda).map(\.text)
                if !searchText.isEmpty {
                    guard person.name.localizedCaseInsensitiveContains(searchText)
                          || items.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
                    else { return nil }
                }
                return (person, items)
            }
            .sorted { $0.0.name < $1.0.name }
    }

    private var filteredInteractions: [Interaction] {
        notion.recentInteractions
            .filter { interaction in
                guard !searchText.isEmpty else { return true }
                if interaction.summary.localizedCaseInsensitiveContains(searchText) { return true }
                return interaction.personIDs.compactMap { id in
                    notion.people.first { $0.id == id }?.name
                }.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
            .sorted { $0.date > $1.date }
    }

    private func interactionTypeColor(_ type: String) -> Color {
        InteractionStyle.color(for: type)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Search bar + filter button (filter hidden on Interactions tab)
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(
                            selectedTab == .people ? "Search people" : "Search by name or summary",
                            text: $searchText
                        )
                        .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color.traceSegmentTrack)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if selectedTab == .people {
                        Button { showingFilter = true } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: activeFilter == .all
                                      ? "line.3.horizontal.decrease.circle"
                                      : "line.3.horizontal.decrease.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(activeFilter == .all ? Color.traceSecondary : Color.tracePurple)
                                if activeFilter != .all {
                                    Circle()
                                        .fill(Color.tracePurple)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 3, y: -3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Segmented pill — Interactions | People (TraceSkin)
                TraceSegmentedControl(options: PeopleTab.allCases, label: { $0.rawValue }, selection: $selectedTab)
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                if selectedTab == .people {
                    peopleTabContent
                } else {
                    interactionsTabContent
                }
            }
        }
        .traceBackground()
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .drawerToolbar()
        .task {
            // Interactions is the default tab now, so it needs its own initial
            // load — the onChange watcher below only covers switching *into*
            // Interactions later, which never fires for the tab that's
            // already selected on first appearance.
            guard !hasLoadedInteractions else { return }
            hasLoadedInteractions = true
            isLoadingInteractions = true
            await notion.fetchRecentInteractions()
            isLoadingInteractions = false
        }
        .onChange(of: selectedTab) { _, newTab in
            searchText = ""
            if newTab == .interactions && !hasLoadedInteractions {
                hasLoadedInteractions = true
                isLoadingInteractions = true
                Task {
                    await notion.fetchRecentInteractions()
                    isLoadingInteractions = false
                }
            }
        }
        .confirmationDialog("Filter People", isPresented: $showingFilter, titleVisibility: .visible) {
            Button(activeFilter == .all ? "✓ All" : "All") { activeFilter = .all }
            Button(activeFilter == .agenda ? "✓ Agenda" : "Agenda") { activeFilter = .agenda }
            ForEach(relationshipTypes, id: \.self) { type in
                Button(activeFilter == .relationship(type) ? "✓ \(type.capitalized)" : type.capitalized) {
                    activeFilter = .relationship(type)
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $selectedPerson) { person in
            PersonDetailView(personID: person.id, personName: person.name)
                .environment(NotionService.shared)
        }
        .sheet(isPresented: $showAddPerson) {
            AddPersonView()
                .environment(notion)
        }
    }

    // MARK: - People tab content

    @ViewBuilder
    private var peopleTabContent: some View {
        // Active filter label
        if activeFilter != .all {
            HStack {
                Text("Showing: \(activeFilter.label)")
                    .font(.caption)
                    .foregroundStyle(Color.tracePurple)
                Spacer()
                Button("Clear") { activeFilter = .all }
                    .font(.caption)
                    .foregroundStyle(Color.tracePurple)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }

        LazyVStack(spacing: 0) {
            ForEach(filtered) { person in
                TraceSwipeRow(id: person.id,
                              openID: $openSwipeID,
                              label: "Delete",
                              icon: "trash") {
                    pendingDelete = person
                } content: {
                Button {
                    selectedPerson = person
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.traceAmberBg)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(String(person.name.prefix(1)))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.traceAmberInk)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                                .foregroundStyle(.primary)
                                .font(.body)
                            peopleRowSubtitle(person)
                        }
                        Spacer()
                        // Blue dot — something queued on their agenda (mockup badge-dot)
                        if hasAgendaItem(person) {
                            Circle()
                                .fill(Color.traceBlue)
                                .frame(width: 7, height: 7)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                }

                if person.id != filtered.last?.id {
                    Divider().padding(.leading, 60)
                }
            }

            if filtered.isEmpty {
                Text(activeFilter == .agenda ? "No one has agenda items" : "No results")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding()
            }
        }
        .traceCard()
        .padding(.horizontal)
        .padding(.bottom, 20)
        // CONFIRMED, unlike a Mail swipe-delete. Mail's is undoable and this is
        // not: it archives the Notion page. Same wording and the same promise
        // about the note file as the one on PersonDetailView, deliberately —
        // two doors to one action should not describe it differently.
        .confirmationDialog("Delete \(pendingDelete?.name ?? "")?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { person in
            Button("Delete Person", role: .destructive) {
                Task {
                    try? await notion.deletePerson(id: person.id)
                    // An UNTOUCHED note goes with them. Satchel's picker scans
                    // files, so a stub left behind keeps a deleted person on
                    // screen in another app. Anything actually written in the
                    // note survives — see `deletePersonNoteIfUntouched`.
                    NoteStore.shared.deletePersonNoteIfUntouched(name: person.name)
                    openSwipeID = nil
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                // Closes the row too. Leaving it peeled open after a cancel
                // implies the delete is still pending.
                withAnimation(.snappy(duration: 0.2)) { openSwipeID = nil }
                pendingDelete = nil
            }
        } message: { _ in
            Text("This removes them from your people. Anything written in their note is kept.")
        }
    }

    private func hasAgendaItem(_ person: Person) -> Bool {
        !(person.agenda ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "Relationship · Dormant" in orange when relationshipStrength is
    /// manually marked dormant (mockup's staleness cue) — falls back to the
    /// plain relationship label, matching the old LifePeopleView row exactly
    /// when the person isn't marked dormant. Computing this automatically
    /// from last-interaction date is still open (Session 47 addendum) — this
    /// uses only the manual field that already exists.
    @ViewBuilder
    private func peopleRowSubtitle(_ person: Person) -> some View {
        if activeFilter == .agenda,
           let agenda = person.agenda,
           let firstItem = AgendaLine.items(from: agenda).first {
            Text(firstItem.text)
                .font(.caption)
                .foregroundStyle(Color.tracePurple)
                .lineLimit(1)
        } else if person.relationshipStrength == "dormant" {
            Text([person.relationship?.capitalized, "Dormant"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Color.traceStale)
        } else if let rel = person.relationship {
            Text(rel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Interactions tab content

    @ViewBuilder
    private var interactionsTabContent: some View {
        VStack(spacing: 16) {
            // Agenda section
            if !agendaPeople.isEmpty {
                interactionsSectionCard(header: "AGENDA") {
                    ForEach(Array(agendaPeople.enumerated()), id: \.element.0.id) { idx, entry in
                        Button {
                            selectedPerson = entry.person
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.orange.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Text(String(entry.person.name.prefix(1)))
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.orange)
                                    )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.person.name)
                                        .foregroundStyle(.primary)
                                        .font(.body)
                                    ForEach(entry.items, id: \.self) { item in
                                        HStack(spacing: 4) {
                                            Circle().fill(Color.orange).frame(width: 4, height: 4)
                                            Text(item)
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if idx < agendaPeople.count - 1 {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }

            // Interactions section
            interactionsSectionCard(
                header: "RECENT INTERACTIONS",
                footer: "Last 45 days"
            ) {
                if isLoadingInteractions {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Loading…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding()
                        Spacer()
                    }
                } else if filteredInteractions.isEmpty {
                    Text(searchText.isEmpty ? "No recent interactions" : "No matching interactions")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .padding()
                } else {
                    ForEach(Array(filteredInteractions.enumerated()), id: \.element.id) { idx, interaction in
                        let names = interaction.personIDs.compactMap { id in
                            notion.people.first { $0.id == id }?.name
                        }
                        let firstPerson = interaction.personIDs.compactMap { id in
                            notion.people.first { $0.id == id }
                        }.first
                        let initial = names.first.flatMap { $0.first.map(String.init) } ?? "?"

                        Button {
                            selectedPerson = firstPerson
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.purple.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Text(initial)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.purple)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(interaction.summary)
                                            .foregroundStyle(.primary)
                                            .font(.body)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(interaction.date, format: .dateTime.month(.abbreviated).day().year())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 6) {
                                        Text(interaction.type.capitalized)
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(interactionTypeColor(interaction.type).opacity(0.15))
                                            .foregroundStyle(interactionTypeColor(interaction.type))
                                            .clipShape(Capsule())
                                        if !names.isEmpty {
                                            Text(names.joined(separator: ", "))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    // WHERE, when there is a where.
                                    //
                                    // David asked whether visit-derived
                                    // interactions deserved their own section.
                                    // They do not: an interaction attached to a
                                    // visit is still an interaction with a
                                    // person, and sectioning by provenance means
                                    // "what happened with Bronwyn" lives in two
                                    // places and you must remember which door it
                                    // came through.
                                    //
                                    // The line only draws when a visit is
                                    // attached, so it marks those rows out
                                    // without splitting the list, and it stays
                                    // sorted by date like everything else.
                                    if let visitID = interaction.visitID,
                                       let visit = notion.visits.first(where: { $0.id == visitID }) {
                                        Label(visit.placeName, systemImage: "mappin.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if idx < filteredInteractions.count - 1 {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func interactionsSectionCard<Content: View>(
        header: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let footer {
                    Text(footer)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .traceCard()
        }
        .padding(.horizontal)
    }
}

// MARK: - Swipe to reveal
//
// David, 2026-08-01: *"i need a way to delete a person in Trace. maybe a leftward
// slide on their name."*
//
// **`.swipeActions` was the obvious answer and it does not apply here.** It is a
// `List` modifier, and this screen is a `LazyVStack` of rows inside a single
// `.traceCard()`, itself inside the page's own `ScrollView`. Using the native one
// would mean rebuilding People as a `List`, giving up the card treatment the
// redesign is built on, and nesting a `List` inside a `ScrollView`. Too much
// demolition for one gesture, so the gesture is hand-rolled.
//
// **The delete itself already existed.** `NotionService.deletePerson` has been
// there all along; until 2026-07-31 only TraceMac called it, and then only
// `PersonDetailView` did. Eighth instance of the same shape this week: the
// capability is built, and the place you would reach for it has no door.
//
// If a second list wants this, MOVE it to TraceSkin.swift rather than copying it.
// Four copies of one idea is how the interaction icons ended up as speech bubbles.

/// A row that peels left to reveal one destructive action.
///
/// The gesture is deliberately fussy about what it claims:
///
/// - `minimumDistance: 20`, so a plain tap still reaches the row's own button.
/// - It engages only once the drag is more horizontal than vertical, so a
///   diagonal scroll keeps scrolling the page instead of peeling rows open.
/// - `openID` is owned by the caller, so opening one row closes any other.
///
/// The action button is hit-testable only while it is actually visible. An
/// invisible destructive button sitting under a row's tap target is how you
/// delete someone by accident.
struct TraceSwipeRow<Content: View>: View {
    let id: String
    @Binding var openID: String?
    let label: String
    let icon: String
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    private let revealWidth: CGFloat = 84
    @State private var drag: CGFloat = 0

    private var isOpen: Bool { openID == id }
    private var offset: CGFloat {
        max(-revealWidth, min(0, (isOpen ? -revealWidth : 0) + drag))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                    Text(label)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(width: revealWidth)
                .frame(maxHeight: .infinity)
                .background(Color.red)
            }
            .buttonStyle(.plain)
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(isOpen)

            content()
                // Opaque, or the red sits visible under a closed row.
                .background(Color.traceCardBackground)
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height)
                            else { return }
                            if openID != nil && !isOpen {
                                openID = nil
                            }
                            drag = value.translation.width
                        }
                        .onEnded { value in
                            let settled = (isOpen ? -revealWidth : 0) + value.translation.width
                            withAnimation(.snappy(duration: 0.22)) {
                                drag = 0
                                openID = settled < -revealWidth / 2 ? id : nil
                            }
                        }
                )
        }
        // Closing from elsewhere (a cancel, another row) must not leave a stale
        // partial drag behind, or the row settles at the wrong offset.
        .onChange(of: isOpen) { _, _ in drag = 0 }
        .clipped()
    }
}
