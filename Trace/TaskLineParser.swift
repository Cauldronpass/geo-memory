// TaskLineParser.swift
// (Renamed from TaskDateParser.swift, Session 81 — the D198-queued rename: it
// parses the whole capture line, the trailing date, the `//` note split and
// the title clean-up, and the old name said only the first of the three.)
// "Ask Bryan about Q4 friday // check the Monarch numbers" -> a task called
// "Ask Bryan about Q4", due Friday, with a note.
// Shared: Trace (iOS), Dayflow, TraceMac. Pure Foundation, no UI.
//
// Session 80 (2026-08-31). David: "im wondering if there is a way to add
// natural language for dates. the keyboard shortcut for adding a task now has
// no option to move it to a date." Then, once that landed: "can we add a way
// for me to add a note to the task. I was thinking '//' at the end of the row
// would do it?"
//
// NAME: this now parses a whole capture line, not only its date. Renaming the
// file costs a pbxproj edit with Xcode closed, so it is in the backlog rather
// than done mid-session. See Trace-Backlog.md.
//
// ── The one rule: the date has to be at the END of the TASK ──────────────
//
// Todoist parses a date anywhere in the line, which is why typing
// "monday sync notes" into Todoist gives you a task called "sync notes". That
// is the failure mode of a parser that is too eager: it does not refuse, it
// quietly edits your words.
//
// Trailing-only inverts which way it fails. A day name in the middle of a
// sentence is just a word ("Read Friday's board pack" survives intact), and a
// date at the end is where you put it when you MEAN it as a date. The cost is
// that "friday deck review" does not parse, and that is the right cost: it
// fails by doing nothing rather than by eating a word.
//
// David chose this over the Todoist behaviour with the trade-off in front of
// him (Session 80).
//
// ── Where the note goes, and why not the other way round ─────────────────
//
// `//` splits the line; everything after it is the note, verbatim. The date is
// then read off the END OF THE HEAD, not the end of the line:
//
//     Ask Bryan about Q4 friday // check the Monarch numbers first
//     └──── title ─────┘ └date┘    └──────────── note ───────────┘
//
// The tempting alternative — let the date sit after the note too, since that is
// where the habit puts it — is parse-anywhere wearing a disguise. "call Bryan
// // he mentioned tuesday" would lose its "tuesday" to the due date, which is
// exactly the failure trailing-only exists to prevent. So the head owns the
// date, and the hint row shows the split so a wrong order is visible rather
// than silent.
//
// **The delimiter needs whitespace in front of it.** Without that guard,
// "read this https://foo.com/x" splits at the scheme and the task is called
// "read this https:". A URL always has a colon there, never a space, so one
// character of context separates the two cases completely.
//
// ── Why NSDataDetector and not a pile of regexes ─────────────────────────
//
// It is Apple's, it is localized, it already knows "next tuesday", "sep 15",
// "9/15", "in 3 days" and "tomorrow at 3pm", and — the part that actually
// matters here — it hands back the RANGE it matched. The strip is therefore
// exact rather than a second guess at what the first guess consumed. A
// hand-rolled parser has to solve the same problem twice and they drift.
//
// A small table sits in front of it for the words it fumbles or is slow about
// ("next week", "eow", "this weekend") and for the three words that will be
// 90% of real use (today, tomorrow, tonight), where deterministic beats clever.
//
// ── Two guards, both learned the hard way in other people's parsers ──────
//
// 1. A match made entirely of digits is refused. Otherwise "Review budget 2026"
//    becomes "Review budget" due January 2026, and "Order 3" becomes "Order".
//    A real date reference in a task line always carries a non-digit somewhere:
//    a slash, a month name, a weekday.
//
// 2. A match that would leave an empty title is refused. "tomorrow" on its own
//    is not a task, and a dateless task with no words is worse than no task.

import Foundation

// MARK: - Result

struct ParsedTaskLine {
    /// Exactly what was typed, trimmed.
    let original: String
    /// The part before the note delimiter, trimmed. This is what the title is
    /// cut from, and what the title returns to when a date is declined — the
    /// un-parse must not drag the note back into the title.
    let head: String
    /// What the task will be called.
    let title: String
    /// Day only, midnight. `nil` when nothing parsed.
    let date: Date?
    /// Set only when the phrase actually carried a time of day. "friday" is a
    /// due date; "friday at 3pm" is a due date and an alarm.
    let remindAt: Date?
    /// The date text that was consumed, for the preview and for the un-parse
    /// signature. `nil` when nothing parsed.
    let phrase: String?
    /// Everything after `//`, verbatim. Never date-parsed and never trimmed of
    /// anything but its outer whitespace: a note is the one part of the line
    /// where the words are the point.
    let note: String?

    var hasDate: Bool { date != nil }
    var hasNote: Bool { !(note ?? "").isEmpty }

    /// Identity of a parse, so a view can remember "the user turned THIS one
    /// off" without remembering a string that changes under it. Adding a
    /// trailing space leaves the signature alone (both halves are trimmed);
    /// editing a word changes it and re-arms the parse.
    ///
    /// The note is deliberately NOT in the signature. Declining a date and then
    /// adding a note should leave the date declined — the two are separate
    /// decisions and typing one should not undo the other.
    var signature: String { "\(title)|\(phrase ?? "")" }

    /// The same line with the date declined: the title becomes the whole head
    /// again, and the note is untouched.
    func withoutDate() -> ParsedTaskLine {
        ParsedTaskLine(original: original, head: head, title: head,
                       date: nil, remindAt: nil, phrase: nil, note: note)
    }

    /// Caps, for the hint row. "TODAY" / "TOMORROW" inside the week you can
    /// name, a weekday inside the week you can count, a date beyond it.
    var dateLabel: String? {
        guard let date else { return nil }
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(date) { day = "Today" }
        else if cal.isDateInTomorrow(date) { day = "Tomorrow" }
        else if cal.isDateInYesterday(date) { day = "Yesterday" }
        else {
            let ahead = cal.dateComponents([.day],
                                           from: cal.startOfDay(for: Date()),
                                           to: date).day ?? 0
            let f = DateFormatter()
            f.dateFormat = (ahead > 0 && ahead < 7) ? "EEEE" : "EEE d MMM"
            day = f.string(from: date)
        }
        guard let remindAt else { return day.uppercased() }
        let t = DateFormatter()
        t.dateFormat = "h:mm a"
        return "\(day) \(t.string(from: remindAt))".uppercased()
    }
}

// MARK: - Parser

enum TaskLineParser {

    /// What starts a note. Two slashes because one is a date separator ("9/15")
    /// and would collide immediately.
    static let noteDelimiter = "//"

    /// Built once. Constructing an `NSDataDetector` is the expensive part, and
    /// this is called on every keystroke of a capture field.
    private static let detector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Connector words that belong to the date, not the title. "Ask Bryan about
    /// Q4 BY friday" should not leave a dangling "by".
    private static let connectors: Set<String> = ["on", "by", "due", "for", "at", "@"]

    /// A date match, before it is assembled with the note into a result.
    private struct DateHit {
        let title: String
        let date: Date
        let remindAt: Date?
        let phrase: String
    }

    static func parse(_ raw: String, now: Date = Date()) -> ParsedTaskLine {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let (head, note) = splitNote(line)

        func result(_ hit: DateHit?) -> ParsedTaskLine {
            guard let hit else {
                return ParsedTaskLine(original: line, head: head, title: head,
                                      date: nil, remindAt: nil, phrase: nil, note: note)
            }
            return ParsedTaskLine(original: line, head: head, title: hit.title,
                                  date: hit.date, remindAt: hit.remindAt,
                                  phrase: hit.phrase, note: note)
        }

        guard !head.isEmpty else { return result(nil) }
        if let hit = tableMatch(head, now: now) { return result(hit) }
        if let hit = detectorMatch(head, now: now) { return result(hit) }
        return result(nil)
    }

    // MARK: The note split

    /// First `//` that has whitespace in front of it. Scanning rather than a
    /// plain `range(of:)` because the first occurrence in the line may well be
    /// inside a URL, and finding it is not the same as accepting it.
    private static func splitNote(_ line: String) -> (head: String, note: String?) {
        var from = line.startIndex
        while let found = line.range(of: noteDelimiter, range: from..<line.endIndex) {
            if found.lowerBound > line.startIndex,
               line[line.index(before: found.lowerBound)].isWhitespace {
                let head = String(line[line.startIndex..<found.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let note = String(line[found.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (head, note.isEmpty ? nil : note)
            }
            from = found.upperBound
        }
        return (line, nil)
    }

    // MARK: The table

    /// Phrases the detector misses, is inconsistent about, or that are common
    /// enough to deserve an answer that never moves.
    private static func tableMatch(_ head: String, now: Date) -> DateHit? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // Longest first, so "next week" is tested before anything that could
        // match "week" and "tomorrow" before a hypothetical "row".
        let table: [(String, Date?)] = [
            ("this weekend", thisWeekend(from: today, cal: cal)),
            ("next month",   cal.date(byAdding: .month, value: 1, to: today)),
            ("next week",    nextWeekday(2, from: today, cal: cal)),   // Monday
            ("tomorrow",     cal.date(byAdding: .day, value: 1, to: today)),
            ("tonight",      today),
            ("today",        today),
            ("tmrw",         cal.date(byAdding: .day, value: 1, to: today)),
            ("tmw",          cal.date(byAdding: .day, value: 1, to: today)),
            ("eow",          nextWeekday(6, from: today, cal: cal)),   // Friday
            ("eod",          today)
        ]

        for (word, resolved) in table {
            guard let resolved else { continue }
            // Strictly longer, not equal: a head that is ONLY a date word has
            // no title and is refused here rather than further down.
            guard head.count > word.count else { continue }
            let cut = head.index(head.endIndex, offsetBy: -word.count)
            // Indices from `head`, never from a lowercased copy: lowercasing is
            // not guaranteed to preserve length in Unicode, and a parser that is
            // right in English and wrong elsewhere is a bug waiting for a
            // holiday.
            guard head[cut...].lowercased() == word else { continue }
            let boundary = head.index(before: cut)
            guard head[boundary] == " " else { continue }
            guard let title = cleanTitle(String(head[head.startIndex..<boundary])) else { continue }
            return DateHit(title: title, date: resolved, remindAt: nil,
                           phrase: String(head[cut...]))
        }
        return nil
    }

    /// `weekday` is `Calendar`'s 1=Sunday numbering. Strictly future: "next
    /// week" said on a Monday means the Monday coming, not this morning.
    ///
    /// Arithmetic rather than `nextDate(after:matching:)`, which searches from
    /// an instant and will happily hand back today at one second past midnight
    /// when the weekday already matches.
    private static func nextWeekday(_ weekday: Int, from day: Date, cal: Calendar) -> Date? {
        let current = cal.component(.weekday, from: day)
        var delta = weekday - current
        if delta <= 0 { delta += 7 }
        return cal.date(byAdding: .day, value: delta, to: day)
    }

    /// "This weekend" is the exception to strictly-future: said ON a Saturday
    /// or Sunday it means the one you are standing in.
    private static func thisWeekend(from day: Date, cal: Calendar) -> Date? {
        let today = cal.component(.weekday, from: day)
        if today == 7 || today == 1 { return day }
        return nextWeekday(7, from: day, cal: cal)
    }

    // MARK: The detector

    private static func detectorMatch(_ head: String, now: Date) -> DateHit? {
        guard let detector else { return nil }
        let ns = head as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Only a match that runs to the end of the head, and when several do
        // (the detector will offer both "tuesday" and "next tuesday"), the one
        // that starts earliest — the longest reading of the phrase.
        var best: NSTextCheckingResult?
        detector.enumerateMatches(in: head, options: [], range: full) { m, _, _ in
            guard let m, m.range.location + m.range.length == ns.length else { return }
            if best == nil || m.range.location < best!.range.location { best = m }
        }
        guard let match = best, let when = match.date else { return nil }

        let phrase = ns.substring(with: match.range)

        // Guard 1: an all-digit match is a quantity, not a date.
        guard phrase.contains(where: { !$0.isNumber }) else { return nil }

        // A word boundary in front, so "Q4friday" is left alone.
        if match.range.location > 0 {
            let prev = ns.substring(with: NSRange(location: match.range.location - 1, length: 1))
            guard prev == " " else { return nil }
        }

        // Guard 2: something has to be left to call the task.
        guard let title = cleanTitle(ns.substring(to: match.range.location)) else { return nil }

        let cal = Calendar.current
        return DateHit(title: title,
                       date: cal.startOfDay(for: when),
                       remindAt: carriesTime(phrase) ? when : nil,
                       phrase: phrase)
    }

    /// The detector reports a `Date` either way, so "friday" arrives with some
    /// hour attached that nobody typed. The matched TEXT is the only honest
    /// witness to whether a time was meant, so that is what gets read.
    private static func carriesTime(_ phrase: String) -> Bool {
        let p = phrase.lowercased()
        if p.contains("noon") || p.contains("midnight") { return true }
        if p.range(of: #"\d\s*(am|pm)"#, options: .regularExpression) != nil { return true }
        if p.range(of: #"\d:\d"#, options: .regularExpression) != nil { return true }
        if p.range(of: #"\bat\s+\d"#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: Title

    /// Trailing connectors and punctuation come off with the date. Returns
    /// `nil` when nothing survives, which is how both guards refuse a parse.
    private static func cleanTitle(_ head: String) -> String? {
        var title = head.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            guard let last = title.split(separator: " ").last,
                  connectors.contains(String(last).lowercased()) else { break }
            title = String(title.dropLast(last.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,-–—:@"))
        return title.isEmpty ? nil : title
    }
}
