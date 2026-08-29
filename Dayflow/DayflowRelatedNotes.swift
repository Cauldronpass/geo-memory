import SwiftUI

// MARK: - DayflowRelatedNotes
//
// Shared "Related Notes" engine + UI — extracted 2026-07-23 (Session 38) from
// DayflowProjectNoteView.swift, where the whole feature (parsing/serializing
// the "## Related Notes" markdown table, the native row rendering, and the
// Daily/Project/Person/Place/Visit link flow) was originally built Sessions
// 37-37.4 as private, screen-local code.
//
// Reason for extraction: David asked to bring the same linking ability to
// the Daily Note (both the home-screen card and the full-page view). The
// feature is ~400 lines of parsing, serialization, candidate-building, and
// multi-step sheet flow — duplicating that wholesale into
// DayflowDailyNoteEditor.swift would mean two independently-maintained
// copies of the same logic that drift the first time either gets a bug fix
// or a new link type (see this file's own Visit addition for how much a
// "just add a case" change touches). Small helpers still get duplicated
// per-file elsewhere in this codebase when genuinely small (see
// DayflowInteractionDetailView's own copy of `icon(for:)`) — this isn't
// that; it's the whole feature.
//
// `DayflowProjectNoteView.swift` was migrated to call into this file rather
// than kept on its own private implementation, so there is exactly one
// implementation of Related Notes, not two that happen to agree today.
//
// Split three ways:
//   - `RelatedNoteRow` / `DayflowLinkKind` — the shared model.
//   - `DayflowRelatedNotesEngine` — pure parsing/serialization/candidate
//     logic, no SwiftUI. Both screens call these from their own load/save.
//   - `DayflowRelatedNotesSection` / `DayflowLinkFlowSheet` /
//     `DayflowDailyNotePeekSheet` — the reusable views. Each screen still
//     owns its own `relatedNotes`/`activeLinkFlow`/peek `@State` and its own
//     load/save (the file header format differs — "# <title>" vs
//     "# yyyy-MM-dd" — so persistence stays screen-local), and wires that
//     state into these shared views via bindings and callbacks.

// MARK: - Model

enum DayflowLinkKind { case daily, project, person, place, visit }

/// One row of a note's "## Related Notes" table, parsed from (and
/// serialized back to) real markdown. `.unknown` covers a wikilink name that
/// doesn't classify as a date, an existing project, a known person/place, or
/// a `visit:` id (e.g. a renamed/deleted project, or a stale hand-edit) —
/// still shown, not silently dropped, just with a generic icon and a no-op
/// tap.
struct RelatedNoteRow: Identifiable {
    enum Kind {
        case daily(Date)
        case project(String)
        case person(String)
        case place(String)
        /// Associated value is the Visit's own Notion page ID — a Visit has
        /// no unique name (a place can have several), so unlike the other
        /// four cases the ID and the display label are different strings.
        case visit(String)
        case unknown(String)
    }

    let id = UUID()
    var kind: Kind
    var description: String

    var wikilinkName: String {
        switch kind {
        case .daily(let date):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        case .visit(let id):
            return "visit:\(id)"
        case .project(let name), .person(let name), .place(let name), .unknown(let name):
            return name
        }
    }
}

// MARK: - Engine (pure logic, no SwiftUI)

enum DayflowRelatedNotesEngine {
    // MARK: Parsing + serialization
    //
    // A "## Related Notes" heading, then "| [[Name]] | Description |" rows
    // under a standard two-column header/divider. Parsing is regex-based on
    // the wikilink shape specifically, so the header ("| Note | Relationship |")
    // and divider ("| --- | --- |") rows never accidentally match — neither
    // contains "[[...]]".

    static func split(_ text: String) -> (prose: String, notes: [RelatedNoteRow]) {
        let heading = "## Related Notes"
        var lines = text.components(separatedBy: "\n")
        guard let headingIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else {
            return (text, [])
        }
        var sectionEnd = lines.count
        for i in (headingIdx + 1)..<lines.count where lines[i].hasPrefix("## ") {
            sectionEnd = i
            break
        }
        let rows = lines[(headingIdx + 1)..<sectionEnd].compactMap { parseRow($0) }
        lines.removeSubrange(headingIdx..<sectionEnd)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return (lines.joined(separator: "\n"), rows)
    }

    static func parseRow(_ line: String) -> RelatedNoteRow? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: #"^\|\s*\[\[(.+?)\]\]\s*\|\s*(.*?)\s*\|$"#) else { return nil }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: match.range(at: 1))
        let description = ns.substring(with: match.range(at: 2))
        return RelatedNoteRow(kind: classify(name), description: description)
    }

    static func serialize(_ notes: [RelatedNoteRow]) -> String {
        guard !notes.isEmpty else { return "" }
        var lines = ["## Related Notes", "", "| Note | Relationship |", "| --- | --- |"]
        for row in notes {
            lines.append("| [[\(row.wikilinkName)]] | \(row.description) |")
        }
        return lines.joined(separator: "\n")
    }

    static func classify(_ name: String) -> RelatedNoteRow.Kind {
        if let date = parseDailyNoteDate(name) { return .daily(date) }
        if name.hasPrefix("visit:") {
            return .visit(String(name.dropFirst("visit:".count)))
        }
        let projectFiles = (try? NoteStore.shared.listFiles(in: "Notes/Projects")) ?? []
        if projectFiles.contains(where: { $0.replacingOccurrences(of: ".md", with: "") == name }) {
            return .project(name)
        }
        if NotionService.shared.places.contains(where: { $0.name == name }) { return .place(name) }
        if NotionService.shared.people.contains(where: { $0.name == name }) { return .person(name) }
        return .unknown(name)
    }

    // MARK: Display

    static func dailyNoteHeadline(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: date)
    }

    static func parseDailyNoteDate(_ name: String) -> Date? {
        guard name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: name)
    }

    /// "<Place> — <date>" — computed live from `NotionService.shared.visits`
    /// rather than stored, so it stays correct even if the visit's place/date
    /// change later in Trace. Falls back to a generic label if the visit was
    /// since deleted (same "still shown, not silently dropped" treatment
    /// `.unknown` gets).
    static func visitDisplayLabel(forID id: String) -> String {
        guard let visit = NotionService.shared.visits.first(where: { $0.id == id }) else {
            return "Visit (not found)"
        }
        return visitDisplayLabel(placeName: visit.placeName, date: visit.date)
    }

    static func visitDisplayLabel(placeName: String, date: Date) -> String {
        "\(placeName) — \(date.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    static func iconName(for kind: RelatedNoteRow.Kind) -> String {
        switch kind {
        case .daily: return "calendar"
        case .project: return "folder"
        case .person: return "person"
        case .place: return "mappin.and.ellipse"
        case .visit: return "figure.walk"
        case .unknown: return "questionmark.circle"
        }
    }

    static func label(for kind: RelatedNoteRow.Kind) -> String {
        switch kind {
        case .daily(let date): return dailyNoteHeadline(date)
        case .visit(let id): return visitDisplayLabel(forID: id)
        case .project(let name), .person(let name), .place(let name), .unknown(let name): return name
        }
    }

    /// e.g. "(6 — 3 daily, 2 people, 1 visit)" — categories with a zero count
    /// are omitted entirely rather than always listing all five.
    static func counterLabel(for notes: [RelatedNoteRow]) -> String {
        var daily = 0, project = 0, person = 0, place = 0, visit = 0, other = 0
        for row in notes {
            switch row.kind {
            case .daily: daily += 1
            case .project: project += 1
            case .person: person += 1
            case .place: place += 1
            case .visit: visit += 1
            case .unknown: other += 1
            }
        }
        var parts: [String] = []
        if daily > 0 { parts.append("\(daily) daily") }
        if project > 0 { parts.append("\(project) project\(project == 1 ? "" : "s")") }
        if person > 0 { parts.append("\(person) \(person == 1 ? "person" : "people")") }
        if place > 0 { parts.append("\(place) place\(place == 1 ? "" : "s")") }
        if visit > 0 { parts.append("\(visit) visit\(visit == 1 ? "" : "s")") }
        if other > 0 { parts.append("\(other) other") }
        return "(\(notes.count) — \(parts.joined(separator: ", ")))"
    }

    // MARK: Candidate lists + note-dot data

    static func projectCandidates(excludingTitle: String?) -> [(id: String, label: String)] {
        let files = (try? NoteStore.shared.listFiles(in: "Notes/Projects")) ?? []
        return files.map { $0.replacingOccurrences(of: ".md", with: "") }
            .filter { $0 != excludingTitle }
            .sorted()
            .map { (id: $0, label: $0) }
    }

    static func personCandidates() -> [(id: String, label: String)] {
        NotionService.shared.people.map { $0.name }.sorted().map { (id: $0, label: $0) }
    }

    static func placeCandidates() -> [(id: String, label: String)] {
        NotionService.shared.places.map { $0.name }.sorted().map { (id: $0, label: $0) }
    }

    /// Newest first — a Visit has no name to alphabetize by, and the most
    /// recent visits are the ones most likely to be what's being linked.
    static func visitCandidates() -> [(id: String, label: String)] {
        NotionService.shared.visits
            .sorted { $0.date > $1.date }
            .map { (id: $0.id, label: visitDisplayLabel(placeName: $0.placeName, date: $0.date)) }
    }

    /// Same computation DayflowCalendarBrowseView.swift's own note-dot
    /// indicator uses — Calendar note filenames parsed to start-of-day Dates
    /// for a plain Set lookup.
    static func datesWithNotes() async -> Set<Date> {
        guard let filenames = try? NoteStore.shared.listFiles(in: "Calendar") else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let dates = filenames.compactMap { filename -> Date? in
            let stem = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
            guard let parsed = formatter.date(from: stem) else { return nil }
            return cal.startOfDay(for: parsed)
        }
        return Set(dates)
    }
}

// MARK: - Shared "link a note" Menu items — used both by
// DayflowRelatedNotesSection's own inline add affordance and by
// DayflowProjectNoteView's screen-level header Menu, so the five options
// only ever get written out once.

@ViewBuilder
func dayflowLinkKindMenuItems(_ start: @escaping (DayflowLinkKind) -> Void) -> some View {
    Button { start(.daily) } label: {
        Label("Daily Note", systemImage: "calendar")
    }
    Button { start(.project) } label: {
        Label("Project Note", systemImage: "folder")
    }
    Button { start(.person) } label: {
        Label("Person", systemImage: "person")
    }
    Button { start(.place) } label: {
        Label("Place", systemImage: "mappin.and.ellipse")
    }
    Button { start(.visit) } label: {
        Label("Visit", systemImage: "figure.walk")
    }
}

// MARK: - DayflowRelatedNotesSection
//
// The native-rendered "RELATED NOTES" section: disclosure toggle (collapse
// to just the header — David's ask, Session 37 addendum 3), title + counter,
// expand toggle (peek-height vs. ~55% of the card — Session 37 addendum 2),
// and the row list itself.
//
// `onStartLink`, added for Daily Note (Session 38): Project Note already has
// a screen-level top-bar Menu for "link a note," so it passes `nil` here and
// keeps its existing hide-when-empty behavior unchanged — a second inline
// entry point would be redundant, not additive. Daily Note has no equivalent
// single top bar shared between its card and full-page forms, so it passes a
// real closure; when non-nil, the section always renders (even at zero
// notes) with an inline "Link a note" Menu affordance.

struct DayflowRelatedNotesSection: View {
    let relatedNotes: [RelatedNoteRow]
    @Binding var expanded: Bool
    @Binding var hidden: Bool
    let availableHeight: CGFloat
    var onStartLink: ((DayflowLinkKind) -> Void)? = nil
    let onOpen: (RelatedNoteRow.Kind) -> Void
    let onRemove: (RelatedNoteRow) -> Void

    /// Rows visible before scrolling kicks in, collapsed state — David's
    /// "three notes max." Row height is an estimate against `row(_:)`'s own
    /// padding/font sizes below; not confirmed on a real device.
    private let collapsedRowCount: CGFloat = 3
    private let rowHeight: CGFloat = 54

    var body: some View {
        if !relatedNotes.isEmpty || onStartLink != nil {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !relatedNotes.isEmpty && !hidden {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(relatedNotes) { row in
                                rowView(row)
                            }
                        }
                    }
                    // Collapsed: fits ~3 rows, scrolls past that. Expanded:
                    // "the larger part of the screen," sized off the actual
                    // available height via the caller's GeometryReader
                    // rather than a fixed point value.
                    //
                    // Session 38 addendum 3 — briefly replaced with a fixed
                    // point value on the theory that the caller's
                    // GeometryReader was the cause of a scroll/background
                    // bug David hit. Reverted (addendum 4) — removing the
                    // GeometryReader didn't fix the full-page issue and
                    // newly broke the home card, which had been fine, so
                    // GeometryReader was not actually the cause. Back to
                    // percentage-based sizing while the real cause gets
                    // diagnosed with more on-device detail.
                    .frame(height: expanded
                        ? max(availableHeight * 0.55, rowHeight * collapsedRowCount)
                        : rowHeight * collapsedRowCount)
                }
            }
            // Session 38 addendum — David flagged this section showing the
            // warm page background through on the Daily Note full page (no
            // card wrapper there, unlike the home card or Project Note,
            // which both already sit on a system-background card). A plain
            // white surface here keeps it visually attached to the note text
            // right above it instead of reading as a separate shaded block.
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private var header: some View {
        if relatedNotes.isEmpty, let start = onStartLink {
            Menu {
                dayflowLinkKindMenuItems(start)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Link a note")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.dayflowColumnLabel)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { hidden.toggle() }
                } label: {
                    // Tap target enlarged 16x16 -> 32x32, 2026-07-25 — David
                    // flagged this specific chevron as "real difficult to
                    // press. I have to press just right." The glyph itself
                    // stays the same visual size (font size unchanged); only
                    // the invisible frame around it grew, via
                    // .contentShape(Rectangle()) so the whole frame — not
                    // just the tiny rendered arrow — is tappable. 32x32 still
                    // trades off against this being a compact secondary
                    // header control, not a primary action, but it's 4x the
                    // hit area of the old 16x16 and now matches or exceeds
                    // the row's other icon buttons.
                    Image(systemName: hidden ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.dayflowColumnLabel)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hidden ? "Show related notes" : "Hide related notes")

                Text("RELATED NOTES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color.dayflowColumnLabel)
                Text(DayflowRelatedNotesEngine.counterLabel(for: relatedNotes))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dayflowColumnLabel.opacity(0.7))
                Spacer()
                if let start = onStartLink {
                    Menu {
                        dayflowLinkKindMenuItems(start)
                    } label: {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dayflowColumnLabel)
                            .frame(width: 20, height: 20)
                    }
                    .accessibilityLabel("Link a note")
                }
                if !hidden {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.dayflowColumnLabel)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Show fewer related notes" : "Show more related notes")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, hidden ? 12 : 6)
        }
    }

    @ViewBuilder
    private func rowView(_ row: RelatedNoteRow) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: DayflowRelatedNotesEngine.iconName(for: row.kind))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            Button {
                onOpen(row.kind)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(DayflowRelatedNotesEngine.label(for: row.kind))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if !row.description.isEmpty {
                        Text(row.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                onRemove(row)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        Divider().padding(.leading, 14)
    }
}

// MARK: - DayflowDailyNotePeekSheet
//
// Shared by two callers: peeking an existing Related Notes row that points
// at a Daily Note (`confirming: false`, just a back button), and step 2 of
// linking a new one from `DayflowLinkFlowSheet` below (`confirming: true`,
// adds a relationship field + Link button). Opens the real
// `DayflowDailyNoteEditor` — same backend the home card and full-page view
// use, not a read-only preview — so this doubles as a "confirm this is the
// right day" check either way.

struct DayflowDailyNotePeekSheet: View {
    let date: Date
    var confirming: Bool = false
    var linkDescription: Binding<String>? = nil
    var onBack: () -> Void
    var onLink: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(DayflowRelatedNotesEngine.dailyNoteHeadline(date)).font(.dayflowSerif(17))
                Spacer()
                if confirming, let onLink {
                    Button("Link", action: onLink)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.dayflowInk)
                        .disabled((linkDescription?.wrappedValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Color.clear.frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            DayflowDailyNoteEditor(date: date)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if confirming, let linkDescription {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RELATIONSHIP")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Color.dayflowColumnLabel)
                    TextField("Why is this related?", text: linkDescription, axis: .vertical)
                        .font(.system(size: 13))
                        .lineLimit(2...4)
                        .padding(10)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(14)
            }
        }
        .dayflowSkinBackground()
    }
}

// MARK: - DayflowLinkFlowSheet
//
// The whole Menu-dispatch + two picker shapes: Daily Note picking reuses
// DayflowMonthGridView.swift's existing note-dot indicator (Session 24) plus
// a peek-before-confirm via DayflowDailyNotePeekSheet above; Project/Person/
// Place/Visit picking share one two-step flow (pick from a searchable list,
// then describe + confirm).
//
// A fresh instance of this view is created every time its presenting
// `.sheet(isPresented:)` flips to true (see either caller's own body), so its
// own `@State` needs no manual reset between uses — unlike the very first
// version of this feature (Session 37), which lived directly on
// DayflowProjectNoteView's own long-lived `@State` and needed an explicit
// `resetLinkFlow()` call after every dismissal.

struct DayflowLinkFlowSheet: View {
    var initialKind: DayflowLinkKind
    /// Set only when opened from a Project Note — excludes that project's
    /// own title from the Project candidate list (can't link a project to
    /// itself).
    var excludeProjectTitle: String? = nil
    /// Set only when opened from a Daily Note — excludes that day from the
    /// Daily Note picker's calendar (can't link a day to itself).
    var excludeDailyDate: Date? = nil
    let onConfirm: (RelatedNoteRow.Kind, String) -> Void
    let onDismiss: () -> Void

    @State private var activeLinkFlow: DayflowLinkKind?
    @State private var linkingDailyDate: Date? = nil
    @State private var linkCandidate: String? = nil
    @State private var linkDescription = ""
    @State private var monthCursor = Date()
    @State private var datesWithNotes: Set<Date> = []
    /// Search box on the Project/Person/Place/Visit candidate picker.
    @State private var candidateSearchText = ""

    init(
        initialKind: DayflowLinkKind,
        excludeProjectTitle: String? = nil,
        excludeDailyDate: Date? = nil,
        onConfirm: @escaping (RelatedNoteRow.Kind, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialKind = initialKind
        self.excludeProjectTitle = excludeProjectTitle
        self.excludeDailyDate = excludeDailyDate
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        _activeLinkFlow = State(initialValue: initialKind)
    }

    var body: some View {
        switch activeLinkFlow {
        case .daily:
            if let date = linkingDailyDate {
                DayflowDailyNotePeekSheet(
                    date: date,
                    confirming: true,
                    linkDescription: $linkDescription,
                    onBack: { linkingDailyDate = nil },
                    onLink: {
                        onConfirm(.daily(date), linkDescription)
                        onDismiss()
                    }
                )
            } else {
                dailyPickerSheet
            }
        case .project:
            if let candidate = linkCandidate {
                describeAndConfirmSheet(title: candidate) {
                    onConfirm(.project(candidate), linkDescription)
                }
            } else {
                candidatePickerSheet(
                    title: "Link a Project Note", icon: "folder",
                    candidates: DayflowRelatedNotesEngine.projectCandidates(excludingTitle: excludeProjectTitle)
                )
            }
        case .person:
            if let candidate = linkCandidate {
                describeAndConfirmSheet(title: candidate) {
                    onConfirm(.person(candidate), linkDescription)
                }
            } else {
                candidatePickerSheet(title: "Link a Person", icon: "person", candidates: DayflowRelatedNotesEngine.personCandidates())
            }
        case .place:
            if let candidate = linkCandidate {
                describeAndConfirmSheet(title: candidate) {
                    onConfirm(.place(candidate), linkDescription)
                }
            } else {
                candidatePickerSheet(title: "Link a Place", icon: "mappin.and.ellipse", candidates: DayflowRelatedNotesEngine.placeCandidates())
            }
        case .visit:
            if let candidate = linkCandidate {
                describeAndConfirmSheet(title: DayflowRelatedNotesEngine.visitDisplayLabel(forID: candidate)) {
                    onConfirm(.visit(candidate), linkDescription)
                    // Session 78, D164 — the context flows BOTH ways for a
                    // Visit (David: "is there a way to... automatically add
                    // that context to the visit itself?"). The relationship
                    // text is appended to the Visit's own Notion Notes with
                    // a dated provenance stamp, via the same append the
                    // enrichment flow uses. Best-effort: the day-note link
                    // is the primary write and never waits on Notion.
                    let text = linkDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"
                        let stamp = "Linked \(f.string(from: Date())): \(text)"
                        Task { try? await NotionService.shared.appendVisitNotes(visitID: candidate, text: stamp) }
                    }
                }
            } else {
                candidatePickerSheet(title: "Link a Visit", icon: "figure.walk", candidates: DayflowRelatedNotesEngine.visitCandidates())
            }
        case nil:
            EmptyView()
        }
    }

    /// Month grid with the same note-dot indicator DayflowCalendarBrowseView
    /// already uses (DayflowMonthGridView.swift, built Session 24) — picking
    /// a day moves to the peek+confirm step, it doesn't link immediately.
    /// Tapping the excluded (self) date, if any, is a silent no-op.
    private var dailyPickerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Cancel", action: onDismiss)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                Text("Link a Daily Note").font(.dayflowSerif(17))
                Spacer()
                Color.clear.frame(width: 50, height: 32)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            ScrollView {
                DayflowMonthGridView(monthCursor: $monthCursor, datesWithNotes: datesWithNotes) { picked in
                    if let exclude = excludeDailyDate, Calendar.current.isDate(picked, inSameDayAs: exclude) {
                        return
                    }
                    linkingDailyDate = picked
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                Text("Days with a note already written are marked. Pick one to peek at it before linking.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
            }
        }
        .dayflowSkinBackground()
        .task { datesWithNotes = await DayflowRelatedNotesEngine.datesWithNotes() }
    }

    /// Shared by Project/Person/Place/Visit — a searchable list, tap one to
    /// move to the description step. `id`/`label` split: Project/Person/Place
    /// pass id == label (their name IS the identifier), Visit passes the
    /// Visit's real ID as `id` with a computed "Place — date" as `label`.
    private func candidatePickerSheet(title: String, icon: String, candidates: [(id: String, label: String)]) -> some View {
        let filtered = candidateSearchText.isEmpty
            ? candidates
            : candidates.filter { $0.label.localizedCaseInsensitiveContains(candidateSearchText) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Cancel", action: onDismiss)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                Text(title).font(.dayflowSerif(17))
                Spacer()
                Color.clear.frame(width: 50, height: 32)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            if !candidates.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $candidateSearchText)
                        .font(.system(size: 13.5))
                    if !candidateSearchText.isEmpty {
                        Button {
                            candidateSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            if candidates.isEmpty {
                Text("Nothing to link yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
                    .padding(.horizontal, 16)
                Spacer()
            } else if filtered.isEmpty {
                Text("No matches.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.id) { item in
                            Button { linkCandidate = item.id } label: {
                                HStack {
                                    Image(systemName: icon)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(item.label).font(.system(size: 13.5)).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .dayflowSkinBackground()
    }

    private func describeAndConfirmSheet(title: String, onLink: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back") { linkCandidate = nil }
                    .font(.system(size: 15))
                    .foregroundStyle(Color.dayflowInk)
                Spacer()
                Text(title).font(.dayflowSerif(16)).lineLimit(1)
                Spacer()
                Button("Link") {
                    onLink()
                    onDismiss()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
                .disabled(linkDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            Form {
                Section {
                    TextField("Why is this related?", text: $linkDescription, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Relationship")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .dayflowSkinBackground()
    }
}
