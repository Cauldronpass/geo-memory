import EventKit
import SwiftUI
import Observation

// MARK: - Model

struct NextCalendarEvent: Identifiable {
    var id: String { "\(startDate.timeIntervalSinceReferenceDate)-\(title)" }
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarTitle: String
    let isAllDay: Bool
    let colorR: Double
    let colorG: Double
    let colorB: Double

    // Widened 2026-07-21 (tap-a-calendar-event-for-details backlog item) —
    // everything below was NOT here before. `makeEvent(_:)` at the bottom of
    // this file is the only place that constructs a `NextCalendarEvent`, so
    // it's the only other spot touched to populate these. Kept the original
    // eight fields/id scheme untouched — every existing caller (Agenda,
    // Upcoming, Agenda Search, Trace's own Home widget) keeps working exactly
    // as before; this only adds new read surface for the new detail view
    // (`DayflowEventDetailView.swift`).
    let location: String?
    let notes: String?
    /// `EKEvent.url` — often where a conferencing add-on (Zoom, etc.) puts
    /// its join link directly, separate from `location`/`notes` text.
    let url: URL?
    /// Display names only (`EKParticipant.name`, falling back to the
    /// `mailto:` address when the name itself is nil — see
    /// `participantDisplayName(_:)` below) — Dayflow has no reason to surface
    /// participant status/role/type, just "who's on this." Empty when the
    /// event has no attendees or Calendar access can't see them.
    let attendeeNames: [String]
    /// The event's organizer, kept separate from `attendeeNames` — some
    /// calendar providers (Exchange/Office 365 in particular) don't include
    /// the organizer in `.attendees` at all, only in `.organizer`, so this
    /// can be populated even when `attendeeNames` is empty. Added 2026-07-21
    /// alongside the `participantDisplayName(_:)` fallback, same day David
    /// found a Teams-meeting event with no visible attendee data at all.
    let organizerName: String?
    /// `EKEvent.eventIdentifier` — not used for anything yet (this struct's
    /// `id` above is unchanged, still the synthesized start-date+title
    /// string), but stored since a real stable identifier is the kind of
    /// thing worth having once it exists rather than re-adding later.
    let eventIdentifier: String?

    var color: Color { Color(red: colorR, green: colorG, blue: colorB) }

    /// Best-effort "join this meeting" link for the detail view. Checks
    /// `url` first (the most authoritative source — many conferencing
    /// integrations set this directly to the join link), then scans
    /// `location` and `notes` text for the first `http(s)` URL found (Google
    /// Meet/Zoom links are commonly pasted into one of those two rather than
    /// `url` itself, depending on how the invite was created). Returns nil
    /// if none of the three have a link — never guesses.
    var videoLink: URL? {
        if let url { return url }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in [location, notes] {
            guard let text, let detector else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = detector.firstMatch(in: text, range: range), let matchURL = match.url {
                return matchURL
            }
        }
        return nil
    }

    var startTimeString: String {
        guard !isAllDay else { return "All day" }
        return DateFormatter.localizedString(from: startDate, dateStyle: .none, timeStyle: .short)
    }

    var timeLabel: String {
        guard startDate > Date() else { return "Now" }
        let mins = Int(startDate.timeIntervalSinceNow / 60)
        guard mins > 0 else { return "Now" }
        if mins < 60 { return "in \(mins)m" }
        let h = mins / 60; let m = mins % 60
        return m > 0 ? "in \(h)h \(m)m" : "in \(h)h"
    }

    var durationLabel: String {
        guard !isAllDay else { return "All day" }
        let mins = Int(endDate.timeIntervalSince(startDate) / 60)
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60; let m = mins % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    /// Label used in the "no events" empty state to show when the next event is.
    var nextEventLabel: String {
        let cal = Calendar.current
        let timeStr = startTimeString
        if cal.isDateInToday(startDate)    { return "Today · \(timeStr)" }
        if cal.isDateInTomorrow(startDate) { return "Tomorrow · \(timeStr)" }
        let f = DateFormatter(); f.dateFormat = "EEEE · h:mm a"
        return f.string(from: startDate)
    }
}

// MARK: - Service

@Observable
final class CalendarService {
    static let shared = CalendarService()
    private init() {}

    private let store = EKEventStore()

    // Title substrings that should never appear on the Home screen.
    // "travel to the office" is a phrase match — "travel" alone is intentionally NOT excluded
    // because David manages the travel team and has many legitimate travel-related events.
    private static let excludedPhrases: [String] = [
        "hold",
        "rehab",
        "blood",
        "travel to the office",
        "you're invited",
        "townhall"
    ]

    private func shouldExclude(title: String) -> Bool {
        let lower = title.lowercased()
        return Self.excludedPhrases.contains { lower.contains($0) }
    }

    /// Max events shown in the Home calendar section.
    private let maxEvents = 5

    /// Events within the next 18 hours (excluding all-day unless setting enabled).
    var upcomingEvents: [NextCalendarEvent] = []

    /// Next event beyond the 18-hour window — used for the empty-state "next up" hint.
    var nextEventBeyondWindow: NextCalendarEvent?

    var showAllDayEvents: Bool {
        UserDefaults.standard.bool(forKey: "cal_show_all_day")
    }

    private var hasAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17, *) { return status == .fullAccess }
        return status == .authorized
    }

    func requestAndFetch() async {
        if !hasAccess {
            if #available(iOS 17, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { _, _ in cont.resume() }
                }
            }
        }
        await fetchUpcomingEvents()
    }

    @MainActor
    func fetchUpcomingEvents() async {
        guard hasAccess else { return }
        let now = Date()
        let windowEnd = Calendar.current.date(byAdding: .hour, value: 18, to: now) ?? now

        let pred = store.predicateForEvents(withStart: now, end: windowEnd, calendars: nil)
        let events = store.events(matching: pred)
            .filter { showAllDayEvents || !$0.isAllDay }
            .filter { $0.status != .canceled }
            .filter { !shouldExclude(title: $0.title ?? "") }
            .sorted { $0.startDate < $1.startDate }

        upcomingEvents = Array(events.prefix(maxEvents)).map { makeEvent($0) }

        // If window is empty after filtering, peek up to 7 days ahead for the next event
        if upcomingEvents.isEmpty {
            let farEnd = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
            let farPred = store.predicateForEvents(withStart: windowEnd, end: farEnd, calendars: nil)
            let farEvents = store.events(matching: farPred)
                .filter { showAllDayEvents || !$0.isAllDay }
                .filter { $0.status != .canceled }
                .filter { !shouldExclude(title: $0.title ?? "") }
                .sorted { $0.startDate < $1.startDate }
            nextEventBeyondWindow = farEvents.first.map { makeEvent($0) }
        } else {
            nextEventBeyondWindow = nil
        }
    }

    // MARK: - Dayflow: arbitrary-day fetch
    //
    // Added 2026-07-19 for Dayflow's Agenda section (Dayflow-Design-Plan.md
    // "Agenda section"; build order step 3). Deliberately separate from
    // `fetchUpcomingEvents()` above (Trace's Home-screen widget: a rolling
    // 18-hour window, all-day events excluded unless a setting is on, and a
    // title-phrase exclusion list) — Dayflow's Agenda is a full calendar-day
    // view for whichever day the user has selected (Yesterday/Today/Tomorrow),
    // always wants all-day events, and has no reason to apply Trace's
    // Home-widget exclusion list. Returns its result directly rather than
    // writing into `upcomingEvents`/`nextEventBeyondWindow`, so it can't touch
    // Trace's own Home screen state — safe to call from a different app target
    // sharing this file via target membership.
    //
    // **Calendar filter added 2026-07-20 (Session 14).** Now passes
    // `includedCalendarsForDayflow()` instead of `nil` — see that method's
    // comment for why this is safe to share with Trace's own
    // `fetchUpcomingEvents()` above, which deliberately keeps `calendars: nil`
    // untouched.
    func fetchDayEvents(for date: Date) async -> [NextCalendarEvent] {
        if !hasAccess {
            if #available(iOS 17, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { _, _ in cont.resume() }
                }
            }
        }
        guard hasAccess else { return [] }

        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }

        let pred = store.predicateForEvents(withStart: start, end: end, calendars: includedCalendarsForDayflow())
        let events = store.events(matching: pred)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        return events.map { makeEvent($0) }
    }

    /// Timed-event count per day of `month` — the New Event composer's busy
    /// dots (Session 77, David: "i like the dot suggestion"). One ranged
    /// query over the same included calendars the day views use; all-day and
    /// canceled events skipped.
    /// Never-attend placeholder invites, hidden from every Dayflow event
    /// surface (Session 78 — "rehab" leaked back in when Session 77's
    /// DayflowTodaySection rewrite didn't inherit DayflowAgendaSection's
    /// filter, and Upcoming never had one). Keywords, substring,
    /// case-insensitive. The widget carries its own deliberate copy
    /// (DayflowWidget.swift) — change both.
    static let excludedTitleKeywords = ["rehab", "bewell", "trivia", "happy hour"]

    static func isExcludedPlaceholderTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return excludedTitleKeywords.contains { lower.contains($0) }
    }

    func fetchMonthEventCounts(for month: Date) async -> [Int: Int] {
        guard hasAccess else { return [:] }
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let end = cal.date(byAdding: .month, value: 1, to: start) else { return [:] }
        let pred = store.predicateForEvents(withStart: start, end: end,
                                            calendars: includedCalendarsForDayflow())
        let events = store.events(matching: pred)
            .filter { !$0.isAllDay }
            .filter { $0.status != .canceled }
            .filter { !shouldExclude(title: $0.title ?? "") }
        var counts: [Int: Int] = [:]
        for ev in events {
            counts[cal.component(.day, from: ev.startDate), default: 0] += 1
        }
        return counts
    }

    // MARK: - Dayflow: date-range fetch (Browse: Upcoming)
    //
    // Added 2026-07-20 for Dayflow's Upcoming browse view
    // (DayflowUpcomingView.swift, Dayflow-Design-Plan.md "Top bar &
    // navigation"; build order step 5). Kept separate from
    // `fetchDayEvents(for:)` (single day) and `fetchUpcomingEvents()` (Trace's
    // rolling 18h Home-widget window) for the same reason those two already
    // stay separate from each other — a distinct real query shape (an
    // arbitrary multi-day range, no exclusion list, no all-day-events
    // setting), added as its own method rather than overloading an existing
    // one's meaning. Grouping the flat result by day is the caller's job
    // (DayflowUpcomingView does this locally) — this just returns everything
    // in range, sorted. Also the same method `DayflowAgendaSearchView` uses
    // for its event search, so the calendar filter below applies there too.
    //
    // **Calendar filter added 2026-07-20 (Session 14).** Same as
    // `fetchDayEvents(for:)` above.
    func fetchEvents(from start: Date, to end: Date) async -> [NextCalendarEvent] {
        if !hasAccess {
            if #available(iOS 17, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { _, _ in cont.resume() }
                }
            }
        }
        guard hasAccess else { return [] }

        let pred = store.predicateForEvents(withStart: start, end: end, calendars: includedCalendarsForDayflow())
        let events = store.events(matching: pred)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        return events.map { makeEvent($0) }
    }

    // MARK: - Dayflow: available calendars (Settings, build order step 6)
    //
    // Added 2026-07-20 for DayflowSettingsView's "Default Calendar" picker.
    // Also now backs the "Calendars Shown in Agenda" checkbox list added
    // Session 14 — same list, two different Settings sections reading it.
    func availableCalendars() async -> [EKCalendar] {
        if !hasAccess {
            if #available(iOS 17, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { _, _ in cont.resume() }
                }
            }
        }
        guard hasAccess else { return [] }
        return store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    // MARK: - Dayflow: included-calendars read filter (Settings, added
    // Session 14, 2026-07-20)
    //
    // David asked directly for this: a checkbox list in Settings controlling
    // which calendars' events show up in the Agenda/Upcoming/Calendar-search
    // surfaces (e.g. hide Birthdays/Holidays, show two of several work +
    // personal calendars) — separate from the single "Default Calendar"
    // picker above, which only controls where a *new* event gets written
    // (an event can only belong to one calendar; this is a many-calendar
    // read filter, not a many-calendar write target).
    //
    // Stored as a comma-separated list of `EKCalendar.calendarIdentifier`
    // strings under `dayflow_included_calendar_ids` in Dayflow's own
    // `UserDefaults.standard` (not the shared App Group suite — this is a
    // Dayflow-only display preference, Trace has no equivalent setting and
    // never reads this key). An EMPTY stored value means "no filter
    // configured" — every calendar shows, matching the app's original
    // zero-config behavior from before this setting existed, so nobody's
    // Agenda goes silently empty just because they never opened Settings.
    // If the saved identifiers no longer resolve to any real calendar (all
    // deleted since), same fallback: show everything rather than nothing.
    //
    // Deliberately NOT used by Trace's own `fetchUpcomingEvents()` above —
    // that method keeps `calendars: nil` exactly as it always has. This is
    // safe even though the two apps share this source file via target
    // membership: `UserDefaults.standard` is scoped per app bundle ID
    // (com.david.Dayflow vs. com.david.Trace), so Trace's process will never
    // see this key populated, and Trace never calls the two Dayflow fetch
    // methods that read it.
    private func includedCalendarsForDayflow() -> [EKCalendar]? {
        let raw = UserDefaults.standard.string(forKey: "dayflow_included_calendar_ids") ?? ""
        guard !raw.isEmpty else { return nil }
        let ids = Set(raw.split(separator: ",").map(String.init))
        let matched = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        return matched.isEmpty ? nil : matched
    }

    // MARK: - Dayflow: create event (build order step 7)
    //
    // Added 2026-07-20. Quick-add's Event mode has always collected a date
    // (via the same When picker Task mode uses) plus separate Start/End time
    // pickers (`DayflowQuickAddSheet`'s `eventDate`/`eventStart`/`eventEnd`
    // — see that file), but until now `ContentView.swift`'s `saveDraft()`
    // just logged the draft instead of writing anything real.
    //
    // `date`/`startTime`/`endTime` are intentionally three separate
    // parameters rather than two already-combined `Date`s: `eventStart`/
    // `eventEnd` are driven by a SwiftUI `DatePicker(displayedComponents:
    // .hourAndMinute)`, which only ever changes the hour/minute of whatever
    // `Date` it's bound to — it does NOT track the day/month/year the user
    // separately picked via the Date pill (`eventDate`, a totally independent
    // `@State` var). Left uncombined, a start/end time picked while the sheet
    // was showing today's date, followed by jumping the Date pill to a future
    // day, would silently create the event on the WRONG day (today, not the
    // chosen date) — the time picker's stale day component would win if its
    // raw `Date` were used directly. Combining here, at the one place the
    // write actually happens, means the call site (`saveDraft()`) can just
    // pass the three pieces through as-is without needing to know about this
    // quirk itself.
    @discardableResult
    func createEvent(title: String, date: Date, startTime: Date, endTime: Date,
                      calendarIdentifier: String?, notes: String? = nil) async -> Bool {
        if !hasAccess {
            if #available(iOS 17, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { _, _ in cont.resume() }
                }
            }
        }
        guard hasAccess else {
            print("[CalendarService] createEvent skipped — no Calendar access")
            return false
        }

        let cal = Calendar.current
        let startTimeComps = cal.dateComponents([.hour, .minute], from: startTime)
        let endTimeComps = cal.dateComponents([.hour, .minute], from: endTime)
        guard let start = cal.date(bySettingHour: startTimeComps.hour ?? 0, minute: startTimeComps.minute ?? 0, second: 0, of: date) else {
            print("[CalendarService] createEvent failed — could not build start date")
            return false
        }
        guard var end = cal.date(bySettingHour: endTimeComps.hour ?? 0, minute: endTimeComps.minute ?? 0, second: 0, of: date) else {
            print("[CalendarService] createEvent failed — could not build end date")
            return false
        }
        // An end time earlier than (or equal to) the start time on the same
        // calendar day means the user picked something crossing midnight
        // (e.g. 11:30 PM → 12:15 AM) — push end to the next day rather than
        // silently saving a zero/negative-duration event.
        if end <= start {
            end = cal.date(byAdding: .day, value: 1, to: end) ?? end
        }

        // Resolve the target calendar: the identifier saved by
        // DayflowSettingsView's "Default Calendar" picker, if it's set and
        // still resolves to a real calendar (it could have been deleted
        // since); otherwise fall back to the OS-level default calendar for
        // new events, same as not picking one at all in Apple's own Calendar
        // app. No calendar at all (fresh device, nothing ever configured) is
        // a real failure, not silently guessed.
        let targetCalendar: EKCalendar?
        if let calendarIdentifier, !calendarIdentifier.isEmpty {
            targetCalendar = store.calendar(withIdentifier: calendarIdentifier)
        } else {
            targetCalendar = nil
        }
        guard let calendar = targetCalendar ?? store.defaultCalendarForNewEvents else {
            print("[CalendarService] createEvent failed — no default calendar available; set one in Dayflow Settings")
            return false
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = calendar

        do {
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            print("[CalendarService] createEvent failed to save: \(error.localizedDescription)")
            return false
        }
    }

    /// `EKParticipant.name` is frequently nil on Exchange/Office 365-synced
    /// calendars even when the participant is real (David found this
    /// 2026-07-21 — a Teams-meeting event organized by a colleague showed no
    /// Attendees section at all). Falls back to the address out of
    /// `.url` (a `mailto:` URL) so something real shows instead of the
    /// participant being silently dropped.
    private func participantDisplayName(_ p: EKParticipant) -> String? {
        if let name = p.name, !name.isEmpty { return name }
        // `EKParticipant.url` is non-optional (always returns *something*,
        // sometimes a generated identifier), so no `if let` here — build
        // error fixed 2026-07-21, David's Xcode run caught two real compile
        // errors this line originally had: (1) `if let url = p.url` doesn't
        // compile since `p.url` isn't Optional, and (2) `URL` has no
        // `.resourceSpecifier` member in Swift (that's an NSURL-only API,
        // not bridged) — replaced with plain string slicing instead, which
        // needs nothing but `.absoluteString`.
        let raw = p.url.absoluteString
        guard raw.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(raw.dropFirst("mailto:".count))
        return address.isEmpty ? nil : address
    }

    private func makeEvent(_ ev: EKEvent) -> NextCalendarEvent {
        let comps = ev.calendar?.cgColor?.components ?? [0.22, 0.36, 0.93, 1.0]
        // Reading `.attendees` unconditionally now (previously gated behind
        // `ev.hasAttendees`) — dropped that gate 2026-07-21 after finding it
        // unreliable on an Exchange/Office 365-synced Teams-meeting event:
        // `hasAttendees` came back false even though the event had a real
        // organizer and at least one other invitee. Reading `.attendees`
        // directly is the same cost either way (EventKit doesn't lazily fetch
        // it), so there was no real reason to gate on it.
        let attendeeNames = (ev.attendees ?? []).compactMap { participantDisplayName($0) }
        let organizerName = ev.organizer.flatMap { participantDisplayName($0) }
        return NextCalendarEvent(
            title: ev.title ?? "Event",
            startDate: ev.startDate,
            endDate: ev.endDate,
            calendarTitle: ev.calendar?.title ?? "",
            isAllDay: ev.isAllDay,
            colorR: comps.count > 0 ? Double(comps[0]) : 0.22,
            colorG: comps.count > 1 ? Double(comps[1]) : 0.36,
            colorB: comps.count > 2 ? Double(comps[2]) : 0.93,
            location: ev.location,
            notes: ev.notes,
            url: ev.url,
            attendeeNames: attendeeNames,
            organizerName: organizerName,
            eventIdentifier: ev.eventIdentifier
        )
    }
}
