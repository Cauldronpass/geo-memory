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
