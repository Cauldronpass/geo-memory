import Foundation
import Observation

// MARK: - Models

struct ThingsTask: Identifiable, Codable {
    let id: String                     // mapped from "uuid"
    let title: String
    let list: String?                  // mapped from "project_title" (area/project name)
    let scheduledDateString: String?   // mapped from "scheduled_date" ("yyyy-MM-dd" or "")
    /// Freeform notes text. Added 2026-07-20 alongside DayflowTaskEditSheet's
    /// notes field/quick-add's notes field — the Mini bridge now sends this on
    /// all four GET endpoints (always a real string, "" for a to-do with no
    /// notes, never missing/null). Optional here anyway so decoding an old
    /// cached response from before this change (UserDefaults cache, see
    /// saveCache()/loadCache() below) doesn't fail — a missing key just
    /// decodes to nil rather than throwing.
    let notes: String?
    /// Whether the underlying reminder has recurrence rules — drives the
    /// repeat glyph on the Today task card (Session 77, design doc). Defaulted
    /// and NOT in CodingKeys, so the legacy Things-bridge decode paths (and
    /// the UserDefaults response cache) are untouched; only
    /// ReminderTaskStore.task(from:) sets it.
    var repeats: Bool = false
    /// The reminder's creationDate as "yyyy-MM-dd" — the Inbox card's "Added
    /// Tuesday" line (Session 77, step c). Defaulted and NOT in CodingKeys,
    /// same reasoning as `repeats` above.
    var createdDateString: String? = nil
    /// The reminder's alarm time, localized short ("5:00 PM") — the bell on
    /// task rows (Session 77, the When card's REMIND toggle). Defaulted and
    /// NOT in CodingKeys, same reasoning as `repeats`.
    var alarmTimeString: String? = nil
    /// The reminder's `completionDate` as "yyyy-MM-dd" — the Logbook groups by
    /// it (Session 80). Defaulted and NOT in CodingKeys, same reasoning as
    /// `repeats` and `alarmTimeString` above: the legacy Things-bridge decode
    /// paths and the UserDefaults response cache are untouched, and only
    /// `ReminderTaskStore.task(from:)` ever sets it.
    ///
    /// Nil for everything that is not completed, which is nearly every task the
    /// app handles — a Logbook row is the exception, not the rule.
    var completedDateString: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "uuid"
        case title
        case list = "project_title"
        case scheduledDateString = "scheduled_date"
        case notes
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Real scheduled date, parsed from the Mini bridge's `scheduled_date` field.
    /// Added 2026-07-20 alongside the `/anytime` and `/upcoming` endpoints — needed
    /// so an edit (DayflowTaskEditSheet) always knows a task's true current date
    /// rather than risking a silent, destructive clear. Nil for undated tasks; the
    /// bridge sends `""` rather than omitting the key, so both are checked.
    var date: Date? {
        guard let s = scheduledDateString, !s.isEmpty else { return nil }
        return Self.dateFormatter.date(from: s)
    }

    /// See `createdDateString`.
    var createdDate: Date? {
        guard let s = createdDateString, !s.isEmpty else { return nil }
        return Self.dateFormatter.date(from: s)
    }
}

// MARK: - What a note actually contains

/// Session 80. David: "the tasks on the screen of the app that have notes have
/// no indication of that fact. This is true for IOS as well."
///
/// **Shared, and shared for a specific reason.** The Mac already had this test
/// living privately inside `MacTaskRow`, and the iOS rows had nothing. Fixing
/// the Mac alone would have left two apps disagreeing about what "has a note"
/// means, which is the same shape as the markdown-renderer drift this project
/// has already paid for once. The test belongs to the MODEL, not to a row.
extension ThingsTask {

    /// The scheme match is CASE-INSENSITIVE, and that is not defensiveness:
    /// David's own note reads `Shortcuts://run-shortcut?name=monarch` with a
    /// capital S, which is perfectly legal (RFC 3986) and which the first
    /// version of this silently missed.
    static let shortcutScheme = "shortcuts://"

    static func isShortcutLine(_ text: any StringProtocol) -> Bool {
        text.range(of: shortcutScheme, options: .caseInsensitive) != nil
    }

    // MARK: - Linked Satchel documents (Session 80, D227)

    /// Marker prefix for a document link. One line per document:
    /// `satchel:doc:Documents/2026/2026-07-02-143022-tax-bill.pdf`
    ///
    /// **The PATH, not the title.** The title is editable in the sidecar and
    /// nothing makes it unique — two years of property tax bills are both
    /// "Property tax bill", and a title-keyed link resolves to whichever the
    /// store returns first. `TraceMacDocument.id` is no use either: it is a
    /// fresh `UUID()` on every load. `relativePath` is the only stable handle,
    /// and it is genuinely stable — `moveDocument` was removed in Session 69
    /// and `Documents-App-Scope.md` records that the move command "was never
    /// built, deliberately". Documents are imported under a timestamped name
    /// and never move; refiling edits the sidecar.
    ///
    /// **A marker line, not a `[[wikilink]]`.** Wikilinks match on NAME, which
    /// is the one property this link must not depend on. The notes field
    /// already carries two kinds of machinery stripped from prose — the
    /// Shortcuts URL and `dayflow:birthday:<personID>:<kind>` — and this is the
    /// third of those, not a fourth kind of thing.
    ///
    /// **No cached title.** The chip resolves against the live document store,
    /// the way the person and place chips resolve against Notion. A cached
    /// title would go stale the first time he retitles a sidecar, and a link
    /// that displays one name while pointing at another is worse than one that
    /// briefly says nothing.
    static let documentMarkerPrefix = "satchel:doc:"

    static func isDocumentLine(_ text: any StringProtocol) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix(documentMarkerPrefix)
    }

    /// Relative paths of every linked document, in the order written.
    var linkedDocumentPaths: [String] {
        guard let notes else { return [] }
        return notes.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line in
                let s = line.trimmingCharacters(in: .whitespaces)
                guard s.hasPrefix(Self.documentMarkerPrefix) else { return nil }
                let path = String(s.dropFirst(Self.documentMarkerPrefix.count))
                    .trimmingCharacters(in: .whitespaces)
                return path.isEmpty ? nil : path
            }
    }

    var hasLinkedDocuments: Bool { !linkedDocumentPaths.isEmpty }

    /// Web URLs sitting in the note.
    ///
    /// Scanned rather than run through `NSDataDetector`: the detector matches
    /// bare hostnames and email addresses too, and "carries a link" has to mean
    /// something a click can follow, not something that looks vaguely like an
    /// address. `shortcuts://` cannot match, so the bolt and this stay separate
    /// marks about separate things.
    var webLinks: [URL] {
        guard let notes, notes.contains("://") else { return [] }
        var out: [URL] = []
        for field in notes.split(whereSeparator: { $0.isWhitespace }) {
            let raw = field.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[],."))
            let lower = raw.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
                  let url = URL(string: raw) else { continue }
            out.append(url)
        }
        return out
    }

    var hasWebLink: Bool { !webLinks.isEmpty }

    /// Does this task point at something you could open?
    ///
    /// **A web page or a Satchel document, and deliberately NOT `[[wikilinks]]`.**
    /// A mark that also covered those would mean "this row has some machinery
    /// on it", and the note mark's own reasoning says why that is the wrong
    /// kind of mark: one that means "this row has SOMETHING" is one you learn
    /// to stop reading. Wikilinks are associations to records inside the app
    /// and already render as chips; this mark is about an attachment pointing
    /// OUT — a page, a file.
    var hasFollowableLink: Bool { hasWebLink || hasLinkedDocuments }

    /// The note with its machinery removed: `[[link]]` lines, which are drawn
    /// as chips, the Shortcuts URL, which is drawn as a bolt, and
    /// `satchel:doc:` markers, which are drawn as document chips.
    ///
    /// This is what "has a note" has to mean. A task whose entire note is a
    /// shortcut URL is already fully represented by its bolt, and marking it as
    /// having a note too would make the mark mean "this row has SOMETHING" —
    /// a mark you learn to stop reading.
    ///
    /// **Shared, so the phone strips the document marker too.** This type lives
    /// here rather than on the Mac precisely so a marker written on the Mac
    /// does not surface as a line of prose in Dayflow. iOS gets the filtering
    /// the moment this ships, and grows the chip whenever it grows the chip.
    /// Is this line machinery rather than something he wrote?
    ///
    /// **The single definition, and it has to stay single.** `noteProse` strips
    /// these lines out for display; the Mac card's `rebuiltNotes` puts them back
    /// when saving an edited note. Those were two separate predicates until
    /// Session 80 and they had ALREADY drifted: the document marker (D227) was
    /// added to the reader and not the writer, so editing a note would have
    /// silently deleted every document link on the task.
    ///
    /// That is the exact failure the note above `rebuiltNotes` was written to
    /// warn about, reintroduced by the next person to add a line kind. One
    /// function, both callers, so a fifth kind cannot repeat it.
    static func isMachineryLine(_ text: any StringProtocol) -> Bool {
        let s = text.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("[[") || isShortcutLine(s) || isDocumentLine(s)
    }

    var noteProse: String {
        guard let notes else { return "" }
        return notes.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !ThingsTask.isMachineryLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasNoteProse: Bool { !noteProse.isEmpty }
}

private struct ThingsResponse: Decodable {
    let today: [ThingsTask]
    let inboxCount: Int

    enum CodingKeys: String, CodingKey {
        case today
        case inboxCount = "inbox_count"
    }
}

private struct AnytimeResponse: Decodable {
    let anytime: [ThingsTask]
}

private struct UpcomingResponse: Decodable {
    let upcoming: [ThingsTask]
}

private struct InboxResponse: Decodable {
    let inbox: [ThingsTask]
}

private struct UpdateResponse: Decodable {
    let success: Bool
}

// ThingsService (the Things 3 URL-scheme/AppleScript bridge, ~550 lines)
// DELETED in the Session 78 housekeeping pass (2026-08-29): Things was
// retired and the class had zero call sites left — every consumer moved to
// ReminderTaskStore. ThingsTask above SURVIVES as the app-wide task model
// (its name is historical; renaming it is a large mechanical pass logged in
// Trace-Backlog.md, not smuggled into a deletion).
