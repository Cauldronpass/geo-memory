// TraceMacJournalView.swift
// Journal section for Trace Mac — Daily, Projects, Places.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import AppKit
// `.image` for the photo panel's allowedContentTypes. Session 65.
import UniformTypeIdentifiers

// MARK: - Notification for Horizons deep-link from calendar panel

extension Notification.Name {
    static let openHorizonsFile  = Notification.Name("trace.openHorizonsFile")
    static let openWikilink      = Notification.Name("trace.openWikilink")
    static let selectDocument    = Notification.Name("trace.selectDocument")
    static let reloadDocuments   = Notification.Name("trace.reloadDocuments")
    /// Navigate to a record from any context. userInfo: ["type": "person"|"place", "id": String]
    static let navigateToRecord  = Notification.Name("trace.navigateToRecord")

    // `selectPerson` and `selectPlace` were removed in Session 63 (2026-08-02).
    //
    // Neither ever crossed a real boundary. Both existed so that
    // `TraceMacContentView` could switch section and then, after a hand-tuned
    // delay, post a notification to a view it had just asked to appear —
    // 0.1s for a wikilink, 0.15s from Home, 0.35s for a record. The target view
    // now takes the id as a `Binding` and consumes it in `.task(id:)`, which
    // does not care whether it was already on screen.
    //
    // Deleted rather than left in place: an unused notification name is an
    // invitation to wire the race back up.
}

// MARK: - Notes — one destination, three tabs

/// Daily, Weekly and Projects, with the tab held in **local `@State`**.
///
/// Session 63 (2026-08-02). This replaces `TraceMacJournalView`, a dispatcher
/// that took a `MacSection` and rendered one of three screens, with the sidebar
/// listing all three as separate rows.
///
/// The first attempt at collapsing them put a tab bar in the detail column
/// driven by the app-level `selectedSection`. It did not respond — three times,
/// as hand-rolled buttons, with a hit-testing fix, and as a native segmented
/// `Picker`. Swapping the control changed nothing, which was the clue: the
/// control was never the problem.
///
/// **Every tab bar in this app that works holds its selection in local `@State`
/// — eight of them.** Archive, Place detail, People, the document pane, the
/// project hub. Mine wrote to `@State` owned by `TraceMacApp`, handed down as a
/// `@Binding`, *and simultaneously read by the sidebar's `List(selection:)`*.
/// Two things arguing over one piece of state.
///
/// So the sidebar picks a destination and the destination owns its tabs. That
/// is the arrangement the codebase already proves works, and it makes the
/// sidebar simpler as a side effect: three rows and a group header become one
/// row and no header.
struct TraceMacNotesView: View {

    enum NotesTab: String, CaseIterable, Identifiable {
        case daily    = "Daily"
        case weekly   = "Weekly"
        case projects = "Projects"
        var id: String { rawValue }
    }

    /// Set by `TraceMacContentView` when a calendar panel asks to open a week
    /// note. Non-nil switches to the Weekly tab; `TraceMacNoteListView` then
    /// consumes and clears it, exactly as before.
    var deepLinkFile: Binding<String?>? = nil

    /// A **container-relative path** to a Project or Daily note, set when a
    /// `[[wikilink]]` to a note is clicked (D64). A bare filename could not say
    /// which tab to switch to, so unlike `deepLinkFile` above this one carries
    /// its folder and gets split here.
    var deepLinkNotePath: Binding<String?>? = nil

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var tab: NotesTab = .daily
    /// Split out of `deepLinkNotePath` and handed to whichever child owns it.
    /// Each child consumes and clears its own, exactly as `TraceMacNoteListView`
    /// has always done with the Weekly one.
    @State private var pendingDailyFile:   String? = nil
    @State private var pendingProjectFile: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // One shared header row — see `TraceMacSectionHeader.swift` for why
            // the title is here and why the tabs are leading rather than
            // trailing. The tab *state* stays local to this view.
            MacSectionHeader("Notes") {
                MacTabStrip(options: NotesTab.allCases,
                            selection: $tab) { $0.rawValue }
            }

            Group {
                switch tab {
                case .daily:
                    TraceMacDailyView(deepLinkFile: $pendingDailyFile)
                        .environment(noteStore)
                        .environment(notionService)
                case .weekly:
                    // The folder stays `Notes/Horizons/` on purpose — Trace iOS
                    // appends the weekly check-in log there, and renaming it
                    // would orphan the writer and every note already in it. Only
                    // the label changed.
                    TraceMacNoteListView(
                        subfolder: "Notes/Horizons",
                        sectionTitle: "Weekly",
                        newNotePrompt: "e.g. 2026-W32",
                        emptyMessage: "No week notes yet.",
                        deepLinkFile: deepLinkFile
                    )
                    .environment(noteStore)
                case .projects:
                    TraceMacProjectsView(deepLinkFile: $pendingProjectFile)
                        .environment(noteStore)
                        .environment(notionService)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A week-note deep link has to land on the Weekly tab, or the file is
        // opened by a view that is not on screen. Setting the tab first means
        // `TraceMacNoteListView` mounts and then consumes the binding itself.
        .task(id: deepLinkFile?.wrappedValue) {
            if deepLinkFile?.wrappedValue != nil { tab = .weekly }
        }
        // Same three-legged handoff, one folder test wide. Switch the tab first
        // so the child mounts, then hand it the bare filename; the child clears
        // its own binding. Anything that is neither folder is ignored rather
        // than guessed at — `linkableNotes()` only ever produces these two.
        .task(id: deepLinkNotePath?.wrappedValue) {
            guard let path = deepLinkNotePath?.wrappedValue else { return }
            let filename = (path as NSString).lastPathComponent
            if path.hasPrefix(NoteStore.dailyFolder + "/") {
                tab = .daily
                pendingDailyFile = filename
            } else if path.hasPrefix(NoteStore.projectsFolder + "/") {
                tab = .projects
                pendingProjectFile = filename
            }
            deepLinkNotePath?.wrappedValue = nil
        }
    }
}

// MARK: - Daily notes — NoteStore backed

/// What one scan of a day note found on its first meaningful line.
///
/// One function and one scan rather than a `firstMeaningfulLine` and a separate
/// `overrideLine`, because the two would have to agree about what "meaningful"
/// means and that agreement is the thing that rots. Same reason `weekVisits`
/// derives its filter from the seven days it draws.
///
/// **File scope, not nested in the view.** A type nested inside a `@MainActor`
/// type inherits that isolation, and `firstMeaningfulLine` is read from a
/// `Task.detached` — which is the *"cannot be called from outside of the
/// actor"* error Xcode reports under Swift 6.
enum DayLine {
    case override(String)
    case prose(String)
    case none
}

struct TraceMacDailyView: View {
    /// Bare `yyyy-MM-dd.md`, set by `TraceMacNotesView` from a note wikilink.
    var deepLinkFile: Binding<String?>? = nil

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var dateFiles: [String] = []
    @State private var selectedDateFile: String? = nil
    @State private var sidebarCollapsed = false
    /// Remembered across launches, and shared with every other resizable
    /// column through `MacColumnResizer`.
    @AppStorage("tracemac.column.daily") private var dailyWidth: Double = 248
    @State private var calendarCollapsed = false
    @State private var searchText = ""
    /// First meaningful line of each day note, keyed by filename. Built once
    /// off the main actor; see `loadNotePreviews`.
    @State private var notePreviews:  [String: String] = [:]
    @State private var noteOverrides: [String: String] = [:]
    /// Non-nil while a visit from the week panel is open for editing.
    @State private var visitDetail: Visit? = nil
    /// Read once per appearance, for the endeavor stripe. D4's other half.
    ///
    /// A second `TraceMacEndeavorStore` instance rather than one hoisted into
    /// the environment: it holds no mutable state anyone else observes, a
    /// reload is one directory listing plus a parse per file, and threading a
    /// shared one through `TraceMacNotesView` for a 3pt rectangle would be the
    /// expensive answer to the cheap question.
    @State private var endeavorStore: TraceMacEndeavorStore? = nil

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var datesWithEntries: Set<String> {
        Set(dateFiles.map { $0.replacingOccurrences(of: ".md", with: "") })
    }

    /// Matches the date *and* the note's first line.
    ///
    /// The search box sits above rows that now show what you wrote, so matching
    /// only the filename means typing a word you can see on screen returns
    /// nothing. This is a preview match, not full-text search — it looks at the
    /// one line the row displays, which is the honest scope for a field sitting
    /// directly above them.
    private var filteredFiles: [String] {
        guard !searchText.isEmpty else { return dateFiles }
        return dateFiles.filter { file in
            file.localizedCaseInsensitiveContains(searchText)
                || (notePreviews[file]?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (noteOverrides[file]?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func label(for filename: String) -> String {
        let dateStr = filename.replacingOccurrences(of: ".md", with: "")
        guard let date = dateFmt.date(from: dateStr) else { return dateStr }
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// The second line of a day row: **what you wrote**, then where you were.
    ///
    /// Session 63 (2026-08-02). This started as the raw date under the label —
    /// `Yesterday` above `2026-07-31`, the same fact twice — which is why a
    /// column of them read as noise.
    ///
    /// First replacement was the day's visits. David: *"the content below every
    /// day is not what is in the note but rather the visits… It is interesting
    /// but not sure it is what i was thinking."* He was right, and his own data
    /// says so plainly. Across the last twenty days the notes read
    /// `Bolden charges tomorrow at $144`, `Go to mens warehouse for tie color`,
    /// `Confirm Friday with Bronwyn`, `The Odyssey - The IMAX 2D`. The visits
    /// for those same days read `Starbucks`. **This is a list of notes, so it
    /// should say what is in the note.**
    ///
    /// Visits keep a job, though: four of those twenty days have an empty note,
    /// and on those "where you were" is the only cue available.
    ///
    /// Order: note preview › visits › raw date. The Endeavor name should sit
    /// above all three once Endeavors reach the Mac (Phase 3), and an explicit
    /// `>` line should override everything — design decision D4.
    /// Where a row's second line came from, so the row can say so.
    ///
    /// David: *"what do you think about somehow signifying that the comment is
    /// visit related vs note content related?"*
    ///
    /// The two are not the same kind of claim. One is something he wrote and can
    /// rely on; the other is machinery reporting where he was. Reading them in
    /// identical grey means checking the note to know which you are looking at,
    /// which defeats the point of a subtitle.
    ///
    /// **Marked on the exception, not the norm.** Note lines are most days, so
    /// they stay plain; a column that is mostly decorated is a column with no
    /// signal in it. The visit line gets a pin and the green the Places section
    /// already uses in the sidebar, so the colour says *where it came from*
    /// rather than being a colour for its own sake.
    private enum DaySubtitle {
        /// A `>` blockquote on the first meaningful line of the day note.
        /// Outranks everything: see `subtitle(for:)`.
        case override(String)
        case note(String)
        case visits(String)
        case bare(String)
        /// Nothing worth saying. The row is one line.
        ///
        /// **`bare` used to be the fallback and it printed the ISO date**, so a
        /// day with an empty note and no visits read `Sat 2 Aug` over
        /// `2026-08-02` — the same fact twice, which is the exact duplication
        /// Session 63 removed from the primary path and left standing here.
        /// A note whose only content is its own `# yyyy-MM-dd` title lands here
        /// too, because `firstMeaningfulLine` skips headings.
        case blank
    }



    @ViewBuilder
    private func subtitleRow(_ subtitle: DaySubtitle) -> some View {
        switch subtitle {
        // David's own suggestion, D4: *"a type of indicator that would allow me
        // to add wording."* The automatic subtitle says where he was; this says
        // what the day was for. `Men's Wearhouse · Chase Bank · Arlington Lanes`
        // becomes `Tux fitting for Megan's wedding`.
        //
        // Indigo and a `❯` so it does not read as either of the automatic
        // lines — grey prose is the note, green is Places. A third source that
        // outranks both should not look like either.
        case .override(let text):
            HStack(spacing: 3) {
                Text("❯")
                    .font(MacType.meta)
                Text(text)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Color.indigo)

        case .note(let text):
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

        case .visits(let text):
            HStack(spacing: 3) {
                Image(systemName: "mappin")
                    .font(MacType.meta)
                Text(text)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Green because the line comes from Places. It matched the Places
            // sidebar row's tint when that was its own section; Places is now a
            // tab inside Directory, so this is the last carrier of that colour.
            // Dimmed because it is a caption under a title, not a heading —
            // full-strength green at 8pt reads as an alert.
            .foregroundStyle(Color.green.opacity(0.85))

        case .bare(let text):
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

        case .blank:
            EmptyView()
        }
    }

    // MARK: - This week's visits, under the calendar

    /// David, after showing NotePlan's Event List: *"the Noteplan spec i showed
    /// you had the visits below the month grid sorted by date… whatever day we
    /// are on that weeks list of visits would show under the calendar with day
    /// headers?"*
    ///
    /// It is the same data the week note already accumulates — `NoteStore`
    /// appends every check-in to `Notes/Horizons/YYYY-Www.md` under a
    /// "Check-in Log" heading, grouped by day with times. This renders that from
    /// the live records instead of the file, so it is current the moment a visit
    /// lands rather than when the note was last written.
    ///
    /// The week follows the *selected* day, not today: paging back through the
    /// calendar to read an old note should bring that week's visits with it.
    private var weekVisits: [(day: Date, visits: [Visit])] {
        guard let file = selectedDateFile,
              let selected = dateFmt.date(from: file.replacingOccurrences(of: ".md", with: "")),
              // Monday-first. `Calendar.current` is Sunday-first in en_US and returned
              // the wrong week entirely on Sundays. See TraceMacCalendar.swift.
              let week = Calendar.traceWeek.dateInterval(of: .weekOfYear, for: selected)
        else { return [] }

        let cal = Calendar.current

        // The seven days are built first and then drive everything: the
        // filter, the grouping and the output order. Nothing else decides
        // which rows exist.
        //
        // Always seven. Not "the days that have visits", and not "the days
        // that have visits, plus the selected one".
        //
        // David: *"draw the header regardless. Id like to see nothing instead
        // of omitting."* Then, when the first pass seeded only the selected
        // day: *"when i click on saturday Aug 1st, then SundayAug 2nd still is
        // omitted. It should stay as 7 days regardless."*
        //
        // Grouping visits by day means a day with no visits produces no key,
        // no header and no row, so the panel's shape changed week to week.
        // That is the complaint: you cannot read "was I anywhere on Sunday"
        // off a list that omits the days you were nowhere. A fixed seven-row
        // frame also makes the header a learnable control, since it opens the
        // day note and a door that only exists on days you checked in is not
        // a door.
        //
        // `week` is Monday-first (see TraceMacCalendar.swift). `cal` stays
        // `Calendar.current` here on purpose: which calendar day a timestamp
        // falls in is a local-time question, and only the *week boundary* is
        // pinned to Monday.
        let weekStart = cal.startOfDay(for: week.start)
        let days: [Date] = (0..<7).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: weekStart).map { cal.startOfDay(for: $0) }
        }
        let dayKeys = Set(days)

        // Membership is "is this visit's day one of the seven", **not**
        // `week.contains(visit.date)`.
        //
        // David: *"i just clicked on July 18th and Monday July 20th appears as
        // does July 13th."* July 13 was right (Sat 18 Jul sits in Mon 13 to
        // Sun 19). July 20 was an eighth row.
        //
        // `DateInterval.contains` is closed at **both** ends: it is
        // `date >= start && date <= end`, and `end` here is Monday 00:00 of
        // the *following* week. Notion stores `Date Visited` as date-only on
        // most records, so those dates parse to exactly midnight — and the
        // CD One Price Cleaners visit on Mon 20 Jul, logged at 12:47 PM in the
        // week note, reaches this code as 20 Jul 00:00:00 and lands precisely
        // on the one instant `contains` wrongly admits. A half-open `..<` on
        // the interval would fix that specific leak; deriving membership from
        // the same seven keys that draw the rows makes an eighth row
        // unrepresentable, which is the stronger claim.
        //
        // The previous version also returned `grouped.keys.sorted()`, so a
        // leaked key became a visible row. Two independent notions of "the
        // days of this week" disagreed. There is now one.
        let byDay = Dictionary(grouping: notionService.visits.filter {
            dayKeys.contains(cal.startOfDay(for: $0.date))
        }) {
            cal.startOfDay(for: $0.date)
        }

        return days.map { day in
            (day, (byDay[day] ?? []).sorted { $0.date < $1.date })
        }
    }

    @ViewBuilder
    private var weekVisitsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("This Week")
                    .macLabel()
                    .foregroundStyle(.tertiary)
                Spacer()
                let total = weekVisits.reduce(0) { $0 + $1.visits.count }
                if total > 0 {
                    Text("\(total)")
                        .font(MacType.metaEmphasis)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if weekVisits.isEmpty {
                Text("No visits this week.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(weekVisits, id: \.day) { entry in
                            Section {
                                if entry.visits.isEmpty {
                                    emptyDayRow(entry.day)
                                } else {
                                    ForEach(entry.visits) { visit in
                                        visitRow(visit)
                                    }
                                }
                            } header: {
                                dayHeader(entry.day)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isSelected(_ day: Date) -> Bool {
        guard let selectedDay else { return false }
        return Calendar.current.isDate(day, inSameDayAs: selectedDay)
    }

    /// The day header is the control that changes which note you are reading.
    ///
    /// David: *"What about clicking the day of the week does what you say and
    /// clicking the name of the visit opens that visit?"* Right split — the two
    /// were doing the same thing before, which wasted the row.
    ///
    /// The selected day is marked harder than a tinted label: *"Is ther a way to
    /// make this more evident?"* It now gets a filled accent bar and a rule down
    /// the left edge of its rows, so the group reads as one block rather than a
    /// slightly bluer line of text.
    private func dayHeader(_ day: Date) -> some View {
        let on = isSelected(day)
        return Button {
            selectedDateFile = dateFmt.string(from: day) + ".md"
        } label: {
            HStack(spacing: 6) {
                Text(day.formatted(.dateTime.weekday(.wide)).uppercased())
                    .macLabel()
                Spacer()
                Text(day.formatted(.dateTime.month(.abbreviated).day()))
                    .font(MacType.meta)
                    .opacity(on ? 0.85 : 1)
            }
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(day.formatted(.dateTime.weekday(.wide).month().day()))")
    }

    /// The body of a day with no visits. With the seven-day frame this can be
    /// any day of the week, not just the selected one.
    ///
    /// Deliberately not a button: there is nothing to open, and a row that
    /// highlights on hover but does nothing on click is a worse lie than a
    /// blank. The header above it is still clickable and still opens the note.
    ///
    /// Metrics copy `visitRow` exactly (12 horizontal, 3 vertical, 11.5pt) so
    /// the group keeps the same rhythm as a populated one, and it carries the
    /// same accent rule and tint when it is the selected day, so an empty
    /// selected day reads as one block rather than a header floating alone.
    private func emptyDayRow(_ day: Date) -> some View {
        let on = isSelected(day)
        return Text("No visits")
            .font(MacType.row)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .overlay(alignment: .leading) {
                if on {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                }
            }
            .background(on ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    /// Clicking a visit opens that visit. The day header above it is what moves
    /// you to the note — see `dayHeader`.
    private func visitRow(_ visit: Visit) -> some View {
        let on = isSelected(visit.date)
        return Button {
            visitDetail = visit
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // No time of day, deliberately.
                //
                // Notion's `Date Visited` is date-only on most records, so it
                // rendered "12:00 AM" against every row. Showing it only when a
                // real timestamp existed fixed the noise but not the problem.
                // David: *"the times are usseful if i remember to record the
                // check in at that time which is probably happening 50% of the
                // time. Id leave the times off to be honest."*
                //
                // Which is the deeper point: the stamp records when he
                // remembered to check in, not when he was there. A field that is
                // right half the time and looks authoritative is worse than no
                // field, because you cannot tell the halves apart.
                //
                // The visits are still *sorted* by it. Order is a weaker claim
                // than a timestamp and survives the same imprecision.
                Text(shortPlaceName(visit.placeName))
                    .font(MacType.row)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let rating = visit.rating, rating > 0 {
                    MacStars(rating: rating)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A rule down the left of the selected day's rows, so the whole group
        // reads as belonging to the header above it.
        .overlay(alignment: .leading) {
            if on {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .background(on ? Color.accentColor.opacity(0.06) : Color.clear)
    }


    private var selectedDay: Date? {
        guard let file = selectedDateFile else { return nil }
        return dateFmt.date(from: file.replacingOccurrences(of: ".md", with: ""))
    }

    /// Priority: an explicit `>` override, then what you wrote, then where you
    /// were, then the bare date.
    ///
    /// **The Endeavor name belongs between the override and the note** (D4) and
    /// is not here yet: TraceMac has no `Endeavor` type. That slot is the
    /// remaining half of D4.
    private func subtitle(for filename: String) -> DaySubtitle {
        if let line = noteOverrides[filename], !line.isEmpty { return .override(line) }
        if let preview = notePreviews[filename], !preview.isEmpty { return .note(preview) }

        let dateStr = filename.replacingOccurrences(of: ".md", with: "")
        guard let date = dateFmt.date(from: dateStr) else { return .bare(dateStr) }
        let cal = Calendar.current
        let names = notionService.visits
            .filter { cal.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.date < $1.date }
            .map { shortPlaceName($0.placeName) }
        // **The subtitle never repeats the label.** `label(for:)` already reads
        // `Sat 2 Aug`, so printing `2026-08-02` under it says nothing and costs
        // a line on every empty day in the list.
        //
        // `Today` and `Yesterday` are the one exception: those labels are
        // relative and genuinely do not tell you which date they are, so they
        // keep an absolute line — in the same human format the other rows use,
        // not the ISO filename.
        guard !names.isEmpty else {
            guard cal.isDateInToday(date) || cal.isDateInYesterday(date) else { return .blank }
            return .bare(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
        }

        // De-duplicate while keeping first-seen order: two Starbucks stops in one
        // day should read "Starbucks", not "Starbucks · Starbucks".
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return .visits(unique.joined(separator: " · "))
    }

    /// First line of a day note worth showing, or "" if there is none.
    ///
    /// The cleaning rules are lifted from `TripLog.candidateText` on iOS, which
    /// solves the identical problem — deciding which lines of a day note are
    /// prose a human wrote and which are machinery. Without it, 2026-07-26 would
    /// render as `[🚗 Parked · 1:19 PM](capture://open?id=3a97a256-…)`.
    ///
    /// Checkbox markers are stripped but their text kept, because
    /// `Confirm Friday with Bronwyn` is the content and `☑` is the state.
    /// Fully struck-through lines are skipped: crossed out means done with.
    /// `nonisolated` because it is pure string processing and both callers run
    /// it on a `Task.detached`, off the main actor on purpose — one file read
    /// per row, and doing it inline would put disk I/O in a `List` row builder.
    /// Without this it is main-actor isolated by inheritance from the view, and
    /// Swift 6 makes calling it from that task an error rather than a warning.
    nonisolated static func firstMeaningfulLine(of body: String) -> DayLine {
        for raw in body.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // The override channel. `>` was chosen (D4) because Obsidian renders
            // it as a callout and `MarkdownTextStorage` had not claimed it.
            // Checked before the skip rules below so that a `>` line is never
            // mistaken for prose, and after the empty check so a leading blank
            // line does not defeat it.
            if line.hasPrefix(">") {
                let text = line.dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "**", with: "")
                return text.isEmpty ? .none : .override(text)
            }
            if line.hasPrefix("#") { continue }                 // the date title, or any heading
            if line.hasPrefix("---") { continue }               // horizontal rule
            if line.hasPrefix("|") { continue }                 // Related Notes table row
            if line.hasPrefix("📎 [") { continue }               // attachment row
            if line.hasPrefix("**Saved:**") { continue }        // capture stamp
            if line.contains("capture://") { continue }         // bare capture link
            // A line that is entirely struck through is finished business.
            if line.hasPrefix("~~") && line.hasSuffix("~~") { continue }

            // Checkbox and bullet markers: drop the marker, keep the text.
            for marker in ["☑ ", "☐ ", "- [x] ", "- [X] ", "- [ ] ", "- ", "• "] {
                if line.hasPrefix(marker) { line = String(line.dropFirst(marker.count)); break }
            }

            // Emphasis markers are noise at caption size.
            line = line.replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "~~", with: "")
                       .replacingOccurrences(of: "==", with: "")

            // `[[Full Name|Short]]` → `Short`, `[[Name]]` → `Name`.
            line = line.replacingOccurrences(
                of: #"\[\[([^\]|]+)\|([^\]]*)\]\]"#, with: "$2",
                options: .regularExpression)
            line = line.replacingOccurrences(
                of: #"\[\[([^\]]+)\]\]"#, with: "$1",
                options: .regularExpression)
            // `[label](url)` → `label`.
            line = line.replacingOccurrences(
                of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                options: .regularExpression)

            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return .prose(line) }
        }
        return .none
    }

    /// Reads every listed day note once and caches its first meaningful line.
    ///
    /// Off the main actor because this is one file read per row and the list can
    /// run to dozens; doing it inside `subtitle(for:)` would put disk I/O in a
    /// `List` row builder, which is how a scroll turns to treacle.
    private func loadNotePreviews(for files: [String]) async {
        let built: (prose: [String: String], override: [String: String]) =
        await Task.detached(priority: .utility) {
            // `NoteStore.shared` rather than capturing the environment value —
            // same pattern `PersonNotesTab` uses for `findWikilinkMentions`.
            let store = NoteStore.shared
            var prose: [String: String] = [:]
            var over:  [String: String] = [:]
            for file in files {
                guard let body = try? store.readFile("Calendar/\(file)") else { continue }
                switch TraceMacDailyView.firstMeaningfulLine(of: body) {
                case .override(let t): over[file]  = t
                case .prose(let t):    prose[file] = t
                case .none:            break
                }
            }
            return (prose, over)
        }.value
        await MainActor.run {
            notePreviews  = built.prose
            noteOverrides = built.override
        }
    }

    /// Re-reads one day note after it was saved.
    ///
    /// Clears the entry when the note becomes empty rather than leaving the old
    /// line in place — deleting everything you wrote should drop the row back to
    /// the visit fallback, not keep showing a sentence that is no longer there.
    private func refreshPreview(for file: String) async {
        let line: DayLine = await Task.detached(priority: .utility) {
            guard let body = try? NoteStore.shared.readFile("Calendar/\(file)") else { return .none }
            return TraceMacDailyView.firstMeaningfulLine(of: body)
        }.value
        await MainActor.run {
            // Both dictionaries are cleared every time, not just the one being
            // written. Turning a prose first line into a `>` override, or back,
            // has to remove the old entry or the row keeps showing the line you
            // just replaced.
            notePreviews.removeValue(forKey: file)
            noteOverrides.removeValue(forKey: file)
            switch line {
            case .override(let t): noteOverrides[file] = t
            case .prose(let t):    notePreviews[file]  = t
            case .none:            break
            }
        }
    }

    // MARK: - The endeavor stripe (D4's other half)

    /// The endeavor covering a day, if any.
    ///
    /// Day granularity at both ends, the same `startOfDay` comparison
    /// `TraceMacEndeavorsView.visits(in:)` uses and for the same reason: an
    /// interval of instants gets the last day of a trip wrong whenever the end
    /// date is stored at midnight.
    ///
    /// First match wins. Two endeavors overlapping the same day is possible and
    /// nothing here has to resolve it — the mark says "this day belongs to
    /// something", and the tooltip names whichever one this is.
    private func endeavor(covering filename: String) -> Endeavor? {
        guard let store = endeavorStore else { return nil }
        let dateStr = filename.replacingOccurrences(of: ".md", with: "")
        guard let date = dateFmt.date(from: dateStr) else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        return store.endeavors.first { e in
            guard let starts = e.starts else { return false }
            return day >= cal.startOfDay(for: starts)
                && day <= cal.startOfDay(for: e.ends ?? starts)
        }
    }

    /// A 3pt indigo stripe down the leading edge of every row inside an
    /// endeavor, or an airplane glyph on each while a search is active.
    ///
    /// D4 asked for the endeavor name *in* the subtitle. That decision predates
    /// the subtitle carrying what you wrote, and taking the slot would have
    /// erased a tux-fitting note and a list of places on all nine days of a trip
    /// to print the same four words nine times.
    ///
    /// **A range wants to be drawn as a range.** Nine separate marks answer
    /// "is this day part of something?" nine times; one continuous line answers
    /// "how long is this and where does it start and stop?" once, which is the
    /// question you have when you are scanning a column of dates. It also costs
    /// no horizontal space, which matters in 200pt.
    ///
    /// **Except under search**, where `filteredFiles` is no longer contiguous
    /// and a stripe with holes in it reads as a rendering bug rather than as a
    /// trip with gaps. Glyphs are per-row by nature and stay correct however the
    /// list is filtered, so the marker changes shape rather than lying.
    ///
    /// Indigo because the calendar dots already use indigo for exactly this
    /// (D5) and the override line already uses it in this same column. The
    /// gutter is a fixed 10pt in all three states so no row's text shifts.
    @ViewBuilder
    private func endeavorMark(for filename: String) -> some View {
        if let e = endeavor(covering: filename) {
            if searchText.isEmpty {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.indigo)
                    .frame(width: 3)
                    .frame(width: 10, alignment: .leading)
                    .help(e.name)
            } else {
                Image(systemName: "airplane")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.indigo)
                    .frame(width: 10)
                    .help(e.name)
            }
        } else {
            Color.clear.frame(width: 10)
        }
    }

    /// Drops one trailing parenthetical. Same rule as `TripLog.shortPlaceName`.
    private func shortPlaceName(_ name: String) -> String {
        guard let open = name.lastIndex(of: "("), name.hasSuffix(")") else { return name }
        let trimmed = name[name.startIndex..<open].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    var body: some View {
        HStack(spacing: 0) {
            // Column 1: date list (fixed 200pt — same pattern as TraceMacProjectsView)
            if !sidebarCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    if dateFiles.isEmpty {
                        Spacer()
                        Text("No daily notes yet.")
                            .font(.caption).foregroundStyle(.secondary).padding()
                        Spacer()
                    } else {
                        List(filteredFiles, id: \.self, selection: $selectedDateFile) { file in
                            HStack(spacing: 7) {
                                endeavorMark(for: file)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label(for: file))
                                        .font(.system(.callout, weight: .medium))
                                    subtitleRow(subtitle(for: file))
                                }
                            }
                            .padding(.vertical, 2)
                            .tag(file as String?)
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                // 248 is the width this starts at, not the width it is stuck
                // with: 200pt fitted "Yesterday" over a bare date, and the second
                // line carrying where you actually were needed the room. Draggable
                // since Session 70.
                .frame(width: dailyWidth)
                MacColumnResizer(width: $dailyWidth)
            }

            CollapseHandle(isCollapsed: $sidebarCollapsed, collapsesRight: false,
                           showLine: true, panelColor: .clear)

            // Columns 2+3: flexible region (editor + fixed calendar) — mirrors the
            // Projects hub layout (editor .frame(maxWidth:) + fixed-width sidebar
            // inside a Group .frame(maxWidth: .infinity)).
            Group {
                HStack(spacing: 0) {
                    editorColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Handle lives outside the `if !calendarCollapsed` block (same
                    // pattern as the date-list handle above) so it's still there to
                    // re-expand the panel once collapsed — previously this was a
                    // plain separator Rectangle inside the conditional, so there was
                    // no way to bring the calendar back except the ⌘⇧K toolbar toggle.
                    CollapseHandle(isCollapsed: $calendarCollapsed, collapsesRight: true,
                                   showLine: true, panelColor: .clear)

                    if !calendarCollapsed {
                        VStack(spacing: 0) {
                            TraceMacCalendarPanel(
                                selectedDateFile: $selectedDateFile,
                                datesWithEntries: datesWithEntries,
                                onOpenHorizonsNote: { filename in
                                    NotificationCenter.default.post(
                                        name: .openHorizonsFile,
                                        object: nil,
                                        userInfo: ["filename": filename]
                                    )
                                }
                            )
                            Divider()
                            weekVisitsPanel
                        }
                        .frame(width: 240)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: selectedDateFile) { _, newFile in
            guard let f = newFile else { return }
            ensureFileExists(f)
        }
        .task(id: deepLinkFile?.wrappedValue) {
            guard let filename = deepLinkFile?.wrappedValue else { return }
            // `ensureFileExists` also inserts into `dateFiles`, so a link to a day
            // with no note yet still opens rather than selecting nothing.
            ensureFileExists(filename)
            selectedDateFile = filename
            deepLinkFile?.wrappedValue = nil
        }
        .task {
            if endeavorStore == nil { endeavorStore = TraceMacEndeavorStore(noteStore: noteStore) }
            await endeavorStore?.reload()
            await loadDates()
            // Visits are the fallback subtitle for a day with an empty note, and
            // this screen never needed them before. Guarded so returning to
            // Daily does not re-hit Notion; Home and Places fetch the same list
            // on their own schedule and whoever arrives first wins.
            if notionService.visits.isEmpty { await notionService.fetchVisits() }
        }
        .sheet(item: $visitDetail) { visit in
            MacVisitDetailView(visit: visit)
                .environment(notionService)
        }
        // The row shows the note's first line, so editing a note has to update
        // the row. Without this the subtitle is whatever the note said when the
        // screen opened, which is worse than showing nothing.
        //
        // `NoteStore.writeFile` posts this for any `Calendar/` path, and the
        // editor saves a second after you stop typing — so this fires through a
        // whole editing session. It names the file that changed, so only that
        // one is re-read. Reloading all of them would be dozens of file reads
        // per pause in typing, for one row that could have changed.
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { note in
            guard let path = note.object as? String, path.hasPrefix("Calendar/") else {
                Task { await loadNotePreviews(for: dateFiles) }
                return
            }
            let file = String(path.dropFirst("Calendar/".count))
            if dateFiles.contains(file) {
                Task { await refreshPreview(for: file) }
            } else {
                // A day that had no note when the list loaded now has one, so
                // the row itself is missing, not just its subtitle.
                Task { await loadDates() }
            }
        }
        .toolbar {
            // The list toggle used to be `ToolbarItem(placement: .navigation)`,
            // which is the one slot to the *left* of the window title. Daily was
            // the only screen in the app that filled it, so the title sat in a
            // different place here than on every other section — half of what
            // David meant by *"the top left of the screen changes position"*.
            //
            // It is also the toggle's natural pair: this button collapses the
            // left column and the next one collapses the right, and they were
            // sitting at opposite ends of the window with "Today" between them.
            ToolbarItem {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        sidebarCollapsed.toggle()
                    }
                } label: { Label("Toggle List", systemImage: "sidebar.leading") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            ToolbarItem {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        calendarCollapsed.toggle()
                    }
                } label: { Label("Toggle Calendar", systemImage: "calendar") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Today") { openToday() }
            }
        }
    }

    // MARK: - Editor column

    @ViewBuilder
    private var editorColumn: some View {
        if let file = selectedDateFile,
           let date = dateFmt.date(from: file.replacingOccurrences(of: ".md", with: "")) {
            TraceMacNoteEditor(
                relativePath: "Calendar/\(file)",
                showMoveButton: true,
                moveSourceDate: date
            )
            .environment(noteStore)
            .environment(notionService)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Text("Select a date")
                    .font(.callout).foregroundStyle(.tertiary)
                Button("Open Today") { openToday() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func openToday() {
        let filename = dateFmt.string(from: Date()) + ".md"
        ensureFileExists(filename)
        selectedDateFile = filename
    }

    private func ensureFileExists(_ filename: String) {
        let path = "Calendar/\(filename)"
        if (try? noteStore.readFile(path)) == nil {
            try? noteStore.writeFile(path, content: "")
        }
        if !dateFiles.contains(filename) {
            dateFiles.insert(filename, at: 0)
        }
    }

    private func loadDates() async {
        let files = (try? noteStore.listFiles(in: "Calendar")) ?? []
        let sorted = files
            .filter { $0.hasSuffix(".md") }
            .filter { dateFmt.date(from: $0.replacingOccurrences(of: ".md", with: "")) != nil }
            .sorted(by: >)
        await MainActor.run {
            dateFiles = sorted
            if selectedDateFile == nil {
                let todayFile = dateFmt.string(from: Date()) + ".md"
                if sorted.contains(todayFile) { selectedDateFile = todayFile }
            }
        }
        await loadNotePreviews(for: sorted)
    }
}

// MARK: - Mac daily move sheet

struct MacDailyMoveSheet: View {
    let sourceDate: Date
    let sourceContent: String
    let onMoved: () -> Void

    @Environment(NotionService.self) private var notionService
    @Environment(NoteStore.self)     private var noteStore
    @Environment(\.dismiss)          private var dismiss

    enum Dest: String, CaseIterable {
        case day, visit, project, horizon, place
        var label: String {
            switch self {
            case .day:     return "Another Day"
            case .visit:   return "Visit"
            case .project: return "Project"
            case .horizon: return "Horizon"
            case .place:   return "Place"
            }
        }
        var icon: String {
            switch self {
            case .day:     return "calendar"
            case .visit:   return "checkmark.circle"
            case .project: return "folder"
            case .horizon: return "square.stack"
            case .place:   return "mappin"
            }
        }
    }

    @State private var dest: Dest = .day
    @State private var targetDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var showDatePopover = false
    @State private var selectedVisit: Visit? = nil
    @State private var selectedPlace: Place? = nil
    @State private var selectedFile: String? = nil
    @State private var files: [String] = []
    @State private var searchText = ""
    @State private var isMoving = false
    @State private var errorMessage: String? = nil

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var canMove: Bool {
        switch dest {
        case .day:               return !isSameAsSource
        case .visit:             return selectedVisit != nil
        case .place:             return selectedPlace != nil
        case .project, .horizon: return selectedFile != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Move Content").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()

            // Destination type pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Dest.allCases, id: \.rawValue) { d in
                        Button {
                            dest = d
                            selectedVisit = nil; selectedPlace = nil
                            selectedFile = nil; searchText = ""
                        } label: {
                            Label(d.label, systemImage: d.icon)
                                .font(.subheadline.weight(dest == d ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(
                                    dest == d ? Color.accentColor
                                              : Color(nsColor: .controlBackgroundColor),
                                    in: Capsule()
                                )
                                .foregroundStyle(dest == d ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()

            // Content preview
            Text(sourceContent.prefix(200))
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)

            // Destination-specific picker
            Group {
                switch dest {
                case .day:     dayPicker
                case .visit:   visitList
                case .project: fileListView(subfolder: "Notes/Projects")
                case .horizon: horizonListView
                case .place:   placeList
                }
            }

            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 20).padding(.bottom, 4)
            }

            Spacer(minLength: 0)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                if isMoving {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                } else {
                    Button("Move") { Task { await performMove() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canMove)
                }
            }
            .padding(16)
        }
        .frame(width: 440, height: 560)
        .task(id: dest) { await loadFilesForDest() }
    }

    // MARK: Day picker

    private var isSameAsSource: Bool {
        Calendar.current.isDate(targetDate, inSameDayAs: sourceDate)
    }

    private var dayPicker: some View {
        VStack(spacing: 4) {
            DatePicker("", selection: $targetDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal, 16)
                .frame(maxWidth: 360)
            if isSameAsSource {
                Text("Same as source — pick a different date.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Visit list

    private var filteredVisits: [Visit] {
        let sorted = notionService.visits.sorted { $0.date > $1.date }
        if searchText.isEmpty { return Array(sorted.prefix(40)) }
        return sorted.filter { $0.placeName.localizedCaseInsensitiveContains(searchText) }
    }

    private var visitList: some View {
        VStack(spacing: 0) {
            TextField("Search visits", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.top, 8)
            List(filteredVisits) { visit in
                Button { selectedVisit = visit } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visit.placeName).foregroundStyle(.primary)
                            Text(visit.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedVisit?.id == visit.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Project / general file list

    private func fileListView(subfolder: String) -> some View {
        VStack(spacing: 0) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.top, 8)
            if files.isEmpty {
                Spacer()
                Text("No files found.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                let filtered = files.filter {
                    searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText)
                }
                List(filtered, id: \.self) { file in
                    Button { selectedFile = file } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(file.replacingOccurrences(of: ".md", with: "")).foregroundStyle(.primary)
                            Spacer()
                            if selectedFile == file {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Horizon list

    /// Was a second definition of the same calendar. Now one name for the
    /// shared one, so the call sites below did not have to change.
    private static let isoCal: Calendar = .traceWeekPOSIX

    private var currentWeekFile: String {
        let wk = Self.isoCal.component(.weekOfYear, from: Date())
        let yr = Self.isoCal.component(.yearForWeekOfYear, from: Date())
        return String(format: "%d-W%02d.md", yr, wk)
    }

    private var currentMonthFile: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"
        return "\(f.string(from: Date())).md"
    }

    private var horizonListView: some View {
        List {
            Section("This Period") {
                horizonRow(file: currentWeekFile,
                           label: "Week \(Self.isoCal.component(.weekOfYear, from: Date()))",
                           icon: "calendar.badge.clock")
                horizonRow(file: currentMonthFile,
                           label: Date().formatted(.dateTime.month(.wide).year()),
                           icon: "calendar")
            }
            let past = files.filter { $0 != currentWeekFile && $0 != currentMonthFile }.sorted(by: >)
            if !past.isEmpty {
                Section("Past") {
                    ForEach(past, id: \.self) { file in
                        horizonRow(file: file,
                                   label: file.replacingOccurrences(of: ".md", with: ""),
                                   icon: "doc.text")
                    }
                }
            }
        }
    }

    private func horizonRow(file: String, label: String, icon: String) -> some View {
        Button { selectedFile = file } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(label).foregroundStyle(.primary)
                Spacer()
                if selectedFile == file {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Place list

    private var filteredPlaces: [Place] {
        let sorted = notionService.places.sorted { $0.name < $1.name }
        if searchText.isEmpty { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(searchText) ||
                               $0.city.localizedCaseInsensitiveContains(searchText) }
    }

    private var placeList: some View {
        VStack(spacing: 0) {
            TextField("Search places", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.top, 8)
            if notionService.places.isEmpty {
                Spacer()
                Text("No places loaded.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredPlaces) { place in
                    Button { selectedPlace = place } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(.primary)
                                if !place.city.isEmpty {
                                    Text(place.city).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedPlace?.id == place.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor).fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            if notionService.places.isEmpty { await notionService.fetchPlaces() }
        }
    }

    // MARK: Data loading

    private func loadFilesForDest() async {
        let subfolder: String
        switch dest {
        case .project: subfolder = "Notes/Projects"
        case .horizon: subfolder = "Notes/Horizons"
        default: return
        }
        let list = (try? noteStore.listFiles(in: subfolder)) ?? []
        await MainActor.run { files = list.filter { $0.hasSuffix(".md") }.sorted(by: >) }
    }

    // MARK: Perform move

    private func performMove() async {
        isMoving = true
        errorMessage = nil
        do {
            switch dest {
            case .day:
                let path = "Calendar/\(dateFmt.string(from: targetDate)).md"
                try appendToFile(path: path, header: dateFmt.string(from: targetDate))
            case .visit:
                guard let visit = selectedVisit else { return }
                try await notionService.appendVisitNotes(visitID: visit.id, text: stripped(sourceContent))
            case .project:
                guard let file = selectedFile else { return }
                try appendToFile(path: "Notes/Projects/\(file)",
                                 header: file.replacingOccurrences(of: ".md", with: ""))
            case .horizon:
                guard let file = selectedFile else { return }
                try appendToFile(path: "Notes/Horizons/\(file)",
                                 header: file.replacingOccurrences(of: ".md", with: ""))
            case .place:
                guard let place = selectedPlace else { return }
                try appendToFile(path: "Notes/Places/\(place.name).md", header: place.name)
            }
            await MainActor.run { onMoved(); dismiss() }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription; isMoving = false }
        }
    }

    private func appendToFile(path: String, header: String) throws {
        let text = stripped(sourceContent)
        let existing = (try? noteStore.readFile(path)) ?? ""
        let updated = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "# \(header)\n\n\(text)"
            : existing + "\n\n" + text
        try noteStore.writeFile(path, content: updated)
    }

    private func stripped(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first,
           first.hasPrefix("# "),
           first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        }
        return lines.joined(separator: "\n")
    }
}


// MARK: - Hover-reveal collapse handle

/// A 12-wide hit zone containing a 1px separator and a hover-reveal circle button.
/// collapsesRight = true  → manages the panel to the RIGHT (e.g. calendar)
/// collapsesRight = false → manages the panel to the LEFT  (e.g. file list)
/// 12px HStack element with a hover-reveal circle collapse button.
///
/// showLine:    draw a separator at the LEADING edge of the zone (the panel boundary)
/// lineWidth:   separator width in points (default 1)
/// panelColor:  fill the zone with this color — use calendarGray on the calendar side
///              so the 12px zone merges into the 240px calendar panel visually
struct CollapseHandle: View {
    @Binding var isCollapsed: Bool
    let collapsesRight: Bool
    var showLine: Bool = true
    var lineWidth: CGFloat = 1
    var panelColor: Color = .clear

    @State private var isHovering = false

    private var icon: String {
        collapsesRight
            ? (isCollapsed ? "chevron.left"  : "chevron.right")
            : (isCollapsed ? "chevron.right" : "chevron.left")
    }

    var body: some View {
        ZStack {
            panelColor  // fills the zone — blends handle into the adjacent shaded panel

            if showLine {
                // Separator pinned to the LEADING edge of the zone so it sits exactly
                // at the panel boundary (white editor → separator → gray calendar).
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: lineWidth)
                    Spacer(minLength: 0)
                }
            }

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    isCollapsed.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.14), radius: 2, x: 0, y: 1)
                        .frame(width: 18, height: 18)
                    Image(systemName: icon)
                        .font(MacGlyph.small)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Generic note list (Projects, custom subfolders)

struct TraceMacNoteListView: View {
    let subfolder: String
    let sectionTitle: String
    let newNotePrompt: String
    let emptyMessage: String
    var deepLinkFile: Binding<String?>? = nil   // non-nil triggers selection + clears itself

    @Environment(NoteStore.self) private var noteStore

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var renameCandidate: String? = nil
    @State private var showRenameSheet = false
    @State private var renameDraft = ""
    @State private var fileListCollapsed = false
    /// Remembered across launches, and shared with every other resizable
    /// column through `MacColumnResizer`.
    @AppStorage("tracemac.column.weekly") private var weeklyWidth: Double = 200
    @State private var selectedTags: Set<String> = []
    @State private var allTags: [String] = []
    @State private var fileContents: [String: String] = [:]

    private var filtered: [String] {
        let base = searchText.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(searchText) }
        guard !selectedTags.isEmpty else { return base }
        return base.filter { filename in
            let content = fileContents[filename] ?? ""
            return selectedTags.allSatisfy { content.range(of: "#\($0)", options: .caseInsensitive) != nil }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: file list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    MacTagChipRow(tags: allTags, selected: $selectedTags)

                    if files.isEmpty {
                        Spacer()
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                        Spacer()
                    } else {
                        List(filtered, id: \.self, selection: $selectedFile) { filename in
                            Text(filename.replacingOccurrences(of: ".md", with: ""))
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                                .padding(.vertical, 4)
                                .tag(filename)
                                .contextMenu {
                                    Button {
                                        renameCandidate = filename
                                        renameDraft = filename.replacingOccurrences(of: ".md", with: "")
                                        showRenameSheet = true
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        deleteCandidate = filename
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: weeklyWidth)
                MacColumnResizer(width: $weeklyWidth)
            }

            CollapseHandle(
                isCollapsed: $fileListCollapsed,
                collapsesRight: false,
                showLine: true,
                panelColor: .clear
            )

            // Right: editor (with optional horizon calendar header)
            Group {
                if let file = selectedFile {
                    VStack(spacing: 0) {
                        if let kind = HorizonKind(filename: file) {
                            HorizonCalendarHeader(kind: kind)
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                                .padding(.bottom, 12)
                            Divider()
                        }
                        TraceMacNoteEditor(relativePath: "\(subfolder)/\(file)")
                            .environment(noteStore)
                    }
                } else {
                    MacEmptyState.placeholder("doc.text", "Select a note or create one")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewNote = true } label: {
                    Label("New Note", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.replacingOccurrences(of: ".md", with: "") ?? "")\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deleteNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingNewNote) {
            newNoteSheet
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .task { await loadFiles() }
        .task(id: deepLinkFile?.wrappedValue) {
            guard let filename = deepLinkFile?.wrappedValue else { return }
            if files.isEmpty {
                let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
                files = loaded.sorted()
            }
            if !files.contains(filename) {
                files.append(filename)
                files.sort()
            }
            selectedFile = filename
            deepLinkFile?.wrappedValue = nil
        }
    }

    private var newNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New \(sectionTitle) Note")
                .font(.headline)
            TextField(newNotePrompt, text: $newNoteName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { createNote() }
            HStack {
                Button("Cancel") {
                    newNoteName = ""
                    showingNewNote = false
                }
                Button("Create") { createNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newNoteName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Note")
                .font(.headline)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { renameNote() }
            HStack {
                Button("Cancel") {
                    showRenameSheet = false
                    renameCandidate = nil
                }
                Button("Rename") { renameNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
        files = loaded.sorted()
        let sf = subfolder
        var contents: [String: String] = [:]
        var tagSet = Set<String>()
        let regex = try? NSRegularExpression(pattern: #"(?<![&\w])#([a-zA-Z][a-zA-Z0-9_]*)"#)
        for filename in files {
            let content = (try? noteStore.readFile("\(sf)/\(filename)")) ?? ""
            contents[filename] = content
            guard let regex else { continue }
            let ns = content as NSString
            regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: content) {
                    tagSet.insert(String(content[r]).lowercased())
                }
            }
        }
        fileContents = contents
        allTags = tagSet.sorted()
    }

    private func renameNote() {
        guard let old = renameCandidate else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let newFilename = newName + ".md"
        guard newFilename != old else {
            showRenameSheet = false; renameCandidate = nil; return
        }
        try? noteStore.moveFile(from: "\(subfolder)/\(old)", to: "\(subfolder)/\(newFilename)")
        if let idx = files.firstIndex(of: old) {
            files[idx] = newFilename
            files.sort()
        }
        if selectedFile == old { selectedFile = newFilename }
        showRenameSheet = false
        renameCandidate = nil
    }

    private func deleteNote(_ filename: String) {
        try? noteStore.deleteFile("\(subfolder)/\(filename)")
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let filename = "\(name).md"
        let path = "\(subfolder)/\(filename)"
        try? noteStore.writeFile(path, content: "# \(name)\n\n")
        if !files.contains(filename) {
            files.append(filename)
            files.sort()
        }
        selectedFile = filename
        newNoteName = ""
        showingNewNote = false
    }
}

// MARK: - Projects view (hub layout: editor + Documents/People/Places tabs)

struct TraceMacProjectsView: View {
    /// Bare `<Title>.md`, set by `TraceMacNotesView` from a note wikilink.
    var deepLinkFile: Binding<String?>? = nil

    private let subfolder = "Notes/Projects"
    /// Bumped when the editor saves, so `MacProjectHubSidebar` re-derives its
    /// People / Places / Notes from the new body.
    @State private var hubReload = 0

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var files: [String] = []
    @State private var selectedFile: String? = nil
    @State private var searchText = ""
    @State private var showingNewNote = false
    @State private var newNoteName = ""
    @State private var deleteCandidate: String? = nil
    @State private var showDeleteConfirm = false
    @State private var renameCandidate: String? = nil
    @State private var showRenameSheet = false
    @State private var renameDraft = ""
    @State private var fileListCollapsed = false
    /// Remembered across launches, and shared with every other resizable
    /// column through `MacColumnResizer`.
    @AppStorage("tracemac.column.projects") private var projectsWidth: Double = 200
    @State private var docStore: TraceMacDocumentStore? = nil
    @State private var selectedTags: Set<String> = []
    @State private var allTags: [String] = []
    @State private var fileContents: [String: String] = [:]
    /// Row under the cursor, so an unpinned row can offer a pin to click.
    @State private var hoveredFile: String? = nil

    private var filtered: [String] {
        let base = searchText.isEmpty ? files : files.filter { $0.localizedCaseInsensitiveContains(searchText) }
        guard !selectedTags.isEmpty else { return pinnedFirst(base) }
        return pinnedFirst(base.filter { filename in
            let content = fileContents[filename] ?? ""
            return selectedTags.allSatisfy { content.range(of: "#\($0)", options: .caseInsensitive) != nil }
        })
    }

    // MARK: - Pinning (queue item 19)
    //
    // The pin is not a Mac-local idea. `DayflowFlagStore` keeps one JSON index
    // in the shared iCloud container, keyed on the vault-relative note path, and
    // Dayflow's project list has read it since 2026-07-22. The Mac joins that
    // index rather than starting a second one — see D78, and the file's own
    // header for why the flag is not in the note.
    //
    // **The key has to match exactly, and it does.** Dayflow builds
    // `"Notes/Projects/\(name).md"` from a bare title; this list's `files` are
    // already `<Title>.md`, so `subfolder + "/" + filename` is the same string.
    // Two ways of spelling one key is how an index like this silently splits.

    private func projectNotePath(_ filename: String) -> String { "\(subfolder)/\(filename)" }

    private func isPinned(_ filename: String) -> Bool {
        DayflowFlagStore.shared.isFlagged(projectNotePath(filename))
    }

    /// Pinned notes float to the top; each group keeps the alphabetical order
    /// `loadFiles` already put `files` in.
    ///
    /// Dayflow layers the same "pinned first" rule over a three-way sort menu
    /// (`sortedProjectNames`, Newest/Oldest/Name). This list has no sort control,
    /// so the question that menu answers — how to order *within* each group —
    /// does not arise here, and inventing a sort menu to match would be copying
    /// the shape of the other screen instead of the behaviour David asked for.
    private func pinnedFirst(_ names: [String]) -> [String] {
        names.filter { isPinned($0) } + names.filter { !isPinned($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: project list
            if !fileListCollapsed {
                VStack(spacing: 0) {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    MacTagChipRow(tags: allTags, selected: $selectedTags)

                    if files.isEmpty {
                        Spacer()
                        Text("No projects yet.")
                            .font(.caption).foregroundStyle(.secondary).padding()
                        Spacer()
                    } else {
                        List(filtered, id: \.self, selection: $selectedFile) { filename in
                            HStack(spacing: 6) {
                                Label(
                                    filename.replacingOccurrences(of: ".md", with: ""),
                                    systemImage: "folder.fill"
                                )
                                .font(.system(.callout, weight: .medium))
                                .lineLimit(1)
                                Spacer(minLength: 4)
                                // A GLYPH THAT LOOKS LIKE A CONTROL IS A CONTROL.
                                //
                                // Session 69 shipped this as a pure indicator with
                                // the toggle in the context menu, reasoning that a
                                // dead-looking pin on every row was worse (D80).
                                // David's first sentence on it: *"the pin is there
                                // but i cant click it on and off."* Nothing about a
                                // pushpin says right-click me, and the argument had
                                // the discoverability backwards anyway — with the
                                // glyph hidden until pinned, there was nothing to
                                // click to pin in the first place. D82.
                                //
                                // Hover is what makes both true at once: a faint
                                // outline pin appears on the row under the cursor,
                                // a filled orange one stays on pinned rows. Same
                                // idiom as Finder and Mail; it does not need the
                                // permanent clutter the original note worried about.
                                if isPinned(filename) || hoveredFile == filename {
                                    Button {
                                        DayflowFlagStore.shared.toggleFlag(projectNotePath(filename))
                                    } label: {
                                        Image(systemName: isPinned(filename) ? "pin.fill" : "pin")
                                            .font(.system(size: 11))
                                            .foregroundStyle(isPinned(filename)
                                                             ? MacPalette.orange
                                                             : Color.secondary)
                                            // Without this the hit area is the glyph's
                                            // drawn pixels, which for a pushpin is a
                                            // thin diagonal and a dot.
                                            .contentShape(Rectangle())
                                    }
                                    // `.plain` and nothing else. A bordered button in
                                    // a sidebar row draws a chrome rectangle over the
                                    // selection highlight, and a Button inside a List
                                    // row consumes its own click, so pinning does not
                                    // also change which note is open.
                                    .buttonStyle(.plain)
                                    .help(isPinned(filename) ? "Unpin" : "Pin")
                                    .accessibilityLabel(isPinned(filename)
                                                        ? "Unpin \(filename)"
                                                        : "Pin \(filename)")
                                }
                            }
                            .padding(.vertical, 4)
                            // The hover target has to be the whole row, not just the
                            // text, or the pin flickers away as the cursor crosses
                            // the gap between the label and the trailing edge.
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hoveredFile = filename }
                                else if hoveredFile == filename { hoveredFile = nil }
                            }
                            .tag(filename)
                            .contextMenu {
                                Button {
                                    DayflowFlagStore.shared.toggleFlag(projectNotePath(filename))
                                } label: {
                                    Label(isPinned(filename) ? "Unpin" : "Pin",
                                          systemImage: isPinned(filename) ? "pin.slash" : "pin")
                                }
                                Divider()
                                Button {
                                    renameCandidate = filename
                                    renameDraft = filename.replacingOccurrences(of: ".md", with: "")
                                    showRenameSheet = true
                                } label: { Label("Rename", systemImage: "pencil") }
                                Divider()
                                Button(role: .destructive) {
                                    deleteCandidate = filename
                                    showDeleteConfirm = true
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(width: projectsWidth)
                MacColumnResizer(width: $projectsWidth)
            }

            CollapseHandle(isCollapsed: $fileListCollapsed, collapsesRight: false,
                           showLine: true, panelColor: .clear)

            // Right: hub (editor + entity sidebar)
            Group {
                if let file = selectedFile, let store = docStore {
                    let notePath = "\(subfolder)/\(file)"
                    HStack(spacing: 0) {
                        TraceMacNoteEditor(relativePath: notePath,
                                           onSaved: { hubReload += 1 })
                            .frame(maxWidth: .infinity)
                        Divider()
                        MacProjectHubSidebar(notePath: notePath, store: store,
                                             reloadToken: hubReload)
                            .frame(width: 260)
                    }
                } else {
                    MacEmptyState.placeholder("folder", "Select a project or create one")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewNote = true } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
            if let file = selectedFile {
                ToolbarItem {
                    Button(role: .destructive) {
                        deleteCandidate = file
                        showDeleteConfirm = true
                    } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(deleteCandidate?.replacingOccurrences(of: ".md", with: "") ?? "")\"?",
            isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let f = deleteCandidate { deleteNote(f) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingNewNote) { newNoteSheet }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .task(id: deepLinkFile?.wrappedValue) {
            guard let filename = deepLinkFile?.wrappedValue else { return }
            if files.isEmpty { await loadFiles() }
            if !files.contains(filename) {
                files.append(filename)
                files.sort()
            }
            selectedFile = filename
            deepLinkFile?.wrappedValue = nil
        }
        .task {
            // Re-read the shared flag index before the list draws. The store is
            // a singleton that loads once, at first touch; a pin David sets on
            // the phone after this Mac launched would otherwise not appear until
            // the app is relaunched — which is the exact complaint item 19 is
            // about, one layer down. See `DayflowFlagStore.reload()`.
            DayflowFlagStore.shared.reload()
            await loadFiles()
            if docStore == nil {
                docStore = TraceMacDocumentStore(noteStore: noteStore)
            }
            await docStore?.reload()
        }
    }

    // MARK: - Sheets

    private var newNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New Project").font(.headline)
            TextField("Project name", text: $newNoteName)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { createNote() }
            HStack {
                Button("Cancel") { newNoteName = ""; showingNewNote = false }
                Button("Create") { createNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newNoteName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Project").font(.headline)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { renameNote() }
            HStack {
                Button("Cancel") { showRenameSheet = false; renameCandidate = nil }
                Button("Rename") { renameNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Actions

    private func loadFiles() async {
        let loaded = (try? noteStore.listFiles(in: subfolder)) ?? []
        files = loaded.sorted()
        var contents: [String: String] = [:]
        var tagSet = Set<String>()
        let regex = try? NSRegularExpression(pattern: #"(?<![&\w])#([a-zA-Z][a-zA-Z0-9_]*)"#)
        for filename in files {
            let content = (try? noteStore.readFile("\(subfolder)/\(filename)")) ?? ""
            contents[filename] = content
            guard let regex else { continue }
            let ns = content as NSString
            regex.enumerateMatches(in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: content) {
                    tagSet.insert(String(content[r]).lowercased())
                }
            }
        }
        fileContents = contents
        allTags = tagSet.sorted()
    }

    private func createNote() {
        let name = newNoteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let filename = "\(name).md"
        let path = "\(subfolder)/\(filename)"
        // **A title line, not frontmatter.** Every project note already in the
        // vault starts `# Name` and nothing else, and the seven-key block this
        // replaced had two writers and zero readers: nothing in either app parses
        // `title:`, `type:`, `created:` or `linked_notes:` on a project note.
        // Tags come from `#tag` in the body (see `loadFiles`' regex), linked notes
        // from `[[wikilinks]]` in the body (D64), documents from Satchel sidecars.
        //
        // It also could not be hidden. `EndeavorFile.parse` splits frontmatter off
        // before an Endeavor note reaches the editor; a project note goes to the
        // generic editor whole, so the block rendered as seven lines of raw text
        // at the top of every new note. David, on the first one he made:
        // *"i added a project note in TraceMac and this came up."*
        let content = """
        # \(name)

        """
        try? noteStore.writeFile(path, content: content)
        if !files.contains(filename) { files.append(filename); files.sort() }
        selectedFile = filename
        newNoteName = ""
        showingNewNote = false
        Task { await docStore?.reload() }
    }

    private func renameNote() {
        guard let old = renameCandidate else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }
        let newFilename = newName + ".md"
        guard newFilename != old else { showRenameSheet = false; renameCandidate = nil; return }
        try? noteStore.moveFile(from: "\(subfolder)/\(old)", to: "\(subfolder)/\(newFilename)")
        // The flag index is keyed on the path, so the rename has to carry it or
        // the pin points at a file that no longer exists and the note comes back
        // unpinned. Same reason `deleteNote` clears rather than leaves.
        DayflowFlagStore.shared.moveFlag(from: projectNotePath(old),
                                         to: projectNotePath(newFilename))
        if let idx = files.firstIndex(of: old) { files[idx] = newFilename; files.sort() }
        if selectedFile == old { selectedFile = newFilename }
        showRenameSheet = false; renameCandidate = nil
    }

    private func deleteNote(_ filename: String) {
        try? noteStore.deleteFile("\(subfolder)/\(filename)")
        DayflowFlagStore.shared.clearFlag(projectNotePath(filename))
        files.removeAll { $0 == filename }
        if selectedFile == filename { selectedFile = nil }
        deleteCandidate = nil
    }
}


// MARK: - Horizon file classification

/// Parses a Horizons filename into a week or month kind.
/// "2026-W27.md" → .week(2026, 27)
/// "2026-07.md"  → .month(2026, 7)
/// Anything else → nil (no header shown)
private enum HorizonKind {
    case week(year: Int, week: Int)
    case month(year: Int, month: Int)

    init?(filename: String) {
        let name = filename.replacingOccurrences(of: ".md", with: "")
        // Weekly: "YYYY-Www"
        if let wRange = name.range(of: "-W") {
            let yearStr = String(name[name.startIndex ..< wRange.lowerBound])
            let weekStr = String(name[wRange.upperBound...])
            if let y = Int(yearStr), let w = Int(weekStr), w >= 1, w <= 53 {
                self = .week(year: y, week: w)
                return
            }
        }
        // Monthly: exactly "YYYY-MM"
        let parts = name.split(separator: "-").map(String.init)
        if parts.count == 2, parts[0].count == 4, parts[1].count == 2,
           let y = Int(parts[0]), let m = Int(parts[1]), m >= 1, m <= 12 {
            self = .month(year: y, month: m)
            return
        }
        return nil
    }
}

// MARK: - Horizon calendar header

private struct HorizonCalendarHeader: View {

    let kind: HorizonKind

    /// Was a third definition of the same calendar. See TraceMacCalendar.swift.
    private var isoCalendar: Calendar { .traceWeek }

    var body: some View {
        switch kind {
        case .week(let year, let week):   weekView(year: year, week: week)
        case .month(let year, let month): monthView(year: year, month: month)
        }
    }

    // MARK: Weekly header

    private func weekDates(year: Int, week: Int) -> [Date] {
        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = week
        comps.weekday = 2   // Monday = first day in ISO week
        guard let monday = isoCalendar.date(from: comps) else { return [] }
        return (0..<7).compactMap { isoCalendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private func weekRangeLabel(_ dates: [Date]) -> String {
        guard let first = dates.first, let last = dates.last else { return "" }
        let mFmt = DateFormatter(); mFmt.dateFormat = "MMMM"
        let dFmt = DateFormatter(); dFmt.dateFormat = "d"
        let yFmt = DateFormatter(); yFmt.dateFormat = "yyyy"
        let firstMonth = isoCalendar.component(.month, from: first)
        let lastMonth  = isoCalendar.component(.month, from: last)
        let year = yFmt.string(from: last)
        if firstMonth == lastMonth {
            return "\(mFmt.string(from: first)) \(dFmt.string(from: first))–\(dFmt.string(from: last)), \(year)"
        } else {
            return "\(mFmt.string(from: first)) \(dFmt.string(from: first)) – \(mFmt.string(from: last)) \(dFmt.string(from: last)), \(year)"
        }
    }

    @ViewBuilder
    private func weekView(year: Int, week: Int) -> some View {
        let dates    = weekDates(year: year, week: week)
        let abbrevs  = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        VStack(alignment: .leading, spacing: 8) {
            Text(weekRangeLabel(dates))
                .font(MacType.row)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(Array(zip(abbrevs, dates)), id: \.0) { abbrev, date in
                    let dayNum    = isoCalendar.component(.day, from: date)
                    let isWeekend = abbrev == "Sat" || abbrev == "Sun"

                    VStack(spacing: 5) {
                        Text(abbrev)
                            .macLabel()
                            .foregroundStyle(isWeekend ? .secondary : .primary)

                        Text("\(dayNum)")
                            .font(MacType.row)
                            .foregroundStyle(isWeekend ? .secondary : .primary)
                            .frame(width: 28, height: 28)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Monthly header

    private func monthDates(year: Int, month: Int) -> [Date?] {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = 1
        guard let firstDay = isoCalendar.date(from: comps) else { return [] }
        guard let range = isoCalendar.range(of: .day, in: .month, for: firstDay) else { return [] }
        let weekday = isoCalendar.component(.weekday, from: firstDay)
        let offset  = (weekday + 5) % 7   // Mon=0 … Sun=6
        var result: [Date?] = Array(repeating: nil, count: offset)
        for d in range {
            var dc = comps; dc.day = d
            result.append(isoCalendar.date(from: dc))
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private func monthHeaderLabel(year: Int, month: Int) -> String {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = 1
        guard let date = isoCalendar.date(from: comps) else { return "" }
        let fmt = DateFormatter(); fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: date)
    }

    @ViewBuilder
    private func monthView(year: Int, month: Int) -> some View {
        let dates   = monthDates(year: year, month: month)
        let rows    = stride(from: 0, to: dates.count, by: 7).map {
            Array(dates[$0 ..< min($0 + 7, dates.count)])
        }
        let headers = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let label   = monthHeaderLabel(year: year, month: month)

        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(MacType.heading)
                .foregroundStyle(.primary)

            // Column headers
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                    Text(h)
                        .macLabel()
                        .foregroundStyle(idx >= 5 ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Date rows
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, date in
                        if let date = date {
                            let dayNum    = isoCalendar.component(.day, from: date)
                            let isWeekend = colIdx >= 5
                            Text("\(dayNum)")
                                .font(MacType.row)
                                .foregroundStyle(isWeekend ? .secondary : .primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 26)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - AppKit text editor (no scrollbar)

// MARK: - Editor command enum

enum MacEditorCommand: Equatable {
    case bold, italic, strike, highlight
    case heading, bullet, checkbox
    case indent, outdent
    case link, date
    case undo, redo
    case timestamp
    case requestMove
    case applyWikiSuggestion(String)
    /// Raw text at the cursor. The photo button's insert goes through here
    /// rather than through the `text` binding, for the same reason every other
    /// command does: the binding round-trip loses the caret.
    case insertText(String)
}

// MARK: - NSTextView subclass: checkbox click detection

/// Intercepts mouseDown to toggle ☐/☑ when the user clicks the checkbox glyph.
/// Also rejects file-URL drags so they propagate up to the Documents drop zone
/// instead of being pasted as text paths.
private final class MarkdownNSTextView: NSTextView {

    /// Fired when the view's WIDTH changes, so thumbnail overlays can be
    /// re-laid out. Session 65.
    ///
    /// Overlays are positioned in absolute points rather than by a layout
    /// system, so nothing moves them when the window resizes — the picture
    /// would sit at its old width while the text reflowed around it. Width
    /// only: a height change is the document growing, which moves nothing
    /// horizontally and would fire this on every keystroke.
    var onWidthChange: (() -> Void)?

    /// Handed image bytes from a ⌘V. Returns true if it consumed them.
    ///
    /// **This is the primary gesture on a Mac and the toolbar button is the
    /// secondary one**, which is the reverse of the phone. A screenshot goes
    /// to the clipboard, not to a photo library, and asking someone to save it
    /// to disk first so a file panel can find it again is the phone's
    /// constraint imported into a place that does not have it.
    var onPasteImage: ((Data) -> Bool)?

    override func paste(_ sender: Any?) {
        if let onPasteImage {
            let pb = NSPasteboard.general
            // TIFF first: that is what a screenshot and most drags arrive as.
            // PNG second, for the sources that only offer it. Both are re-encoded
            // downstream, so which one wins does not affect what is stored.
            if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
               onPasteImage(data) { return }
        }
        super.paste(sender)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let before = frame.width
        super.setFrameSize(newSize)
        if abs(before - newSize.width) > 0.5 { onWidthChange?() }
    }

    // Refuse file-URL drags — let the Documents left-column .onDrop handle them.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let fileTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        ]
        if fileTypes.contains(where: { sender.draggingPasteboard.types?.contains($0) == true }) {
            return []
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let fileTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        ]
        if fileTypes.contains(where: { sender.draggingPasteboard.types?.contains($0) == true }) {
            return false
        }
        return super.prepareForDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let adj = NSPoint(x: point.x - textContainerInset.width,
                          y: point.y - textContainerInset.height)
        if let lm = layoutManager, let tc = textContainer {
            let glyphIdx = lm.glyphIndex(for: adj, in: tc,
                                          fractionOfDistanceThroughGlyph: nil)
            let charIdx  = lm.characterIndexForGlyph(at: glyphIdx)
            if charIdx < (textStorage?.length ?? 0) {
                // Click on [[wikilink]] → navigate to record.
                // Single-click navigates and places cursor; Cmd+click navigates without moving cursor.
                if let target = textStorage?.attribute(.macWikiTarget, at: charIdx,
                                                       effectiveRange: nil) as? String {
                    NotificationCenter.default.post(name: .openWikilink, object: nil,
                                                    userInfo: ["name": target])
                    if event.modifierFlags.contains(.command) { return }
                    // Fall through to super so cursor is placed at the click position
                }
                // Click on checkbox → toggle
                if textStorage?.attribute(.macCheckboxState, at: charIdx,
                                          effectiveRange: nil) != nil {
                    let ns = (textStorage?.string ?? "") as NSString
                    let lineRange = ns.lineRange(for: NSRange(location: charIdx, length: 0))
                    let line = ns.substring(with: lineRange)
                    if line.hasPrefix("☐ ") {
                        textStorage?.replaceCharacters(in: lineRange,
                                                       with: "☑ " + String(line.dropFirst(2)))
                    } else if line.hasPrefix("☑ ") {
                        textStorage?.replaceCharacters(in: lineRange,
                                                       with: "☐ " + String(line.dropFirst(2)))
                    }
                    didChangeText()
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

// MARK: - MacEditorActions (direct command channel — bypasses SwiftUI binding timing)

/// Shared by TraceMacNoteEditor and MacTextEditor. Toolbar buttons call execute(_:) directly;
/// MacTextEditor wires it to the coordinator in makeNSView. No binding timing issues.
final class MacEditorActions {
    var execute: (MacEditorCommand) -> Void = { _ in }
    /// Called by .requestMove with (textToMove, remainingContent).
    var onMoveRequest: ((String, String) -> Void)?

    /// Rewrites the editor's live body and saves it. Session 65.
    ///
    /// **Why this and not a write to the file.** The Endeavor rail needs to put
    /// a visit into the note the editor beside it is holding. Writing the file
    /// directly loses: the editor's next debounced save takes its own `content`
    /// as the truth for the body, so the rail's line would be gone one keystroke
    /// later, silently. `saveTransform` re-reads the file to protect the
    /// *frontmatter*, which is a different half of the same document.
    ///
    /// So an owner hands in a transform and the editor applies it to what it is
    /// holding, then saves through the one path that already exists. Set by
    /// `TraceMacNoteEditor`; nil until an editor is on screen, which is also the
    /// only time an owner has any business writing into one.
    var applyToBody: ((@escaping (String) -> String) -> Void)?
}

// MARK: - MacTextEditor (NSViewRepresentable)

/// NSTextView backed by MacMarkdownTextStorage with live markdown rendering.
private struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    let actions: MacEditorActions
    /// Called when the cursor enters/exits a [[...]] span. Receives the partial name or nil.
    var onWikilinkQuery: ((String?) -> Void)? = nil
    /// Called when the user presses Return while a wikilink session is open.
    /// Returns true if a suggestion was actually applied. False means there was
    /// nothing to accept, and the Return must be allowed through as a newline.
    var onWikilinkAccept: (() -> Bool)? = nil
    /// Called by .requestMove with (textToMove, remainingContent).
    var onMoveRequest: ((String, String) -> Void)? = nil
    /// Handed image bytes from a ⌘V; returns true if it stored and inserted them.
    var onPasteImage: ((Data) -> Bool)? = nil
    /// Lowercased titles of linkable notes, so the storage can paint a note
    /// wikilink in its own colour. See `MacMarkdownTextStorage.noteTitles`.
    var noteTitles: Set<String> = []

    // MARK: makeNSView

    func makeNSView(context: Context) -> NSScrollView {
        let storage   = MacMarkdownTextStorage()
        let manager   = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let tv = MarkdownNSTextView(frame: .zero, textContainer: container)
        let paraStyle = MacMarkdownTextStorage.baseParagraphStyle

        tv.isEditable              = true
        tv.isRichText              = false
        tv.allowsUndo              = true
        tv.backgroundColor         = NSColor.clear
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask        = [.width]
        tv.minSize                 = NSSize(width: 0, height: 0)
        tv.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset      = NSSize(width: 40, height: 24)
        tv.defaultParagraphStyle = paraStyle as? NSMutableParagraphStyle
        tv.typingAttributes = [
            NSAttributedString.Key.font:            MacMarkdownTextStorage.bodyFont,
            NSAttributedString.Key.foregroundColor: MacMarkdownTextStorage.textColor,
            NSAttributedString.Key.paragraphStyle:  paraStyle
        ] as [NSAttributedString.Key: Any]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled  = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        // Session 64/65. Kept, but NOT the fix for David's *"after the first
        // character it auto completes the link"* — that was diagnosed here
        // first and it was wrong. The real cause was the link button inserting
        // a *complete* `[[]]` pair, which made `applyWikilinks` match at one
        // typed character and hide the brackets; see `beginWikilink` below.
        //
        // These two stay disabled on their own merits, matching iOS
        // (`MarkdownEditorView.swift:395`, `autocorrectionType = .no`, comment
        // *"disabled — pill bar is the autocomplete surface"*): the Mac had
        // disabled three of the four members of that family, and these are the
        // ones that complete and rewrite rather than merely flag. Continuous
        // spell *checking* is left on deliberately.
        tv.isAutomaticTextCompletionEnabled  = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        tv.onWidthChange = { [weak coord = context.coordinator, weak tv] in
            guard let coord, let tv else { return }
            coord.refreshHorizontalRules(in: tv)
            coord.refreshThumbnails(in: tv)
        }

        // Wire toolbar actions directly to coordinator — no SwiftUI binding round-trip.
        let coord = context.coordinator
        actions.execute = { [weak coord] cmd in
            guard let c = coord, let tv = c.textView else { return }
            c.execute(cmd, in: tv)
        }
        coord.onWikilinkQuery  = onWikilinkQuery
        coord.onWikilinkAccept = onWikilinkAccept
        coord.onMoveRequest    = onMoveRequest
        actions.onMoveRequest  = onMoveRequest
        tv.onPasteImage        = onPasteImage

        let scrollView = NSScrollView()
        scrollView.documentView          = tv
        scrollView.hasVerticalScroller   = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = false
        scrollView.backgroundColor       = NSColor.clear
        scrollView.drawsBackground       = false

        if !text.isEmpty {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            // Explicit: a programmatic `replaceCharacters` does not go through
            // the delegate, so nothing else would style the loaded document now
            // that `processEditing` no longer does.
            storage.applyStyles()
            // `DispatchQueue.main.async`, deliberately, and reverted back to it
            // in Session 65.
            //
            // It was converted to `Task { @MainActor in }` to silence a
            // cross-actor warning on `NoteStore.shared`. That warning is gone by
            // a better route — `readFile`, `resolvedURL` and `findWikilinkMentions`
            // are `nonisolated` now — so the conversion buys nothing.
            //
            // And it is not free. GCD schedules on the runloop; a `Task` runs on
            // the main actor's cooperative executor, which can land at a
            // different point relative to AppKit's own text-input processing.
            // These blocks manipulate the text view — subviews, wikilink state —
            // and a caret bug that appeared the same day as that conversion is
            // not something to leave a rewritten scheduler under. **If it is
            // ever changed again, that is a text-input timing change, not a
            // concurrency tidy-up.**
            DispatchQueue.main.async { [weak coord] in
                guard let c = coord, let tv = c.textView else { return }
                c.refreshHorizontalRules(in: tv)
                c.refreshThumbnails(in: tv)
            }
        }

        return scrollView
    }

    // MARK: updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Re-wire on every update so the closure always reaches the live coordinator.
        let coord = context.coordinator
        actions.execute = { [weak coord] cmd in
            guard let c = coord, let tv = c.textView else { return }
            c.execute(cmd, in: tv)
        }
        coord.onWikilinkQuery  = onWikilinkQuery
        coord.onWikilinkAccept = onWikilinkAccept
        coord.onMoveRequest    = onMoveRequest
        actions.onMoveRequest  = onMoveRequest
        guard let tv = scrollView.documentView as? MarkdownNSTextView else { return }
        tv.onPasteImage = onPasteImage
        // Before the text guard below, deliberately. The set changes when a new
        // project note appears while the text has not changed at all, and the
        // guard would skip the restyle and leave the link the wrong colour.
        if let storage = tv.textStorage as? MacMarkdownTextStorage,
           storage.noteTitles != noteTitles {
            storage.noteTitles = noteTitles
            storage.applyStyles()
            tv.needsDisplay = true
        }
        guard tv.string != text else { return }
        let savedRange = tv.selectedRange()
        tv.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: tv.textStorage?.length ?? 0),
            with: text)
        (tv.textStorage as? MacMarkdownTextStorage)?.applyStyles()
        let newLen = tv.textStorage?.length ?? 0
        tv.setSelectedRange(NSRange(location: min(savedRange.location, newLen), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    // MARK: Sizing

    /// Fully flexible: adopt whatever SwiftUI proposes; never report an intrinsic
    /// minimum. Without this, SwiftUI derives sizing from the scroll view's fitting
    /// size, which reads as a wide minimum once the text view has laid out wide and
    /// refuses to compress — pushing sibling columns (e.g. the calendar) off-window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> NSSize? {
        guard proposal.width != nil || proposal.height != nil else { return nil }
        return NSSize(width: proposal.width ?? nsView.frame.width,
                      height: proposal.height ?? nsView.frame.height)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: MarkdownNSTextView?
        /// Last known selection — stored here so commands can use it even after focus leaves the text view.
        var lastSelection = NSRange(location: 0, length: 0)
        /// Called when cursor enters/exits a [[...]] span.
        var onWikilinkQuery: ((String?) -> Void)?
        /// Called when user presses Return while a wikilink session is open.
        /// True if a suggestion was applied; false leaves the Return alone.
        var onWikilinkAccept: (() -> Bool)?
        /// Called by .requestMove with (textToMove, remainingContent).
        var onMoveRequest: ((String, String) -> Void)?
        /// Character position of the opening [[ in the active wikilink session.
        private var wikilinkOpenLoc: Int? = nil

        /// Marker subclass for thin NSView separators overlaid on `---` lines.
        private final class HROverlay: NSView {}
        /// Marker subclass for pictures overlaid on `!![desc](path)` lines.
        /// A subclass rather than `tag`, matching `HROverlay` — `NSView.tag` is
        /// a read-only property and overriding it to carry a magic number is a
        /// worse way to say "mine" than a type is.
        private final class ThumbOverlay: NSImageView {
            /// Invisible to the mouse. `isEditable = false` stops an image view
            /// accepting a drop; it does not stop it swallowing clicks, and a
            /// picture that eats the click is a picture you cannot put the
            /// caret next to — so you cannot select the line, and you cannot
            /// delete it with the keyboard. The marker is text and must stay
            /// reachable as text.
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        /// Decoded images, by container-relative path. Cleared by nothing: a
        /// note holds a handful of pictures and the coordinator dies with the
        /// pane.
        private var thumbCache: [String: NSImage] = [:]
        /// Paths with an iCloud download in flight, so one miss schedules one
        /// retry rather than one per refresh.
        private var thumbRetries: Set<String> = []
        /// Bounded backstop for the case where the view has no width yet.
        private var thumbLayoutRetries: [String: Int] = [:]

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Reset typing attributes so new text never inherits markdown styles (bold, color, etc.)
            tv.typingAttributes = [
                NSAttributedString.Key.font:            MacMarkdownTextStorage.bodyFont,
                NSAttributedString.Key.foregroundColor: MacMarkdownTextStorage.textColor,
                NSAttributedString.Key.paragraphStyle:  MacMarkdownTextStorage.baseParagraphStyle
            ] as [NSAttributedString.Key: Any]
            // STYLE HERE, not in `MacMarkdownTextStorage.processEditing` — see
            // the long note at the top of that file. Restyling inside the edit
            // cycle gets its `.editedAttributes` notification merged into the
            // user's `.editedCharacters` one, and the layout manager then fixes
            // the selection across the union of both ranges. That is the caret
            // bug, and every symptom of it, in one sentence.
            //
            // Out here it is a second, separate pass carrying attributes alone.
            (tv.textStorage as? MacMarkdownTextStorage)?.applyStyles()
            if text.wrappedValue != tv.string { text.wrappedValue = tv.string }
            // GCD, not `Task` — see the note in `makeNSView`. This is the block
            // that runs on every keystroke, so it is the one where scheduling
            // against AppKit's text input matters most.
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv else { return }
                // Force layout for anything the edit left pending.
                //
                // David, after the paragraph-scoped restyle landed: pressing
                // Return at the end of the first row made the LAST row vanish,
                // and double-clicking it brought it back. Double-clicking forces
                // layout, which is the tell — the line's attributes were never
                // wrong, its layout was simply never generated.
                //
                // The insertion shifts every character index after it, and the
                // attribute notification that follows covers only the edited
                // paragraph, so the tail can be left with pending layout that
                // nothing asks for. The final line is the one that shows it,
                // because it has no trailing newline and therefore no following
                // fragment to drag it into being laid out.
                //
                // `ensureLayout` GENERATES pending layout. It does not
                // invalidate, does not touch attributes and does not move the
                // caret — which is what makes it the right tool here after six
                // attempts with `invalidateGlyphs` / `invalidateLayout` /
                // `invalidateDisplay`, every one of which threw something away
                // in order to rebuild it. `refreshHorizontalRules` below has
                // called this for months without incident.
                if let lm = tv.layoutManager, let tc = tv.textContainer {
                    lm.ensureLayout(for: tc)
                }
                // Generate any layout the edit left pending.
                //
                // Safe here in a way it was not before: styling now happens in
                // `textDidChange` rather than inside `processEditing`, so by the
                // time this runs the attribute edit has already been announced
                // over the whole document and the layout it invalidated needs
                // generating rather than replacing. `ensureLayout` only
                // generates — it does not invalidate, touch attributes or move
                // the caret.
                //
                // The symptom it exists for: deleting a blank row could leave
                // the row below it undrawn until clicked, and a click forces
                // layout. `refreshHorizontalRules` has called this for months.
                if let lm = tv.layoutManager, let tc = tv.textContainer {
                    lm.ensureLayout(for: tc)
                }
                // REDRAW THE VIEW, not a character range.
                //
                // Instrumented rather than guessed, 2026-08-04. Deleting the
                // blank row between a title and a checkbox line drew the
                // checkbox row TWICE, and the log said:
                //
                //   chars=55 lines=5 laidOutChars=0..<55 usedH=128 frameH=919
                //
                // Two copies of that line cannot fit in 55 characters, and the
                // document was fully laid out in 128pt of a 919pt frame. **The
                // duplicate was never in the document.** It was the pixels of
                // the row's previous position, never repainted after the text
                // above it shrank.
                //
                // That is also why `invalidateDisplay(forCharacterRange:)` did
                // nothing when it was tried: it can only dirty the area a
                // character range currently occupies, and stale pixels sit where
                // characters USED to be — below the used rect, mapped to no
                // character at all. Only a view-level redraw reaches them.
                //
                // The same mechanism, in the other direction, is the "row goes
                // missing" symptom: the row is drawn where it no longer is, and
                // blank where it now is.
                //
                // Cheap: `usedH` is ~128pt for a real note, and AppKit coalesces
                // this to one repaint per runloop turn. It touches neither
                // layout, attributes, nor the selection.
                tv.needsDisplay = true
                self.refreshHorizontalRules(in: tv)
                self.refreshThumbnails(in: tv)
                self.checkForWikilink(in: tv)
                // Order matters: `checkForWikilink` is what sets `wikilinkOpenLoc`
                // for the text as it stands now, and the converter reads it.
                // Text-change path only — mutating the storage from inside
                // `textViewDidChangeSelection` is how you get re-entrancy.
                self.convertURLWikilink(in: tv)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Only snapshot the selection while the text view actually owns focus.
            // When the user clicks a toolbar button macOS collapses the selection
            // *before* the button action fires — if we saved that we'd lose the range.
            if tv.window?.firstResponder === tv {
                lastSelection = tv.selectedRange()
            }
            checkForWikilink(in: tv)
        }

        // MARK: - Thumbnail overlays
        //
        // Session 65. A port of iOS `refreshThumbnails`, including the bug it
        // documents, because the bug is a property of the approach rather than
        // of UIKit and would have been rewritten here otherwise.
        //
        // Overlays are subviews of the text view, which is the scroll view's
        // document view, so their frames are in content coordinates and they
        // scroll with the text for free. Same as iOS, where the text view is
        // itself a scroll view.

        /// Draws a picture over every `!![desc](path)` line.
        ///
        /// Called after every text change, once on load, and on width change.
        func refreshThumbnails(in tv: NSTextView) {
            tv.subviews
                .compactMap { $0 as? ThumbOverlay }
                .forEach { $0.removeFromSuperview() }

            guard tv.string.contains("!!["),
                  let regex = try? NSRegularExpression(
                      pattern: #"^!!\[([^\]]*)\]\(([^)]+)\)"#,
                      options: .anchorsMatchLines),
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }

            let ns = tv.string as NSString
            let matches = regex.matches(in: tv.string,
                                        range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return }
            lm.ensureLayout(for: tc)

            // WIDTH COMES FROM THE VIEW, NOT FROM THE LINE.
            //
            // iOS measured this from `boundingRect(forGlyphRange:)` and spent
            // two days on the consequence. That rect means two different things
            // depending on where the line sits: with a line terminator in the
            // glyph range it spans the whole fragment, i.e. the container width,
            // which is right by accident. **The last line of a document has no
            // terminator**, so the rect collapses to the tight bounds of the
            // glyphs — and every glyph on a thumbnail line is deliberately
            // hidden behind a 0.01pt font. Near-zero width, zero-size image
            // view, invisible picture, while the reserved 200pt line and the
            // click target stay exactly where they were.
            //
            // The observation that identified it was David's: adding a second
            // photo brought the first one back and hid the new one. *"like the
            // bug switched spots."* Nothing about a layout race explains that.
            //
            // `refreshHorizontalRules` below already measures from `tv.bounds`,
            // for the same reason.
            let padding = tc.lineFragmentPadding
            let available = tv.bounds.width
                - tv.textContainerInset.width * 2
                - padding * 2

            for match in matches {
                guard match.range(at: 2).location != NSNotFound else { continue }
                let path = ns.substring(with: match.range(at: 2))

                guard available > 2 else {
                    // No frame yet. `onWidthChange` is the real answer and calls
                    // back when there is one; this is a bounded backstop so a
                    // host that never resizes still lands.
                    let n = thumbLayoutRetries[path, default: 0]
                    if n < 3 {
                        thumbLayoutRetries[path] = n + 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tv] in
                            guard let self, let tv else { return }
                            self.refreshThumbnails(in: tv)
                        }
                    }
                    continue
                }
                thumbLayoutRetries[path] = nil

                guard let image = thumbImage(at: path, in: tv) else { continue }

                let lineCharRange = ns.lineRange(for: match.range)
                let glyphRange = lm.glyphRange(forCharacterRange: lineCharRange,
                                               actualCharacterRange: nil)
                var lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                lineRect = lineRect.offsetBy(dx: tv.textContainerInset.width,
                                             dy: tv.textContainerInset.height)

                // 196 against the 200 reserved, so the picture never touches the
                // lines above and below it. `1.0` in the min so a small image is
                // shown at its own size rather than blown up into mush.
                let maxHeight: CGFloat = 196
                let scale = min(available / image.size.width,
                                maxHeight / image.size.height,
                                1.0)
                let size = NSSize(width:  image.size.width  * scale,
                                  height: image.size.height * scale)

                let iv = ThumbOverlay(frame: NSRect(
                    x: tv.textContainerInset.width + padding,
                    y: lineRect.origin.y + (lineRect.height - size.height) / 2,
                    width:  size.width,
                    height: size.height))
                iv.image = image
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.wantsLayer = true
                iv.layer?.cornerRadius = 6
                iv.layer?.masksToBounds = true
                // Non-interactive: clicks fall through to the text view, which
                // is what puts the caret on the line so the marker can be
                // selected and deleted like any other text. A picture you
                // cannot delete with the keyboard would be worse than no
                // picture.
                iv.isEditable = false
                tv.addSubview(iv)
            }
        }

        /// The image at a container path, waiting out iCloud when it has to.
        ///
        /// Same staircase as the document preview and the endeavor cover: try
        /// the direct read, and only if that fails start the download and
        /// schedule ONE retry. A permanent placeholder for a file that is on its
        /// way is the wrong answer, and so is a retry per refresh.
        private func thumbImage(at path: String, in tv: NSTextView) -> NSImage? {
            if let cached = thumbCache[path] { return cached }
            guard let url = NoteStore.shared.resolvedURL(for: path) else { return nil }
            if let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
                thumbCache[path] = image
                return image
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            if !thumbRetries.contains(path) {
                thumbRetries.insert(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tv] in
                    guard let self else { return }
                    self.thumbRetries.remove(path)
                    if let tv { self.refreshThumbnails(in: tv) }
                }
            }
            return nil
        }

        // MARK: - Horizontal rule overlay

        func refreshHorizontalRules(in tv: NSTextView) {
            tv.subviews
                .compactMap { $0 as? HROverlay }
                .forEach { $0.removeFromSuperview() }

            guard tv.string.contains("---"),
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)

            let ns = tv.string as NSString
            var pos = 0
            while pos < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
                guard lineRange.length > 0 else { break }
                let line = ns.substring(with: lineRange)
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                    let glyphRange = lm.glyphRange(forCharacterRange: lineRange,
                                                   actualCharacterRange: nil)
                    let lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                    let insetW = tv.textContainerInset.width
                    let insetH = tv.textContainerInset.height
                    let midY   = lineRect.origin.y + lineRect.height / 2 + insetH
                    let xLeft  = insetW + 16
                    let xRight = tv.bounds.width - insetW - 16

                    let rule = HROverlay(frame: NSRect(x: xLeft, y: midY - 0.5,
                                                       width: max(0, xRight - xLeft), height: 1.0))
                    rule.wantsLayer = true
                    // Session 64: was NSColor(white: 0.45), a frozen grey that
                    // ignored appearance and was legible in dark by luck. This is
                    // the case that ruled out `@Environment(\.colorScheme)` for the
                    // palette — an AppKit overlay has no SwiftUI environment to
                    // read. `tertiaryLabelColor` rather than `separatorColor`: a
                    // markdown rule is content, and separator weight is a hairline.
                    // Swap if it reads heavy.
                    rule.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
                    tv.addSubview(rule)
                }
                pos = lineRange.location + lineRange.length
            }
        }

        // MARK: - Wikilink autocomplete detection

        private func checkForWikilink(in tv: NSTextView) {
            let cursorLoc = tv.selectedRange().location
            let ns = tv.string as NSString

            // Only check within the current line
            let lineRange = ns.lineRange(for: NSRange(location: cursorLoc, length: 0))
            let lineStart = lineRange.location
            guard cursorLoc > lineStart + 1 else {
                endWikilinkSession()
                return
            }

            // Scan backward from cursor on this line for [[
            let beforeCursor = ns.substring(with: NSRange(location: lineStart,
                                                          length: cursorLoc - lineStart))
            let bns = beforeCursor as NSString

            var scanIdx = bns.length - 2
            var found: (openLoc: Int, partial: String)? = nil
            while scanIdx >= 0 {
                if bns.character(at: scanIdx)     == 91 &&   // '['
                   bns.character(at: scanIdx + 1) == 91 {   // '['
                    let partial = bns.substring(from: scanIdx + 2)
                    if !partial.contains("]]") && !partial.contains("\n") {
                        found = (lineStart + scanIdx, partial)
                    }
                    break
                }
                scanIdx -= 1
            }

            if let ctx = found {
                wikilinkOpenLoc = ctx.openLoc
                onWikilinkQuery?(ctx.partial)
            } else {
                endWikilinkSession()
            }
        }

        private func endWikilinkSession() {
            guard wikilinkOpenLoc != nil else { return }
            wikilinkOpenLoc = nil
            onWikilinkQuery?(nil)
        }

        /// `[[` followed by a URL is not a wikilink and never becomes one.
        ///
        /// David: *"when i click the link in the editor, two brackets appear but
        /// it doesnt format the link like it does in IOS."* The note on disk read
        /// `[[https://www.zola.com/wedding/lahaieweiss/poi` — unclosed, under
        /// `## Reference`, with no `]]` anywhere on the line.
        ///
        /// That is `beginWikilink` working exactly as designed, meeting an input
        /// it was never designed for. The button opens a *session*: it writes
        /// `[[` and leaves the closing pair to `applyWikiSuggestion`, because
        /// Session 65 established that a wikilink is not finished until a name is
        /// chosen. Paste a URL and no name is ever chosen, so the `]]` never
        /// arrives and the `[[` sits there permanently.
        ///
        /// **The phone hides this rather than solving it.** Its button writes the
        /// finished `[[]]` up front, so a pasted URL lands as `[[https://…]]` —
        /// closed, painted blue, and a wikilink to a note that cannot exist. It
        /// looks right and does nothing when tapped.
        ///
        /// So neither platform's answer was actually a link. A URL wants
        /// markdown's own form, `[label](url)`, which `applyMarkdownLinks` already
        /// renders on both sides: label in link colour, brackets and URL hidden,
        /// genuinely clickable. The conversion fires the moment a scheme shows up
        /// after `[[`, leaves the caret in the empty label so the next thing typed
        /// is the link text, and closes the suggestion list.
        ///
        /// Keying on `://` is safe: no place, person or note title in this vault
        /// contains one, and a title that did could not be opened as a wikilink
        /// anyway.
        @discardableResult
        private func convertURLWikilink(in tv: NSTextView) -> Bool {
            guard let openLoc = wikilinkOpenLoc, let storage = tv.textStorage else { return false }
            let ns = tv.string as NSString
            let cursorLoc = tv.selectedRange().location
            guard cursorLoc > openLoc + 2, cursorLoc <= ns.length else { return false }
            let partial = ns.substring(with: NSRange(location: openLoc + 2,
                                                     length: cursorLoc - openLoc - 2))
            guard partial.contains("://") else { return false }

            let url = partial.trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return false }
            // A real label, not an empty one — `applyMarkdownLinks` needs at
            // least one character or the whole thing renders as raw markdown.
            let label = NoteStore.linkLabel(for: url)
            let replacement = "[\(label)](\(url))"
            storage.replaceCharacters(in: NSRange(location: openLoc, length: cursorLoc - openLoc),
                                      with: replacement)
            tv.didChangeText()
            // The label is SELECTED, not an empty caret: leave it and you have a
            // link that reads `zola.com`, type and you have replaced it.
            tv.setSelectedRange(NSRange(location: openLoc + 1,
                                        length: (label as NSString).length))
            text.wrappedValue = tv.string
            endWikilinkSession()
            return true
        }

        private func applyWikiSuggestion(_ name: String, in tv: NSTextView) {
            let cursorLoc = tv.selectedRange().location
            guard let openLoc = wikilinkOpenLoc, openLoc <= cursorLoc else { return }
            let replaceRange = NSRange(location: openLoc, length: cursorLoc - openLoc)
            let replacement  = "[[\(name)]]"
            tv.textStorage?.replaceCharacters(in: replaceRange, with: replacement)
            tv.didChangeText()
            let newLoc = openLoc + (replacement as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            text.wrappedValue = tv.string
            wikilinkOpenLoc = nil
            onWikilinkQuery?(nil)
        }

        // MARK: Smart keyboard — auto-list continuation and dash-to-bullet conversion

        func textView(_ tv: NSTextView,
                      shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString replacement: String?) -> Bool {
            guard let replacement else { return true }
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
            let line = ns.substring(with: lineRange)

            // ── Typing third "-" to complete "---" → create HR and move cursor below ──
            let lineWithoutNewline0 = line.hasSuffix("\n") ? String(line.dropLast()) : line
            if replacement == "-" && lineWithoutNewline0 == "--" {
                tv.textStorage?.replaceCharacters(in: affectedCharRange, with: "-\n")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: affectedCharRange.location + 2, length: 0))
                text.wrappedValue = tv.string
                return false
            }

            // ── Tab: indent line ──────────────────────────────────────────────────
            if replacement == "\t" {
                tv.textStorage?.replaceCharacters(in: lineRange, with: "  " + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: affectedCharRange.location + 2, length: 0))
                return false
            }

            // ── Space after lone "-" at line start → bullet ───────────────────────
            // Checks the character immediately before the cursor is "-" and everything
            // before it on the line is spaces. Handles both mid-doc and last-line cases.
            if replacement == " " && affectedCharRange.location > 0 {
                let dashPos = affectedCharRange.location - 1
                let charBefore = ns.character(at: dashPos)
                if charBefore == UInt16(UnicodeScalar("-").value) {
                    let lineStart = lineRange.location
                    if dashPos >= lineStart {
                        let prefix = ns.substring(with: NSRange(location: lineStart,
                                                                length: dashPos - lineStart))
                        if prefix.allSatisfy({ $0 == " " }) {
                            tv.textStorage?.replaceCharacters(
                                in: NSRange(location: dashPos, length: 1), with: "\u{2022}")
                            tv.didChangeText()
                            return true   // let the space insert normally
                        }
                    }
                }
            }

            // ── Return while wikilink session active → accept top suggestion ──────
            //
            // Only swallow the Return if something was actually accepted. A
            // session is open from the moment `[[` exists, including while the
            // query is still empty, and unconditionally returning false there
            // meant Return did nothing at all and said nothing — the same
            // silent-no-op shape as the visit date picker.
            if replacement == "\n" && wikilinkOpenLoc != nil {
                if onWikilinkAccept?() == true { return false }
            }

            // ── Return key: continue or exit list ─────────────────────────────────
            guard replacement == "\n" else { return true }

            // RETURN AT THE START OF A LINE PUSHES IT DOWN. It does not start a
            // new list item.
            //
            // David, 2026-08-03: *"I went to the beginning of the top row before
            // the checkbox and hit enter and it added an extra check box for
            // some reason rather than just moving it down a row."*
            //
            // All three continuations below test the LINE for a marker and never
            // asked where the caret is. With the caret at offset 0 of
            // `☐ Facetime…` the checkbox branch saw a non-empty checkbox line,
            // inserted `"\n☐ "` at the caret, and produced a stray `☐ ` on the
            // new empty line above. Bullets and dashes had the identical flaw.
            //
            // Continuation means "I finished this item, give me the next one",
            // which cannot be true when nothing on the line is behind the caret.
            // Mid-line and end-of-line behaviour is unchanged: splitting a list
            // item still carries the marker onto the second half, which is what
            // every markdown editor does.
            guard affectedCharRange.location > lineRange.location else { return true }

            let lineWithoutNewline = line.hasSuffix("\n") ? String(line.dropLast()) : line

            // Bullet continuation
            let bulletPrefix = "\u{2022} "
            if let bulletRange = lineWithoutNewline.range(of: bulletPrefix) {
                let indent = String(lineWithoutNewline[lineWithoutNewline.startIndex..<bulletRange.lowerBound])
                let afterBullet = lineWithoutNewline[bulletRange.upperBound...]
                if afterBullet.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Empty bullet — exit list
                    tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                } else {
                    // Continue bullet
                    let insert = "\n" + indent + bulletPrefix
                    tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                length: 0))
                }
                text.wrappedValue = tv.string
                return false
            }

            // Dash list continuation ("- item")
            if let dashRange = lineWithoutNewline.range(of: "- ") {
                let prefixSlice = lineWithoutNewline[lineWithoutNewline.startIndex..<dashRange.lowerBound]
                guard prefixSlice.allSatisfy({ $0 == " " }) else { return true }
                let indent = String(prefixSlice)
                let afterDash = lineWithoutNewline[dashRange.upperBound...]
                if afterDash.trimmingCharacters(in: .whitespaces).isEmpty {
                    tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                } else {
                    let insert = "\n" + indent + "- "
                    tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                length: 0))
                }
                text.wrappedValue = tv.string
                return false
            }

            // Checkbox continuation
            let checkPrefixes = ["☐ ", "☑ "]
            for prefix in checkPrefixes {
                if lineWithoutNewline.hasPrefix(prefix) {
                    let afterCheck = lineWithoutNewline.dropFirst(prefix.count)
                    if afterCheck.trimmingCharacters(in: .whitespaces).isEmpty {
                        tv.textStorage?.replaceCharacters(in: lineRange, with: "\n")
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    } else {
                        let insert = "\n☐ "
                        tv.textStorage?.replaceCharacters(in: affectedCharRange, with: insert)
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: affectedCharRange.location + (insert as NSString).length,
                                                    length: 0))
                    }
                    text.wrappedValue = tv.string
                    return false
                }
            }

            return true
        }

        // MARK: Command execution

        func execute(_ command: MacEditorCommand, in tv: NSTextView) {
            switch command {
            case .bold:      wrapSelection("**", in: tv)
            case .italic:    wrapSelection("*", in: tv)
            case .strike:    wrapSelection("~~", in: tv)
            case .highlight: wrapSelection("==", in: tv)
            case .link:      beginWikilink(in: tv)
            case .heading:   toggleLinePrefix("## ", in: tv)
            case .bullet:    toggleBullet(in: tv)
            case .checkbox:  toggleCheckbox(in: tv)
            case .indent:    indentLine(in: tv)
            case .outdent:   outdentLine(in: tv)
            case .date:      insertDate(in: tv)
            case .timestamp: insertTimestamp(in: tv)
            case .requestMove: requestMove(in: tv)
            case .undo:      tv.undoManager?.undo()
            case .redo:      tv.undoManager?.redo()
            case .applyWikiSuggestion(let name): applyWikiSuggestion(name, in: tv)
            case .insertText(let raw): insertText(raw, in: tv)
            }
        }

        /// Wraps the selection (or inserts an empty pair) in a symmetric marker.
        /// The asymmetric `closing:` parameter was removed in Session 65 when
        /// `.link` stopped being a caller — it had no other one, and a spare
        /// parameter is an invitation to build the bug `beginWikilink` fixed.
        private func wrapSelection(_ marker: String, in tv: NSTextView) {
            let close   = marker
            let range   = lastSelection
            guard let storage = tv.textStorage else { return }
            if range.length == 0 {
                let pair = marker + close
                storage.replaceCharacters(in: range, with: pair)
                tv.didChangeText()
                let newLoc = range.location + (marker as NSString).length
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else if let swiftRange = Range(range, in: storage.string) {
                let selected = String(storage.string[swiftRange])
                storage.replaceCharacters(in: range, with: marker + selected + close)
                tv.didChangeText()
            }
            text.wrappedValue = storage.string
        }

        /// The link button, Session 65.
        ///
        /// David: *"when i press the link button in the editor, i can start
        /// typing but after the first character it auto completes the link."*
        ///
        /// It was never autocomplete. The button used to insert the finished
        /// pair `[[]]` and drop the cursor in the middle, so the very first
        /// character typed produced `[[M]]` — five characters, which is exactly
        /// `applyWikilinks`' `m.range.length >= 5` threshold. The storage then
        /// did what it is supposed to do to a complete wikilink: hid `[[` and
        /// `]]` behind `hiddenFont` and painted the middle in link colour. One
        /// keystroke, and the link looked finished.
        ///
        /// The phone never had this because on the phone you type `[[`
        /// yourself and there is no closing pair until a suggestion is
        /// accepted, so the regex cannot match while you are still typing. So
        /// the button now opens a session rather than writing a link:
        /// `applyWikiSuggestion` supplies the `]]` when a name is chosen, which
        /// is the one moment the link genuinely is complete.
        ///
        /// A non-empty selection still wraps to a finished `[[name]]`, because
        /// there the name is already known and rendering it immediately is
        /// correct rather than premature.
        ///
        /// **Session 67 — the button now recognises a URL.** Two cases that used
        /// to produce a wikilink to a page that cannot exist:
        ///
        /// - the selection *is* a URL, which becomes `[](url)` with the caret in
        ///   the empty label;
        /// - the selection is text and the clipboard holds a URL, which becomes
        ///   `[selection](url)` — the paste-a-link-onto-words gesture every other
        ///   Mac editor has.
        ///
        /// Everything else is unchanged: known name wraps, empty selection opens a
        /// session.
        private func beginWikilink(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let range = lastSelection
            let clipboard = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if range.length > 0, let swiftRange = Range(range, in: storage.string) {
                let selected = String(storage.string[swiftRange])
                if selected.contains("://") {
                    let url   = selected.trimmingCharacters(in: .whitespaces)
                    let label = NoteStore.linkLabel(for: url)
                    let link  = "[\(label)](\(url))"
                    storage.replaceCharacters(in: range, with: link)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: range.location + 1,
                                                length: (label as NSString).length))
                    text.wrappedValue = storage.string
                    return
                }
                if clipboard.contains("://"), !clipboard.contains(" ") {
                    let link = "[\(selected)](\(clipboard))"
                    storage.replaceCharacters(in: range, with: link)
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: range.location + (link as NSString).length,
                                                length: 0))
                    text.wrappedValue = storage.string
                    return
                }
                storage.replaceCharacters(in: range, with: "[[" + selected + "]]")
                tv.didChangeText()
            } else {
                storage.replaceCharacters(in: range, with: "[[")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        /// Inserts text at the cursor, on its own line when it needs one.
        ///
        /// A `!![…]` marker is only recognised at the start of a line, so
        /// inserting one mid-sentence would write a marker that never renders
        /// and never says why. The trailing newline is not cosmetic either: a
        /// marker on the final line of the file has no line terminator, and
        /// that is the bug iOS spent two days on — see `refreshThumbnails`.
        private func insertText(_ raw: String, in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns = storage.string as NSString
            let loc = min(lastSelection.location, ns.length)
            let atLineStart = loc == 0 || ns.character(at: loc - 1) == 10   // newline
            let block = (atLineStart ? "" : "\n") + raw + "\n"
            storage.replaceCharacters(in: NSRange(location: loc, length: 0), with: block)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: loc + (block as NSString).length, length: 0))
            text.wrappedValue = storage.string
        }

        private func toggleLinePrefix(_ prefix: String, in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            if line.hasPrefix(prefix) {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(prefix.count)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - (prefix as NSString).length)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: prefix + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + (prefix as NSString).length,
                                            length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func toggleBullet(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            let bullet    = "\u{2022} "
            if line.hasPrefix(bullet) {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(2)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: bullet + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func toggleCheckbox(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            if line.hasPrefix("☑ ") {
                storage.replaceCharacters(in: lineRange, with: "☐ " + String(line.dropFirst(2)))
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location, length: 0))
            } else if line.hasPrefix("☐ ") {
                storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(2)))
                tv.didChangeText()
                let newLoc = max(lineRange.location, lastSelection.location - 2)
                tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            } else {
                storage.replaceCharacters(in: lineRange, with: "☐ " + line)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            }
            text.wrappedValue = storage.string
        }

        private func indentLine(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            storage.replaceCharacters(in: lineRange, with: "  " + line)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: lastSelection.location + 2, length: 0))
            text.wrappedValue = storage.string
        }

        private func outdentLine(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let ns        = storage.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: lastSelection.location, length: 0))
            let line      = ns.substring(with: lineRange)
            let toRemove  = line.hasPrefix("  ") ? 2 : (line.hasPrefix(" ") ? 1 : 0)
            guard toRemove > 0 else { return }
            storage.replaceCharacters(in: lineRange, with: String(line.dropFirst(toRemove)))
            tv.didChangeText()
            let newLoc = max(lineRange.location, lastSelection.location - toRemove)
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            text.wrappedValue = storage.string
        }

        private func insertDate(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "MMMM d, yyyy"
            let str   = fmt.string(from: Date()) + " "
            let range = lastSelection
            storage.replaceCharacters(in: range, with: str)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + (str as NSString).length, length: 0))
            text.wrappedValue = storage.string
        }

        private func insertTimestamp(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "h:mm a"
            let timeStr = fmt.string(from: Date())
            let insert  = "\n\n**\(timeStr)**\n\n"
            // Insert at end of document
            let endLoc = storage.length
            storage.replaceCharacters(in: NSRange(location: endLoc, length: 0), with: insert)
            tv.didChangeText()
            let newLoc = endLoc + (insert as NSString).length
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
            tv.scrollRangeToVisible(NSRange(location: newLoc, length: 0))
            text.wrappedValue = storage.string
        }

        private func requestMove(in tv: NSTextView) {
            let sel = lastSelection
            let fullText = tv.string
            if sel.length > 0, let r = Range(sel, in: fullText) {
                let selected  = String(fullText[r])
                let remaining = fullText.replacingCharacters(in: r, with: "")
                onMoveRequest?(selected, remaining)
            } else {
                onMoveRequest?(fullText, "")
            }
        }
    }
}

// MARK: - Shared markdown editor

struct TraceMacNoteEditor: View {
    let relativePath: String
    var showMoveButton: Bool = false
    var moveSourceDate: Date? = nil

    /// File text → what the editor shows. Session 64, for Endeavor notes,
    /// which carry frontmatter a day note does not. Without it the editor puts
    /// the YAML on screen and invites you to break it.
    var loadTransform: ((String) -> String)? = nil

    /// (edited text, the file **as it is on disk right now**) → new file text.
    ///
    /// The second argument is re-read at save time rather than captured at
    /// load, so a change made to the frontmatter elsewhere — the phone editing
    /// dates while this pane holds the body — survives. Same rule as `remind:`:
    /// a save must not rewrite a field it was not asked to change.
    var saveTransform: ((String, String) -> String)? = nil

    /// Fired after a debounced write lands, so an owner can refresh anything
    /// derived from the file. The Endeavor rail reads "which visits does the
    /// log name" straight out of the body, so it has to re-derive on save.
    var onSaved: (() -> Void)? = nil

    /// An externally-owned command channel, so an owner can reach the live
    /// editor — see `MacEditorActions.applyToBody`. Defaulted to nil, so the
    /// eleven call sites that have no such need are untouched and keep the
    /// private instance below.
    var externalActions: MacEditorActions? = nil

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var content        = ""
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var lastSaved: Date? = nil
    // @State keeps the same MacEditorActions instance across re-renders; makeNSView wires it once.
    @State private var ownActions  = MacEditorActions()
    private var editorActions: MacEditorActions { externalActions ?? ownActions }
    // Wikilink autocomplete state
    @State private var wikiQuery:       String? = nil
    @State private var wikiSuggestions: [String] = []
    /// Projects + Daily, per D49. Rebuilt when a wikilink session *opens* rather
    /// than per keystroke — `linkableNotes()` is two directory reads.
    @State private var linkableNotes:   [LinkableNote] = []
    private var noteTitleSet: Set<String> {
        Set(linkableNotes.map { $0.title.lowercased() })
    }
    // Move sheet state
    @State private var showMoveSheet   = false
    @State private var moveContent     = ""
    @State private var postMoveContent = ""

    var body: some View {
        VStack(spacing: 0) {
            MacTextEditor(text: $content, actions: editorActions,
                          onWikilinkQuery: { query in
                              // A session opening is the moment to re-read the note
                              // folders: often enough to catch a note made minutes
                              // ago, rare enough not to hit the disk per keystroke.
                              if wikiQuery == nil, query != nil {
                                  linkableNotes = noteStore.linkableNotes()
                              }
                              wikiQuery = query
                              // Read directly from NotionService at query time — avoids the
                              // load-once race where people/places aren't yet fetched.
                              if let q = query, !q.isEmpty {
                                  let people = notionService.people
                                      .filter { !$0.isArchived }
                                      .map(\.name)
                                  let places = notionService.places.map(\.name)
                                  // D49. Notes are a third source, not a replacement:
                                  // `[[Megan]]` should still offer the person.
                                  let notes  = linkableNotes.map { $0.title }
                                  var seen = Set<String>()
                                  wikiSuggestions = Array((people + places + notes)
                                      .filter { $0.localizedCaseInsensitiveContains(q) }
                                      .sorted()
                                      // The pill row is keyed `id: \.self`, so a note
                                      // titled the same as a person would collide and
                                      // SwiftUI would drop one silently.
                                      .filter { seen.insert($0.lowercased()).inserted }
                                      .prefix(8))
                              } else {
                                  wikiSuggestions = []
                              }
                          },
                          onWikilinkAccept: {
                              guard let first = wikiSuggestions.first else { return false }
                              editorActions.execute(.applyWikiSuggestion(first))
                              return true
                          },
                          onMoveRequest: showMoveButton ? { textToMove, remaining in
                              moveContent     = textToMove
                              postMoveContent = remaining
                              showMoveSheet   = true
                          } : nil,
                          onPasteImage: { data in storeImage(data) != nil },
                          noteTitles: noteTitleSet)
                .onChange(of: content) { _, newValue in
                    scheduleSave(content: newValue)
                }

            // Wikilink suggestion pills — shown only when cursor is inside [[...]]
            if !wikiSuggestions.isEmpty {
                Divider()
                wikiSuggestionBar
            }

            // Formatting toolbar
            Divider()
            formattingToolbar

            // Footer
            Divider()
            HStack {
                let wordCount = content.split(separator: " ").count
                Text("\(wordCount) words")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let saved = lastSaved {
                    Text("Saved \(saved.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .task(id: relativePath) {
            // Re-wired per note, not once: `externalActions` is owned by a view
            // that outlives any single note, so the closure has to close over
            // the right `relativePath` — otherwise switching endeavor and then
            // adding a visit writes into the endeavor you were reading before.
            editorActions.applyToBody = { transform in
                let updated = transform(content)
                guard updated != content else { return }
                content = updated
                scheduleSave(content: updated)
            }
            // Also here, not only when a `[[` session opens: the colour has to be
            // right for links already in the note the moment it appears, and
            // nobody types anything to open a note they are only reading.
            linkableNotes = noteStore.linkableNotes()
            await loadContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { note in
            guard saveTask == nil else { return }
            guard let changedPath = note.object as? String,
                  changedPath == relativePath else { return }
            Task { await loadContent() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteStorePlaceNoteDidChange)) { note in
            guard saveTask == nil else { return }
            if let placeName = note.object as? String,
               relativePath == "Notes/Places/\(placeName).md" {
                Task { await loadContent() }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Save") { saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            if showMoveButton {
                ToolbarItem {
                    Button {
                        editorActions.execute(.timestamp)
                    } label: {
                        Label("Timestamp", systemImage: "clock")
                    }
                    .help("Insert timestamp (HH:MM AM)")
                }
                ToolbarItem {
                    Button {
                        editorActions.execute(.requestMove)
                    } label: {
                        Label("Move", systemImage: "arrow.up.right.square")
                    }
                    .help("Move selection (or whole note) to another destination")
                }
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            if let date = moveSourceDate ?? parsedDate(from: relativePath) {
                MacDailyMoveSheet(
                    sourceDate: date,
                    sourceContent: moveContent,
                    onMoved: {
                        content = postMoveContent
                        scheduleSave(content: postMoveContent)
                        saveNow()
                    }
                )
                .environment(noteStore)
                .environment(notionService)
            }
        }
    }

    private func parsedDate(from path: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return fmt.date(from: base)
    }

    // MARK: - Wiki suggestion bar

    private var wikiSuggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(wikiSuggestions, id: \.self) { name in
                    Button {
                        editorActions.execute(.applyWikiSuggestion(name))
                    } label: {
                        Text(name)
                            .font(MacType.row)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.13))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Formatting toolbar

    private var formattingToolbar: some View {
        // Horizontal ScrollView (not a plain HStack) so this row's fixed content
        // (14 buttons + dividers, ~450pt minimum) never forces a minimum width on
        // the parent VStack/editor column — same pattern as wikiSuggestionBar above.
        // A plain HStack here was B9's second constraint: it survived the
        // MacTextEditor sizeThatFits fix because a VStack won't compress below a
        // child's intrinsic minimum width.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                fmtButton("bold",            .bold,      "Bold (**)")
                    .keyboardShortcut("b", modifiers: .command)
                fmtButton("italic",          .italic,    "Italic (*)")
                    .keyboardShortcut("i", modifiers: .command)
                fmtButton("strikethrough",   .strike,    "Strikethrough (~~)")
                fmtButton("highlighter",     .highlight, "Highlight (==)")

                toolbarDivider()

                fmtButton("number",          .heading,   "Heading (##)")
                fmtButton("list.bullet",     .bullet,    "Bullet (•)")
                fmtButton("checkmark.square",.checkbox,  "Checkbox (☐)")

                toolbarDivider()

                fmtButton("decrease.indent", .outdent,   "Outdent")
                fmtButton("increase.indent", .indent,    "Indent")

                toolbarDivider()

                fmtButton("link",            .link,      "Wikilink [[]]")
                fmtButton("calendar",        .date,      "Insert date")
                // The paperclip David asked for, and the reason it is here
                // rather than only on the Endeavor pane: inline photos did not
                // exist anywhere in TraceMac, including the Daily editor, which
                // is the note he writes every day. Built once, in the shared
                // editor, so all eleven call sites get it.
                fmtButton("paperclip",       nil,        "Insert a photo") { chooseImage() }

                toolbarDivider()

                fmtButton("arrow.uturn.backward", .undo, "Undo")
                    .keyboardShortcut("z", modifiers: .command)
                fmtButton("arrow.uturn.forward",  .redo, "Redo")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func fmtButton(_ icon: String,
                           _ command: MacEditorCommand?,
                           _ tip: String,
                           action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() }
            else if let command { editorActions.execute(command) }
        } label: {
            Image(systemName: icon)
                .font(MacGlyph.control)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(tip)
    }

    private func toolbarDivider() -> some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    private func loadContent() async {
        let raw = (try? noteStore.readFile(relativePath)) ?? ""
        content = loadTransform?(raw) ?? raw
    }

    private func scheduleSave(content: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
            saveTask = nil
        }
    }

    // MARK: - Photos

    /// Writes image bytes into the container and inserts a thumbnail marker.
    /// Returns the container-relative path, or nil if nothing was stored.
    ///
    /// **The storage rule is iOS's, spelled the same way**:
    /// `Photos/<year>/<month>/yyyy-MM-dd-HHmmss.jpg`, re-encoded. It is
    /// duplicated here rather than shared, and that is a debt rather than a
    /// decision — iOS has three inline copies of the same eight lines in
    /// `MarkdownEditorView`, so the right fix is one helper on `NoteStore` that
    /// all four adopt. Not done in this change because it edits the largest and
    /// most-used file on the phone in a session that has already shipped a lot
    /// uncompiled. Recorded so it is not rediscovered.
    ///
    /// `EndeavorFile.downscaledJPEG` does the re-encode. Its home is now wrong —
    /// it is ImageIO, not endeavor format — but a fourth copy of a
    /// `CGImageSource` dance would be worse than a misfiled function, and moving
    /// it is a job for whenever a third caller appears.
    @discardableResult
    private func storeImage(_ data: Data) -> String? {
        let jpeg = EndeavorFile.downscaledJPEG(data) ?? data
        let now = Date()
        let cal = Calendar.current
        let year  = cal.component(.year, from: now)
        let month = String(format: "%02d", cal.component(.month, from: now))
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "\(fmt.string(from: now)).jpg"
        guard let path = try? noteStore.writePhoto(jpeg,
                                                   category: "\(year)/\(month)",
                                                   filename: filename) else { return nil }
        // TWO bangs: the rendered-thumbnail form. One bang is the compact link
        // form — orange text, no picture — which is what iOS inserted until
        // 2026-07-30 and what produced *"there is no photo rendering"*.
        //
        // The description is the source filename, or the timestamp for a paste.
        // It is hidden by the renderer here, so it exists for the phone, for
        // Obsidian, and for anyone reading the raw file.
        editorActions.execute(.insertText("!![\(imageCaption(filename))](\(path))"))
        return path
    }

    private func imageCaption(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    /// The toolbar path. Secondary to ⌘V on a Mac, which is why the paste hook
    /// exists at all, but it is the one that works when the picture is a file
    /// you already have rather than something you just captured.
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Insert"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            storeImage(data)
        }
    }

    private func saveNow() {
        let out: String
        if let saveTransform {
            let onDisk = (try? noteStore.readFile(relativePath)) ?? ""
            out = saveTransform(content, onDisk)
        } else {
            out = content
        }
        try? noteStore.writeFile(relativePath, content: out)
        lastSaved = Date()
        onSaved?()
    }
}

// MARK: - MacTagChipRow

/// Horizontally scrolling `#tag` filter chips for note list views.
/// Shows only when `tags` is non-empty. Selected chips AND-filter the list.
struct MacTagChipRow: View {
    let tags: [String]
    @Binding var selected: Set<String>

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(tags, id: \.self) { tag in
                        let on = selected.contains(tag)
                        Button {
                            if on { selected.remove(tag) }
                            else  { selected.insert(tag) }
                        } label: {
                            Text("#\(tag)")
                                .font(on ? MacType.metaEmphasis : MacType.meta)
                                .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    on ? Color.accentColor : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }
}
