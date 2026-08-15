// TraceMacEndeavorsView.swift
// The Endeavors destination. Mac-only.
//
// Session 64, design decision **D22**. David chose option B from
// `tracemac-endeavor-mockup-v1.html`: the app's existing shell — list, detail,
// rail — rather than D8's three peer columns.
//
// **Why D8 lost.** D8 specified *"a three-column workspace, note in the middle,
// filed documents one side, visits in range the other"*, and it was decided
// before Phase 1 gave the app a shape. Every destination now reads sidebar →
// list → detail → rail: Daily is day-list / editor / calendar rail, Directory
// is people-list / person / tabs, Satchel is doc-list / preview / metadata.
// Three peer columns would have been a fourth layout in an app that just spent
// a phase getting to one, and D8 never answered how you switch Endeavor. The
// list answers it, and the status filter gets the same tab strip as everywhere
// else.
//
// Known cost, accepted: with one Endeavor on disk the list holds one row. That
// is a fact about when we are looking, not about the shape.
//
// ── What this is for, which is not "the phone screens, wider" ─────────────
//
// Five visits happened on 31 July; the trip log in the note names two of them.
// The others were not part of the day with Bronwyn, and that is correct. On the
// phone `TripLog` computes candidates and you select on a separate screen. Here
// both are on screen at once, so the rail marks which visits the log already
// names and which it does not. **That is the thing three phone screens cannot
// do**, and it is why this is not a port.
//
// Read-only in this first pass. Writing a visit into the log is the next
// increment and needs Dayflow's writer, or a move of it into `Trace/`.

import SwiftUI
// `.onReceive` takes a Combine publisher. Session 63 converted a controller off
// ObservableObject specifically to avoid adding Combine to this target — that
// was about the observation model, not about NotificationCenter. This is the
// narrow, standard use.
import Combine
// NSOpenPanel for the `+`, UTType.fileURL for the drop. Both are the same
// APIs `TraceMacDocumentsView` already imports for the identical job.
import AppKit
import UniformTypeIdentifiers

struct TraceMacEndeavorsView: View {

    enum Filter: String, CaseIterable, Identifiable {
        case active   = "Active"
        case upcoming = "Upcoming"
        case past     = "Past"
        var id: String { rawValue }
    }

    /// Set by `TraceMacContentView` so a rail row can open the record it names.
    /// Same handoff Directory and Satchel already use — a `Binding` consumed in
    /// `.task(id:)` rather than a notification and a delay.
    var deepLinkPersonID:    Binding<String?>? = nil
    var deepLinkDocumentPath: Binding<String?>? = nil
    /// Added Session 66 for the Destinations rows. `TraceMacDirectoryView`
    /// already takes the same binding from the same `@State` in the container.
    var deepLinkPlaceID:     Binding<String?>? = nil
    /// Added Session 67 for the Linked notes rows (D64). Container-relative path,
    /// consumed by `TraceMacNotesView`, which splits the folder off it to pick a
    /// tab.
    var deepLinkNotePath:    Binding<String?>? = nil
    /// Endeavor slug — the frontmatter `id:`, which is what `selectedID` keys
    /// on. Added Session 70 for global search.
    ///
    /// It sets the **filter** as well as the selection, and it has to: the rail
    /// shows one of Active / Upcoming / Past at a time, and setting `selectedID`
    /// to a past trip while the filter says Active selects a row that is not on
    /// screen. `selected` falls back to `filtered.first`, so the panel would
    /// have opened the wrong Endeavor rather than none — a silent wrong answer,
    /// which is worse than a visible failure.
    var deepLinkEndeavorID:  Binding<String?>? = nil
    var selectedSection:     Binding<MacSection?>? = nil

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var store: TraceMacEndeavorStore?
    /// Rows with a write in flight, so a double click cannot log two visits.
    @State private var resolving: Set<String> = []
    @State private var resolveError: String? = nil
    @State private var showOtherVisits = false
    @State private var docStore: TraceMacDocumentStore?
    @State private var filter: Filter = .active
    @State private var isDocDropTargeted = false
    /// Projects + Daily. Read once when the section appears; a note created
    /// while it is open shows up on the next visit, which is the same freshness
    /// the document and visit lists have.
    @State private var linkableNotes: [LinkableNote] = []
    /// Live while the band is being dragged. Held here rather than in
    /// `MacEndeavorCover` because the gesture is on a sibling overlay — see
    /// `coverDragTarget` — and the store write happens here too.
    @State private var coverDrag: CoverDrag? = nil
    /// Owned here rather than inside the editor, so the rail's `+` can write
    /// into the note the editor is currently holding. See
    /// `MacEditorActions.applyToBody` for why writing the file instead loses.
    @State private var editorActions = MacEditorActions()
    @State private var showingNew = false
    @State private var coverTarget: Endeavor? = nil
    @State private var settingsTarget: Endeavor? = nil
    @State private var deleteTarget: Endeavor? = nil
    @State private var addingDestinationTo: Endeavor? = nil
    /// Hosted on `peopleSection`, not on the rail's ScrollView, which already
    /// carries the destination sheet. D36: two `.sheet` modifiers on one view is
    /// a coin flip and the later one wins silently.
    @State private var addingPersonTo: Endeavor? = nil
    @State private var selectedID: String?
    @State private var navigator = MacNavigator.shared
    /// Remembered across launches. The two inline copies of this strip in
    /// People and Places used plain `@State`, so a widened column was narrow
    /// again on the next launch.
    @AppStorage("tracemac.column.endeavors") private var listWidth: Double = 200

    // MARK: Derived

    private var all: [Endeavor] { store?.endeavors ?? [] }

    private var filtered: [Endeavor] {
        all.filter { e in
            switch e.status() {
            case .active:              return filter == .active
            case .upcoming, .idea:     return filter == .upcoming
            case .past, .cancelled:    return filter == .past
            // On hold is neither coming nor done. It sits with Active, because
            // the reason you paused it is the reason you still need to see it.
            case .onHold:              return filter == .active
            }
        }
    }

    private var selected: Endeavor? {
        guard let selectedID else { return filtered.first }
        return all.first { $0.id == selectedID } ?? filtered.first
    }

    /// Visits inside the Endeavor's dates, inclusive of both ends.
    ///
    /// Day granularity, via `isDate(_:inSameDayAs:)` at the edges rather than
    /// an interval containing instants. `DateInterval.contains` is closed at
    /// both ends and Notion stores most visit dates at midnight, which is the
    /// pair of facts that put an eighth row in the This Week panel this morning.
    ///
    /// Session 72: the range test moved to `Endeavor.covers(_:)` so the visit
    /// screen's new Endeavor row answers this from the same definition. Same
    /// logic, same day granularity, one copy.
    private func visits(in e: Endeavor) -> [Visit] {
        notionService.visits
            .filter { e.covers($0.date) }
            .sorted { $0.date < $1.date }
    }

    /// One attached destination on a past endeavor with nothing logged against
    /// it. Session 72.
    struct OpenDestination: Identifiable {
        let endeavor: Endeavor
        let placeName: String
        var id: String { "\(endeavor.id)|\(placeName)" }
    }

    /// How long after an endeavor ends before its unvisited destinations become
    /// a question. David's number: *"past by say 3 days"*. Long enough that a
    /// trip you are still driving home from does not nag.
    private static let settleDays = 3

    /// Attached destinations on finished endeavors with no visit logged.
    ///
    /// David asked for the Endeavors screen to raise these itself: *"what do you
    /// think about a way for the app to notify me if there are endeavors whos
    /// date is past by say 3 days and the status of places that are in the
    /// endeavor still say want to visit."* The status half of that became an
    /// automatic sweep — a logged visit proves a status wrong with no judgement
    /// needed, so it is fixed rather than asked about. **This is the half that
    /// is genuinely a question**: nothing in the data can tell whether he
    /// skipped the place or just never checked in.
    ///
    /// Guarded on visits being loaded. With an unfetched `visits` array every
    /// destination looks unvisited, and a panel that asks about all of them
    /// because it has not read anything yet is D116's shape exactly.
    private var openDestinations: [OpenDestination] {
        guard !notionService.visits.isEmpty, let store else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return store.endeavors.flatMap { e -> [OpenDestination] in
            guard e.status() == .past, !e.places.isEmpty else { return [] }
            guard let last = e.ends ?? e.starts,
                  let age = cal.dateComponents([.day], from: cal.startOfDay(for: last), to: today).day,
                  age >= Self.settleDays else { return [] }
            let visitedNames = Set(visits(in: e).map { shortPlaceName($0.placeName).lowercased() })
            let skipped = Set(e.skippedPlaces.map { shortPlaceName($0).lowercased() })
            return e.places.compactMap { name in
                let key = shortPlaceName(name).lowercased()
                guard !visitedNames.contains(key), !skipped.contains(key) else { return nil }
                return OpenDestination(endeavor: e, placeName: name)
            }
        }
        .sorted { ($0.endeavor.ends ?? .distantPast) > ($1.endeavor.ends ?? .distantPast) }
    }

    /// Whether the note's body already names this place.
    ///
    /// Matched against the body text rather than a stored list, because the
    /// trip log *is* the body — there is no separate record of what is in it.
    ///
    /// Session 72: moved to `Endeavor.logNames(placeName:)`. The reverse
    /// direction on the visit screen has to agree with this rail, and two
    /// copies of "what is in the endeavor" is how they would stop agreeing.
    private func logNames(_ visit: Visit, in e: Endeavor) -> Bool {
        e.logNames(placeName: visit.placeName)
    }

    /// Documents filed against this Endeavor, by **either** association.
    ///
    /// `endeavor` is what Satchel's capture writes, and it is what this rail
    /// filtered on when it was built. `linked_note` is what the phone's
    /// `SatchelDocumentChips` filters on, keyed to the Endeavor note's own
    /// path — and that is the mechanism behind the Add Document button on the
    /// phone's Endeavor screen, so it is not a rare case.
    ///
    /// **The two apps were reading two different keys**, which means a document
    /// added to an endeavor on the phone would never have appeared here, and
    /// nothing anywhere would have said so. Union rather than a choice: one
    /// filter over one array, so no document can appear twice.
    private func documents(for e: Endeavor) -> [TraceMacDocument] {
        (docStore?.documents ?? [])
            .filter { $0.endeavor == e.id || $0.linkedNote == e.relativePath }
            .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    /// People from the visits the log actually names, **not** from every visit
    /// inside the dates.
    ///
    /// David, on the first build: *"seeing Bryan and Hannah when they did not go
    /// with us to Inspired and Nics is not helpful."* Right, and the cause is
    /// exact: he was at Panera and Cornerstone that evening with Bryan and
    /// Hannah, and those visits fall inside 31 July without being part of the
    /// lunch. Deriving from the range answers "who did you see that day"; the
    /// question the card is asking is "who was on this endeavor".
    private func people(in e: Endeavor) -> [Person] {
        let ids = Set(visits(in: e).filter { logNames($0, in: e) }.flatMap { $0.peopleIDs })
        return notionService.people
            .filter { ids.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `TripLog.shortPlaceName`, not a fourth copy.
    ///
    /// This was a local implementation with a comment admitting it was the same
    /// rule as `TripLog`'s and `TraceMacDailyView`'s. **It was not the same
    /// rule.** This one looked for the last `"("`, `TripLog` looks backwards for
    /// `" ("`, and on a name written `Nick's(formerly Popeye's)` they disagree.
    /// That is not cosmetic here: `logNames` decides whether the tick appears by
    /// searching the body for the shortened name, so the marker and the line the
    /// phone actually wrote could disagree — a hollow circle on a visit already
    /// in the log, offering to add it a second time.
    private func shortPlaceName(_ name: String) -> String {
        TripLog.shortPlaceName(name)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // The `+` was suspected during the hit-testing hunt and is
            // innocent — the cause was the cover image's unclipped hit area,
            // see `coverBand`. Restored. `New Endeavor…` stays in the list's
            // context menu as well, which is a better place for it anyway.
            MacSectionHeader("Endeavors",
                             action: MacHeaderButton(icon: "plus",
                                                     help: "New endeavor") { showingNew = true }) {
                MacTabStrip(options: Filter.allCases,
                            selection: $filter) { $0.rawValue }
            }

            // Open questions band.
            //
            // David chose the surface himself: *"The endeavor active screen is
            // the one place i think makes sense. its mainly blank because it
            // defaults to the active tab and Im not in the middle of an active
            // endeavor most times."*
            //
            // **Above the split, not inside the empty state**, so it is there
            // whether or not an active endeavor happens to be selected. The
            // empty-state placeholder only renders when nothing is selected,
            // and a prompt that hides itself the moment he has one live trip is
            // a prompt he would meet once a season.
            //
            // Active tab only. Past is where he goes to read what happened, and
            // a nag bar over it would be answering a question he did not ask.
            if filter == .active, !openDestinations.isEmpty {
                openQuestionsBand
                Divider()
            }

            HStack(spacing: 0) {
                listColumn
                MacColumnResizer(width: $listWidth)
                Divider()
                if let e = selected {
                    detail(e)
                    Divider()
                    rail(e)
                } else {
                    MacEmptyState.placeholder("flag", "Select an endeavor")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // **Which endeavor, not just "Endeavors".** Without this, back from a
        // document opened out of Megan's rail would return to the Endeavors
        // section and land on whatever the filter selects first — near enough to
        // look intended and wrong enough to be useless. `selected` is derived
        // (it falls back to `filtered.first`), so the id it resolves to is the
        // one on screen, which is the one worth returning to.
        .onChange(of: selected?.id) { _, id in
            guard let id else { return }
            // **NOT WHILE A DEEP LINK IS IN FLIGHT.**
            //
            // David: *"i clicked the arrow and went back to the megan wedding
            // endeavor. When i then pressed the back arrow nothing happened. I
            // had to press that back arrow a few times."*
            //
            // `selected` is derived and falls back to `filtered.first`, which is
            // the property that makes the comment above this work — and the
            // property that breaks it on arrival. Landing here from a document's
            // Endeavor arrow, the rail renders once with the filter's first row
            // selected, records THAT as a place, and only then does the deep-link
            // `.task` run `reveal` and move to the requested Endeavor. So the
            // back stack gains an Endeavor he never chose, sitting between where
            // he is and where he came from — and pressing back lands on the same
            // screen showing a different record, which reads as nothing
            // happening.
            //
            // Suppressed rather than de-duplicated afterwards: an intermediate
            // the view picked for itself is not a place anyone visited, and the
            // honest fix is not to report it. `openSearchResult` has already
            // recorded the real destination by this point, so nothing is lost —
            // and `reveal`'s own selection change records an entry equal to
            // `current`, which `record` discards.
            guard deepLinkEndeavorID?.wrappedValue == nil else { return }
            navigator.record(.record(.endeavor(id)))
        }
        .task {
            if store == nil { store = TraceMacEndeavorStore(noteStore: noteStore) }
            if docStore == nil { docStore = TraceMacDocumentStore(noteStore: noteStore) }
            linkableNotes = noteStore.linkableNotes()
            await store?.reload()
            await docStore?.reload()
            if notionService.visits.isEmpty { await notionService.fetchVisits() }
        }
        // Search result → this rail. `reveal` already exists and already does
        // the whole job — it sets the filter from the Endeavor's own status and
        // then selects it — so this is a lookup and a call, not new behaviour.
        .task(id: MacDeepLinkKey(value: deepLinkEndeavorID?.wrappedValue,
                                 loaded: store?.endeavors.count ?? 0)) {
            guard let id = deepLinkEndeavorID?.wrappedValue,
                  let match = store?.endeavors.first(where: { $0.id == id }) else { return }
            reveal(match)
            deepLinkEndeavorID?.wrappedValue = nil
        }
        // The other half of the watcher added to `NoteStore` this session: an
        // Endeavor note edited on the phone now reaches a Mac sitting on this
        // screen, instead of waiting for the section to be revisited.
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreEndeavorsDidChange)) { _ in
            Task { await store?.reload() }
        }
        .sheet(isPresented: $showingNew) {
            MacEndeavorSheet(existing: nil,
                             onSave: { _, name, type, starts, ends, destination, _, _ in
                guard let store else { return }
                let made = try? await store.create(name: name, type: type,
                                                   starts: starts, ends: ends,
                                                   destination: destination)
                if let made { reveal(made) }
            })
        }
    }

    // MARK: Open questions

    /// **Two buttons per row and no confirmation.** David: *"an easy way to
    /// make the decisions that it is prompting me about (this is important, I
    /// dont want to have to click a lot of times to resolve the question)."*
    /// One click resolves one row and the row leaves. Both answers are
    /// reversible by hand — a visit can be deleted from the visit sheet, and
    /// `skipped:` is a line in the endeavor's frontmatter — which is what makes
    /// no confirmation the right call rather than a risky one.
    private var openQuestionsBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(openDestinations.count == 1
                     ? "1 place from a finished endeavor has no visit logged"
                     : "\(openDestinations.count) places from finished endeavors have no visit logged")
                    .font(.system(.callout, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Four, then a count. The band sits above the whole screen, and one
            // that can grow without limit pushes the endeavors it is sitting on
            // off the bottom. Resolving four reveals the next four.
            ForEach(openDestinations.prefix(4)) { item in
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortPlaceName(item.placeName))
                            .font(MacType.row)
                        Text("\(item.endeavor.name) · ended \(endedLine(item.endeavor))")
                            .font(MacType.meta)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Went") { Task { await resolveWent(item) } }
                        .disabled(resolving.contains(item.id) || placeRecord(for: item.placeName) == nil)
                        .help(placeRecord(for: item.placeName) == nil
                              ? "No Place record named \(item.placeName)"
                              : "Log a visit on \(endedLine(item.endeavor))")
                    Button("Didn't go") { Task { await resolveSkipped(item) } }
                        .disabled(resolving.contains(item.id))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }

            if openDestinations.count > 4 {
                Text("and \(openDestinations.count - 4) more")
                    .font(MacType.meta)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            if let resolveError {
                Text(resolveError)
                    .font(MacType.meta)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }

    private func endedLine(_ e: Endeavor) -> String {
        guard let d = e.ends ?? e.starts else { return "—" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The Place record an attached name refers to. Attached destinations are
    /// full Notion names by design, so this is an exact match, with the
    /// shortened form as a fallback for a name edited in Notion since.
    private func placeRecord(for name: String) -> Place? {
        notionService.places.first { $0.name == name }
            ?? notionService.places.first {
                shortPlaceName($0.name).caseInsensitiveCompare(shortPlaceName(name)) == .orderedSame
            }
    }

    /// He went: log a visit, dated the endeavor's last day.
    ///
    /// **The date is a guess and is meant to be**, which is why it is the last
    /// day rather than anything cleverer. A multi-day trip cannot know which
    /// day he was at the restaurant, and asking would be the extra clicks he
    /// specifically did not want. The visit sheet has a date picker.
    private func resolveWent(_ item: OpenDestination) async {
        guard let place = placeRecord(for: item.placeName) else { return }
        resolving.insert(item.id)
        defer { resolving.remove(item.id) }
        let date = item.endeavor.ends ?? item.endeavor.starts ?? Date()
        do {
            _ = try await notionService.checkIn(place: place, date: date)
            // Re-read rather than append: `checkIn` returns an id, not a Visit,
            // and this list is derived from `visits`.
            await notionService.fetchVisits()
            resolveError = nil
        } catch {
            resolveError = "Could not log the visit: \(error.localizedDescription)"
        }
    }

    /// He did not go: record it on the endeavor so the question stays answered.
    private func resolveSkipped(_ item: OpenDestination) async {
        guard let store else { return }
        resolving.insert(item.id)
        defer { resolving.remove(item.id) }
        var updated = item.endeavor
        guard !updated.skippedPlaces.contains(item.placeName) else { return }
        updated.skippedPlaces.append(item.placeName)
        do {
            _ = try await store.update(updated)
            resolveError = nil
        } catch {
            resolveError = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: List

    /// Carries the settings sheet. **Not the cover band**, which already has
    /// the cover picker on it: two `.sheet` modifiers on one view is the
    /// SwiftUI coin flip noted there, where the later wins and the earlier
    /// silently never presents. Three sheets in this view means three different
    /// hosts, and the list is the one that outlives any single endeavor.
    private var listColumn: some View {
        VStack(spacing: 0) {
            if filtered.isEmpty {
                MacEmptyState.list("flag", "Nothing \(filter.rawValue.lowercased())")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // New has to be reachable when the list is empty, which is
                    // exactly when you most want it.
                    .contentShape(Rectangle())
                    .contextMenu { Button("New Endeavor…") { showingNew = true } }
            } else {
                List(filtered, id: \.id, selection: $selectedID) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name)
                            .font(.system(.callout, weight: .medium))
                            .lineLimit(1)
                        Text(dateLine(e))
                            .font(MacType.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(e.id as String?)
                    // Right-click on the row. David, 2026-08-04, after the
                    // settings and cover chips on the cover band turned out to
                    // be hard to find against a photograph: *"please add this
                    // as a right click option as well on the card to the left."*
                    //
                    // The chips stay — they are where you look when you are
                    // already reading the endeavor. This is where you look when
                    // you are picking one, and on a Mac a list row that cannot
                    // be right-clicked reads as inert.
                    //
                    // Both entries route to the same places the chips do, so
                    // there is one implementation of each verb and no second
                    // path to keep in step.
                    .contextMenu {
                        Button("New Endeavor…") { showingNew = true }
                        Divider()
                        Button("Endeavor Settings…") { settingsTarget = e }
                        Button("Change Cover…")      { coverTarget = e }
                        Divider()
                        // Confirmed separately from the sheet's own Delete.
                        // A destructive action reached by right-click, with no
                        // sheet in front of it, is the one that most needs the
                        // extra beat.
                        Button("Delete…", role: .destructive) { deleteTarget = e }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: listWidth)
        .confirmationDialog("Delete “\(deleteTarget?.name ?? "")”?",
                            isPresented: Binding(
                                get: { deleteTarget != nil },
                                set: { if !$0 { deleteTarget = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let target = deleteTarget, let store else { return }
                deleteTarget = nil
                Task {
                    try? await store.delete(target)
                    selectedID = nil
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Deletes the note. Documents filed to it are left alone — Satchel owns those.")
        }
        .sheet(item: $settingsTarget) { target in
            MacEndeavorSheet(
                existing: target,
                onSave: { _, name, type, starts, ends, destination, status, stamps in
                    guard let store else { return }
                    var updated = target
                    updated.name           = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.type           = type
                    updated.starts         = starts
                    updated.ends           = ends
                    updated.destination    = destination.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.statusOverride = status
                    updated.stampsCaptures = stamps
                    if let saved = try? await store.update(updated) { reveal(saved) }
                },
                onDelete: { deleted in
                    guard let store else { return }
                    try? await store.delete(deleted)
                    selectedID = nil
                }
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func dateLine(_ e: Endeavor) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        var out = ""
        if let s = e.starts {
            out = f.string(from: s)
            if let en = e.ends, !Calendar.current.isDate(en, inSameDayAs: s) {
                out += " – " + f.string(from: en)
            }
        }
        if let d = e.destination?.replacingOccurrences(of: ",", with: ", "), !d.isEmpty {
            out += out.isEmpty ? d : " · \(d)"
        }
        return out.isEmpty ? e.type : out
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ e: Endeavor) -> some View {
        VStack(spacing: 0) {
            coverBand(e)
            // The **shared** editor, not a second one. `TraceMacNoteEditor`
            // already carries wikilink autocomplete with live suggestions,
            // the formatting toolbar, and a one-second debounced save; it was
            // written path-parameterised for exactly this.
            //
            // The two transforms are the whole difference between a day note
            // and an Endeavor note: this one has frontmatter, and the editor
            // must own only what is below the fence.
            TraceMacNoteEditor(
                relativePath: e.relativePath,
                loadTransform: { EndeavorFile.splitRaw($0).body },
                saveTransform: { edited, onDisk in
                    let fm = EndeavorFile.splitRaw(onDisk).frontmatter
                    return fm.isEmpty ? edited : fm + "\n\n" + edited
                },
                onSaved: { Task { await store?.reload() } },
                externalActions: editorActions
            )
            .id(e.id)
        }
        .frame(maxWidth: .infinity)
    }

    /// Height of the cover band.
    ///
    /// **160, up from 96.** David, comparing the same endeavor on both
    /// platforms: *"the iphone app dayflow shows a lot more of the photo than
    /// the mac version."* He is right, and it is proportion rather than
    /// preference. The detail column runs to several hundred points, so a 96pt
    /// band is roughly a 7:1 letterbox and `scaledToFill` throws away most of a
    /// landscape photograph. Dayflow's card is close to 16:9.
    ///
    /// 160 is a compromise rather than parity: the Mac shows the note itself
    /// below, and matching the phone's ratio on a 900pt-wide column would push
    /// Summary below the fold. It roughly doubles what you see of the picture
    /// while the five headings still start on screen.
    ///
    /// One constant, three call sites, so the band and its gradient and its
    /// frame cannot disagree — they were three separate `96`s before.
    private static let coverHeight: CGFloat = 160

    /// One drag in progress. A struct rather than a tuple because `@State`
    /// wants something nameable, and `id` is here so a drag cannot bleed onto a
    /// different endeavor if the selection changes mid-gesture.
    private struct CoverDrag {
        let id: String
        let start: Double
        var current: Double
    }

    private func liveCoverOffset(for e: Endeavor) -> Double {
        if let drag = coverDrag, drag.id == e.id { return drag.current }
        return e.coverOffset
    }

    /// The only part of the band that is in the hit path.
    ///
    /// David: *"Can i move the photo i picked around within frame to fine the
    /// exact location i want to show in the window?"*
    ///
    /// **The picture itself stays `.allowsHitTesting(false)`** — D58, and the
    /// bug that cost four wrong fixes. `scaledToFill` gives the image a frame
    /// hundreds of points taller than the band, and putting the gesture on that
    /// would put the whole invisible remainder back over the section header. So
    /// the gesture lives on a `Color.clear` sized to the band exactly, which
    /// cannot reach anything above it.
    ///
    /// Below the title row in the ZStack, so the two chips keep their clicks:
    /// SwiftUI hit-tests topmost first, and they are added after this.
    ///
    /// **Sensitivity is a full sweep per band height**, not one-to-one with the
    /// photograph. A true 1:1 needs the scaled overflow, which only
    /// `MacEndeavorCover` knows once the image has loaded, and reporting it back
    /// up is a preference key and a re-layout for a feel adjustment. This moves
    /// faster than the cursor on a tall photograph; it also means any framing is
    /// reachable in one short drag.
    private func coverDragTarget(_ e: Endeavor) -> some View {
        Color.clear
            .frame(height: Self.coverHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let start = (coverDrag?.id == e.id ? coverDrag?.start : nil) ?? e.coverOffset
                        // Drag down to bring the top of the picture into view,
                        // which is what dragging the picture itself would do.
                        let delta = -value.translation.height / Self.coverHeight
                        coverDrag = CoverDrag(id: e.id,
                                              start: start,
                                              current: min(1, max(0, start + delta)))
                    }
                    .onEnded { _ in
                        guard let drag = coverDrag, drag.id == e.id, let store else {
                            coverDrag = nil
                            return
                        }
                        var updated = e
                        updated.coverOffset = drag.current
                        Task {
                            _ = try? await store.update(updated)
                            // Cleared only after the reload, so the band does not
                            // snap back to the saved value for a frame.
                            coverDrag = nil
                        }
                    }
            )
            .help("Drag to reposition the cover")
    }

    /// The cover is Travel-only by D8 — a photograph makes a trip feel like a
    /// trip; a stock photo of a kitchen makes a renovation feel like a
    /// brochure. Without one, the same band renders as a plain title row so the
    /// note does not start at a different height depending on the type.
    @ViewBuilder
    private func coverBand(_ e: Endeavor) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let cover = e.cover, !cover.isEmpty {
                // Not `MacNoteStorePhotoView`: that one draws a square, taking
                // one `size` for both axes, which is right for an avatar well
                // and wrong for a band.
                MacEndeavorCover(path: cover, offset: liveCoverOffset(for: e))
                    .frame(height: Self.coverHeight)
                    .clipped()
                    // **`.clipped()` clips DRAWING, not hit testing.**
                    //
                    // Session 66, and David found it: *"I added a photo of my
                    // own to the endeavor which must be covering even though it
                    // was not visible. When i removed the cover photo now it
                    // works."*
                    //
                    // `MacEndeavorCover` draws `Image(nsImage:).resizable()
                    // .scaledToFill()`. `scaledToFill` in a 96pt-high band makes
                    // the image's own frame far larger than the band — for a
                    // tall photograph, hundreds of points taller. `.clipped()`
                    // hides the overflow but leaves the frame intact as a click
                    // target, so the invisible remainder sat over the section
                    // header above and swallowed clicks on the tab strip.
                    //
                    // Which is why the Past tab could not be clicked while
                    // Notes and Directory were fine: they have no cover band.
                    // Four wrong theories went past this — `fixedSize`, the
                    // stock `Picker`, the header's action slot, the tab strip
                    // itself — because every one of them looked at the control
                    // rather than at what was on top of it.
                    //
                    // The cover and the gradient are decoration. They should
                    // never have been in the hit path at all.
                    .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.coverHeight)
                    .allowsHitTesting(false)
                coverDragTarget(e)
            } else {
                Color(nsColor: .controlBackgroundColor).frame(height: 56)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(e.name).font(MacType.title)
                Text(e.status().label)
                    .macLabel()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                // On the band, because the band is the thing it changes. It
                // reads on both states: over a photograph the material chip
                // keeps it legible, and on the plain 56pt title row it is the
                // only affordance saying a cover is possible at all.
                Button { coverTarget = e } label: {
                    Image(systemName: "photo")
                        .font(MacGlyph.control)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(e.cover?.isEmpty == false ? "Change cover" : "Add a cover")
                Button { settingsTarget = e } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(MacGlyph.control)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Endeavor settings")
            }
            .foregroundStyle(e.cover?.isEmpty == false ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.bottom, 9)
        }
        .frame(height: e.cover?.isEmpty == false ? Self.coverHeight : 56)
        .overlay(alignment: .bottom) { Divider() }
        // Attached HERE, not beside `.sheet(isPresented: $showingNew)` on the
        // outer VStack. Two `.sheet` modifiers on the same view is a long-
        // standing SwiftUI coin flip — the later one wins and the earlier one
        // silently never presents. On different views in the hierarchy both
        // work, and this is also the view the sheet is about.
        .sheet(item: $coverTarget) { target in
            MacCoverPickerSheet(
                endeavor: target,
                onPick: { data, credit in
                    guard let store else { return }
                    _ = try? await store.setCover(data, credit: credit, for: target)
                },
                onRemove: {
                    guard let store else { return }
                    try? await store.clearCover(for: target)
                }
            )
        }
    }

    // MARK: Rail

    @ViewBuilder
    private func rail(_ e: Endeavor) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Two lists, not one.
                //
                // David: *"the visits in range are true but not something i need
                // to see."* They are the pool the log is selected from, and a
                // pool is only interesting while you are choosing from it. What
                // is *in* the endeavor is the answer; the rest is the working.
                //
                // So the ones the log names are the section, and the others sit
                // behind a disclosure that states its own count. Nothing is
                // hidden, but nothing unchosen is competing either.
                destinationsSection(e)
                Divider().padding(.vertical, 6)

                linkedNotesSection(e)
                Divider().padding(.vertical, 6)

                let inLog  = visits(in: e).filter {  logNames($0, in: e) }
                let others = visits(in: e).filter { !logNames($0, in: e) }

                railHeader("Visits", inLog.count)
                if inLog.isEmpty {
                    railEmpty("No visits are named in the log yet.")
                } else {
                    ForEach(inLog) { v in visitRow(v, in: e) }
                }

                if !others.isEmpty {
                    DisclosureGroup(isExpanded: $showOtherVisits) {
                        ForEach(others) { v in visitRow(v, in: e) }
                    } label: {
                        // `row`/`.secondary`, not `meta`/`.tertiary`. David,
                        // 2026-08-02, testing the `+`: *"I missed it entirely."*
                        // He was right to. Session 64 gave this the lightest
                        // type and the faintest colour in the rail on the
                        // reasoning that it is chrome around a list — and then
                        // the next session made it the only door to adding a
                        // visit to the log. **A control's weight follows what
                        // is behind it, not what it looks like.** It is now the
                        // same size as the rows it reveals, one step down in
                        // colour so it still reads as the lid rather than the
                        // contents.
                        Text("Also that day (\(others.count))")
                            .font(MacType.row)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                }

                Divider().padding(.vertical, 6)
                satchelSection(e)

                Divider().padding(.vertical, 6)
                peopleSection(e)
            }
            .padding(.bottom, 12)
        }
        .frame(width: 232)
        .background(Color(nsColor: .windowBackgroundColor))
        // Hosted on the rail — the fourth sheet in this view, and the fourth
        // distinct host view, per D36.
        .sheet(item: $addingDestinationTo) { target in
            MacAddDestinationSheet(endeavor: target,
                                   places: notionService.places) { name in
                attach(name, to: target)
            }
        }
    }

    private func railHeader(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title).macLabel().foregroundStyle(.tertiary)
            Spacer()
            if count > 0 {
                Text("\(count)").font(MacType.metaEmphasis).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)
    }

    private func railEmpty(_ text: String) -> some View {
        Text(text)
            .font(MacType.meta)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.bottom, 4)
    }

    /// A tick when the trip log already names this place, a `+` when it does
    /// not — and the `+` is now real.
    ///
    /// Session 64 drew a hollow `circle.dotted` here instead, with a note saying
    /// a control that looks actionable and does nothing is exactly what
    /// `emptyDayRow` had refused to be that morning. It becomes a plus in the
    /// same commit that gives it something to do, which was the condition.
    ///
    /// **The tick is not a button.** Removing a visit from the log means
    /// deleting a block David may have written prose into, and the note is the
    /// place he owns. Undoing an add is selecting it and pressing delete, in the
    /// editor, where he can see what he is removing.
    private func visitRow(_ v: Visit, in e: Endeavor) -> some View {
        let inLog = logNames(v, in: e)
        return HStack(spacing: 8) {
            Group {
                if inLog {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.indigo)
                } else {
                    Button { addToLog(v, in: e) } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.secondary.opacity(0.55))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add to the trip log")
                }
            }
            .font(MacGlyph.small)
            .frame(width: 14)
            MacIconBadge(icon: placeIcon(for: placeCategory(v)),
                         tint: placeColor(for: placeCategory(v)),
                         size: .compact)
            VStack(alignment: .leading, spacing: 1) {
                Text(shortPlaceName(v.placeName)).font(MacType.row).lineLimit(1)
                Text(v.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(MacType.meta).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let r = v.rating, r > 0 { MacStars(rating: r) }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(inLog ? Color.indigo.opacity(0.05) : .clear)
    }

    /// Writes one visit into the endeavor note's trip log.
    ///
    /// Goes through the **editor**, not the file. The editor beside this rail is
    /// holding the body, so a direct write would be overwritten by its next
    /// debounced save with nothing reported. `applyToBody` hands the transform
    /// to the editor, which applies it to what it is holding and saves through
    /// the path that already preserves the frontmatter.
    ///
    /// Nothing re-derives the tick by hand: `onSaved` already reloads the store,
    /// `logNames` re-reads the fresh body, and the row redraws as a tick. The
    /// marker is the same test the insert guards on, so the two cannot disagree.
    private func addToLog(_ v: Visit, in e: Endeavor) {
        let entry = TripLog.entry(for: v, people: notionService.people)
        let day   = Calendar.current.startOfDay(for: v.date)
        editorActions.applyToBody? { body in
            TripLog.insert(entry, on: day, into: body)
        }
    }

    /// Selects an endeavor and moves the filter to wherever it actually is.
    ///
    /// Creating a trip for next month while Past is showing, or putting an
    /// active one on hold, would otherwise leave it behind a tab you are not
    /// looking at — which reads as the save having failed rather than as a tab
    /// being wrong. Shared by create and by save so the two cannot disagree.
    private func reveal(_ e: Endeavor) {
        switch e.status() {
        case .upcoming, .idea:  filter = .upcoming
        case .past, .cancelled: filter = .past
        default:                filter = .active
        }
        selectedID = e.id
    }

    private func placeCategory(_ v: Visit) -> String {
        notionService.places.first { $0.id == v.placeID }?.category ?? ""
    }

    /// One row of the People rail: a name, whatever record it resolves to, and
    /// whether it got there by hand or by way of a visit.
    ///
    /// Keyed on the lowercased name rather than the Notion id, because an
    /// attached name that resolves to nothing still needs a stable identity in
    /// the `ForEach` — and because that is what dedupes the two sources against
    /// each other.
    private struct RailPerson: Identifiable {
        let name: String
        let person: Person?
        let attached: Bool
        var id: String { name.lowercased() }
    }

    /// Attached first, then everyone the trip log found, deduplicated.
    ///
    /// **Union, not a choice**, exactly like `documents(for:)`. Someone you put
    /// on the endeavor and someone who demonstrably went are both on it, and
    /// letting the explicit list win would quietly drop the second group the
    /// moment you attached anybody at all.
    ///
    /// Attached above derived for the same reason Destinations sits above
    /// Visits: what you decided comes before what was inferred.
    private func railPeople(_ e: Endeavor) -> [RailPerson] {
        var seen = Set<String>()
        var out: [RailPerson] = []
        for name in e.people {
            guard seen.insert(name.lowercased()).inserted else { continue }
            out.append(RailPerson(
                name: name,
                person: notionService.people.first {
                    $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                },
                attached: true))
        }
        for p in people(in: e) {
            guard seen.insert(p.name.lowercased()).inserted else { continue }
            out.append(RailPerson(name: p.name, person: p, attached: false))
        }
        return out
    }

    @ViewBuilder
    private func peopleSection(_ e: Endeavor) -> some View {
        let rows = railPeople(e)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("People").macLabel().foregroundStyle(.tertiary)
                Spacer()
                if !rows.isEmpty {
                    Text("\(rows.count)")
                        .font(MacType.metaEmphasis).foregroundStyle(.tertiary)
                }
                Button { addingPersonTo = e } label: {
                    Image(systemName: "plus")
                        .font(MacGlyph.smallBold)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add someone to \(e.name)")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)

            if rows.isEmpty {
                railEmpty("Nobody attached yet.")
            } else {
                ForEach(rows) { row in personRow(row, in: e) }
            }
        }
        .sheet(item: $addingPersonTo) { target in
            MacAddPersonSheet(endeavor: target,
                              people: notionService.people) { name in
                attachPerson(name, to: target)
            }
        }
    }

    private func personRow(_ row: RailPerson, in e: Endeavor) -> some View {
        Button {
            guard let person = row.person else { return }
            deepLinkPersonID?.wrappedValue = person.id
            selectedSection?.wrappedValue  = .directory
        } label: {
            HStack(spacing: 9) {
                MacAvatar(name: row.name, size: .row, tint: .purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(MacType.row).lineLimit(1)
                    // Shown, not hidden, matching `destinationRow`: renaming in
                    // Notion orphans the attachment, and a row that quietly
                    // disappears is worse than one that says why it will not open.
                    if row.person == nil {
                        Text("not in your people")
                            .font(MacType.meta).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if row.attached {
                Button("Remove", role: .destructive) { removePerson(row.name, from: e) }
            } else {
                // A derived row has nothing to remove — it is a fact about the
                // trip log, not a choice. Rather than a right-click that does
                // nothing, offer the one action that makes sense: promote it,
                // which also makes it removable and survives the visit being
                // re-dated out of range.
                Button("Attach to this endeavor") { attachPerson(row.name, to: e) }
            }
        }
    }

    private func attachPerson(_ name: String, to e: Endeavor) {
        guard let store, !e.people.contains(name) else { return }
        var updated = e
        updated.people.append(name)
        Task { _ = try? await store.update(updated) }
    }

    private func removePerson(_ name: String, from e: Endeavor) {
        guard let store else { return }
        var updated = e
        updated.people.removeAll { $0 == name }
        Task { _ = try? await store.update(updated) }
    }

    /// Notes this endeavor's body links to, resolved against Projects and Daily.
    ///
    /// David: *"I created a new project note which contains a text about Megans
    /// wedding and i want to link that to the main Megan Endeavor note without
    /// having to type that entire text into the endeavor. This will save space
    /// and organize things."*
    ///
    /// **Derived from the body, not stored** — the opposite call to `places:`
    /// (D59) and the same one as the trip log (D28). A wikilink in the prose *is*
    /// the link; a parallel list in frontmatter would be a second copy that can
    /// disagree with what you can see written on the page. It also means removal
    /// is deleting the link, which is what anyone would try first.
    ///
    /// No `+`. The way to add one is to type `[[` in the body and pick the note,
    /// which is where you are already looking when you decide to link it.
    private func linkedNotes(_ e: Endeavor) -> [LinkableNote] {
        let targets = NoteStore.wikilinkTargets(in: e.body)
        guard !targets.isEmpty else { return [] }
        var seen = Set<String>()
        return targets.compactMap { target in
            linkableNotes.first {
                $0.title.localizedCaseInsensitiveCompare(target) == .orderedSame
            }
        }
        .filter { seen.insert($0.relativePath).inserted }
    }

    @ViewBuilder
    private func linkedNotesSection(_ e: Endeavor) -> some View {
        let notes = linkedNotes(e)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes").macLabel().foregroundStyle(.tertiary)
                Spacer()
                if !notes.isEmpty {
                    Text("\(notes.count)")
                        .font(MacType.metaEmphasis).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)

            if notes.isEmpty {
                railEmpty("Type [[ in the note to link one.")
            } else {
                ForEach(notes) { note in linkedNoteRow(note) }
            }
        }
    }

    private func linkedNoteRow(_ note: LinkableNote) -> some View {
        Button {
            deepLinkNotePath?.wrappedValue = note.relativePath
            selectedSection?.wrappedValue  = .notes
        } label: {
            HStack(spacing: 9) {
                MacIconBadge(icon: note.isDaily ? "calendar" : "doc.text",
                             // Same literal the editor paints a note wikilink
                             // with, read off the storage rather than re-picked,
                             // so the badge and the link cannot drift apart.
                             tint: Color(nsColor: MacMarkdownTextStorage.noteLinkColor),
                             size: .compact)
                Text(note.title).font(MacType.row).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Places attached to this endeavor, ahead of any visit.
    ///
    /// **The rail was entirely retrospective before this.** Visits, People and
    /// Satchel are all records of things that happened. David asked for the
    /// other half — *"How do i attach locations/places to my endeavor?"* — with
    /// Lakemore Resort, a destination for a wedding weeks away that nobody has
    /// checked into yet.
    ///
    /// It sits **above** Visits deliberately: where you are going comes before
    /// where you went, and for an upcoming endeavor Visits is empty anyway.
    ///
    /// Rows rather than pills, matching Satchel and People. The rail is 232pt
    /// and pills wrap badly in it — the same call as D26.
    @ViewBuilder
    private func destinationsSection(_ e: Endeavor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Destinations").macLabel().foregroundStyle(.tertiary)
                Spacer()
                if !e.places.isEmpty {
                    Text("\(e.places.count)")
                        .font(MacType.metaEmphasis).foregroundStyle(.tertiary)
                }
                Button { addingDestinationTo = e } label: {
                    Image(systemName: "plus")
                        .font(MacGlyph.smallBold)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a destination to \(e.name)")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)

            if e.places.isEmpty {
                railEmpty("Nowhere attached yet.")
            } else {
                ForEach(e.places, id: \.self) { name in destinationRow(name, in: e) }
            }
        }
    }

    /// One attached destination.
    ///
    /// **Skipped destinations are shown, dimmed and struck, not hidden.**
    /// Session 72 gave the Active tab's band a "Didn't go" button that writes
    /// `skipped:` to the endeavor, and then nothing in the app rendered that
    /// key — so the answer was unreversible from inside the app and the file
    /// looked identical to one that had never been asked. David's own rule from
    /// the same day, about a Place record with no visible bucket: **a derived
    /// or recorded judgement has to be visible to be challenged.** Same
    /// mistake, made twice in one session, caught the second time by having
    /// been caught the first.
    ///
    /// The row keeps its normal target — a skipped place is still a place, and
    /// clicking it should still open it — and gains "Went after all" in the
    /// context menu beside Remove.
    private func destinationRow(_ name: String, in e: Endeavor) -> some View {
        let place = notionService.places.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        let isSkipped = e.skippedPlaces.contains {
            shortPlaceName($0).caseInsensitiveCompare(shortPlaceName(name)) == .orderedSame
        }
        return Button {
            guard let place else { return }
            deepLinkPlaceID?.wrappedValue  = place.id
            selectedSection?.wrappedValue  = .directory
        } label: {
            HStack(spacing: 9) {
                MacIconBadge(icon: placeIcon(for: place?.category ?? ""),
                             tint: placeColor(for: place?.category ?? ""),
                             size: .compact)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortPlaceName(name))
                        .font(MacType.row)
                        .lineLimit(1)
                        .strikethrough(isSkipped, color: .secondary)
                        .foregroundStyle(isSkipped ? .secondary : .primary)
                    // A name that no longer resolves is SHOWN, not hidden.
                    // Renaming a Place in Notion orphans the attachment, and a
                    // row that quietly disappears is worse than one that says
                    // why it will not open.
                    if place == nil {
                        Text("not in your places")
                            .font(MacType.meta).foregroundStyle(.tertiary)
                    } else if isSkipped {
                        // Says which answer was given, not merely that one was.
                        Text("didn't go")
                            .font(MacType.meta).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isSkipped ? 0.75 : 1)
        .contextMenu {
            if isSkipped {
                Button("Went after all") { Task { await unskip(name, in: e) } }
            }
            Button("Remove", role: .destructive) { remove(name, from: e) }
        }
    }

    /// Clears a destination's skipped mark, putting it back in the Active tab's
    /// band as an open question. **Not the same as logging a visit** — that is
    /// what the band's own "Went" button is for, and doing both from one menu
    /// item would guess a date he has not been asked about.
    private func unskip(_ name: String, in e: Endeavor) async {
        guard let store else { return }
        var updated = e
        let short = shortPlaceName(name).lowercased()
        updated.skippedPlaces.removeAll {
            shortPlaceName($0).lowercased() == short
        }
        guard updated.skippedPlaces.count != e.skippedPlaces.count else { return }
        _ = try? await store.update(updated)
    }

    private func attach(_ name: String, to e: Endeavor) {
        guard let store, !e.places.contains(name) else { return }
        var updated = e
        updated.places.append(name)
        Task { _ = try? await store.update(updated) }
    }

    private func remove(_ name: String, from e: Endeavor) {
        guard let store else { return }
        var updated = e
        updated.places.removeAll { $0 == name }
        Task { _ = try? await store.update(updated) }
    }

    /// The Satchel rail section, and the first place in TraceMac that files a
    /// document against an Endeavor.
    ///
    /// David: *"i dont think i need the document in the note. Look at how this
    /// works in IOS. It is just added as a pill I believe and when i click it
    /// opens the satchel. Same could be true on the mac."*
    ///
    /// The **behaviour** he is describing already existed here: `documentRow`
    /// deep-links into the Documents section, which is the Mac's Satchel. Two
    /// things did not. It was filtering on the wrong key (see `documents(for:)`),
    /// and there was no way to put a document there at all.
    ///
    /// **The drop target is the whole section, and there is no paperclip.** The
    /// Mac has a pointer and a visible filesystem that the phone does not, so
    /// dragging is the native verb for adding a file — and
    /// `MarkdownNSTextView.draggingEntered` already refuses file drags
    /// specifically so they fall through to a zone like this one. The `+` is
    /// the keyboard-and-panel path, the same `NSOpenPanel` the Documents
    /// section has carried since it was written.
    ///
    /// **Kept as rows, not the phone's pills.** A pill is right on a full-width
    /// note screen where documents are their own band. This rail is 232pt wide
    /// and everything else in it — visits, people — is a badge, a title and a
    /// subtitle in a row. Copying the pill across would make the one section
    /// that is a list stop looking like one.
    @ViewBuilder
    private func satchelSection(_ e: Endeavor) -> some View {
        let docs = documents(for: e)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Satchel").macLabel().foregroundStyle(.tertiary)
                Spacer()
                if !docs.isEmpty {
                    Text("\(docs.count)").font(MacType.metaEmphasis).foregroundStyle(.tertiary)
                }
                Button { chooseDocuments(for: e) } label: {
                    // 9pt bold to sit level with the `.macLabel()` beside it,
                    // in a 16pt hit area — the glyph belongs to the header's
                    // scale, the target does not have to.
                    Image(systemName: "plus")
                        .font(MacGlyph.smallBold)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a document to \(e.name)")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)

            if docs.isEmpty {
                // States the gesture rather than the absence. The empty rail
                // is the only place a drop zone with no contents can announce
                // itself, and a zone nobody knows about is not a feature.
                railEmpty("Nothing filed yet. Drop a file here.")
            } else {
                // Grouped by `DocumentBucket`, Session 72, the same buckets the
                // phone uses and derived from the same `resolvedIcon`.
                //
                // **No collapsing here, unlike iOS.** The phone collapses
                // because the endeavor screen is one fixed vertical budget and
                // the documents were eating the note. This rail is a scrolling
                // 232pt column whose whole job is showing what is attached, so
                // hiding it behind six disclosure triangles would be borrowing a
                // solution to a problem this side does not have. Sub-headers
                // instead, reading like the Destinations / Visits / People
                // sections above.
                //
                // **Always headed, including for a single group.** The first
                // version suppressed the header below two groups on the grounds
                // that a rail reading "Satchel 1 / Receipts 1" says the same
                // thing twice. David, looking at Lunch with Bronwyn: *"on the
                // mac the one satchel item has no organization?"*
                //
                // He is right, and it is not a cosmetic point. That document is
                // the Nick's on the Lake reservation, and it carries `icon:
                // card`, so it files under **Receipts** — wrong for what it
                // actually is. The whole scheme rests on a wrong bucket being
                // obvious and one tap to fix in Satchel's icon picker, and a
                // suppressed header hides exactly the case that needs fixing.
                // **Tidiness was bought with the thing that makes it
                // correctable.**
                let groups = DocumentBucket.group(docs)
                Group {
                    ForEach(groups, id: \.bucket) { group in
                        HStack(spacing: 5) {
                            Image(systemName: group.bucket.sfSymbol)
                                .font(MacGlyph.smallBold)
                                .foregroundStyle(.tertiary)
                            Text(group.bucket.shortLabel).macLabel().foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(group.documents.count)")
                                .font(MacType.metaEmphasis)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        ForEach(group.documents, id: \.relativePath) { d in documentRow(d) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: isDocDropTargeted ? 1.5 : 0)
                .padding(.horizontal, 6)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDocDropTargeted) { providers in
            handleDocumentDrop(providers, for: e)
        }
    }

    private func chooseDocuments(for e: Endeavor) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt  = "Add"
        panel.message = "Add to \(e.name)"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                _ = try? docStore?.importDocument(from: url, filedTo: e)
            }
            Task { @MainActor in await docStore?.reload() }
        }
    }

    /// Mirrors `TraceMacDocumentsView.handleDrop` deliberately, including the
    /// security-scope dance and doing the import **inside** the provider
    /// closure. The scope ends when that closure returns, so hopping to the
    /// main actor before reading would put the read outside it — a sandbox
    /// denial that presents as a file that is simply not there.
    ///
    /// Directories and dotfiles are refused for the same reason they are there:
    /// `importDocument` files whatever it is given as an opaque blob, and a
    /// folder dropped by accident would become a zero-byte document with a
    /// plausible name.
    @discardableResult
    private func handleDocumentDrop(_ providers: [NSItemProvider], for e: Endeavor) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue,
                      !url.lastPathComponent.hasPrefix(".") else { return }

                _ = try? docStore?.importDocument(from: url, filedTo: e)
                Task { @MainActor in await docStore?.reload() }
            }
            handled = true
        }
        return handled
    }

    private func documentRow(_ d: TraceMacDocument) -> some View {
        Button {
            deepLinkDocumentPath?.wrappedValue = d.relativePath
            selectedSection?.wrappedValue      = .documents
        } label: {
            documentRowBody(d).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func documentRowBody(_ d: TraceMacDocument) -> some View {
        HStack(spacing: 9) {
            // The document's own icon and tint, as set in Satchel. This was a
            // hard-coded blue `doc.richtext` for every row, which threw away
            // the one piece of metadata whose entire job is to make a document
            // recognisable at a glance.
            MacIconBadge(icon: d.resolvedIcon.sfSymbol,
                         tint: MacPalette.documentTint(d.resolvedTint),
                         size: .compact)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.title).font(MacType.row).lineLimit(1)
                if let c = d.created {
                    Text(c, format: .dateTime.day().month(.abbreviated))
                        .font(MacType.meta).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
    }
}


// MARK: - Cover band image

/// A container-relative image drawn to fill a wide band.
///
/// Separate from `MacNoteStorePhotoView` because that view takes a single
/// `size` and applies it to both axes — correct for the square photo wells it
/// was written for, useless here. The iCloud staircase is the same one the
/// document preview uses: ask for the file, and if it is not local yet, start
/// the download and retry on a widening delay rather than rendering a
/// permanent placeholder for a file that is on its way.
private struct MacEndeavorCover: View {
    let path: String
    /// 0 is the top edge of the photograph, 1 the bottom. See
    /// `Endeavor.coverOffset`. Defaults to centred, which is exactly what the
    /// bare `scaledToFill` this replaced did.
    var offset: Double = 0.5
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image {
                    // **Not `scaledToFill().frame(w, h)`.** That produces a view
                    // of the band's size whose content overflows *centred*, and
                    // an `.offset` on it moves the frame too, sliding empty
                    // space in from one edge. The scaled size is computed here
                    // instead and the image is positioned inside a top-leading
                    // stack, so the offset moves the picture within a fixed
                    // window — which is what repositioning means.
                    let box = fill(image.size, in: geo.size)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: box.width, height: box.height)
                        // Horizontal stays centred: the band is wide and short,
                        // so a normal photograph has no horizontal overflow to
                        // choose from. See `Endeavor.coverOffset`.
                        .offset(x: (geo.size.width - box.width) / 2,
                                y: -max(0, box.height - geo.size.height) * offset)
                } else {
                    LinearGradient(colors: [Color.secondary.opacity(0.22),
                                            Color.secondary.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: path) { image = await load() }
    }

    /// The size the image is drawn at to cover `box` without distortion, i.e.
    /// what `scaledToFill` computes internally and does not expose.
    private func fill(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = max(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func load() async -> NSImage? {
        guard let url = NoteStore.shared.resolvedURL(for: path) else { return nil }
        if let img = NSImage(contentsOf: url) { return img }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for delay in [300, 700, 1_500, 3_000] as [UInt64] {
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            if let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }
}


// MARK: - Endeavor sheet (new and settings)

/// One sheet for creating and for editing.
///
/// Session 65. Created first as `MacNewEndeavorSheet`, then David: you can make
/// an endeavor on the Mac and cannot change it. The fix was **not** a second
/// sheet. The two differ by a title, a status field and a delete button; every
/// other field, every validation and the whole layout is the same, and two
/// copies of that is how a field gets added to one and forgotten in the other.
/// `DayflowEndeavorViews` made the same call — one sheet, an optional
/// `existing`.
///
/// **Five fields, not everything an Endeavor can carry.** Cover has its own
/// picker on the band, and `placeID` is a phone concept that has no picker here
/// yet — it is preserved through the round trip rather than offered.
///
/// **Dates are optional and the end is not defaulted to the start.** A dateless
/// endeavor is legitimate; that is what `EndeavorStatus.idea` is for. Copying
/// `starts` into `ends` would silently make every open-ended project a one-day
/// event in the status filter.
///
/// **The name does not rename the file.** The slug is the identity, the path is
/// where the bytes are, and moving the file to stay cosmetically in step would
/// break `linked_note` on every document filed against it — which now includes
/// everything dropped on the Satchel rail.
struct MacEndeavorSheet: View {

    /// `Travel` and `Project`, matching `DayflowEndeavorViews`' own two. Not an
    /// enum: `type` is a free string on the model and on disk, and closing it
    /// here would make a hand-edited third value unparseable on the Mac and
    /// fine on the phone.
    private let types = ["Travel", "Project"]

    /// Nil creates, non-nil edits.
    let existing: Endeavor?
    let onSave: (Endeavor?, String, String, Date?, Date?, String, EndeavorStatus?, Bool) async -> Void
    /// Only offered when editing. Nil hides the button entirely.
    var onDelete: ((Endeavor) async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var name        = ""
    @State private var type        = "Travel"
    @State private var destination = ""
    @State private var hasStart    = true
    @State private var hasEnd      = true
    @State private var starts      = Date()
    @State private var ends        = Date()
    @State private var status: EndeavorStatus? = nil
    @State private var stamps      = true
    @State private var saving      = false
    @State private var confirmingDelete = false
    @State private var seeded      = false

    private var isEdit: Bool { existing != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEdit ? "Endeavor Settings" : "New Endeavor")
                .font(MacType.heading)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $type) {
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }
                // Doubles as the cover search seed, which is why it earns a
                // field rather than a line in the body: type it once.
                TextField("Destination", text: $destination)

                Toggle("Start date", isOn: $hasStart)
                if hasStart { MacDateField(label: "Starts", date: $starts) }
                Toggle("End date", isOn: $hasEnd)
                if hasEnd { MacDateField(label: "Ends", date: $ends) }

                if isEdit {
                    // ONLY the two a calendar cannot express. Active, upcoming
                    // and past are computed from the dates, and offering them
                    // here would let you pin a status that then contradicts
                    // them — `EndeavorStatus.storable` is the model saying so.
                    Picker("Status", selection: $status) {
                        Text("From dates").tag(EndeavorStatus?.none)
                        ForEach(EndeavorStatus.storable, id: \.self) { s in
                            Text(s.label).tag(EndeavorStatus?.some(s))
                        }
                    }
                    // Edit-only. On create it is derived from the dates by
                    // `newEndeavor`, and a toggle that has to re-derive itself
                    // every time a date picker moves is a toggle that will
                    // disagree with the model.
                    Toggle("Stamp captures", isOn: $stamps)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isEdit, onDelete != nil {
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                        .disabled(saving)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 380)
        .confirmationDialog("Delete “\(existing?.name ?? "")”?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let existing, let onDelete else { return }
                saving = true
                Task { await onDelete(existing); dismiss() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Deletes the note. Documents filed to it are left alone — Satchel owns those.")
        }
        .task {
            // Seeded once, not bound: an edit to a field must survive the next
            // re-render, and `.task` re-runs on identity change rather than on
            // every body evaluation.
            guard !seeded, let e = existing else { seeded = true; return }
            seeded      = true
            name        = e.name
            type        = types.contains(e.type) ? e.type : types[0]
            destination = e.destination ?? ""
            hasStart    = e.starts != nil
            hasEnd      = e.ends   != nil
            if let s = e.starts { starts = s }
            if let n = e.ends   { ends   = n }
            status      = e.statusOverride
            stamps      = e.stampsCaptures
        }
    }

    private func save() {
        saving = true
        Task {
            await onSave(existing, name, type,
                         hasStart ? starts : nil,
                         hasEnd   ? ends   : nil,
                         destination, status, stamps)
            dismiss()
        }
    }
}

// MARK: - Cover picker

/// Search Wikimedia Commons for a cover, or pick a file.
///
/// Session 65. David: *"Id like the same way to add the cover image like we did
/// with the iphone. It looks up photos based on my search."*
///
/// **Commons, not Unsplash**, and that was decided on 2026-07-29 by Unsplash's
/// own API terms: *"All API uses must use the hotlinked image URLs returned by
/// the API"*. D8 requires the opposite, for a reason that cannot be negotiated
/// away — a cover that is a remote URL goes blank on a plane, which is exactly
/// when a trip note is most likely to be open. The full argument, and the
/// three-pass quality cascade that makes Commons results usable, are in
/// `Trace/CommonsImages.swift`.
///
/// **Seeded from the destination, not left empty.** The endeavor already knows
/// where it is, and an empty search box on a sheet whose whole job is one query
/// is a question the app can answer itself. Editable, because "Lake Geneva, WI"
/// is a worse search term than "Lake Geneva".
///
/// **Choose File sits beside the search, not behind it.** The Mac has a
/// filesystem and David has his own photographs of these trips; making the web
/// the primary path and the disk a fallback would be the phone's constraint
/// imported into a place that does not have it.
struct MacCoverPickerSheet: View {

    let endeavor: Endeavor
    /// (image bytes, credit line). Credit is nil for a local file — there is
    /// nobody to credit, and writing an empty string would leave the field
    /// present and blank in the frontmatter.
    let onPick: (Data, String?) async -> Void
    /// Clears the reference. Offered only when there is one, and it is a
    /// separate closure rather than `onPick(nil, nil)` so "set" and "clear"
    /// cannot be confused at the call site.
    var onRemove: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var query   = ""
    @State private var results: [CommonsImage] = []
    @State private var loading = false
    @State private var picking = false
    @State private var message: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Cover").font(MacType.heading)
                Spacer()
                if endeavor.cover?.isEmpty == false, onRemove != nil {
                    Button("Remove") {
                        picking = true
                        Task { await onRemove?(); dismiss() }
                    }
                    .disabled(picking)
                }
                Button("Choose File…") { chooseFile() }
                    .disabled(picking)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            HStack(spacing: 8) {
                TextField("Search Wikimedia Commons", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Search") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)

            Divider()

            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message {
                    MacEmptyState.placeholder("photo", message)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    MacEmptyState.placeholder("photo", "Search for a photograph, or choose a file.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)],
                                  spacing: 10) {
                            ForEach(results) { image in
                                Button { pick(image) } label: { thumb(image) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(height: 360)

            Divider()
            HStack {
                if picking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 580)
        .task {
            // Seeded once, on appear, rather than bound to the destination —
            // so an edit survives a re-render.
            if query.isEmpty {
                query = endeavor.destination?.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? endeavor.name
            }
            if !query.isEmpty { search() }
        }
    }

    /// Drawn at the cover's own proportions, not square. The band is roughly
    /// 3:1, and a square thumbnail of a portrait photograph looks fine and then
    /// arrives as a slice of one wall — which is the complaint that produced
    /// the `ranked` shape heuristic in the service.
    private func thumb(_ image: CommonsImage) -> some View {
        AsyncImage(url: image.thumbURL) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            case .failure:          Color(nsColor: .controlBackgroundColor)
            default:                Color(nsColor: .controlBackgroundColor)
            }
        }
        .frame(height: 74)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomLeading) {
            if !image.credit.isEmpty {
                Text(image.credit)
                    .font(MacType.meta)
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        loading = true
        message = nil
        Task {
            do {
                results = try await CommonsImageService.search(term)
                if results.isEmpty { message = "Nothing found for “\(term)”." }
            } catch {
                results = []
                // The service's errors are already written for a person to
                // read, so they are shown rather than replaced with a generic
                // line. Anything else loses "check your connection".
                message = error.localizedDescription
            }
            loading = false
        }
    }

    private func pick(_ image: CommonsImage) {
        picking = true
        Task {
            defer { picking = false }
            guard let data = try? await CommonsImageService.download(image) else {
                message = "Could not download that photo."
                return
            }
            await onPick(data, image.credit.isEmpty ? nil : image.credit)
            dismiss()
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            picking = true
            Task {
                await onPick(data, nil)
                picking = false
                dismiss()
            }
        }
    }
}

// MARK: - Add destination

/// Attaches a saved Place to an endeavor.
///
/// Session 66. **Saved places only, deliberately.** Discover already owns
/// finding somewhere new and saving it, and a second search that could create
/// records would be a second place for that decision to live. If Lakemore
/// Resort is not in the list, the answer is to save it in Discover first, and
/// the empty state says so rather than leaving you guessing.
///
/// Filters on the full name, not the shortened one, because that is what is
/// written to the file — searching on a display form and storing another is how
/// a list stops matching itself.
struct MacAddDestinationSheet: View {

    let endeavor: Endeavor
    let places: [Place]
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [Place] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = places
            .filter { !endeavor.places.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !q.isEmpty else { return Array(pool.prefix(50)) }
        return pool.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a destination")
                .font(MacType.heading)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            TextField("Search your places", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.bottom, 12)

            Divider()

            Group {
                if matches.isEmpty {
                    MacEmptyState.placeholder(
                        "mappin.slash",
                        query.isEmpty ? "Every place is already attached."
                                      : "Nothing saved matches. Save it in Discover first.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(matches) { place in
                        Button {
                            onAdd(place.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 9) {
                                MacIconBadge(icon: placeIcon(for: place.category),
                                             tint: placeColor(for: place.category),
                                             size: .compact)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(place.name).font(MacType.row).lineLimit(1)
                                    if !place.category.isEmpty {
                                        Text(place.category)
                                            .font(MacType.meta).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(height: 300)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 380)
    }
}

// MARK: - Add person

/// Attaches a saved Person to an endeavor. `MacAddDestinationSheet` for people,
/// deliberately down to the wording: the two do the same job and reading
/// differently would be drift, not variety.
///
/// **Saved people only**, on the same reasoning — Directory owns creating a
/// person, and a second search that could create records would be a second home
/// for that decision.
///
/// Archived people are filtered out. They are archived because David is no
/// longer tracking them, and an endeavor is a live thing.
struct MacAddPersonSheet: View {

    let endeavor: Endeavor
    let people: [Person]
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [Person] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = people
            .filter { !$0.isArchived }
            .filter { !endeavor.people.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !q.isEmpty else { return Array(pool.prefix(50)) }
        return pool.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add someone")
                .font(MacType.heading)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            TextField("Search your people", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.bottom, 12)

            Divider()

            Group {
                if matches.isEmpty {
                    MacEmptyState.placeholder(
                        "person.slash",
                        query.isEmpty ? "Everyone is already attached."
                                      : "Nobody saved matches. Add them in Directory first.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(matches) { person in
                        Button {
                            onAdd(person.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 9) {
                                MacAvatar(name: person.name, size: .row, tint: .purple)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name).font(MacType.row).lineLimit(1)
                                    if let rel = person.relationship, !rel.isEmpty {
                                        Text(rel).font(MacType.meta).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 420, height: 480)
    }
}
