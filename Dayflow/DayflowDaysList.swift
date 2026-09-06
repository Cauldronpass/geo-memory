//
//  DayflowDaysList.swift
//  Dayflow
//
//  Session 89. The running list of days, on Today, behind a fourth word.
//
//  ── Where this came from ────────────────────────────────────────────────
//
//  David: *"what if instead we put Days on the top to the right of tomorrow
//  just like we have on mac."* It is his own Mac design, and copying it means
//  there is nothing to name and nothing to learn.
//
//  `MacDaysList` records the shape and the reason he chose it, after
//  rejecting a rail on Today: **the left column answers WHICH DAY, the right
//  column is THAT DAY'S NOTE, and DAYS is a fourth answer to the first
//  question.** Pressing it swaps the day column for this list and leaves the
//  note column exactly where it is.
//
//  The phone is that same layout stacked vertically. TO DO and THE DAY are
//  the top half, the day note is the bottom half.
//
//  **The first build filled the note card BELOW the list, and that was wrong**
//  in a way the mockup hid: on the Mac the two are side by side, so a pick
//  fills something already in front of you, while stacked vertically the note
//  sits under as many as a hundred and twenty rows. David tapped a day and
//  reported that nothing happened, and he was right from where he stood. The
//  mockup had been drawn with five rows, which flattered the design instead of
//  describing it.
//
//  **So the note opens under the row you tapped**, in place, the way the month
//  already unfolds under the date. The question and the answer stay together,
//  which is what the Mac's second column was doing all along. Tap again to
//  close it, tap another day to move.
//
//  It shows the note to READ. Editing is one more tap, on OPEN THIS DAY, which
//  hands the day to the full page editor that already exists — deliberately
//  not an editor nested inside a scrolling list, which is two scroll views
//  fighting over the same finger.
//
//  ── Grouped by week, and what that does NOT do here ─────────────────────
//
//  Weeks are the grouping on the Mac (D255) and they are the grouping here.
//  **A week rule on the Mac also OPENS that week's note; this one does not**,
//  and the week headings are deliberately drawn as headings rather than as
//  rows so that nothing on this screen looks like a door that is not one
//  (warning FIFTEEN).
//
//  The reason is worth stating rather than leaving as a gap: the phone's day
//  note card and the editor under it are date-shaped all the way down, from
//  the card's own `relativePath` to `NoteStore.readDailyNote(date:)`. A week
//  note is `Notes/Horizons/YYYY-Www.md`, which is not a date, so opening one
//  means teaching that whole stack to take a FILE instead of a DAY. That is a
//  change every screen sharing the editor would inherit, and it deserves its
//  own session rather than a ride-along in this one.
//
//  ── Pinned days ─────────────────────────────────────────────────────────
//
//  An accent dot on the row, in date order. The Records tab's version listed
//  pinned days a second time in a block at the top, which reads as a useful
//  shortcut in a Mac column and as a duplicate on a phone.
//

import SwiftUI
import UIKit

struct DayflowDaysList: View {

    /// Hands a day to the full page editor. The list keeps its scroll.
    var onOpen: (Date) -> Void

    @State private var entries: [Entry] = []
    @State private var weekEntries: [Entry] = []
    @State private var loaded = false
    /// Days or weeks. David's shape: *"we could use that row and add a
    /// 'weeks' at the far right that would change the entire screen to
    /// weeks."* It repeats the move one row up, where DAYS sits at the far
    /// right of the nav — same gesture, same place, one level down, so there
    /// is nothing new to learn.
    @State private var grain: Grain = .days

    enum Grain { case days, weeks }
    /// The row whose note is open underneath it. One at a time: two open
    /// notes in a list is a list you have to scroll to compare, which is the
    /// thing this is meant to save.
    @State private var expanded: Date? = nil

    private let cal = Calendar.current

    struct Entry: Identifiable {
        let date: Date
        let preview: String
        /// The note itself, for the in-place read. Loaded with the preview
        /// rather than on tap: the preview already costs a full read of every
        /// file, so keeping what was read is free and opening a day is
        /// instant. Bounded so one enormous day cannot sit in memory whole.
        let body: String
        let pinned: Bool
        var id: Date { date }
    }

    /// How far back the list reads.
    ///
    /// Every row costs a file read for its preview line, so this is a real
    /// cost rather than a cap for tidiness. The Records tab's version read 30
    /// and was a browse list inside a tab; this one IS the screen while it is
    /// up, so it reads further.
    private let limit = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            if !loaded {
                // Not an empty state. The listing and one read per row have
                // not finished, and a screen that says "no days" while it is
                // still counting is reporting an absence it cannot tell apart
                // from ignorance (warning TWELVE).
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.top, 30)
            } else if entries.isEmpty {
                Text("No day notes yet.")
                    .font(.dayflowSerif(15))
                    .foregroundStyle(Color.dayflowMuted)
                    .padding(.top, 24)
            } else if grain == .weeks {
                if weekEntries.isEmpty {
                    Text("No week notes yet. Your check-ins write them.")
                        .font(.dayflowSerif(15))
                        .foregroundStyle(Color.dayflowMuted)
                        .padding(.top, 24)
                } else {
                    ForEach(weekEntries) { entry in
                        row(entry, weekly: true)
                        if expanded.map({ cal.isDate($0, inSameDayAs: entry.date) }) ?? false {
                            // No OPEN door on a week. The check-in writer
                            // CREATES a week file from a template when one is
                            // missing, so an editor reached from here could
                            // mint an empty scaffold that syncs everywhere.
                            // Weeks are for reading until that is deliberate.
                            expansion(entry, openable: false)
                        }
                        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                    }
                }
            } else {
                ForEach(weeks, id: \.0) { key, days in
                    weekHeading(days)
                    ForEach(days) { entry in
                        row(entry)
                        if expanded.map({ cal.isDate($0, inSameDayAs: entry.date) }) ?? false {
                            expansion(entry)
                        }
                        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
    }

    // MARK: - Masthead

    /// **The list's own headline, not the day's.**
    ///
    /// The Mac does exactly this: pressing DAYS swaps the day masthead for one
    /// titled Days, with the counts in the kicker. Leaving Today's date
    /// headline above a list of dates gives the page a heading that describes
    /// neither half, and its tap then does something the reader cannot
    /// predict — which is how David found it.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.dayflowInk).frame(height: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(kicker)
                        .font(.system(size: 11, weight: .medium))
                        .tracking(2.2)
                        .foregroundStyle(Color.dayflowMuted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // The other grain, at the far right of its row.
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            grain = grain == .days ? .weeks : .days
                            expanded = nil
                        }
                    } label: {
                        Text(grain == .days ? "WEEKS" : "DAYS")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.6)
                            .foregroundStyle(Color.dayflowAccent)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text(grain == .days ? "Days" : "Weeks")
                    .font(.dayflowSerif(30, weight: .heavy))
                    .foregroundStyle(Color.dayflowInk)
            }
            .padding(.vertical, 9)
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
        }
    }

    /// How many notes, and how far back.
    ///
    /// **The week count came out** (2026-09-06). It was the Mac's kicker
    /// copied whole, and it counted week GROUPS — weeks you wrote something
    /// in — while reading as a duration. On David's build "24 days · 7 weeks ·
    /// since 19 July" happened to span 6.9 real weeks, so the two numbers
    /// agreed by coincidence and the line looked like a date range. The first
    /// time he skips three weeks it would say seven while spanning eleven.
    ///
    /// David: *"im curious why the row here says 24 days 7 weeks since 19
    /// july"*, which is the whole case against it. The week headings in the
    /// list directly below already show the weeks, and they show the gaps too,
    /// which a single number never could.
    private var kicker: String {
        guard loaded else { return "READING" }
        let source = grain == .days ? entries : weekEntries
        guard let oldest = source.last?.date else { return "NOTHING YET" }
        let n = source.count
        let f = DateFormatter()
        f.dateFormat = cal.isDate(oldest, equalTo: Date(), toGranularity: .year)
            ? "d MMMM" : "d MMMM yyyy"
        let unit = grain == .days
            ? (n == 1 ? "1 DAY" : "\(n) DAYS")
            : (n == 1 ? "1 WEEK" : "\(n) WEEKS")
        return unit + " \u{00B7} SINCE " + f.string(from: oldest).uppercased()
    }

    // MARK: - Weeks

    /// Newest week first, newest day first inside it. The key is the week's
    /// Monday, so grouping never re-derives a boundary twice.
    private var weeks: [(Date, [Entry])] {
        let groups = Dictionary(grouping: entries) { entry in weekStart(entry.date) }
        return groups.keys.sorted(by: >).map { key in
            (key, (groups[key] ?? []).sorted { $0.date > $1.date })
        }
    }

    /// **Through `NoteStore`, never computed here** (Session 89).
    ///
    /// This used to be a Gregorian calendar set to start on Monday, which
    /// agrees with a real ISO week all year and disagrees in early January.
    /// Harmless while it only drew headings; wrong the moment the Weeks view
    /// named a FILE, because the check-in writer names files by ISO week and
    /// the two would have diverged once a year, silently, into a second file
    /// for the same week.
    private func weekStart(_ date: Date) -> Date {
        NoteStore.weekStart(for: date)
    }

    private func weekHeading(_ days: [Entry]) -> some View {
        let start = weekStart(days.first?.date ?? Date())
        let f = DateFormatter()
        f.dateFormat = cal.isDate(start, equalTo: Date(), toGranularity: .year)
            ? "d MMMM" : "d MMMM yyyy"
        let thisWeek = cal.isDate(start, equalTo: Date(), toGranularity: .weekOfYear)
        return HStack(alignment: .firstTextBaseline) {
            Text(thisWeek ? "THIS WEEK" : "WEEK OF \(f.string(from: start).uppercased())")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(thisWeek ? Color.dayflowAccent : Color.dayflowFaint)
            Spacer()
            Text("\(days.count)")
                .font(.system(size: 10))
                .foregroundStyle(Color.dayflowFaint)
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dayflowInk).frame(height: 1)
        }
    }

    // MARK: - Rows

    private func row(_ entry: Entry, weekly: Bool = false) -> some View {
        let isToday = weekly
            ? cal.isDate(entry.date, equalTo: Date(), toGranularity: .weekOfYear)
            : cal.isDateInToday(entry.date)
        let isSelected = expanded.map { cal.isDate($0, inSameDayAs: entry.date) } ?? false
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.18)) {
                expanded = isSelected ? nil : entry.date
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if entry.pinned {
                        Circle()
                            .fill(Color.dayflowAccent)
                            .frame(width: 5, height: 5)
                    }
                    Text(weekly ? weekLabel(entry.date) : label(entry.date))
                        .font(.dayflowSerif(isToday ? 17 : 15.5,
                                            weight: isToday ? .bold : .semibold))
                        .foregroundStyle(Color.dayflowInk)
                    Spacer(minLength: 0)
                }
                if !entry.preview.isEmpty {
                    Text(entry.preview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.dayflowFaint)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, isSelected ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.dayflowAccent.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The note, under the row, to read.
    ///
    /// Capped in height with its own scroll rather than running the page long:
    /// a day you wrote a lot in should not push the next four days off the
    /// screen while you are browsing them.
    @ViewBuilder
    private func expansion(_ entry: Entry, openable: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Nothing written that day.")
                    .font(.dayflowSerif(14))
                    .foregroundStyle(Color.dayflowFaint)
            } else {
                ScrollView {
                    Text(entry.body)
                        .font(.dayflowSerif(14))
                        .foregroundStyle(Color.dayflowNoteText)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
                .scrollIndicators(.hidden)
            }
            if openable {
                Button {
                    onOpen(entry.date)
                } label: {
                    HStack(spacing: 6) {
                        Text("OPEN THIS DAY")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.5)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.dayflowAccent)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dayflowAccent.opacity(0.05))
        .transition(.opacity)
    }

    /// "This week", or the Monday it starts on.
    private func weekLabel(_ start: Date) -> String {
        if cal.isDate(start, equalTo: Date(), toGranularity: .weekOfYear) { return "This week" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(start, equalTo: Date(), toGranularity: .year)
            ? "'Week of' d MMMM" : "'Week of' d MMMM yyyy"
        return f.string(from: start)
    }

    private func label(_ date: Date) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        return f.string(from: date)
    }

    // MARK: - Data

    /// Same listing and same preview rule the Records tab's day list used —
    /// the first non-empty, non-heading line of the note.
    private func load() async {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let names = (try? NoteStore.shared.listFiles(in: "Calendar")) ?? []
        let dates = names.compactMap { name -> Date? in
            let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            return f.date(from: stem)
        }.sorted(by: >).prefix(limit)
        let built: [Entry] = dates.map { d in
            let raw = (try? NoteStore.shared.readDailyNote(date: d)) ?? ""
            let body = DayflowDailyNoteEditor.stripDateHeader(raw)
            let preview = body.split(separator: "\n").map(String.init)
                .first(where: { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return !t.isEmpty && !t.hasPrefix("#")
                })?.trimmingCharacters(in: .whitespaces) ?? ""
            return Entry(date: d,
                         preview: preview,
                         body: String(body.trimmingCharacters(in: .whitespacesAndNewlines)
                                          .prefix(4000)),
                         pinned: DayflowFlagStore.shared.isFlagged("Calendar/\(f.string(from: d)).md"))
        }
        entries = built

        // The weeks, from the files themselves rather than from the days.
        //
        // A week appears here only when its NOTE exists — the same rule the
        // days list follows, and the reason every row on this screen opens
        // something. Deriving weeks from the days instead would list weeks
        // with nothing behind them, which is a door to nothing.
        //
        // The Monday comes from `NoteStore.weekStart(fromStem:)`, so the
        // heading and the file can never disagree about which week this is.
        let weekNames = (try? NoteStore.shared.listFiles(in: "Notes/Horizons")) ?? []
        var weeksBuilt: [Entry] = []
        for name in weekNames {
            let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
            guard let start = NoteStore.weekStart(fromStem: stem) else { continue }
            let raw = (try? NoteStore.shared.readFile("Notes/Horizons/\(name)")) ?? ""
            let preview = raw.split(separator: "\n").map(String.init)
                .first(where: { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return !t.isEmpty && !t.hasPrefix("#") && t != "\u{2022}" && !t.hasPrefix("---")
                })?.trimmingCharacters(in: .whitespaces) ?? ""
            weeksBuilt.append(Entry(date: start,
                                    preview: preview,
                                    body: String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                                    .prefix(4000)),
                                    pinned: false))
        }
        weekEntries = weeksBuilt.sorted { $0.date > $1.date }

        loaded = true
    }
}
