// TripLog.swift
// Trace
//
// The trip-log composition, lifted out of `Dayflow/DayflowEndeavor.swift` in
// Session 65 and otherwise unchanged. Shared by Dayflow and TraceMac.
//
// WHY IT MOVED. David asked for the Mac to be able to put a visit into an
// endeavor's log. The rail already computes the answer — a tick where the log
// names a place, a hollow marker where it does not — and only the insert was
// missing. Writing that insert on the Mac meant one of two things: a second
// implementation of the day heading, the wikilink form, the name-shortening
// rule and the two-blank-line block boundary, or this move.
//
// **A second implementation was not an option, and the evidence was already in
// the tree.** `shortPlaceName` existed three times before this file — here,
// in `TraceMacEndeavorsView` and in `TraceMacDailyView` — and the Mac copies
// carried a comment saying so. They were also **not the same rule**: this one
// looks backwards for `" ("`, the Mac ones for the last `"("`. On a name
// written `Nick's(formerly Popeye's)` they disagree, and the consequence is not
// cosmetic: `logNames` decides whether the tick appears by searching the note
// body for the shortened name, so a Mac that shortens differently from the
// phone that wrote the line shows a hollow marker for a visit already in the
// log, and offers to add it twice.
//
// That is the twin-parser failure this codebase has now hit three times — the
// `remind:` sidecar key, the two `Endeavor` parsers whose own comment admitted
// they *"must stay in step"*, and this. Same fix each time: one definition,
// read from both sides.
//
// WHAT DID NOT MOVE. The day-note scanning half — `dayNoteCandidates`,
// `candidateText`, the model call and its review sheet — stays in
// `DayflowEndeavor.swift` as an `extension TripLog`. It is a Dayflow feature
// with a Dayflow surface, and moving it would drag the AI path into a file two
// other targets compile for no gain. `TripLogDayNote` itself moved because
// `TripLogDay` holds an array of them.
//
// ── TARGET MEMBERSHIP IS NOT INHERITED ────────────────────────────────────
//
// A new file in `TraceMac/` compiles into TraceMac because that is a buildable
// folder. **`Trace/` is not.** Session 64 learned this by breaking the Dayflow
// build with 34 `Cannot find type 'Endeavor' in scope` errors after dropping
// `Trace/Endeavor.swift` in and assuming otherwise. Membership on files in
// `Trace/` is set per file, in the File Inspector.
//
// So this file needs **Dayflow** and **TraceMac** ticked by hand, exactly as
// `Trace/Endeavor.swift` did. Until that is done, both builds fail on every
// `TripLog` reference.

import Foundation

// MARK: - Trip log
//
// **"Show me what it finds, then write it."** David's call, 2026-07-31, over the
// alternative of writing everything found. The one trip where half of it was
// work is the case that justifies the extra screen.
//
// **This writes into the note; it is NOT a section on the Endeavor screen.**
// Scope §9 says the Endeavor screen is a filtered library and not a trip
// dashboard, because trip content on a home screen is what made Trace's Home
// unusable. A generated list in the note is content the user owns — editable,
// deletable, something to write around. A panel is furniture that is there
// whether it is wanted or not. The distinction is the whole reason this is a
// button rather than a view.
//
// **A skeleton, not a dump.** The hard part of a write-up is the blank page, not
// the facts, so this produces a heading per day with the places and people under
// it and room to write. The thing worth having a year later is prose, not a log.

/// One day of a trip, and what the app knows happened.
struct TripLogDay: Identifiable {
    let date: Date
    var entries: [TripLogEntry]
    /// Lines lifted out of that day's daily note. Filled in AFTER the sheet is
    /// already on screen — `gather` is local and instant, this is not, and the
    /// button must not get slower. See `EndeavorTripLogSheet.scanDayNotes`.
    var dayNotes: [TripLogDayNote] = []
    var id: TimeInterval { date.timeIntervalSince1970 }

    /// The day-note lines still ticked, as one block for the note.
    ///
    /// Titled the way a visit is, because on the page it is the same kind of
    /// thing: a name with lines under it. Untitled it would run straight into the
    /// first visit, which is the exact complaint that produced titles at all.
    var dayNoteBlock: String? {
        let kept = dayNotes.filter(\.include).map(\.text)
        guard !kept.isEmpty else { return nil }
        return "**Day note**\n" + kept.joined(separator: "\n")
    }
}

/// A name as it is written and as it is read.
///
/// The note holds the FULL Notion name, because that is the string
/// `resolveWikiLink` matches on — shorten what is inside the brackets and the
/// link stops resolving, silently, in a file that still looks right. The reader
/// sees `short`. Identical strings collapse back to a plain `[[name]]` rather
/// than a pointless `[[Inspired|Inspired]]`.
struct TripLogName {
    let full: String
    let short: String

    var wikilink: String {
        full == short ? "[[\(full)]]" : "[[\(full)|\(short)]]"
    }
}

struct TripLogEntry: Identifiable {
    let id: String
    let place: TripLogName
    let people: [TripLogName]
    /// What David wrote on the visit itself, already run through
    /// `TripLog.sanitizedNote`. Nil when the visit has no note.
    let note: String?
    /// Ticked in the review sheet. Everything arrives ticked; the sheet is for
    /// taking things OUT, which is the common case.
    var include: Bool = true

    /// Plain words, for the review sheet. That sheet is a list of Toggles with no
    /// markdown renderer behind it, so it must never be handed `markdownBlock` —
    /// it would show the brackets and the asterisks. It shows the SHORT names on purpose: the
    /// preview should read the way the note is about to read.
    var displayLine: String {
        people.isEmpty ? place.short
                       : "\(place.short) · with \(people.map(\.short).joined(separator: ", "))"
    }

    /// The note flattened to one line with its markers stripped, for that same
    /// renderer-less sheet.
    var notePreview: String? {
        guard let note else { return nil }
        return TripLog.plainPreview(note)
    }

    /// The visit's title line: the place, bold, still a wikilink.
    ///
    /// **Bold and not a heading.** This editor's styler knows `# `, `## ` and
    /// `### ` and nothing below that (`styleHeading`, three `hasPrefix` checks),
    /// and `### ` is already the day. A fourth level would have to land at about
    /// 16pt semibold to sit under a 17pt day — which is what bold already renders
    /// as. Adding a heading level to a storage class four targets compile, to end
    /// up looking the same, was not worth it. Checked before choosing, 2026-08-01.
    ///
    /// It reads distinctly from a demoted heading inside a note (also bold)
    /// because this one is bold AND link-coloured, and that one is bold and black.
    var markdownTitle: String { "**\(place.wikilink)**" }

    /// Who was there, on its own line under the title. Nil for a solo visit —
    /// a bare "with" line would be worse than no line.
    var markdownPeopleLine: String? {
        people.isEmpty
            ? nil
            : "with " + people.map(\.wikilink).joined(separator: ", ")
    }

    /// One whole visit: title, companions, then David's own words.
    ///
    /// David chose this shape over the one-line form, 2026-08-01: *"id is difficult
    /// to see the distinction between each event (they all blend into one another).
    /// Is there a way to introduce some sort of title or indication of each event in
    /// the note and then a few blank rows maybe between them? I may want to add
    /// additional words later."*
    ///
    /// The blank line before the note is what makes the gap exist even when there is
    /// NO note — which is the case that matters, because that is the visit he has
    /// not written up yet and the one the empty space is an invitation for.
    var markdownBlock: String {
        var out = markdownTitle
        if let peopleLine = markdownPeopleLine { out += "\n" + peopleLine }
        if let note, !note.isEmpty { out += "\n\n" + note }
        return out
    }
}

enum TripLog {

    private static var dayHeadingFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM"
        return f
    }

    /// The heading written for a day. Also the dedupe key — see `append`.
    static func heading(for date: Date) -> String {
        "### \(dayHeadingFormatter.string(from: date))"
    }

    // MARK: Shortening
    //
    // David, 2026-08-01: *"Yes build the shortening rule. I think it's worth it to
    // make the notes look nicer."*
    //
    // Both rules only ever DROP text that is already in the name. Neither invents a
    // nickname, expands an initial, or consults an abbreviation list, so the worst
    // case for an unusual name is a line that reads exactly as it did before. That
    // is the whole reason they are safe to run unattended on every visit.

    /// Drops one trailing parenthetical: "Nick's on the Lake (formerly known as
    /// Popeye's)" becomes "Nick's on the Lake". A name that is entirely a
    /// parenthetical keeps all of it — there would be nothing left otherwise.
    static func shortPlaceName(_ name: String) -> String {
        guard name.hasSuffix(")"),
              let open = name.range(of: " (", options: .backwards) else { return name }
        let head = String(name[..<open.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? name : head
    }

    /// Markdown stripped down to the words, for anywhere with no renderer behind
    /// it — which in this feature means the review sheet, a plain list of Toggles.
    ///
    /// David, 2026-08-01, on seeing `[[Nick's on the Lake (formerly known as
    /// Popeye's)]]` filling three lines of a checkbox row: *"that Nick's choice
    /// has marked down, which seems strange."*
    ///
    /// **Only the DISPLAY is stripped. The line written to the note keeps its
    /// wikilink**, which is the whole point — he typed that link in his daily note
    /// and it should still be a link when it lands in the Endeavor note.
    static func plainPreview(_ text: String) -> String {
        var out = text
        if let rx = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]*))?\]\]"#) {
            let ns = out as NSString
            var result = ""
            var cursor = 0
            for m in rx.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: cursor,
                                                     length: m.range.location - cursor))
                let alias = m.numberOfRanges >= 3 ? m.range(at: 2) : NSRange(location: NSNotFound, length: 0)
                let shown = (alias.location != NSNotFound && alias.length > 0) ? alias : m.range(at: 1)
                result += ns.substring(with: shown)
                cursor = m.range.location + m.range.length
            }
            result += ns.substring(from: cursor)
            out = result
        }
        return out
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Everything before the first space.
    static func firstName(_ name: String) -> String {
        let head = name.split(separator: " ").first.map(String.init) ?? name
        return head.isEmpty ? name : head
    }

    // MARK: The visit's own note
    //
    // David, 2026-08-01, asked about summarising these. Answered by looking at the
    // last thirty: the MEDIAN visit note is 60 characters. "ATM 100." "Pick up."
    // "Two pizzas." A summary would run longer than the note for most of them. And
    // every note over 400 characters is already a summary — the pool and
    // Orangetheory flows wrote them — so summarising those is a copy of a copy that
    // drops exactly the detail they were kept for. His words go in verbatim.
    //
    // Which also means no network call, no spinner, no hallucination in a permanent
    // note, and no silent failure. Every AI call site in this codebase swallows its
    // errors, so an AI step here would have looked like the button doing nothing.

    /// A visit's note, made safe to sit under a day heading.
    ///
    /// Two things happen, and nothing else is touched:
    ///
    /// 1. **Heading lines are demoted to bold.** A `#` inside a note outranks the
    ///    day's own `###` and pulls the log apart around it. The text survives; only
    ///    its rank changes.
    /// 2. **Blank lines are removed**, so the note is one contiguous run. That is
    ///    what keeps the two-blank-line gap between visits reading as a boundary
    ///    rather than as one more paragraph break. The cost is that a genuinely
    ///    multi-paragraph note reads as adjacent lines — acceptable, since the long
    ///    notes in practice are a title plus one paragraph.
    ///
    /// Nothing is deleted and nothing is rewritten. Returns nil rather than an empty
    /// string so callers cannot accidentally write a bare newline.
    static func sanitizedNote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var lines: [String] = []
        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n")
                          .components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // `\s+|$` and not just `\s+`, so a bare "##" with nothing after it is
            // recognised and dropped rather than passed through as a literal.
            // Requiring the space is also what keeps a "#pool" HASHTAG a hashtag.
            guard let hash = trimmed.range(of: #"^#{1,6}(\s+|$)"#, options: .regularExpression) else {
                lines.append(trimmed)
                continue
            }
            let text = String(trimmed[hash.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            // A heading line with nothing after it carries no text to keep.
            if !text.isEmpty { lines.append("**\(text)**") }
        }
        let out = lines.joined(separator: "\n")
        return out.isEmpty ? nil : out
    }

    /// Everything the app knows happened inside the endeavor's range.
    ///
    /// Visits are the single source on purpose: a visit already carries the
    /// date, the place and the people, so one list answers all three of the
    /// things David asked for without a second unbounded fetch.
    static func gather(for endeavor: Endeavor,
                       visits: [Visit],
                       people: [Person]) -> [TripLogDay] {
        guard let starts = endeavor.starts, let ends = endeavor.ends else { return [] }
        let cal = Calendar.current
        let first = cal.startOfDay(for: starts)
        let last  = cal.startOfDay(for: ends)

        let inRange = visits.filter {
            let day = cal.startOfDay(for: $0.date)
            return day >= first && day <= last
        }

        let grouped = Dictionary(grouping: inRange) { cal.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            let dayVisits = grouped[day, default: []].sorted { $0.date < $1.date }

            // FIRST NAMES ARE DECIDED PER DAY — not per line, and not per trip.
            //
            // A day is what the reader takes in at once: one heading with its lines
            // under it. That is the only scope in which "Karla" can actually be
            // ambiguous. Deciding per line would shorten one Karla and not the other
            // on the very page where both appear; deciding per trip would demote
            // every day of a fortnight to full names because two people collided on
            // a Tuesday.
            let namesToday = Set(dayVisits.flatMap(\.peopleIDs).compactMap { id in
                people.first { $0.id == id }?.name
            })
            var firstNameUses: [String: Int] = [:]
            for name in namesToday { firstNameUses[firstName(name), default: 0] += 1 }

            let entries = dayVisits.map { visit in
                TripLogEntry(
                    id: visit.id,
                    place: TripLogName(full: visit.placeName,
                                       short: shortPlaceName(visit.placeName)),
                    people: visit.peopleIDs
                        .compactMap { id in people.first { $0.id == id }?.name }
                        .map { name in
                            // A shared first name that day: EVERYONE holding it keeps
                            // their full name, including whoever is unambiguous on
                            // this particular line. Shortening only one of them reads
                            // as if the app knows which Karla you meant.
                            let head = firstName(name)
                            return TripLogName(
                                full: name,
                                short: firstNameUses[head, default: 0] > 1 ? name : head
                            )
                        },
                    note: sanitizedNote(visit.notes)
                )
            }
            return TripLogDay(date: day, entries: entries)
        }
    }

    /// Appends the ticked days to `body`, skipping any day already written.
    ///
    /// **Additive, never destructive.** The obvious design was a marked section
    /// rewritten on every run, which is how `DayflowRelatedNotesEngine` handles a
    /// generated block — and it is wrong here, because the entire point is that
    /// the user writes *underneath* these headings. Rewriting would eat the
    /// write-up the feature exists to start.
    ///
    /// So: a day already present in the note is left completely alone, headings
    /// and prose and all. Run it again after another visit and only the new day
    /// arrives.
    ///
    /// One consequence of that, worth knowing rather than fixing: days written
    /// before wikilinks existed (2026-08-01) stay plain text forever. Nothing goes
    /// back over them, by design — a pass that rewrote old lines would be exactly
    /// the destructive behaviour this method exists to avoid.
    static func append(_ days: [TripLogDay], to body: String) -> String {
        var blocks: [String] = []

        for day in days {
            let head = heading(for: day.date)
            let entries = day.entries.filter(\.include)
            let dayNoteBlock = day.dayNoteBlock
            // A day can now earn its heading with day-note lines alone: a travel
            // day with no check-in anywhere still happened.
            guard !entries.isEmpty || dayNoteBlock != nil else { continue }
            // Already written about. Leave it entirely untouched.
            guard !body.contains(head) else { continue }

            blocks.append(head)
            if let dayNoteBlock { blocks.append(dayNoteBlock) }
            blocks.append(contentsOf: entries.map(\.markdownBlock))
        }

        // NOTHING TO ADD MEANS NOTHING CHANGES. Returns `body` byte for byte
        // rather than the trimmed copy the old version returned — a run that
        // finds no new days should not be able to edit the file at all.
        guard !blocks.isEmpty else { return body }

        // TWO BLANK LINES BETWEEN BLOCKS, and a block is a whole visit: title,
        // companions, note. That single rule is what gives every visit its own
        // room to write in. Before notes existed the gap was per DAY, which was
        // fine when a day was three bare lines and is not fine now that a visit
        // is a titled section.
        //
        // Two rather than one because ONE is already used inside a block, between
        // the companions line and the note. The gap between visits has to be
        // bigger than the gap inside a visit or the structure does not read —
        // which is the whole thing David reported.
        //
        // It stays unambiguous because `sanitizedNote` strips blank lines out of
        // the note itself, so a note is one contiguous run. Change that and the
        // two-blank boundary stops being a boundary.
        let addition = blocks.joined(separator: "\n\n\n")
        let existing = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? addition + "\n"
                                : existing + "\n\n" + addition + "\n"
    }

    // MARK: One visit at a time
    //
    // Session 65. `append` is the phone's verb: review a whole trip in a sheet,
    // then write the days that are not there yet. The Mac's is different, and it
    // is different because of what the rail can show that three phone screens
    // cannot — every visit in range next to the log, marked for whether the log
    // already names it. The gesture that follows from that picture is "this one
    // too", one visit, into a day that is usually already written.
    //
    // Which `append` cannot do: it skips any day whose heading is already in the
    // body, and for the Mac that is the normal case rather than the exception.

    /// Inserts one visit's block into the log, into its own day.
    ///
    /// Two cases, and the first one deliberately delegates rather than
    /// duplicating: when the day has no heading yet, this is exactly `append`
    /// with a one-entry day, so it calls it. That keeps the first visit of a day
    /// formatted by the same code that formats a whole trip, and there is no
    /// second place for the heading format or the leading blank lines to drift.
    ///
    /// When the heading exists, the block goes at the **end of that day's
    /// section**, before the next `### ` heading or the end of the note.
    ///
    /// **Not time-sorted within the day, and that is a choice.** Sorting would
    /// mean knowing which existing block is which visit, and the only way to
    /// learn that from the file is to parse the blocks back into visits — the
    /// reverse parse this file exists to avoid. The day is also where David
    /// writes his own prose, so any position inside it is a guess about text
    /// the app did not write. End of the day is the one position that is
    /// predictable, never lands in the middle of a paragraph, and is a drag
    /// away from anywhere else.
    ///
    /// Idempotent by the same test the rail draws with: if the body already
    /// names the place, nothing happens. That is what stops the phone and the
    /// Mac adding the same visit twice, and it is deliberately the *same*
    /// check rather than a stricter one — a marker that says "already there"
    /// and an insert that disagrees with it would be worse than either.
    static func insert(_ entry: TripLogEntry, on day: Date, into body: String) -> String {
        guard !body.localizedCaseInsensitiveContains(entry.place.short) else { return body }

        let head = heading(for: day)
        guard let headRange = body.range(of: head) else {
            return append([TripLogDay(date: day, entries: [entry])], to: body)
        }

        // The end of this day's section: the next line that starts a day.
        let afterHead = body[headRange.upperBound...]
        let sectionEnd: String.Index = {
            var cursor = afterHead.startIndex
            while let nl = afterHead[cursor...].firstIndex(of: "\n") {
                let lineStart = afterHead.index(after: nl)
                guard lineStart < afterHead.endIndex else { break }
                if afterHead[lineStart...].hasPrefix("### ") { return lineStart }
                cursor = lineStart
            }
            return afterHead.endIndex
        }()

        let section = String(body[headRange.upperBound..<sectionEnd])
        let tail     = String(body[sectionEnd...])

        // Two blank lines, the same boundary `append` uses between blocks. The
        // section is re-trimmed at its end so a day that already ends in blank
        // lines does not accumulate more each time a visit is added.
        let trimmedSection = section.replacingOccurrences(
            of: #"\s+$"#, with: "", options: .regularExpression)
        let rebuilt = trimmedSection + "\n\n\n" + entry.markdownBlock + "\n"

        return String(body[..<headRange.upperBound]) + rebuilt + (tail.isEmpty ? "" : "\n" + tail)
    }

    /// One visit turned into a log entry, with the same shortening and
    /// note-sanitising `gather` applies.
    ///
    /// Split out so the Mac's single-visit path and the phone's whole-trip path
    /// cannot disagree about what an entry looks like. The one thing it does
    /// **not** reproduce is `gather`'s per-day first-name collision check: that
    /// rule needs the whole day to decide, and a single insert does not have it,
    /// so this is conservative and writes full names. A full name is always
    /// correct and always resolves; a wrongly-shortened one is neither.
    static func entry(for visit: Visit, people: [Person]) -> TripLogEntry {
        TripLogEntry(
            id: visit.id,
            place: TripLogName(full: visit.placeName,
                               short: shortPlaceName(visit.placeName)),
            people: visit.peopleIDs
                .compactMap { id in people.first { $0.id == id }?.name }
                .map { TripLogName(full: $0, short: $0) },
            note: sanitizedNote(visit.notes)
        )
    }
}

/// One line lifted out of a daily note.
///
/// `text` is read from the file and never touched by the model. If that ever stops
/// being true, the guarantee above is gone.
struct TripLogDayNote: Identifiable {
    let id: String
    let text: String
    /// Carried `#trip`, so it was taken on David's word rather than judged.
    let tagged: Bool
    var include: Bool = true
}
