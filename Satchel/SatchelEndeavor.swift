import Foundation
import Observation

// MARK: - Endeavor
//
// The four-field identity contract from `Documents-App-Scope.md` §3, LOCKED
// 2026-07-27. These four are the only fields Satchel depends on, and they were
// frozen so Satchel could be built before Endeavor's own design pass happened.
//
// That pass happened on 2026-07-29 and CANCELLED the Notion database this
// comment used to point at: an Endeavor is a note in `Notes/Endeavors` with its
// fields in frontmatter (`Endeavor-Design.md`). The contract survived the change
// untouched, which is the only reason nothing in Satchel had to be redesigned —
// worth noting as evidence that freezing four fields was the right call.
//
// | id        | Notion page ID. Authoritative.     |
// | name      | Display name, e.g. "Japan 2026".   |
// | type      | "Travel" or "Project" today.       |
// | dateRange | Start and end, both optional.      |
//
// Do not change these four without checking what breaks in Satchel.

struct Endeavor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let start: Date?
    let end: Date?

    /// A FIFTH field, added 2026-07-29, and deliberately not part of the locked
    /// four-field contract above. It defaults to false and is declared LAST, so
    /// the memberwise initialiser every existing caller uses still compiles —
    /// the same rule that governs `SatchelCaptureView.incoming`.
    ///
    /// Why it is needed: a cancelled trip still has its dates, and without this
    /// it would keep auto-filling Kit right through the fortnight it was
    /// supposed to happen.
    var isCancelled: Bool = false

    /// A SIXTH field, added 2026-07-31, under the same rule as `isCancelled`
    /// above: defaults to false, declared last, so every existing memberwise
    /// call still compiles.
    ///
    /// Set on the Endeavor in Dayflow ("File captures to this endeavor"), and
    /// **seeded there from length** — on for trips over three days, off for
    /// short ones. David, after a day trip to Wisconsin: *"this one day trip
    /// wouldnt really qualify for auto stamping."* Everything captured across
    /// nine days in Japan belongs to Japan; most of what you capture on a day
    /// trip is just that day.
    var stampsCaptures: Bool = false

    var isTravel: Bool { type.caseInsensitiveCompare("Travel") == .orderedSame }

    /// Days before `start` that a trip's documents start appearing in Kit.
    ///
    /// Scope §5 justifies reserving Kit slots so four manual pins "cannot crowd
    /// the boarding pass out **on the day it matters**". Strict range membership
    /// read that as the departure date and nothing earlier, so the boarding pass
    /// appeared at midnight on the day of the flight and not a minute sooner —
    /// which is not when it matters. It matters the evening before, checking in
    /// and packing. David's number, 2026-07-29.
    static let kitLeadInDays = 3

    /// Days after `end` that they stay. The return leg is flown on the last day
    /// and receipts are collected on it, so Kit going dark at midnight on the
    /// final date drops the documents on the day they are still in use.
    static let kitTailDays = 1

    /// Days after `end` that a trip is still offered in the FILING pickers'
    /// main list, before it drops into their "Past" submenu.
    ///
    /// **A third window, and deliberately not either of the other two.** This file
    /// already refuses to collapse "has it started" into "do I need this in hand";
    /// filing is a third question again — *could this document belong to that
    /// trip*. Reusing `kitTailDays` would push a trip out of the way the morning
    /// after it ended, and the last day's receipts are filed the next morning.
    ///
    /// **David's number, 2026-08-01, and he chose the short one.** The first
    /// version of this was 30, argued from late-arriving receipts and statements.
    /// He overruled it: *"3 days. I can always go one menu item deeper (eg past)
    /// if i have to."* Which is the better read of the trade — the submenu means
    /// nothing is ever unfileable, so the only thing a long tail buys is fewer
    /// taps in the rare late case, paid for with a cluttered menu in the common
    /// one. Optimise the common case; the rare one has a door.
    ///
    /// Nothing is lost past this line. This number decides ordering and
    /// prominence, never possibility. That is what made it safe to pick.
    static let filingTailDays = 3

    /// True when this trip is near enough that its documents belong to hand.
    ///
    /// **NOT the same question as "has it started".** Dayflow's
    /// `Endeavor.status(on:)` answers that one, and must stay strict: a trip
    /// starting tomorrow reads `upcoming` on the Endeavor screen even while its
    /// papers are already in Kit. Kit asks "do I need this now?", the screen asks
    /// "has it begun?", and collapsing the two into one predicate would make the
    /// screen lie about the trip's status.
    ///
    /// Renamed from `isActive(on:)` on 2026-07-29 for exactly that reason — the
    /// old name invited the two to be treated as one thing.
    ///
    /// Depends on nothing but the contract fields plus the two windows above, so
    /// there is no state to clean up when a trip ends.
    func isKitRelevant(on date: Date) -> Bool {
        guard isTravel, !isCancelled else { return false }
        // A Travel Endeavor with no dates at all is never relevant — otherwise
        // every undated trip would permanently occupy half the Kit grid.
        guard start != nil || end != nil else { return false }

        let cal = Calendar.current
        let day = cal.startOfDay(for: date)

        if let start {
            let opens = cal.date(byAdding: .day, value: -Self.kitLeadInDays,
                                 to: cal.startOfDay(for: start))
            if let opens, day < opens { return false }
        }
        if let end {
            let closes = cal.date(byAdding: .day, value: Self.kitTailDays,
                                  to: cal.startOfDay(for: end))
            if let closes, day > closes { return false }
        }
        return true
    }

    /// A clause that reads grammatically after the trip's name: *"starts in 3
    /// days"*, *"runs through Jul 31"*, *"ended yesterday"*.
    ///
    /// EXISTS BECAUSE THE OLD WORDING BECAME FALSE. Kit now holds a trip's
    /// documents when the trip is not running at all — three days before it
    /// starts, a day after it ends — and every string that said "while Japan is
    /// running" or "from Japan through Jul 31" was flatly wrong in those windows.
    /// David caught it the day it shipped: a trip starting tomorrow was described
    /// as running through the 31st.
    ///
    /// One helper, used by the Library footnote, the document caption and the Kit
    /// screen, so three strings about the same fact cannot drift apart.
    ///
    /// Relative wording up close and an absolute date further out, deliberately.
    /// "starts in 3 days" is what you want to know when it is soon; "runs through
    /// Jul 31" is what you want once it is under way, because by then the question
    /// is when it stops rather than how far off it is.
    func kitTimingPhrase(on date: Date = Date()) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: date)
        func days(from: Date, to: Date) -> Int {
            cal.dateComponents([.day], from: from, to: to).day ?? 0
        }
        // No POSIX locale here, unlike the parsing formatters: this one is read
        // by a human, so month names should follow the device.
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"

        if let start {
            let s = cal.startOfDay(for: start)
            if today < s {
                let n = days(from: today, to: s)
                return n == 1 ? "starts tomorrow" : "starts in \(n) days"
            }
            // Departure day. Said before anything about the end date, because on
            // the day itself that is the fact that matters.
            if today == s { return "starts today" }
        }

        if let end {
            let e = cal.startOfDay(for: end)
            if today > e {
                let n = days(from: e, to: today)
                return n == 1 ? "ended yesterday" : "ended \(n) days ago"
            }
            switch days(from: today, to: e) {
            case 0:  return "ends today"
            case 1:  return "ends tomorrow"
            default: return "runs through \(fmt.string(from: e))"
            }
        }

        return "is under way"
    }
}

// MARK: - Endeavor store

/// Reads the Endeavor notes out of the shared container.
///
/// WAS A STUB UNTIL 2026-07-29, and this is worth knowing because the stub was
/// correct when it was written. Scope §3 planned Endeavors as rows in a Notion
/// database, so this returned an empty list on device rather than fixture data,
/// deliberately, so nothing downstream would be built against values that would
/// not exist on first run.
///
/// Then the design changed: **an Endeavor is a note**, in `Notes/Endeavors`, with
/// its fields in frontmatter (see `Endeavor-Design.md`). Dayflow was given a
/// full store for them and this end was never reconnected — so on David's phone
/// the Endeavor picker was permanently empty, and Kit's auto-trip membership,
/// the Endeavor browse chip and Satchel's Endeavor screen were all dark behind
/// it. Nothing was broken; nothing was reachable either.
///
/// NO CACHING, on purpose. Every caller's `.task` rescans. Four apps write this
/// container, so a store that decides for itself when its data is fresh is the
/// bug this project hit four times in two days (see the chip-store history in
/// `Dayflow-HANDOFF.md`). There are tens of these files, not thousands.
///
/// DUPLICATED PARSING, acknowledged. `EndeavorStore` in Dayflow parses the same
/// frontmatter with the same fallbacks. It lives in `Dayflow/` and Satchel
/// cannot see it, and moving it into the shared `Trace/` group means editing
/// target membership by hand. The two must agree on: the folder, the `id`
/// fallback, the `type` default, and the date format. **Consolidate when a third
/// app needs to read Endeavors, not before** — one duplication is cheaper than a
/// cross-target file move done for tidiness.
@Observable
final class SatchelEndeavorStore {

    static let folder = "Notes/Endeavors"

    private(set) var endeavors: [Endeavor] = []
    private(set) var hasLoaded: Bool = false

    private var noteStore: NoteStore { .shared }

    /// Scans the folder and parses every note.
    ///
    /// Returns WITHOUT setting `hasLoaded` when the container is not available
    /// yet, so the next caller retries instead of trusting an empty list. That
    /// exact line — marking loaded after bailing early — is what made the
    /// document chips render empty for a whole session on 2026-07-28.
    func reload() async {
        guard noteStore.hasAccess else { return }

        let files = (try? noteStore.listFiles(in: Self.folder)) ?? []
        var parsed = files
            .filter { $0.hasSuffix(".md") }
            .compactMap { parse(filename: $0) }

#if targetEnvironment(simulator)
        // The Simulator has no iCloud container, so a fresh one finds nothing.
        // Seed data only when the real scan came up empty — never instead of it,
        // or a simulator test would stop exercising the parser.
        if parsed.isEmpty { parsed = SatchelSimulatorSeed.endeavors }
#endif

        endeavors = parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        hasLoaded = true
    }

    private func parse(filename: String) -> Endeavor? {
        let path = "\(Self.folder)/\(filename)"
        guard let raw = try? noteStore.readFile(path), !raw.isEmpty else { return nil }

        let fields = Self.frontmatter(raw)
        let fallbackName = (filename as NSString).deletingPathExtension

        // A note with no `id:` was written by hand, or predates the slug. Give it
        // a deterministic slug from its filename rather than skipping it: an
        // Endeavor that does not appear because of a field it never knew about is
        // worse than one whose slug is not pretty. Matches Dayflow exactly, so
        // both apps derive the SAME id for the same file — documents are filed
        // against that id, so disagreeing would file them into nothing.
        let id = fields["id"]?.nilIfEmptySatchel ?? Self.slug(from: fallbackName)

        return Endeavor(
            id: id,
            name: fields["name"]?.nilIfEmptySatchel ?? fallbackName,
            type: fields["type"]?.nilIfEmptySatchel ?? "Project",
            start: Self.date(fields["starts"]),
            end: Self.date(fields["ends"]),
            isCancelled: fields["status"]?.trimmingCharacters(in: .whitespaces).lowercased() == "cancelled",
            stampsCaptures: ["true", "yes", "y", "1"].contains(
                fields["stamp_captures"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
        )
    }

    func endeavor(id: String?) -> Endeavor? {
        guard let id else { return nil }
        return endeavors.first { $0.id == id }
    }

    /// The single trip whose documents belong in Kit today, if any. If two
    /// windows ever overlap, the one ending soonest wins — it is the one about to
    /// stop being relevant.
    ///
    /// "Active" here means **kit-relevant**, which includes the lead-in and tail
    /// windows — see `Endeavor.isKitRelevant(on:)`. It is not the same as the
    /// trip having started.
    func activeTrip(on date: Date = Date()) -> Endeavor? {
        endeavors
            .filter { $0.isKitRelevant(on: date) }
            .sorted { ($0.end ?? .distantFuture) < ($1.end ?? .distantFuture) }
            .first
    }

    /// What the filing pickers should offer, in the order worth offering it.
    ///
    /// David, 2026-08-01: *"satchel adding an endeavor to link to shouldn't
    /// surface items that are out of date (past their time period). Maybe the fact
    /// that the Bronwyn lunch is available is because it is only 1 day past and we
    /// gave that buffer?"*
    ///
    /// **It was not the buffer.** Both pickers walked `endeavors` raw — every trip
    /// ever, sorted by name, with no notion of a date anywhere in the path. The
    /// Bronwyn lunch was not showing because it had just ended; it would have been
    /// sitting there next year.
    ///
    /// `current` is what belongs in the menu:
    ///
    /// - anything undated, since "past its time period" cannot apply to it;
    /// - anything upcoming, because a booking confirmation is filed before you go;
    /// - anything running now;
    /// - anything that ended within `filingTailDays`.
    ///
    /// `past` is the rest, for the submenu. Cancelled trips are dropped from both:
    /// unlike an old trip, nothing will ever arrive that belongs to one.
    ///
    /// Ordered by how likely it is to be the answer rather than alphabetically —
    /// running now, then soonest upcoming, then most recently ended, then undated.
    /// Alphabetical put a trip from last spring above the one he was on.
    func filingChoices(on date: Date = Date()) -> (current: [Endeavor], past: [Endeavor]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: date)
        guard let horizon = cal.date(byAdding: .day, value: -Endeavor.filingTailDays, to: today)
        else { return (endeavors, []) }

        var current: [Endeavor] = []
        var past: [Endeavor] = []
        for e in endeavors where !e.isCancelled {
            guard let end = e.end.map({ cal.startOfDay(for: $0) }) else { current.append(e); continue }
            if end >= horizon { current.append(e) } else { past.append(e) }
        }

        /// 0 running, 1 upcoming, 2 recently ended, 3 undated.
        func rank(_ e: Endeavor) -> Int {
            let start = e.start.map { cal.startOfDay(for: $0) }
            let end   = e.end.map { cal.startOfDay(for: $0) }
            switch (start, end) {
            case (nil, nil):                       return 3
            case let (s?, e2?) where s <= today && today <= e2: return 0
            case let (s?, _) where s > today:      return 1
            case (_, _?):                          return 2
            default:                               return 3
            }
        }

        current.sort { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            switch ra {
            case 1:  return (a.start ?? .distantFuture) < (b.start ?? .distantFuture)  // soonest first
            case 2:  return (a.end ?? .distantPast) > (b.end ?? .distantPast)          // most recent first
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        past.sort { ($0.end ?? .distantPast) > ($1.end ?? .distantPast) }
        return (current, past)
    }

    /// The endeavor a capture made now should be filed to, or nil.
    ///
    /// **Deliberately not `activeTrip(on:)`.** That one means *kit-relevant* and
    /// includes the lead-in and tail windows, which is right for a shelf of
    /// documents you want in hand before you leave and is wrong here: a receipt
    /// scanned three days before a trip is not part of the trip. This uses the
    /// literal range, and only for endeavors that asked to be filed to.
    ///
    /// Soonest-ending wins when trips overlap, the same tiebreak the widget and
    /// the agenda use.
    func stampTarget(on date: Date = Date()) -> Endeavor? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: date)
        return endeavors
            .filter { e in
                guard e.stampsCaptures, !e.isCancelled,
                      let start = e.start, let end = e.end else { return false }
                return cal.startOfDay(for: start) <= today && today <= cal.startOfDay(for: end)
            }
            .sorted { ($0.end ?? .distantFuture) < ($1.end ?? .distantFuture) }
            .first
    }

    // MARK: Parsing — must stay in step with EndeavorStore in Dayflow

    /// Frontmatter fields only. Satchel never needs the body: it does not author
    /// or display Endeavor notes, it only files documents against them.
    private static func frontmatter(_ raw: String) -> [String: String] {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            let parts = line.split(separator: ":", maxSplits: 1)
                          .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            fields[parts[0].lowercased()] =
                parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return fields
    }

    static func slug(from name: String) -> String {
        let mapped = name.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "endeavor" : collapsed
    }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return iso.date(from: raw)
    }
}

private extension String {
    /// Named to avoid colliding with the `nilIfEmpty` already defined for the
    /// Dayflow store — Satchel and Dayflow share some files and a second
    /// fileprivate extension on String with the same member name is exactly the
    /// kind of ambiguity that only shows up when the two targets are built
    /// together.
    var nilIfEmptySatchel: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}


// MARK: - Kit preferences

/// How many of the four Library grid slots the active trip gets.
///
/// Scope §5 locks the grid at four tiles and defaults the split to 2 pins + 2
/// trip documents, with the stated reason that four manual pins must not be
/// able to crowd the boarding pass out on the day it matters. David asked for
/// the split itself to be adjustable (2026-07-27), so the default stands and
/// the number is now his to move per trip.
///
/// Stored in `UserDefaults`, keyed by Endeavor ID, because it is a **display
/// preference about a trip**, not document data. Nothing here belongs in a
/// sidecar (it describes no single document) and nothing here belongs in Notion
/// (scope §D4). Consequence: it does not follow you to another device. Fine for
/// an iOS-only v1; revisit if Satchel ever ships on the Mac.
enum SatchelKitPreferences {

    static let defaultTripSlots = 2
    static let range = 0...4

    private static func key(for endeavorID: String) -> String {
        "satchel.kit.tripSlots.\(endeavorID)"
    }

    static func tripSlots(for endeavorID: String?) -> Int {
        guard let endeavorID else { return defaultTripSlots }
        let stored = UserDefaults.standard.object(forKey: key(for: endeavorID)) as? Int
        return stored.map { min(max($0, range.lowerBound), range.upperBound) } ?? defaultTripSlots
    }

    static func setTripSlots(_ value: Int, for endeavorID: String) {
        UserDefaults.standard.set(min(max(value, range.lowerBound), range.upperBound),
                                  forKey: key(for: endeavorID))
    }
}

// MARK: - Kit

/// One member of Kit, and how it got there.
struct KitEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        /// `pinned: true` in the sidecar. Orange pushpin. Permanent until unpinned.
        case pinned
        /// Computed from `endeavor` + the Endeavor's date range plus the lead-in
        /// and tail windows. Indigo plane. Writes nothing to the sidecar and
        /// disappears a day after the trip ends.
        case activeTrip(endeavorName: String)
    }

    let document: TraceMacDocument
    let kind: Kind

    var id: String { document.relativePath }

    var isPinned: Bool {
        if case .pinned = kind { return true }
        return false
    }
}

/// The Kit assembly rules, kept out of the view so they can be read and changed
/// as rules. All of §5 "Kit display, overflow and sorting" lives here.
enum KitMembership {

    struct Layout {
        /// Exactly what the Library grid draws. Never more than 4.
        var grid: [KitEntry] = []
        /// Full membership, uncapped — what the Full Kit screen draws.
        var all: [KitEntry] = []
        var pinnedCount: Int = 0
        var tripCount: Int = 0
        var activeTrip: Endeavor?
        /// Grid slots currently reserved for the active trip. Meaningless with
        /// no trip; carried so the Kit screen can show and change it.
        var tripSlots: Int = SatchelKitPreferences.defaultTripSlots

        /// Scope §5: hidden entirely when Kit has 4 or fewer items, rather than
        /// sitting there dead — the grid is already showing everything.
        var showsSeeAll: Bool { all.count > 4 }

        /// Whether the Library should offer a way INTO the Kit screen at all.
        ///
        /// `showsSeeAll` alone was wrong, and David found it by asking whether he
        /// could still choose how many slots a trip gets. He can — the stepper is
        /// on the Kit screen — but with four or fewer items there was **no door to
        /// that screen**, so the setting existed and could not be reached. The
        /// original rule was written when the screen only listed documents; it
        /// now also holds the one control Kit has.
        var showsKitDoor: Bool { showsSeeAll || activeTrip != nil }

        /// "Show all" when there is more than the grid can hold, otherwise the
        /// door is really about the slots setting and should say so.
        var kitDoorLabel: String { showsSeeAll ? "Show all" : "Adjust" }
    }

    /// Grid is **always at most 4 tiles**. Kit's footprint on the Library never
    /// grows, whatever the trip size — only *which* four changes. With an active
    /// trip the split is 2 pins + 2 trip documents, and the slots are reserved so
    /// four manual pins cannot crowd the boarding pass out on the day it matters.
    /// If either side has fewer than its 2, the other backfills so the grid still
    /// fills out.
    static let gridCapacity = 4

    static func assemble(
        documents: [TraceMacDocument],
        endeavors: [Endeavor],
        today: Date = Date()
    ) -> Layout {
        var result = Layout()

        // --- Manual pins ---
        // Scope §5 locks the sort to "user order, drag to reorder, default =
        // order pinned" — muscle memory is most of the value on a grab-it-fast
        // surface, and a passport that moves because something else became more
        // relevant is worse than useless in a queue.
        //
        // `kit_order` (Session 50, sixth sidecar key) carries that order.
        // Documents pinned before the key existed have none, and sort AFTER the
        // ordered ones by capture date, so they land at the end instead of
        // shuffling to the front on first launch.
        let pinned = documents
            .filter(\.pinned)
            .sorted { lhs, rhs in
                switch (lhs.kitOrder, rhs.kitOrder) {
                case let (l?, r?): return l < r
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):
                    return (lhs.created ?? .distantPast) < (rhs.created ?? .distantPast)
                }
            }

        // --- Active-trip documents ---
        let trip = endeavors
            .filter { $0.isKitRelevant(on: today) }
            .sorted { ($0.end ?? .distantFuture) < ($1.end ?? .distantFuture) }
            .first
        result.activeTrip = trip

        var tripDocs: [TraceMacDocument] = []
        if let trip {
            // Your order first, then the fallback. §5 asks for **imminence**
            // (nearest date first) and that is still not expressible: no
            // sidecar key carries a per-document event date, and `created` is a
            // capture timestamp that always points backwards. So an explicit
            // `kit_order` wins where you have set one, and everything else
            // falls back to most-recently-added — which is a decent proxy for a
            // trip you are actively assembling, and a poor one on flight day.
            tripDocs = documents
                .filter { $0.endeavor == trip.id && !$0.pinned }
                .sorted { lhs, rhs in
                    switch (lhs.kitOrder, rhs.kitOrder) {
                    case let (l?, r?): return l < r
                    case (nil, _?):    return false
                    case (_?, nil):    return true
                    case (nil, nil):
                        return (lhs.created ?? .distantPast) > (rhs.created ?? .distantPast)
                    }
                }
        }

        result.pinnedCount = pinned.count
        result.tripCount = tripDocs.count

        let pinnedEntries = pinned.map { KitEntry(document: $0, kind: .pinned) }
        let tripEntries = tripDocs.map {
            KitEntry(document: $0, kind: .activeTrip(endeavorName: trip?.name ?? "Trip"))
        }

        // Full membership is uncapped: any number may be pinned and they all
        // live on the Full Kit screen. Only the grid is capped.
        result.all = pinnedEntries + tripEntries

        // --- Grid allocation ---
        //
        // The reserved trip share is David's to set per trip (default 2, scope
        // §5). Whatever it is, the grid is still exactly four tiles: only which
        // four changes. Backfill runs BOTH directions, so a side with fewer
        // than its reservation hands the surplus over rather than leaving a
        // hole — four pins and no trip is four pins, no pins and a live trip is
        // four trip documents.
        if tripEntries.isEmpty {
            result.grid = Array(pinnedEntries.prefix(gridCapacity))
        } else {
            let reserved = SatchelKitPreferences.tripSlots(for: trip?.id)
            result.tripSlots = reserved

            var tripSlots = min(reserved, gridCapacity)
            var pinnedSlots = gridCapacity - tripSlots

            if pinnedEntries.count < pinnedSlots {
                tripSlots += pinnedSlots - pinnedEntries.count
                pinnedSlots = pinnedEntries.count
            }
            if tripEntries.count < tripSlots {
                pinnedSlots += tripSlots - tripEntries.count
                tripSlots = tripEntries.count
            }
            pinnedSlots = min(pinnedSlots, pinnedEntries.count)

            result.grid =
                Array(pinnedEntries.prefix(pinnedSlots)) +
                Array(tripEntries.prefix(tripSlots))
        }

        return result
    }

    /// The footnote under the grid: *"4 of 11 · 2 pinned, 2 from Japan (starts
    /// tomorrow)."* Informational first, tappable second — scope §5 is explicit
    /// that it must not be the only door to the full list.
    ///
    /// The timing is parenthesised rather than run on with a comma because the
    /// outer list is already comma-joined, and "2 from Japan, starts tomorrow, 2
    /// pinned" reads as three items instead of two.
    static func footnote(for result: Layout) -> String? {
        guard !result.all.isEmpty else { return nil }
        var parts: [String] = []
        if result.pinnedCount > 0 {
            parts.append("\(result.pinnedCount) pinned")
        }
        if result.tripCount > 0, let trip = result.activeTrip {
            let phrase = "\(result.tripCount) from \(trip.name) (\(trip.kitTimingPhrase()))"
            parts.append(phrase)
        }
        guard !parts.isEmpty else { return nil }
        let shown = min(result.grid.count, result.all.count)
        return "\(shown) of \(result.all.count) · " + parts.joined(separator: ", ")
    }
}
