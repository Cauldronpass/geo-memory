// DayflowWidget.swift — paste over the Xcode-generated widget file in the new
// DayflowWidget extension target.
//
// Medium-size Home Screen widget. Design locked with David 2026-07-24 across
// several mockup rounds (dayflow-widget-mockup-v5.html is the final one):
//   - Fantastical-style big date block (weekday in red, day number in ink,
//     both right-justified in a fixed-width column) alongside today's
//     TIMED events + open-time gap tiles — no tasks, no all-day events.
//   - White background, "Today" in blue, weather NOT built in this pass
//     (mocked visually for review only — flagged to David as its own real
//     chunk of scope, WeatherKit + location, not reused code like the
//     calendar part is; still an open decision, see Dayflow-HANDOFF.md).
//   - Two separate tap targets: the blue "+" opens Dayflow straight into
//     the quick-add sheet in Event mode (`dayflow://addEvent`), everywhere
//     else on the card just opens Dayflow (`dayflow://open`). Both need the
//     `dayflow` URL scheme registered on the Dayflow APP target's Info tab
//     (not this widget target) — see the walkthrough in the handoff.
//
// **Gap-tile logic is intentionally DUPLICATED here, not shared**, from
// DayflowAgendaSection.swift's private `timedRows(now:)`/`gapLabel(_:)`/
// `isExcludedPlaceholderTitle(_:)`. That existing code has a lot of
// carefully-tuned, explicitly-documented edge-case behavior (leading-gap
// suppression, past-meeting hiding, a tomorrow-preview chain) built up over
// several sessions — refactoring it into a shared file this session, with no
// way to compile/run and visually verify the live Agenda card afterward,
// carried real risk of a subtle regression to a feature that already works.
// This widget reimplements that behavior narrowly below rather than sharing
// the file outright. If the real Agenda's gap rules ever change, this needs
// a matching manual update — flagged here and in the handoff so that's not a
// silent trap later.
//
// **Tomorrow-preview, added 2026-07-25**: originally shipped WITHOUT the
// in-app Agenda's tomorrow-preview chain (reasoning at the time: a widget's
// own periodic refresh makes that nicety less valuable than it is on the
// live, seconds-ticking Agenda card). David reported "the next day's first
// meeting is not showing up" — turned out to be exactly this gap, not a bug
// — so it's now ported in too: once today's remaining events run out,
// `fetchEntry()` falls through to tomorrow's first timed event, same filters
// as DayflowAgendaSection.swift's `tomorrowFirstTimedEvent`. Rendered with
// the same lavender "TOMORROW" pill as the in-app `tomorrowPreviewRow` — see
// `DayflowWidgetRow.tomorrow` and `rowView`'s `.tomorrow` case below. The big
// date/weekday block and "TODAY" label are left showing today's real date
// either way, matching how the in-app version leaves its own day header
// alone too — only the row itself is tagged.
//
// **Known gap, flagged rather than silently handled**: DayflowAgendaSection
// filters out a small list of placeholder/never-attend meeting titles
// (`isExcludedPlaceholderTitle`, mirrored below) AND respects a
// user-configurable "which calendars to include" Settings preference
// (`CalendarService.includedCalendarsForDayflow()`, stored in Dayflow's own
// `UserDefaults.standard`). That preference is scoped per bundle ID — this
// widget extension has its own separate bundle ID/UserDefaults store from
// the main Dayflow app, so if David has ever actually set a calendar filter
// in Dayflow's Settings, this widget won't currently know about it and will
// show every calendar's events instead of the filtered subset. Harmless
// (shows MORE, not less) if no filter is set, which `includedCalendarsForDayflow`'s
// own comment says is the default/common case — but a real mismatch if a
// filter IS set. Fixing this for real means moving that preference into the
// shared `group.com.david.trace` App Group UserDefaults suite instead of
// `.standard` — not done here since it touches `CalendarService.swift`
// (shared with Trace) and wasn't part of what was asked; flagging as a
// known follow-up if it turns out to matter in practice.

import WidgetKit
import SwiftUI
import EventKit

// MARK: - Timeline Entry

struct DayflowWidgetEntry: TimelineEntry {
    let date: Date
    let rows: [DayflowWidgetRow]
    let calendarUnavailable: Bool
}

enum DayflowWidgetRow: Identifiable {
    case event(id: String, timeLabel: String, title: String)
    case gap(id: String, label: String)
    /// Tomorrow's first timed meeting, shown once today's remaining events
    /// run out — ported 2026-07-25 from DayflowAgendaSection.swift's own
    /// `.tomorrow` row/`tomorrowFirstTimedEvent`, which the widget originally
    /// shipped without (see this file's header comment). Distinct case
    /// (rather than reusing `.event`) so `rowView` can render the same
    /// "TOMORROW" pill tag the in-app version uses, instead of looking like
    /// one of today's own meetings.
    case tomorrow(id: String, timeLabel: String, title: String)

    var id: String {
        switch self {
        case .event(let id, _, _): return id
        case .gap(let id, _): return id
        case .tomorrow(let id, _, _): return id
        }
    }
}

// MARK: - Timeline Provider

struct DayflowProvider: TimelineProvider {

    func placeholder(in context: Context) -> DayflowWidgetEntry {
        DayflowWidgetEntry(
            date: .now,
            rows: [
                .event(id: "p1", timeLabel: "9:00 AM", title: "Team Standup"),
                .gap(id: "pg1", label: "1h 30m open"),
                .event(id: "p2", timeLabel: "10:30 AM", title: "SIF Financial Review"),
            ],
            calendarUnavailable: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DayflowWidgetEntry) -> Void) {
        Task { completion(await fetchEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DayflowWidgetEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            // No live "reload on save" hook exists for calendar events the
            // way Jot's widget gets one from CaptureView's commit() — nothing
            // in Dayflow writes a NEW event through a path this widget could
            // hook (Quick-add's Event mode goes through EventKit directly,
            // not a shared store this process observes). A 15-minute refresh
            // is a reasonable middle ground: frequent enough that "what's
            // open right now" stays roughly current, not so frequent it
            // burns WidgetKit's background budget.
            let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    // MARK: Gap-tile logic (deliberately duplicated — see file header)

    private static let minGapSeconds: TimeInterval = 30 * 60
    private static let excludedTitleKeywords = ["rehab", "bewell", "trivia", "happy hour"]

    private static func isExcludedPlaceholderTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return excludedTitleKeywords.contains { lower.contains($0) }
    }

    private static func gapLabel(_ seconds: TimeInterval) -> String {
        let mins = max(0, Int(seconds / 60))
        if mins < 60 { return "\(mins)m open" }
        let h = mins / 60, m = mins % 60
        return m > 0 ? "\(h)h \(m)m open" : "\(h)h open"
    }

    private static func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// Mirrors DayflowAgendaSection.swift's `tomorrowFirstTimedEvent` — same
    /// filters (non-all-day, non-placeholder), same "earliest start wins"
    /// selection. That one reads from a `tomorrowEvents` array already
    /// fetched by `loadDayData()`; this fetches directly since the widget has
    /// no equivalent standing state to read from.
    private static func tomorrowFirstTimedEvent(after now: Date) async -> NextCalendarEvent? {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) else { return nil }
        let events = await CalendarService.shared.fetchDayEvents(for: tomorrow)
        return events
            .filter { !$0.isAllDay }
            .filter { !Self.isExcludedPlaceholderTitle($0.title) }
            .min { $0.startDate < $1.startDate }
    }

    /// Checked directly via EventKit's own static API rather than adding a
    /// public accessor to `CalendarService.swift`'s private `hasAccess` —
    /// that file is shared with Trace, so this widget deliberately avoids
    /// touching it at all. `fetchDayEvents(for:)` returns `[]` both when
    /// there's genuinely nothing on the calendar AND when access isn't
    /// granted, so this is the only way to tell those two apart for the
    /// "Calendar unavailable" vs. "Nothing on your calendar" empty states.
    private static var hasCalendarAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17, *) { return status == .fullAccess }
        return status == .authorized
    }

    @MainActor
    private func fetchEntry() async -> DayflowWidgetEntry {
        let now = Date()
        guard Self.hasCalendarAccess else {
            return DayflowWidgetEntry(date: now, rows: [], calendarUnavailable: true)
        }
        let dayEvents = await CalendarService.shared.fetchDayEvents(for: now)
        let all = dayEvents
            .filter { !$0.isAllDay }
            .filter { !Self.isExcludedPlaceholderTitle($0.title) }
            .sorted { $0.startDate < $1.startDate }

        let visible = all.filter { $0.endDate > now }
        guard let first = visible.first else {
            // Tomorrow-preview, ported 2026-07-25 from
            // DayflowAgendaSection.swift's tomorrowFirstTimedEvent/`.tomorrow`
            // row (see this file's header comment for why the widget
            // originally shipped without it) — once today's remaining
            // meetings run out, fall through to tomorrow's first timed event
            // instead of reading as empty. Fetched only in this branch, not
            // unconditionally alongside today's events above, since it's only
            // ever needed here — same "only fetch what this render actually
            // needs" reasoning the in-app version already documents (there:
            // "only fetched/populated when isToday").
            if let tomorrowFirst = await Self.tomorrowFirstTimedEvent(after: now) {
                return DayflowWidgetEntry(
                    date: now,
                    rows: [.tomorrow(
                        id: tomorrowFirst.id,
                        timeLabel: Self.timeLabel(tomorrowFirst.startDate),
                        title: tomorrowFirst.title
                    )],
                    calendarUnavailable: false
                )
            }
            return DayflowWidgetEntry(date: now, rows: [], calendarUnavailable: false)
        }

        var rows: [DayflowWidgetRow] = []

        if first.startDate > now, let veryFirst = all.first, veryFirst.id != first.id {
            let remaining = first.startDate.timeIntervalSince(now)
            if remaining >= Self.minGapSeconds {
                rows.append(.gap(id: "gap-lead-\(first.id)", label: Self.gapLabel(remaining)))
            }
        }

        for (index, event) in visible.enumerated() {
            rows.append(.event(id: event.id, timeLabel: Self.timeLabel(event.startDate), title: event.title))
            guard index + 1 < visible.count else { continue }
            let next = visible[index + 1]
            let gap = next.startDate.timeIntervalSince(event.endDate)
            if gap >= Self.minGapSeconds {
                rows.append(.gap(id: "gap-\(event.id)-\(next.id)", label: Self.gapLabel(gap)))
            }
        }

        return DayflowWidgetEntry(date: now, rows: rows, calendarUnavailable: false)
    }
}

// MARK: - Widget View

struct DayflowWidgetView: View {
    let entry: DayflowWidgetEntry

    private var weekdayLabel: String {
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: entry.date)
    }
    private var dayNumberLabel: String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: entry.date)
    }
    private var monthLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMMM"
        return f.string(from: entry.date)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(monthLabel)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color(red: 0.541, green: 0.514, blue: 0.471))
                        .textCase(.uppercase)
                        .frame(width: 100, alignment: .trailing)
                    Spacer()
                    Text("TODAY")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color(red: 0.231, green: 0.435, blue: 0.878))
                }

                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(weekdayLabel)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color(red: 0.761, green: 0.255, blue: 0.047))
                        Text(dayNumberLabel)
                            .font(.system(size: 68, weight: .bold))
                            .foregroundStyle(Color(red: 0.110, green: 0.110, blue: 0.118))
                            .tracking(-2.5)
                    }
                    .frame(width: 100, alignment: .trailing)

                    if entry.calendarUnavailable {
                        Text("Calendar unavailable")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if entry.rows.isEmpty {
                        Text("Nothing on your calendar")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(entry.rows) { row in
                                rowView(row)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.white, for: .widget)
            .widgetURL(URL(string: "dayflow://open"))

            Link(destination: URL(string: "dayflow://addEvent")!) {
                Text("+")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color(red: 0.231, green: 0.435, blue: 0.878), in: Circle())
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func rowView(_ row: DayflowWidgetRow) -> some View {
        switch row {
        case .event(_, let timeLabel, let title):
            HStack(alignment: .top, spacing: 6) {
                Text("🕒").font(.system(size: 10)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeLabel)
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .gap(_, let label):
            HStack(spacing: 4) {
                Circle().fill(Color.black.opacity(0.30)).frame(width: 4, height: 4)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .italic()
                    .foregroundStyle(.black.opacity(0.5))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.black.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        // Same lavender "TOMORROW" pill + colors as
        // DayflowAgendaSection.swift's tomorrowPreviewRow (Mockup "Option 2")
        // — reused as-is rather than inventing a new widget-only look, since
        // this is the same concept shown in a smaller space. The big
        // date/weekday block above still reads today's real date — only this
        // row's own pill tag marks it as tomorrow's meeting, matching how the
        // in-app version leaves its own day header alone too.
        case .tomorrow(_, let timeLabel, let title):
            HStack(alignment: .top, spacing: 6) {
                Text("🕒").font(.system(size: 10)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOMORROW")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.3)
                        .foregroundStyle(Color(red: 0.478, green: 0.435, blue: 0.761))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(red: 0.863, green: 0.839, blue: 0.949), in: RoundedRectangle(cornerRadius: 5))
                    Text(timeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.357, green: 0.310, blue: 0.639))
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.357, green: 0.310, blue: 0.639))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

// MARK: - Widget Definition

struct DayflowWidget: Widget {
    let kind: String = "DayflowWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DayflowProvider()) { entry in
            DayflowWidgetView(entry: entry)
        }
        .configurationDisplayName("Dayflow")
        .description("Today's schedule, with open time between meetings.")
        .supportedFamilies([.systemMedium])
    }
}
