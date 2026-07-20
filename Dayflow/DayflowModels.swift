import Foundation

// MARK: - Dayflow Quick-Add Models
//
// Shared types for the quick-add half-sheet (Dayflow-Design-Plan.md, "Quick-add
// half-sheet" section; ground truth is Dayflow-Mockup.html). Kept in their own
// file since both DayflowQuickAddSheet and DayflowWhenPickerSheet reference them.

/// Event vs. Task toggle at the top of the quick-add sheet.
enum DayflowEntryKind: String {
    case event
    case task
}

/// The value chosen in the When? picker. `.today` and `.date` are valid for both
/// Event and Task; `.thisEvening` and `.someday` are Task-only Things concepts
/// (mirrors `taskQuickPicks`/`taskQuickPicks2` being hidden in Event mode in the
/// mockup's `applyMode()`).
enum DayflowWhenValue: Equatable {
    case none
    case today
    case thisEvening
    case date(Date)
    case someday

    var label: String {
        switch self {
        case .none:         return "No date"
        case .today:        return "Today"
        case .thisEvening:  return "This Evening"
        case .someday:      return "Someday"
        case .date(let d):
            let f = DateFormatter()
            f.dateFormat = "EEE MMM d"
            return f.string(from: d)
        }
    }

    /// True for the two Things-native buckets that the Mac Mini bridge's `/add`
    /// endpoint can't express (it only takes an arbitrary date) — see
    /// Dayflow-Design-Plan.md "Open questions": whether these should fire the
    /// Things URL scheme directly from-device instead. Not yet resolved.
    var isThingsNativeBucket: Bool {
        switch self {
        case .thisEvening, .someday: return true
        default: return false
        }
    }
}

/// The result handed back from DayflowQuickAddSheet on Save. The sheet itself
/// only builds this — actually persisting it (ThingsService.addTask / a future
/// EventKit write) is the caller's job, so the sheet stays reusable.
struct DayflowQuickAddDraft {
    var kind: DayflowEntryKind
    var title: String
    var when: DayflowWhenValue
    var list: String?          // Things area/project name, exact match, Task only
    var eventDate: Date        // Event mode only
    var eventStart: Date       // Event mode only
    var eventEnd: Date         // Event mode only
}

// MARK: - Things areas (quick-insert chip row)

enum DayflowThingsAreas {
    /// David's real Things areas, shown without emoji per the confirmed spec —
    /// the real Things data keeps emoji prefixes (e.g. "🏡Home and Household"),
    /// but the chip always inserts/sends the exact real name under the hood.
    /// See Dayflow-Design-Plan.md "Open questions" — list-name normalization for
    /// freehand-typed names is still open; chip taps are unaffected by it.
    static let displayNames = [
        "Personal", "Relationships", "Finance", "Home and Household",
        "Health", "Routines", "Someday"
    ]
}

// MARK: - Agenda section models
//
// Dayflow-Design-Plan.md "Agenda section" / Dayflow-Mockup.html's #agendaSection.
// The main screen's `Yesterday / Today / Tomorrow` day-pill and the Agenda
// card's two-column split (all-day events + no-date tasks mixed on the left,
// timed events on the right).

/// The three days the top-bar pill switches between. Real `Date` math, not
/// fixed demo strings like the mockup's static `dayContent` object — selecting
/// a day here should actually change what's fetched.
enum DayflowRelativeDay: Int, CaseIterable, Identifiable {
    case yesterday = -1
    case today = 0
    case tomorrow = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .yesterday: return "Yesterday"
        case .today:     return "Today"
        case .tomorrow:  return "Tomorrow"
        }
    }

    /// Start-of-day `Date` for this relative day, computed off `reference`
    /// (defaults to now) rather than hardcoded — unlike the mockup, which only
    /// ever shows "Sunday, 19 July" because it's a static demo.
    func date(relativeTo reference: Date = Date()) -> Date {
        let cal = Calendar.current
        let startOfReference = cal.startOfDay(for: reference)
        return cal.date(byAdding: .day, value: rawValue, to: startOfReference) ?? startOfReference
    }
}

/// A single row in the Agenda's two-column grid — a merged view over an
/// EventKit `NextCalendarEvent` (mixed in from CalendarService) or a Things
/// `ThingsTask`, whichever produced it. The column a row appears in and which
/// marker it gets (round checkbox vs. rounded-square event marker) is driven
/// by `kind` + `isAllDay`, mirroring the mockup's visual distinction between
/// "things you can complete" and "things you can't check off."
struct DayflowAgendaItem: Identifiable {
    enum Kind { case task, event }

    let id: String
    let kind: Kind
    let title: String
    /// All-day calendar event or a no-date Things task — both land in the
    /// left "All day / no time" column. `false` means a timed calendar event
    /// (right column); Things to-dos never have a time, so a task is always
    /// `isAllDay == true` here.
    let isAllDay: Bool
    /// Populated only for timed calendar events, e.g. "9:00 AM" — the right
    /// column's primary label, per the mockup (`.time` above `.title`).
    let timeLabel: String?
    /// Secondary caption under the title in the left column, e.g. "Calendar ·
    /// All day" for an event, or the Things list name for a task. Nil when
    /// there's nothing meaningful to show (unlisted task with no due-date
    /// data — see the "Overdue" note below).
    let metaLabel: String?
    /// The underlying `ThingsTask.id` — nil for calendar events (`kind ==
    /// .event`, never completable), populated for tasks. Added 2026-07-20
    /// after David found the Agenda's round checkboxes were purely decorative
    /// (Session 4 built the visual marker distinction but never wired a tap
    /// action) — DayflowAgendaSection.swift's checkbox `Button` now calls
    /// `ThingsService.complete(taskID:)` with this. See Dayflow-HANDOFF.md
    /// Session 6's second addendum.
    let taskID: String?
    /// The underlying `ThingsTask.date` — nil for calendar events and for
    /// undated tasks. Added 2026-07-20 (third addendum) alongside tap-to-edit:
    /// DayflowAgendaSection.swift's title tap opens DayflowTaskEditSheet, which
    /// needs the task's real current date to prefill correctly rather than
    /// risking a silent clear if the sheet assumed "no date."
    let taskDate: Date?

    // Note: the mockup shows an illustrative "Overdue" meta label on one demo
    // task, styled in red. `ThingsTask` (ThingsService.swift) doesn't carry a
    // due-date field today — only id/title/list — so there's no real data to
    // drive that state yet. Left out rather than faked; logged as an open
    // question in Dayflow-Design-Plan.md to revisit if/when the Mini bridge
    // starts surfacing due dates.
}

// MARK: - Browse views (Upcoming / Calendar / Anytime / Inbox)
//
// Added 2026-07-20, Dayflow-Design-Plan.md "Top bar & navigation" (build
// order step 5) — the destinations off the top-bar calendar icon's menu.
// `Identifiable` so ContentView.swift can drive a single
// `.fullScreenCover(item:)` off one optional value instead of separate Bool
// flags. See DayflowUpcomingView.swift, DayflowCalendarBrowseView.swift,
// DayflowAnytimeView.swift for the original three destinations.
//
// `.inbox` added 2026-07-20 (step 5b, new scope requested same day as the
// original three) — see DayflowInboxView.swift.
enum DayflowBrowseDestination: String, Identifiable {
    case upcoming, calendar, anytime, inbox
    var id: String { rawValue }
}
