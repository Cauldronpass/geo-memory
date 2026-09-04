// MacDaysList.swift
// The running list of days, grouped by week, that replaces THE DAY column on
// Today when DAYS is pressed (D254, D255 — Session 83).
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// ── What this is ──────────────────────────────────────────────────────────
//
// The Notes screen's Daily tab and Today's DAY NOTE column edited the same
// `Calendar/<date>.md` with the same editor, in two rooms. The one thing
// Daily had that Today did not was this: the list of days, newest first, each
// carrying the first line of what you wrote. David's shape for it, after
// rejecting a rail on Today ("today (the concept) is now more than just a
// day... busy, which is the opposite of joy"): a fourth word on the day nav,
// DAYS, that swaps the day column for the list and leaves the note column
// exactly where it is. The left column answers *which day*; the right column
// is *that day's note*. Days is a fourth answer to the first question.
//
// Weeks are the grouping (D255). A week note (`Notes/Horizons/YYYY-Www.md`)
// is written by the phone's check-ins and read by scrolling back through
// time, which is the same motion as reading old days — so a week is an ink
// rule over its days, and clicking the rule puts the week note in the note
// column. The file as the phone wrote it, not a compilation: David chose that
// because the days beside it already say what he wrote, and "I kind of like A
// because it is not duplicative."
//
// ── What it deliberately does not do ──────────────────────────────────────
//
// It never creates a file. A day or week with no note shows an empty editor,
// and the editor writes the file when you type — the rule the Daily tab
// followed by accident (its `ensureFileExists` never worked, D249) and this
// screen follows on purpose. Every row is a day that HAS something: a note
// or a visit. Weeks are the weeks those days fall in.

import SwiftUI

// MARK: - The selection

/// What the list has picked: a day's note or a week's note. Both resolve to a
/// container-relative path the shared editor can open, and to the heading the
/// note column draws over it.
enum MacDaysPick: Equatable {
    /// `yyyy-MM-dd`.
    case day(String)
    /// ISO week, as the phone's check-in writer names the file.
    case week(year: Int, week: Int)

    var relativePath: String {
        switch self {
        case .day(let key):             return "Calendar/\(key).md"
        case .week(let year, let week): return "Notes/Horizons/" + String(format: "%d-W%02d.md", year, week)
        }
    }

    var heading: String {
        switch self {
        case .day(let key):
            guard let date = MacDaysList.dayFormatter.date(from: key) else { return "Day note" }
            return "Day note \u{00B7} " + date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week(_, let week):
            return "Week note \u{00B7} Week \(week)"
        }
    }
}

// MARK: - First-line scan

/// What one scan of a day note found on its first meaningful line. Moved here
/// from `TraceMacJournalView` (where it served the Daily tab) so the list that
/// outlives that tab owns the rule. Body unchanged.
///
/// One function and one scan rather than a `firstMeaningfulLine` and a
/// separate `overrideLine`, because the two would have to agree about what
/// "meaningful" means and that agreement is the thing that rots.
///
/// File scope, not nested in a view: a type nested inside a `@MainActor` type
/// inherits that isolation, and this is read from a `Task.detached`.
enum DayLine {
    case override(String)
    case prose(String)
    case none
}

enum MacDayScan {
    nonisolated static func firstMeaningfulLine(of body: String) -> DayLine {
        for raw in body.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // A `>` blockquote on the first meaningful line is the day's own
            // caption (D4) and outranks everything.
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
            if line.hasPrefix("~~") && line.hasSuffix("~~") { continue }

            for marker in ["☑ ", "☐ ", "- [x] ", "- [X] ", "- [ ] ", "- ", "• "] {
                if line.hasPrefix(marker) { line = String(line.dropFirst(marker.count)); break }
            }

            line = line.replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "~~", with: "")
                       .replacingOccurrences(of: "==", with: "")

            line = line.replacingOccurrences(
                of: #"\[\[([^\]|]+)\|([^\]]*)\]\]"#, with: "$2",
                options: .regularExpression)
            line = line.replacingOccurrences(
                of: #"\[\[([^\]]+)\]\]"#, with: "$1",
                options: .regularExpression)
            line = line.replacingOccurrences(
                of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                options: .regularExpression)

            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return .prose(line) }
        }
        return .none
    }
}

// MARK: - The list

struct MacDaysList: View {

    @Binding var pick: MacDaysPick?
    /// Double-click on a day: open it in full, meetings and all.
    let onOpenDay: (Date) -> Void

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    /// `yyyy-MM-dd` keys, newest first. Days with a note file, plus days with
    /// a visit and no file — "where you were" is the only cue those have.
    @State private var dayKeys: [String] = []
    @State private var previews:  [String: String] = [:]
    @State private var overrides: [String: String] = [:]
    /// For the indigo stripe. A second store instance rather than one hoisted
    /// into the environment, for the reason the Daily tab gave: it holds no
    /// mutable state anyone else observes, and a reload is one directory read.
    @State private var endeavorStore: TraceMacEndeavorStore? = nil
    @State private var search = ""

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// ISO weeks, Monday first, as `NoteStore.appendToWeeklyCheckInLog` names
    /// them. Not `Calendar.current`, which is Sunday-first in en_US and would
    /// put Sunday's note under the wrong week rule.
    private static let isoCal: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone.current
        return c
    }()

    // MARK: Derived

    private struct WeekGroup: Identifiable {
        let year: Int
        let week: Int
        let start: Date
        let end: Date
        let days: [String]
        var id: String { "\(year)-\(week)" }
    }

    private var visibleKeys: [String] {
        guard !search.isEmpty else { return dayKeys }
        return dayKeys.filter { key in
            key.localizedCaseInsensitiveContains(search)
                || (previews[key]?.localizedCaseInsensitiveContains(search) ?? false)
                || (overrides[key]?.localizedCaseInsensitiveContains(search) ?? false)
                || visitsLine(for: key).localizedCaseInsensitiveContains(search)
                || dayName(for: key).localizedCaseInsensitiveContains(search)
        }
    }

    private var weeks: [WeekGroup] {
        var order: [String] = []
        var bucket: [String: (year: Int, week: Int, start: Date, days: [String])] = [:]
        let cal = Self.isoCal
        for key in visibleKeys {
            guard let date = Self.dayFormatter.date(from: key) else { continue }
            let week = cal.component(.weekOfYear, from: date)
            let year = cal.component(.yearForWeekOfYear, from: date)
            let id = "\(year)-\(week)"
            if bucket[id] == nil {
                let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
                bucket[id] = (year, week, cal.startOfDay(for: start), [])
                order.append(id)
            }
            bucket[id]?.days.append(key)
        }
        return order.compactMap { id in
            guard let b = bucket[id] else { return nil }
            let end = cal.date(byAdding: .day, value: 6, to: b.start) ?? b.start
            return WeekGroup(year: b.year, week: b.week, start: b.start, end: end, days: b.days)
        }
    }

    private var kicker: String {
        let n = dayKeys.count
        guard n > 0, let oldest = dayKeys.last,
              let first = Self.dayFormatter.date(from: oldest) else { return "Nothing yet" }
        var parts: [String] = [n == 1 ? "1 day" : "\(n) days"]
        let w = weeks.count
        if search.isEmpty { parts.append(w == 1 ? "1 week" : "\(w) weeks") }
        parts.append("since " + first.formatted(.dateTime.day().month(.wide)))
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacEditorialMasthead(kicker: kicker, title: "Days")
                .padding(.horizontal, MacEditorialLayout.margin)
            searchLine
                .padding(.horizontal, MacEditorialLayout.margin)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(weeks) { group in
                        weekRule(group)
                        ForEach(group.days, id: \.self) { key in dayRow(key) }
                    }
                    if weeks.isEmpty {
                        Text(dayKeys.isEmpty ? "No days yet. Write something on Today." : "Nothing matches.")
                            .font(MacEditorialType.meta)
                            .foregroundStyle(MacEditorialColor.faint)
                            .padding(.top, 18)
                    }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, MacEditorialLayout.margin)
            }
        }
        .task {
            if endeavorStore == nil { endeavorStore = TraceMacEndeavorStore(noteStore: noteStore) }
            await endeavorStore?.reload()
            if notionService.visits.isEmpty { await notionService.fetchVisits() }
            await loadDays()
        }
        // A note edited in the column beside this list changes the row that
        // summarises it. The store names the file, so only that one re-reads.
        .onReceive(NotificationCenter.default.publisher(for: .noteStoreCalendarDidChange)) { note in
            guard let path = note.object as? String, path.hasPrefix("Calendar/") else { return }
            let key = String(path.dropFirst("Calendar/".count)).replacingOccurrences(of: ".md", with: "")
            if dayKeys.contains(key) {
                Task { await refreshPreview(for: key) }
            } else {
                Task { await loadDays() }
            }
        }
    }

    // MARK: Pieces

    private var searchLine: some View {
        TextField("Search what you wrote", text: $search)
            .textFieldStyle(.plain)
            .font(MacEditorialType.meta)
            .foregroundStyle(MacEditorialColor.ink)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { MacEditorialRule.hair }
    }

    /// An ink rule carrying the week's name and its span, at the weight of
    /// Today's section labels, so a week reads as a section and its days as
    /// rows. Accent when it is the selected note.
    private func weekRule(_ group: WeekGroup) -> some View {
        let picked: Bool = pick == .week(year: group.year, week: group.week)
        let tint: Color = picked ? MacEditorialColor.accent : MacEditorialColor.ink
        let wash: Color = picked ? MacEditorialColor.canvas : Color.clear
        return Button {
            pick = .week(year: group.year, week: group.week)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Week \(group.week)")
                        .editorialSectionLabel()
                        .foregroundStyle(tint)
                    Spacer(minLength: 8)
                    Text(spanText(group))
                        .font(MacEditorialType.meta)
                        .foregroundStyle(MacEditorialColor.faint)
                }
                .padding(.top, 20)
                .padding(.bottom, 6)
                Rectangle().fill(tint).frame(height: 1)
            }
            .padding(.horizontal, MacEditorialLayout.margin)
            .background(wash)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -MacEditorialLayout.margin)
        .help("Open the week note")
    }

    /// Weekday in serif with the date small beneath, then what you wrote —
    /// the same three sources the Daily tab had, keeping their marks: plain
    /// for the note's first line, green pin when there is only a visit, indigo
    /// ❯ for a `>` override, indigo stripe when an endeavor covers the day.
    private func dayRow(_ key: String) -> some View {
        let picked: Bool = pick == .day(key)
        let wash: Color = picked ? MacEditorialColor.canvas : Color.clear
        let covering: Endeavor? = endeavor(covering: key)
        let date: Date? = Self.dayFormatter.date(from: key)
        // Not a `Button`: a button eats the click, and the double-click that
        // opens the day in full has to be seen first. Two tap gestures,
        // two-count declared before one-count, which is how SwiftUI orders
        // them.
        return HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(covering == nil ? Color.clear : Color.indigo)
                .frame(width: 3, height: 26)
                .help(covering?.name ?? "")
            VStack(alignment: .leading, spacing: 1) {
                Text(dayName(for: key))
                    .font(MacEditorialType.rowTitle)
                    .foregroundStyle(MacEditorialColor.ink)
                    .lineLimit(1)
                if let date {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .editorialListLabel()
                }
            }
            .frame(width: 112, alignment: .leading)
            subtitle(for: key)
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .padding(.horizontal, MacEditorialLayout.margin)
        .background(wash)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let date { onOpenDay(date) } }
        .onTapGesture { pick = .day(key) }
        .padding(.horizontal, -MacEditorialLayout.margin)
        .overlay(alignment: .bottom) { MacEditorialRule.hair }
    }

    @ViewBuilder
    private func subtitle(for key: String) -> some View {
        if let line = overrides[key], !line.isEmpty {
            HStack(spacing: 4) {
                Text("\u{276F}").font(MacEditorialType.meta)
                Text(line).font(MacEditorialType.meta).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(Color.indigo)
        } else if let line = previews[key], !line.isEmpty {
            Text(line)
                .font(MacEditorialType.meta)
                .foregroundStyle(MacEditorialColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            let visits: String = visitsLine(for: key)
            if visits.isEmpty {
                Text("Nothing written")
                    .font(MacEditorialType.meta)
                    .foregroundStyle(MacEditorialColor.faint)
                    .italic()
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "mappin").font(MacEditorialType.meta)
                    Text(visits).font(MacEditorialType.meta).lineLimit(1).truncationMode(.tail)
                }
                // Green because the line comes from Places, dimmed because it
                // is a caption, not a heading — the Daily tab's reasoning.
                .foregroundStyle(Color.green.opacity(0.85))
            }
        }
    }

    // MARK: Text

    private func dayName(for key: String) -> String {
        guard let date = Self.dayFormatter.date(from: key) else { return key }
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDateInTomorrow(date)  { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    /// "31 Aug to 6 Sep", or "24 to 30 Aug" inside one month.
    private func spanText(_ g: WeekGroup) -> String {
        let cal = Calendar.current
        let sameMonth = cal.component(.month, from: g.start) == cal.component(.month, from: g.end)
        let d = DateFormatter(); d.dateFormat = "d"
        let dm = DateFormatter(); dm.dateFormat = "d MMM"
        return sameMonth
            ? "\(d.string(from: g.start)) to \(dm.string(from: g.end))"
            : "\(dm.string(from: g.start)) to \(dm.string(from: g.end))"
    }

    private func visitsLine(for key: String) -> String {
        guard let date = Self.dayFormatter.date(from: key) else { return "" }
        let cal = Calendar.current
        let names = notionService.visits
            .filter { cal.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.date < $1.date }
            .map { TripLog.shortPlaceName($0.placeName) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.joined(separator: " \u{00B7} ")
    }

    private func endeavor(covering key: String) -> Endeavor? {
        guard let store = endeavorStore, let date = Self.dayFormatter.date(from: key) else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        return store.endeavors.first { e in
            guard let starts = e.starts else { return false }
            return day >= cal.startOfDay(for: starts)
                && day <= cal.startOfDay(for: e.ends ?? starts)
        }
    }

    // MARK: Loading

    /// Days with a note file, plus days with a visit. Newest first. Picks
    /// today's row (or the newest) if nothing is picked yet.
    private func loadDays() async {
        let files = (try? noteStore.listFiles(in: "Calendar")) ?? []
        var keys = Set(files
            .filter { $0.hasSuffix(".md") }
            .map { $0.replacingOccurrences(of: ".md", with: "") }
            .filter { Self.dayFormatter.date(from: $0) != nil })
        for visit in notionService.visits {
            keys.insert(Self.dayFormatter.string(from: visit.date))
        }
        let sorted = keys.sorted(by: >)
        await MainActor.run {
            dayKeys = sorted
            if pick == nil {
                let today = Self.dayFormatter.string(from: Date())
                pick = .day(sorted.contains(today) ? today : (sorted.first ?? today))
            }
        }
        await loadPreviews(for: sorted)
    }

    private func loadPreviews(for keys: [String]) async {
        let built: (prose: [String: String], override: [String: String]) =
        await Task.detached(priority: .utility) {
            let store = NoteStore.shared
            var prose: [String: String] = [:]
            var over:  [String: String] = [:]
            for key in keys {
                // `readFile` returns "" for a missing file rather than throwing
                // (D249) — which is exactly right here: a visit-only day scans
                // as empty and falls through to its places.
                guard let body = try? store.readFile("Calendar/\(key).md") else { continue }
                switch MacDayScan.firstMeaningfulLine(of: body) {
                case .override(let t): over[key]  = t
                case .prose(let t):    prose[key] = t
                case .none:            break
                }
            }
            return (prose, over)
        }.value
        await MainActor.run {
            previews  = built.prose
            overrides = built.override
        }
    }

    private func refreshPreview(for key: String) async {
        let line: DayLine = await Task.detached(priority: .utility) {
            guard let body = try? NoteStore.shared.readFile("Calendar/\(key).md") else { return .none }
            return MacDayScan.firstMeaningfulLine(of: body)
        }.value
        await MainActor.run {
            previews.removeValue(forKey: key)
            overrides.removeValue(forKey: key)
            switch line {
            case .override(let t): overrides[key] = t
            case .prose(let t):    previews[key]  = t
            case .none:            break
            }
        }
    }
}
