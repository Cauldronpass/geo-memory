// Endeavor.swift
// The Endeavor model, shared. One type, one parser, one set of frontmatter keys.
//
// Session 64. Created because the trigger `SatchelEndeavor.swift` named for
// itself finally fired: *"the duplicate is tolerable because there are only
// two"*, and TraceMac made three.
//
// ── What was duplicated, and why it mattered ──────────────────────────────
//
// Two `Endeavor` structs existed, and they were never two versions of one
// type — they were a writer and a read-only projection that had drifted:
//
//     shared        id · name · type · stampsCaptures · isTravel
//     naming        Dayflow `starts`/`ends`      Satchel `start`/`end`
//     mutability    Dayflow `var`                Satchel `let`
//     Dayflow only  statusOverride · cover · coverCredit · destination
//                   placeID · relativePath · body
//     Satchel only  isCancelled · the three Kit window constants
//
// **`isCancelled` was a lossy projection of `statusOverride`.**
// `EndeavorStatus.storable` is `[.onHold, .cancelled]`, so Satchel's boolean
// cannot represent *on hold* and a paused trip reads as live.
//
// **The names are `starts`/`ends`** because those are the frontmatter keys on
// disk. A model should name what the file names.
//
// ── The parser is the actual prize ────────────────────────────────────────
//
// Both stores parsed the same seven keys with separate code.
// `SatchelEndeavor.swift` heads its copy *"Parsing — must stay in step with
// EndeavorStore in Dayflow"*, and inside it: *"Matches Dayflow exactly, so
// both apps derive the SAME id for the same file — documents are filed against
// that id, so disagreeing would file them into nothing."*
//
// A comment stating that two hand-kept things must stay in step is the
// `remind:` bug of Session 63 with a warning label on it. Where a parser and a
// writer share a format they should be one table read in both directions, not
// two lists somebody remembers to update. `EndeavorFile` below is that table.
//
// ── Scope, and what is deliberately still separate ────────────────────────
//
// `Trace/` compiles into Trace, Dayflow, Jot and TraceMac — confirmed by David
// against Xcode, and **not** what the checked-in `project.pbxproj` says, which
// is stale. So this file reaches three of the four apps by being written.
//
// **Satchel does not compile `Trace/`** and still has its own copy. Folding it
// in is one Target Membership tick on this file plus deleting its struct and
// parser; it is a separate step on purpose, so nothing here depends on an
// Xcode action being remembered.
//
// Staying in Dayflow: `EndeavorStore` (read/write, covers, create, delete),
// `TripLog`, the widget feed and agenda surfacing. Staying in Satchel: Kit,
// `KitEntry`, `KitMembership` and the three window constants, which are
// Satchel policy rather than facts about an Endeavor.

import Foundation
import ImageIO
import CoreGraphics

// MARK: - Status

enum EndeavorStatus: String, CaseIterable, Hashable {
    case idea
    case upcoming
    case active
    case past
    case onHold    = "on hold"
    case cancelled

    var label: String {
        switch self {
        case .idea:      return "idea"
        case .upcoming:  return "upcoming"
        case .active:    return "active"
        case .past:      return "past"
        case .onHold:    return "on hold"
        case .cancelled: return "cancelled"
        }
    }

    /// The two a calendar cannot express, and therefore the only two ever
    /// written to a file. Everything else is computed from the dates.
    static var storable: [EndeavorStatus] { [.onHold, .cancelled] }

    static func parse(_ raw: String?) -> EndeavorStatus? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return storable.first { $0.rawValue == key }
    }
}

// MARK: - Model

struct Endeavor: Identifiable, Hashable {

    /// The slug. Frontmatter `id:`. Never edited after creation — see D9.
    let id: String
    var name: String
    /// Open string, not an enum (D10). The app special-cases only `Travel`;
    /// everything else is a label it displays. Adding a type is a typed word,
    /// not a code change and not a migration.
    var type: String
    var starts: Date?
    var ends: Date?
    /// Empty in the overwhelming majority of cases. Only ever `on hold` or
    /// `cancelled`; when nil the status is derived.
    var statusOverride: EndeavorStatus?
    /// Container-relative path to a cover image. **Travel only** (D8) — a
    /// photograph makes a trip feel like a trip; a stock photo of a kitchen
    /// makes a renovation feel like a brochure.
    var cover: String?
    /// Attribution for `cover`. Wikimedia Commons images are mostly CC-licensed
    /// and require crediting the photographer and naming the licence; this is
    /// where that lives. Shown on the details sheet, deliberately not on the
    /// Endeavor screen, which is meant to stay quiet. Empty for public-domain
    /// images and for photos from the user's own library.
    var coverCredit: String?
    /// Which slice of `cover` the band shows, vertically. `0` is the top edge of
    /// the photograph, `1` the bottom, `0.5` the centre — which is what
    /// `scaledToFill` does on its own and therefore the default for every note
    /// written before this key existed.
    ///
    /// David: *"Can i move the photo i picked around within frame to fine the
    /// exact location i want to show in the window?"*
    ///
    /// **Vertical only, and one number.** The band is wide and short, so a
    /// normal photograph is scaled to fill the width and the crop it loses is
    /// top and bottom. The horizontal case only exists for a panorama wider than
    /// the band's ratio, where there is nothing to choose anyway because the
    /// whole height already fits. A second axis would be a field, a gesture and
    /// a migration for a case that does not arise.
    ///
    /// **A fraction, not pixels.** The same note is read on a 1400pt Mac column
    /// and a 390pt phone, and the band height has already changed once this
    /// week (96 → 160). A stored offset in points would mean something different
    /// in each, and would have to be re-tuned every time the band was resized.
    var coverOffset: Double = 0.5
    /// Where it is. Free text — "Kyoto", "Traverse City / Omena, MI" — matching
    /// the field David's existing vault trips already carry.
    ///
    /// Also the search term for a Commons cover, which is why it earns a field
    /// rather than living in the body: type it once, and the photograph and the
    /// header both come from it.
    var destination: String?
    /// Optional link to a Trace Place, by its Notion id. **`destination` stays
    /// the label**; this is the thing that makes the label actionable.
    ///
    /// Two fields rather than one because they answer different questions.
    /// "Kyoto" is where the trip is and is also the Commons cover search term,
    /// and no Place record will ever exist for it. A hotel, a restaurant or a
    /// venue is a real Place with coordinates, which is what Directions and
    /// Check In need. A trip can have either, both, or neither.
    ///
    /// Deliberately NOT for countries. A country's coordinate is its geographic
    /// centre, so Directions routes you to a field in the middle of it, and
    /// every Place also feeds geofencing and Nearby. Use the text for those.
    var placeID: String?
    /// Places attached to this endeavor, by their full Trace Place name.
    ///
    /// Session 66. David: *"How do i attach locations/places to my endeavor? Is
    /// linking the only way or is there a way to add it as a pill outside the
    /// note itself like documents?"*
    ///
    /// **This is a different question from the trip log, and that is the point.**
    /// The Visits rail is retrospective — it reads places out of the log because
    /// the log is a record of where you went. This is prospective: where you are
    /// going, attached before any visit exists. Lakemore Resort is a destination
    /// for Megan's wedding week weeks before anybody checks in there.
    ///
    /// **Frontmatter, not the body**, unlike linked notes and the trip log. The
    /// body is prose the user owns and the skeleton is five fixed headings (D5);
    /// a managed sixth section would be app furniture inside a document that is
    /// meant to be written in. A set of attached records is exactly what
    /// frontmatter is for, and `place:` above already establishes it.
    ///
    /// **Full Notion names, not ids**, matching `TripLogName`: the note keeps
    /// the full name because that is the string wikilink resolution matches on,
    /// and a name is legible when the file is read outside the app. The cost is
    /// that renaming a Place in Notion orphans the attachment, which is the same
    /// trade every `[[wikilink]]` in this vault already makes.
    ///
    /// Distinct from `destination` (free text, one line, also the cover search
    /// term) and from `placeID` (one place, the thing that makes the label
    /// actionable). Those answer "where is this" once; this answers "which
    /// places belong to it", many times.
    var places: [String] = []
    /// People attached to this Endeavor by hand, by full Notion name.
    ///
    /// David: *"can we add people to edeavors? like we did for notes and
    /// destinations?"*
    ///
    /// **The same prospective/retrospective split as `places`.** The rail's
    /// People section derives from the visits the trip log names — it answers
    /// "who was there", after the fact, and it can only ever answer it once
    /// somebody has checked in. Nobody has checked into Megan's wedding yet, and
    /// the guest list exists now.
    ///
    /// Deliberately **not** a replacement for the derived list: the rail unions
    /// the two. Someone you attached and someone the log found are both on this
    /// endeavor, and making the explicit list win would silently drop people who
    /// demonstrably went.
    ///
    /// Names not ids, for the reasons spelled out on `places` above.
    var people: [String] = []
    /// Attached destinations David has since said he did NOT get to.
    ///
    /// Session 72. A past endeavor carrying a destination with no visit logged
    /// against it is an open question — he either went and forgot to check in,
    /// or he skipped it — and the Endeavors screen now asks. "Went" writes a
    /// visit, which answers it in the place the answer belongs. "Didn't go" had
    /// nowhere to be recorded, and needed somewhere, or the prompt returns every
    /// launch forever.
    ///
    /// **Not solved by removing it from `places:`.** That was the cheaper
    /// option and it destroys the more interesting fact: you meant to go to
    /// Cornerstone on the wedding week and did not. Planning is a record too.
    ///
    /// Names, matching `places:`, and a subset of it in practice — anything
    /// here that is not in `places:` is inert rather than wrong.
    var skippedPlaces: [String] = []
    /// Whether captures made while this endeavor is running are filed to it.
    ///
    /// **Stated positively on purpose.** The obvious spelling was "skip
    /// stamping", and a checkbox you untick to stop something not happening is
    /// a sentence nobody can read twice the same way.
    ///
    /// David, having driven to Wisconsin and back in a day: *"this one day trip
    /// wouldnt really qualify for auto stamping."* Right, and it generalises —
    /// the value of stamping scales with how long you are away. Everything
    /// captured during nine days in Japan belongs to Japan. Most of what you
    /// capture on a day trip is just Tuesday.
    ///
    /// So the **default is derived from length, once**, and then it is an
    /// ordinary stored setting: see `defaultStampsCaptures`. Derived at parse
    /// time only when the key is absent, written explicitly on every save. That
    /// means an endeavor created before this existed gets a sensible answer, the
    /// checkbox always shows the value actually in force, and extending a trip
    /// later never silently flips a decision the user has since made themselves.
    var stampsCaptures: Bool

    /// Where the note lives. Derived from the filename, never stored in the
    /// file — a file does not need to be told its own path.
    var relativePath: String
    /// Everything after the closing `---`. Round-tripped untouched on every
    /// save, which is the whole reason `renderFrontmatter` merges rather than
    /// rebuilds.
    var body: String

    var isTravel: Bool { type.caseInsensitiveCompare("Travel") == .orderedSame }

    /// The five types the app offers (D268).
    ///
    /// **Still an open string on the model (D10).** This is the OFFERED list,
    /// not a closed set: a type typed by hand into frontmatter still parses,
    /// still displays, and must never be quietly rewritten to one of these.
    ///
    /// D10 held the list at two on the reasoning that a type changed no
    /// behaviour, so a third would be "a filing decision with no consequence".
    /// D268's body band ended that: the type now decides what you see, which is
    /// why the list is chosen deliberately here and then closed.
    ///
    /// **Gathering, not Hosting.** David: *"if i am going to my parents for
    /// dinner and have a few things to consider on that, it is not me hosting
    /// it."* Hosting names your role; Gathering names the thing, and the shape
    /// is the same either way — a schedule in hours rather than days.
    ///
    /// **Milestone is for the occasion you do NOT travel for.** A week away at
    /// a wedding is a trip with events on it, and typing it Milestone would
    /// take it out of Satchel's packing Kit (`isKitRelevant` guards on
    /// `isTravel`) and hide the cover section on the phone, for a word.
    static let offeredTypes = ["Travel", "Milestone", "Gathering", "Project", "Decision"]

    /// The type's glyph, and its tint as a `DocumentTint`.
    ///
    /// D268: **the type gets its own glyph and tint, in the list and beside the
    /// masthead, and nowhere else.** Travel and Project keep the phone's own
    /// indigo airplane and green hammer, unchanged since Session 78.
    ///
    /// An unrecognised type gets a dashed circle in gray rather than falling
    /// through to the hammer. A type the app does not know should look like one,
    /// not like a Project.
    var typeGlyph: String {
        switch type.lowercased() {
        case "travel":    return "airplane"
        case "milestone": return "star"
        case "gathering": return "person.2"
        case "project":   return "hammer"
        case "decision":  return "arrow.triangle.branch"
        default:          return "circle.dashed"
        }
    }

    var typeTint: DocumentTint {
        switch type.lowercased() {
        case "travel":    return .indigo
        case "milestone": return .rose
        case "gathering": return .amber
        case "project":   return .green
        case "decision":  return .teal
        default:          return .gray
        }
    }

    /// What the body's schedule band is CALLED for this type, or nil when this
    /// type does not lead with one (D268).
    ///
    /// Travel reads ITINERARY. Milestone and Gathering read SCHEDULE — **not
    /// "run of show"**, which is host language and would read oddly for an
    /// evening you are a guest at.
    ///
    /// Project reads SCHEDULE too. A project has dated things on it - a site
    /// visit, a delivery, an inspection - and D268's table puts the schedule
    /// third in its body, after the punch list and the quotes. The band is the
    /// same band; only its position in the body differs.
    ///
    /// Decision returns nil. A decision is a comparison, not a calendar: its
    /// one band is the ledger below.
    var scheduleBandLabel: String? {
        switch type.lowercased() {
        case "travel":                            return "Itinerary"
        case "milestone", "gathering", "project": return "Schedule"
        default:                                  return nil
        }
    }

    /// What the body's LEDGER band is CALLED for this type, or nil when this
    /// type does not compare anything (D268).
    ///
    /// The ledger is the other band shape: **a Bookings row with a cost and no
    /// date**. Project calls it QUOTES and Decision calls it OPTIONS, and they
    /// are the same rows drawn the same way - the type decides the NAME and the
    /// ORDER, never what a row IS. That is the same move D267 made one level
    /// down, where the sheet's labels follow the Kind and the columns do not.
    ///
    /// Travel, Milestone and Gathering return nil, and that is what keeps an
    /// undated costed row visible on a trip: with no ledger to move to, it
    /// stays in the itinerary's Undated bucket exactly as it does today. A rule
    /// that pulled it out unconditionally would make a real Notion row appear
    /// on no screen at all.
    var ledgerBandLabel: String? {
        switch type.lowercased() {
        case "project":  return "Quotes"
        case "decision": return "Options"
        default:         return nil
        }
    }

    /// Whether the punch list is drawn in the BODY rather than on the rail
    /// (D268, Session 87).
    ///
    /// D268's table: a project is lived punch list, quotes, schedule, note. The
    /// tasks are the first thing about it, and on the rail they were the first
    /// thing about every endeavor, which is a different claim. Nothing is drawn
    /// in both places - the rail skips this section for the type that moves it,
    /// which is standing warning FIVE's shape.
    ///
    /// It is the same function drawing in either place, not a second one.
    var bodyLeadsWithTasks: Bool {
        type.lowercased() == "project"
    }

    /// Inclusive length in days, nil when either end is missing.
    var dayCount: Int? {
        guard let starts, let ends else { return nil }
        let cal = Calendar.current
        let from = cal.startOfDay(for: starts)
        let to = cal.startOfDay(for: ends)
        guard let days = cal.dateComponents([.day], from: from, to: to).day else { return nil }
        return max(1, days + 1)
    }

    /// The starting answer for `stampsCaptures`, used only when nothing is
    /// stored. **Same three-day threshold David set for the agenda rows**, and
    /// deliberately pointing the other way: a short endeavor shows on every day
    /// because it is easy to forget it is happening, and does NOT stamp because
    /// most of what you capture on a day trip is just that day. A long one is
    /// the reverse on both counts.
    ///
    /// Not a live rule. It seeds the value; after that the setting is the truth.
    static func defaultStampsCaptures(starts: Date?, ends: Date?) -> Bool {
        guard let starts, let ends else { return false }
        let cal = Calendar.current
        let days = (cal.dateComponents([.day],
                                       from: cal.startOfDay(for: starts),
                                       to: cal.startOfDay(for: ends)).day ?? 0) + 1
        return days > 3
    }

    // MARK: Derived status

    func status(on date: Date = Date()) -> EndeavorStatus {
        if let statusOverride { return statusOverride }
        guard let starts else { return .idea }

        let cal = Calendar.current
        if cal.startOfDay(for: date) < cal.startOfDay(for: starts) { return .upcoming }
        if let ends, cal.startOfDay(for: date) > cal.startOfDay(for: ends) { return .past }
        return .active
    }

    /// Whole days from today until this starts. Negative once it has begun.
    func daysUntilStart(on date: Date = Date()) -> Int? {
        guard let starts else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: date),
                                  to: cal.startOfDay(for: starts)).day
    }

    /// Total length in days, inclusive of both ends. Nil when open-ended.
    var totalDays: Int? {
        guard let starts, let ends else { return nil }
        let cal = Calendar.current
        guard let d = cal.dateComponents([.day],
                                         from: cal.startOfDay(for: starts),
                                         to: cal.startOfDay(for: ends)).day else { return nil }
        return d + 1
    }

    /// Which day of it today is, 1-based. Nil before it starts.
    func dayIndex(on date: Date = Date()) -> Int? {
        guard let starts else { return nil }
        let cal = Calendar.current
        guard let d = cal.dateComponents([.day],
                                         from: cal.startOfDay(for: starts),
                                         to: cal.startOfDay(for: date)).day, d >= 0 else { return nil }
        return d + 1
    }

    /// Sort key. Running now first, then what is coming, then what is done —
    /// which is the order the browse list reads in.
    ///
    /// Within each band the tiebreak is imminence, so the trip about to start
    /// outranks the one in a year. Undated endeavors sort last within their
    /// band rather than first, because a thing with no dates is by definition
    /// not the thing about to happen.
    func sortKey(on date: Date = Date()) -> (Int, Int) {
        let band: Int
        switch status(on: date) {
        case .active:    band = 0
        case .upcoming:  band = 1
        case .idea:      band = 2
        case .onHold:    band = 3
        case .past:      band = 4
        case .cancelled: band = 5
        }
        return (band, daysUntilStart(on: date).map { abs($0) } ?? Int.max)
    }
}

// MARK: - The file format
//
// One place that knows what an Endeavor note looks like on disk. Both stores
// read through it; `EndeavorStore` keeps same-named statics that forward here
// so its own call sites did not have to move.

enum EndeavorFile {

    static let folder = "Notes/Endeavors"

    /// Builds an `Endeavor` from a raw note.
    ///
    /// `path` and `filename` are passed in rather than derived, because the two
    /// stores reach the file differently and neither should have to agree with
    /// the other about how a path is spelled.
    static func parse(raw: String, path: String, filename: String) -> Endeavor? {
        guard !raw.isEmpty else { return nil }
        let (fields, body) = splitFrontmatter(raw)
        let fallbackName = (filename as NSString).deletingPathExtension

        // A file with no `id:` was written by hand in Finder, or predates the
        // slug. Give it a deterministic slug from its filename rather than
        // skipping it: an Endeavor that does not appear because of a field it
        // never knew about is worse than one whose slug is not pretty.
        //
        // This rule being identical across apps is load-bearing, not tidy.
        // Documents are filed against the derived id, so two apps disagreeing
        // would file them into nothing. That is exactly why it is now one
        // function instead of two that match.
        let id = fields["id"]?.endeavorNilIfEmpty ?? slug(from: fallbackName)
        let starts = date(fields["starts"])
        let ends   = date(fields["ends"])

        return Endeavor(
            id: id,
            name: fields["name"]?.endeavorNilIfEmpty ?? fallbackName,
            type: fields["type"]?.endeavorNilIfEmpty ?? "Project",
            starts: starts,
            ends: ends,
            statusOverride: EndeavorStatus.parse(fields["status"]),
            cover: fields["cover"]?.endeavorNilIfEmpty,
            coverCredit: fields["cover_credit"]?.endeavorNilIfEmpty,
            // Clamped on the way in, not only on the way out. These files are
            // hand-editable and `cover_offset: 3` should crop to the bottom
            // rather than fly the picture off the band.
            coverOffset: clamped01(fields["cover_offset"]) ?? 0.5,
            destination: fields["destination"]?.endeavorNilIfEmpty,
            placeID: fields["place"]?.endeavorNilIfEmpty,
            places: list(fields["places"]),
            people: list(fields["people"]),
            skippedPlaces: list(fields["skipped"]),
            stampsCaptures: bool(fields["stamp_captures"])
                ?? Endeavor.defaultStampsCaptures(starts: starts, ends: ends),
            relativePath: path,
            body: body
        )
    }

    /// A frontmatter number pinned to 0...1, or nil when absent or unparseable.
    /// Tolerant like `bool(_:)` and `list(_:)` beside it, for the same reason:
    /// these files are meant to be editable by hand and in Obsidian.
    static func clamped01(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let value = Double(raw) else { return nil }
        return min(1, max(0, value))
    }

    /// Splits a note into its frontmatter fields and everything after.
    ///
    /// Returns an EMPTY field set and the whole file as body when there is no
    /// frontmatter, so a hand-written note is still openable rather than
    /// silently half-parsed.
    static func splitFrontmatter(_ raw: String) -> ([String: String], String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], raw)
        }

        var fields: [String: String] = [:]
        var bodyLines: [String] = []
        var closed = false

        for line in lines.dropFirst() {
            if !closed, line.trimmingCharacters(in: .whitespaces) == "---" {
                closed = true
                continue
            }
            if closed {
                bodyLines.append(line)
            } else {
                let parts = line.split(separator: ":", maxSplits: 1)
                              .map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                fields[parts[0].lowercased()] =
                    parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        // An unterminated block means the whole file was frontmatter and there
        // is no body. Do not hand the caller the fields as prose.
        guard closed else { return (fields, "") }

        // Drop leading blank lines so the editor does not open on empty space.
        var body = bodyLines
        while let first = body.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            body.removeFirst()
        }
        return (fields, body.joined(separator: "\n"))
    }

    /// Splits a note into its frontmatter **verbatim** and its body.
    ///
    /// Deliberately different from `splitFrontmatter`, which parses into a
    /// dictionary and therefore loses key order and anything it does not know
    /// about. This one hands back the literal `---` block, so an editor that
    /// only owns the body can put the file back together **byte-identically
    /// above the fence**.
    ///
    /// Why that matters more than re-rendering: `EndeavorStore.save`'s own
    /// comment says keys are written in a fixed order *"so a file does not
    /// churn in git or in iCloud's version history every time an unrelated
    /// field changes"*. Re-rendering from parsed fields on every keystroke-
    /// debounce would defeat that, and would silently drop any key a future
    /// version of the phone adds before this version learns about it. Same
    /// lesson as `remind:` in Session 63: do not rewrite what you were not
    /// asked to change.
    ///
    /// Returns an empty prefix and the whole text when there is no frontmatter.
    static func splitRaw(_ raw: String) -> (frontmatter: String, body: String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ("", raw)
        }
        for (i, line) in lines.enumerated() where i > 0 {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let fm = lines[0...i].joined(separator: "\n")
                var body = Array(lines[(i + 1)...])
                while let f = body.first, f.trimmingCharacters(in: .whitespaces).isEmpty {
                    body.removeFirst()
                }
                return (fm, body.joined(separator: "\n"))
            }
        }
        // Unterminated: the whole file is frontmatter and there is no body.
        return (raw, "")
    }

    // MARK: Slugs and filenames

    static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "endeavor" : collapsed
    }

    /// The filename keeps the human name — this is a note somebody may open in
    /// a file browser. Only the characters a path genuinely cannot hold are
    /// replaced, the same short list `NoteStore.placeNoteFilename` uses.
    static func safeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Dates and booleans

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return iso.date(from: raw)
    }

    static func string(_ date: Date) -> String { iso.string(from: date) }

    /// Tolerant on purpose — these files are hand-editable, and "yes" in a
    /// frontmatter key should not silently mean false.
    // MARK: Writing
    //
    // Session 65. Moved out of `EndeavorStore.save` in Dayflow so TraceMac can
    // create an endeavor. David: *"I also have no way to add an endeavor
    // currently in this mac app."*
    //
    // This is the "share the frontmatter renderer" step Session 64 named as the
    // first move in the sequence, and it is the same argument as every other
    // extraction this week: a second writer of these keys, in another target,
    // would drift from the parser twelve lines up. Parser and writer are one
    // table read in two directions and they live in one file.

    /// The whole file: frontmatter, then the body untouched.
    ///
    /// Key order is fixed so a file does not churn in git or in iCloud's version
    /// history every time an unrelated field changes. Empty optionals are
    /// omitted rather than written blank — `ends:` with nothing after it parses
    /// back as nil anyway, and its absence reads as "open-ended" to a human.
    static func render(_ endeavor: Endeavor) -> String {
        var out = "---\n"
        out += "id: \(endeavor.id)\n"
        out += "name: \(endeavor.name)\n"
        out += "type: \(endeavor.type)\n"
        if let starts = endeavor.starts { out += "starts: \(string(starts))\n" }
        if let ends   = endeavor.ends   { out += "ends: \(string(ends))\n" }
        if let status = endeavor.statusOverride { out += "status: \(status.rawValue)\n" }
        if let dest = endeavor.destination?.endeavorNilIfEmpty { out += "destination: \(dest)\n" }
        if let place = endeavor.placeID?.endeavorNilIfEmpty { out += "place: \(place)\n" }
        // Comma-separated, the same shape the document sidecars use for `people`
        // and `tags`. Omitted entirely when empty rather than written as `[]`,
        // matching every other optional key here.
        if !endeavor.places.isEmpty {
            out += "places: \(renderList(endeavor.places))\n"
        }
        if !endeavor.people.isEmpty {
            out += "people: \(renderList(endeavor.people))\n"
        }
        if !endeavor.skippedPlaces.isEmpty {
            out += "skipped: \(renderList(endeavor.skippedPlaces))\n"
        }
        // Always written, never conditional: this is what turns a derived
        // migration default into an explicit setting the moment anything saves.
        out += "stamp_captures: \(endeavor.stampsCaptures)\n"
        if let cover  = endeavor.cover?.endeavorNilIfEmpty { out += "cover: \(cover)\n" }
        if let credit = endeavor.coverCredit?.endeavorNilIfEmpty { out += "cover_credit: \(credit)\n" }
        // Written only when it has been moved, and only when there is a cover to
        // move. A key that says "centred" on every note in the vault is noise in
        // a file meant to be readable, and its absence already means 0.5.
        if endeavor.cover?.endeavorNilIfEmpty != nil, abs(endeavor.coverOffset - 0.5) > 0.001 {
            out += "cover_offset: \(String(format: "%.3f", endeavor.coverOffset))\n"
        }
        out += "---\n\n"
        out += endeavor.body
        return out
    }

    /// `japan-2026`. The year comes from the start date when there is one,
    /// because "japan" alone collides the second time he goes.
    ///
    /// Takes the ids already in use rather than reading a store, so both apps
    /// can call it with whatever they have loaded.
    static func uniqueSlug(for name: String, on starts: Date?, existing: [String]) -> String {
        var base = slug(from: name)
        if let starts {
            let year = Calendar.current.component(.year, from: starts)
            if !base.hasSuffix("-\(year)") { base += "-\(year)" }
        }
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// The five headings a new endeavor starts with.
    ///
    /// **No `# Name` heading.** The name already appears above the editor, and a
    /// third copy inside the body was pure repetition — David flagged it on the
    /// first endeavor he made, 2026-07-29. It is in the frontmatter as `name:`,
    /// which is the field the app reads.
    static func skeleton() -> String {
        """
        ## Summary


        ## Plan


        ## Open items


        ## Log


        ## Reference

        """
    }

    /// A brand-new endeavor, not yet written anywhere.
    ///
    /// Shared so the two apps cannot disagree about what a fresh endeavor is:
    /// its id form, its default `stamp_captures`, its skeleton, or where its
    /// file goes. `folder` is already declared at the top of this enum.
    static func newEndeavor(name: String,
                            type: String,
                            starts: Date?,
                            ends: Date?,
                            destination: String? = nil,
                            placeID: String? = nil,
                            stampsCaptures: Bool? = nil,
                            existingIDs: [String]) -> Endeavor {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled" : trimmed
        return Endeavor(
            id: uniqueSlug(for: finalName, on: starts, existing: existingIDs),
            name: finalName,
            type: type,
            starts: starts,
            ends: ends,
            statusOverride: nil,
            cover: nil,
            coverCredit: nil,
            destination: destination?.trimmingCharacters(in: .whitespacesAndNewlines).endeavorNilIfEmpty,
            placeID: placeID?.endeavorNilIfEmpty,
            stampsCaptures: stampsCaptures
                ?? Endeavor.defaultStampsCaptures(starts: starts, ends: ends),
            relativePath: "\(folder)/\(safeFilename(finalName)).md",
            body: skeleton()
        )
    }

    // MARK: Covers
    //
    // Session 65, moved out of `EndeavorStore` so TraceMac can set a cover too.
    //
    // The stamped filename and the matcher that recognises it are **one rule**,
    // and the reason they belong beside the parser rather than in either app is
    // that they are read from both sides: one app writes `<slug>-yyyyMMdd-HHmmss
    // .jpg` and the other decides, on that pattern alone, which files are stale
    // covers safe to delete. A Mac that stamped differently would leave every
    // cover it wrote behind forever, and a Mac that matched differently would
    // delete something it should not.

    /// Where cover images live.
    static let photoFolder = "Photos/Endeavors"

    /// Seconds, not minutes: two covers chosen inside one minute would produce
    /// the same filename, and a collision brings back the exact bug the stamp
    /// exists to fix. POSIX locale so a non-Gregorian device calendar cannot
    /// produce a filename that no longer matches `isStampedCover`.
    private static let coverStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// `<slug>-yyyyMMdd-HHmmss.jpg`.
    ///
    /// **Stamped, not fixed.** It was `<slug>.jpg` until 2026-07-29, on the
    /// reasoning that re-choosing a cover should overwrite rather than litter.
    /// Right about storage, wrong about everything else: the path in the note
    /// never changed, so nothing on screen ever changed. Every view keys its
    /// load on the path, and so does iCloud. David chose a new photograph, it
    /// was written correctly, and the old one stayed on screen.
    static func coverFilename(slug: String, at date: Date = Date()) -> String {
        "\(slug)-\(coverStamp.string(from: date)).jpg"
    }

    /// True only for `<slug>-yyyyMMdd-HHmmss.jpg` exactly.
    ///
    /// Matched narrowly, and that is not fussiness: a plain prefix match would
    /// let `japan-2026` claim files belonging to `japan-2026-2`.
    static func isStampedCover(_ filename: String, slug: String) -> Bool {
        guard filename.hasPrefix("\(slug)-"), filename.hasSuffix(".jpg") else { return false }
        let tail = filename.dropFirst(slug.count + 1).dropLast(4)
        guard tail.count == 15 else { return false }
        guard tail[tail.index(tail.startIndex, offsetBy: 8)] == "-" else { return false }
        return tail.prefix(8).allSatisfy(\.isNumber) && tail.suffix(6).allSatisfy(\.isNumber)
    }

    /// Any file that is a cover for this slug, current or historic — including
    /// the pre-2026-07-29 unstamped `<slug>.jpg`, so no migration is needed.
    static func isCoverFile(_ filename: String, slug: String) -> Bool {
        filename == "\(slug).jpg" || isStampedCover(filename, slug: slug)
    }

    /// Re-encoded at most 1600px on its long edge.
    ///
    /// A modern phone photo is 3-5MB and a cover is drawn at 132pt, so storing
    /// the original would put tens of megabytes into a container whose entire
    /// premise is that everything in it is worth carrying.
    ///
    /// ImageIO rather than `UIImage`/`NSImage`, which is why it can be shared at
    /// all: `CGImageSource` and `CGImageDestination` are the same API on both
    /// platforms. It was already written this way in Dayflow.
    static func downscaledJPEG(_ data: Data, maxDimension: CGFloat = 1600) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg,
                                   [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// A comma-separated frontmatter value as a list.
    ///
    /// Tolerant in the same way `bool` is: these files are hand-editable, so
    /// surrounding brackets are stripped, blanks dropped, and whitespace
    /// trimmed. `places: [Inspired, Nick\'s on the Lake]` and
    /// `places: Inspired, Nick\'s on the Lake` both parse.
    static func list(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") { t.removeFirst() }
        if t.hasSuffix("]") { t.removeLast() }
        return splitTopLevel(t)
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// Splits on commas that are **not inside double quotes**.
    ///
    /// A Notion place called `Nick's on the Lake, Minocqua` used to become two
    /// destinations on the next parse, because `render` joined with `", "` and
    /// this split on every comma. Nothing in the vault trips it today; something
    /// eventually would, silently, and the halves would both fail to resolve.
    ///
    /// Quoting rather than a different separator: `places:` and `people:` are
    /// already written comma-separated in files that exist, and a semicolon would
    /// orphan every one of them. A quoted member is still legible in Obsidian.
    static func splitTopLevel(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle(); current.append(ch) }
            else if ch == "," && !inQuotes { out.append(current); current = "" }
            else { current.append(ch) }
        }
        out.append(current)
        return out
    }

    /// Strips one matched pair of surrounding double quotes.
    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    /// Renders one frontmatter list, quoting any member containing a comma.
    ///
    /// One writer for both `places:` and `people:`, so the two cannot disagree
    /// with each other or with `list(_:)` — the parser-and-writer-are-one-table
    /// rule that `shortPlaceName` cost this project three copies to learn.
    static func renderList(_ items: [String]) -> String {
        items.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ", ")
    }

    static func bool(_ raw: String?) -> Bool? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty
        else { return nil }
        if ["true", "yes", "y", "1"].contains(raw) { return true }
        if ["false", "no", "n", "0"].contains(raw) { return false }
        return nil
    }
}

// Deliberately its own name rather than `nilIfEmpty`. Three files already
// declare a `private extension String` with a variant of this — `nilIfEmpty`,
// `nilIfEmptyView`, `nilIfEmptySatchel` — and this file compiles into four
// targets alongside all of them. A distinct name means adding this cannot
// collide with any of them today or with a fourth tomorrow.
private extension String {
    var endeavorNilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Visit membership
//
// Session 72. David, rejecting a proposed Endeavors row on the Place record:
// *"the affiliation is more about the visit than the place or the person. If i
// happen to go to Nicks on a different day outside the lunch with bronwyn date,
// i dont need to see that it was with that endeavor… if i click the visit it
// would be helpful to see on the visit screen what endeavor that was part of."*
//
// **A Place is permanent and a visit is one afternoon**, and an Endeavor is
// also one dated thing, so the visit is the only end that can honestly hold the
// association. A restaurant visited on four trips would otherwise wear four
// Endeavor labels, none of which describe the restaurant.
//
// Lives here, on the model, rather than in either app: `TraceMacEndeavorsView`
// already had both halves of this as private methods, and the reverse direction
// needs the same answer or the two ends of one relationship can disagree. The
// Mac's rail now calls these, so there is one definition of what "in the
// endeavor" means. Deliberately takes a place NAME and a DATE rather than a
// `Visit`, so this file gains no dependency on `Models.swift` — it compiles
// into four targets and not all of them carry the same model files.
extension Endeavor {

    /// Whether `date` falls inside the endeavor's dates, both ends inclusive.
    ///
    /// **Day granularity, not instants.** Notion stores most visit dates at
    /// midnight, and `DateInterval.contains` on raw instants put an eighth row
    /// in the Mac's This Week panel once already. An endeavor with no start
    /// date contains nothing; one with no end date is a single day.
    func covers(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let starts else { return false }
        let day  = calendar.startOfDay(for: date)
        let from = calendar.startOfDay(for: starts)
        let to   = calendar.startOfDay(for: ends ?? starts)
        return day >= from && day <= to
    }

    /// Whether the endeavor's body names this place.
    ///
    /// Matched against the body text rather than a stored list, because **the
    /// trip log is the body** — there is no separate record of what is in it.
    /// This is what the checkmarks in the Mac's Visits rail are reading, and
    /// what "Also that day (N)" is hiding.
    ///
    /// Through `TripLog.shortPlaceName` on both sides: the Notion record reads
    /// "Nick's on the Lake (formerly known as Popeye's)" and the log line reads
    /// "Nick's on the Lake". Comparing the full name would match nothing and
    /// say nothing about why.
    func logNames(placeName: String) -> Bool {
        let short = TripLog.shortPlaceName(placeName)
        guard !short.isEmpty else { return false }
        return body.localizedCaseInsensitiveContains(short)
    }

    /// Whether this endeavor claims a visit: inside its dates **and** named in
    /// its log.
    ///
    /// Both halves, on purpose. Dates alone answer "who did you see that day",
    /// which David rejected in Session 64 for exactly the case that recurs
    /// here: *"seeing Bryan and Hannah when they did not go with us to Inspired
    /// and Nics is not helpful."* The log is the part he curates by hand, and
    /// it is the answer.
    ///
    /// The endeavor's `places:` frontmatter is deliberately NOT consulted. That
    /// list is prospective — where you are going, attached before any visit
    /// exists — so a destination attached but never checked off in the log is
    /// one he did not claim, and this should not claim it for him.
    func claimsVisit(placeName: String, on date: Date, calendar: Calendar = .current) -> Bool {
        covers(date, calendar: calendar) && logNames(placeName: placeName)
    }
}

// MARK: - Note membership, from the note's side
//
// Session 72. The last one-way case left after D120. An Endeavor's body
// `[[wikilinks]]` a project note and the Endeavor screen lists it; the note
// itself said nothing back. David: *"lts fix the notes membership."*
//
// **Notes are unlike Places and People here, which is why D120 excluded them
// rather than settling them.** A visit is one dated event and belongs to a trip;
// a Place is permanent and does not. A note is neither — it is a document, and
// being written FOR an endeavor is a durable property of it. "Final Wedding
// Speech" is about Megan's wedding for as long as it exists, so the backlink
// says something true forever, which is the test D120 set.
//
// Derived, from the same `NoteStore.wikilinkTargets` parser the forward
// direction already uses, so the two ends cannot disagree about what a link is.
// Nothing stored, nothing to migrate, and a note renamed out from under an
// endeavor stops matching in both directions at once rather than one.
extension Endeavor {
    /// Whether this endeavor's body links a note by that title.
    ///
    /// Title, not path: `[[Final Wedding Speech]]` is what the body carries and
    /// what the forward lookup matches on. Case-insensitive for the same reason
    /// it is there.
    func linksNote(titled title: String) -> Bool {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return NoteStore.wikilinkTargets(in: body).contains {
            $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame
        }
    }
}

// MARK: - Loading, for surfaces with no store of their own
//
// Session 72. Three targets already carry a store (`EndeavorStore`,
// `TraceMacEndeavorStore`, `SatchelEndeavorStore`) and each of them opens with
// the same six lines: list the folder, read each file, hand it to
// `EndeavorFile.parse`. The Trace app has no store and needs exactly those six
// lines for one read-only row, and a fourth store to render one label is the
// duplication this file's own split was written to prevent.
//
// So the walk moves here, next to the parser it feeds. Deliberately NOT a
// refactor of the three existing stores — they own writes, covers, deletion and
// the widget feed, and changing four things to add one row is how a row becomes
// a regression.
extension EndeavorFile {
    /// Every parsed endeavor note, unsorted.
    ///
    /// Returns empty when the container is unavailable rather than throwing:
    /// every caller is a view deciding whether to draw a row, and the honest
    /// answer to "is this visit in an endeavor" when the notes cannot be read
    /// is the same shape as "no" for that purpose. Callers that need to tell
    /// the two apart should ask `noteStore.hasAccess` themselves.
    /// Every endeavor's name mapped to its id (Session 87).
    ///
    /// One definition, two callers with different needs: a task ROW only wants
    /// to know whether a `[[wikilink]]` names an endeavor, and an open CARD
    /// wants the id so its chip can navigate. Two lookups built separately
    /// would be two answers to "is this an endeavor", and the row would
    /// eventually flag something the card could not open.
    ///
    /// Not cached here. `loadAll` reads the endeavor files, which is cheap
    /// enough once per screen and far too much once per row, so the callers
    /// hold the result and the row is handed a set rather than reaching for
    /// one.
    static func nameIndex(from noteStore: NoteStore) -> [String: String] {
        var out: [String: String] = [:]
        for endeavor in loadAll(from: noteStore) { out[endeavor.name] = endeavor.id }
        return out
    }

    static func loadAll(from noteStore: NoteStore) -> [Endeavor] {
        guard noteStore.hasAccess else { return [] }
        let files = (try? noteStore.listFiles(in: folder)) ?? []
        return files.filter { $0.hasSuffix(".md") }.compactMap { filename in
            let path = "\(folder)/\(filename)"
            guard let raw = try? noteStore.readFile(path) else { return nil }
            return parse(raw: raw, path: path, filename: filename)
        }
    }
}
