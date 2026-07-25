// DayflowWidget.swift — paste over the Xcode-generated widget file in the new
// DayflowWidget extension target.
//
// Medium-size Home Screen widget. Original design locked with David
// 2026-07-24 across several mockup rounds (dayflow-widget-mockup-v5.html);
// **restyled 2026-07-25 to sit closer to Fantastical's own medium widget**
// (dayflow-widget-fantastical-mockup-v1.html — David: "its perfect"):
//   - Left date block is now the full Fantastical stack — month over weekday
//     over a much bigger day number (68pt bold → 78pt heavy), right-aligned
//     as one block in a slightly narrower column, so the dead space that used
//     to sit left of the number is mostly gone. Weekday dropped the old burnt
//     orange for iOS system red (#FF3B30 light / #FF453A dark), the bright
//     red Fantastical uses.
//   - Moving the month into the date stack freed the header row: "TODAY" on
//     the left, weather (today's high/low + condition SF Symbol) on the
//     right, in Fantastical's position. Weather is REAL now (WeatherKit),
//     not the visual mock the first pass shipped without — see the Weather
//     section below for the fetch/cache/location strategy and the manual
//     Xcode setup it needs.
//   - Light/dark is now a per-widget setting (long-press → Edit Widget →
//     Appearance: Match System / Light / Dark) via AppIntentConfiguration —
//     same layout, two skins (`DayflowWidgetSkin`). Default is Light, i.e.
//     exactly the widget's original look, so existing placements don't
//     change appearance on update.
//   - THREE tap targets now (was two): the blue "+" opens Dayflow straight
//     into the quick-add sheet in Event mode (`dayflow://addEvent`); the
//     date block (month/weekday/number) opens the Jot capture app via a
//     `dayflow://openJot` relay — iOS widgets can only launch their own
//     containing app, so Dayflow catches this URL and immediately hands off
//     with `UIApplication.open("jot://open")` (DayflowContentView.swift's
//     `.onOpenURL`; the `jot` scheme is already registered on the Jot target
//     for JotWidget). Expect a sub-second Dayflow flash on the way — flagged
//     to David before building, accepted. Everywhere else on the card just
//     opens Dayflow (`dayflow://open`). The `dayflow` scheme lives on the
//     Dayflow APP target's Info tab (not this widget target).
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
// **Tomorrow-preview, added 2026-07-25**: once today's remaining events run
// out, `fetchEntry()` falls through to tomorrow's first timed event, same
// filters as DayflowAgendaSection.swift's `tomorrowFirstTimedEvent`.
// Rendered with the same lavender "TOMORROW" pill as the in-app
// `tomorrowPreviewRow`, re-tuned per skin so it stays readable on the dark
// background. The big date/weekday block and "TODAY" label are left showing
// today's real date either way — only the row itself is tagged.
//
// **Weather (added 2026-07-25)** — `DayflowProvider.fetchWeather()`:
//   - WeatherKit `WeatherService`, queried for `.current` + `.daily`; shows
//     today's high/low in the locale's unit plus the current condition's
//     `symbolName` as a multicolor SF Symbol.
//   - Location comes from `CLLocationManager().location` — the system's
//     cached fix, which a widget process gets when the CONTAINING APP holds
//     location authorization and this widget's Info.plist has
//     `NSWidgetWantsLocation` = YES. Widgets can't prompt for permission
//     themselves; DayflowApp.swift now primes when-in-use authorization at
//     app launch (see `DayflowLocationPrimer` there).
//   - Cached in the `group.com.david.trace` App Group UserDefaults (suite
//     name inlined below rather than referencing AppGroup.swift — that file
//     isn't in this widget target's membership, and one string constant
//     isn't worth adding it): fresh within 30 min → no network call at all;
//     on any failure (no location fix, offline, WeatherKit error) a stale
//     cache up to 6 h old is shown rather than nothing; past that the
//     weather block simply disappears (layout collapses gracefully — TODAY
//     keeps the header line to itself).
//   - MANUAL XCODE SETUP this needs (one-time, David-side): (1) WeatherKit
//     capability on the DayflowWidget EXTENSION target (Signing &
//     Capabilities → + Capability → WeatherKit; automatic signing updates
//     the App ID), (2) `NSWidgetWantsLocation` = YES in the DayflowWidget
//     target's Info.plist, (3) `NSLocationWhenInUseUsageDescription` string
//     on the DAYFLOW APP target's Info tab, (4) launch Dayflow once and
//     accept the location prompt, (5) optionally confirm the App Group
//     `group.com.david.trace` is also on the widget extension target — only
//     the weather CACHE depends on it; live fetches work without it.
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
import AppIntents
import WeatherKit
import CoreLocation

// MARK: - Appearance configuration (Edit Widget → Appearance)

enum DayflowWidgetAppearance: String, AppEnum {
    case system
    case light
    case dark

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Appearance"
    static var caseDisplayRepresentations: [DayflowWidgetAppearance: DisplayRepresentation] = [
        .system: "Match System",
        .light: "Light",
        .dark: "Dark"
    ]
}

struct DayflowWidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Dayflow"
    static var description = IntentDescription("Choose how the widget looks.")

    // Default .light = the widget's original locked look, so placements that
    // existed before this setting was added don't silently change on update.
    @Parameter(title: "Appearance", default: .light)
    var appearance: DayflowWidgetAppearance
}

// MARK: - Timeline Entry

struct DayflowWidgetEntry: TimelineEntry {
    let date: Date
    let rows: [DayflowWidgetRow]
    let calendarUnavailable: Bool
    let weather: DayflowWidgetWeather?
    let appearance: DayflowWidgetAppearance
    /// **TEMPORARY, added 2026-07-25** — David can't connect his phone to
    /// his Mac (company restrictions block it) and is on TestFlight, so
    /// there's no way to read Console.app or an attached debugger while
    /// weather stays broken after the `@MainActor` fix, a confirmed-paid
    /// WeatherKit capability, and a clean reinstall. This surfaces the
    /// *reason* `fetchWeather()` came back empty directly on the widget
    /// face, in whatever text is normally blank, so it's readable just by
    /// looking at the phone. Remove this field (and the `weatherView` case
    /// that displays it) once weather is confirmed working — see this
    /// addendum in Dayflow-HANDOFF.md for the removal checklist.
    let weatherDebug: String
}

/// Codable because it doubles as the App Group cache payload — see
/// `DayflowProvider.fetchWeather()`.
struct DayflowWidgetWeather: Codable {
    let hi: Int
    let lo: Int
    let symbolName: String
    let fetchedAt: Date
}

enum DayflowWidgetRow: Identifiable {
    case event(id: String, timeLabel: String, title: String)
    case gap(id: String, label: String)
    /// Tomorrow's first timed meeting, shown once today's remaining events
    /// run out — ported 2026-07-25 from DayflowAgendaSection.swift's own
    /// `.tomorrow` row/`tomorrowFirstTimedEvent`. Distinct case (rather than
    /// reusing `.event`) so `rowView` can render the "TOMORROW" pill tag the
    /// in-app version uses, instead of looking like one of today's own
    /// meetings.
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

struct DayflowProvider: AppIntentTimelineProvider {
    typealias Entry = DayflowWidgetEntry
    typealias Intent = DayflowWidgetConfigIntent

    func placeholder(in context: Context) -> DayflowWidgetEntry {
        DayflowWidgetEntry(
            date: .now,
            rows: [
                .event(id: "p1", timeLabel: "9:00 AM", title: "Team Standup"),
                .gap(id: "pg1", label: "1h 30m open"),
                .event(id: "p2", timeLabel: "10:30 AM", title: "SIF Financial Review"),
            ],
            calendarUnavailable: false,
            weather: nil,
            appearance: .light,
            weatherDebug: ""
        )
    }

    func snapshot(for configuration: DayflowWidgetConfigIntent, in context: Context) async -> DayflowWidgetEntry {
        await fetchEntry(appearance: configuration.appearance)
    }

    func timeline(for configuration: DayflowWidgetConfigIntent, in context: Context) async -> Timeline<DayflowWidgetEntry> {
        let entry = await fetchEntry(appearance: configuration.appearance)
        // No live "reload on save" hook exists for calendar events the way
        // Jot's widget gets one from CaptureView's commit() — nothing in
        // Dayflow writes a NEW event through a path this widget could hook
        // (Quick-add's Event mode goes through EventKit directly, not a
        // shared store this process observes). A 15-minute refresh is a
        // reasonable middle ground: frequent enough that "what's open right
        // now" stays roughly current, not so frequent it burns WidgetKit's
        // background budget. Weather rides the same cycle but only actually
        // hits the network when its own 30-min cache has gone stale.
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        return Timeline(entries: [entry], policy: .after(refresh))
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

    // MARK: Weather (see file header for the full strategy + manual setup)

    /// Inlined rather than referencing `AppGroup.identifier` — AppGroup.swift
    /// isn't in this widget target's membership and one string constant
    /// isn't worth adding it. Must match AppGroup.swift if it ever changes.
    private static let appGroupID = "group.com.david.trace"
    private static let weatherCacheKey = "dayflowWidgetWeatherCache"
    private static let weatherFreshSeconds: TimeInterval = 30 * 60
    private static let weatherStaleCapSeconds: TimeInterval = 6 * 60 * 60
    /// **TEMPORARY, added 2026-07-25** — the widget face is too small to
    /// show a full raw error string legibly (confirmed: David couldn't read
    /// it even zoomed into a screenshot). Full, untruncated debug text goes
    /// here instead; a temporary section in DayflowSettingsView.swift reads
    /// it back with real screen space and `.textSelection(.enabled)` so
    /// David can copy/paste the exact text. Remove alongside the rest of
    /// this debug instrumentation once weather is confirmed working.
    private static let weatherDebugTextKey = "dayflowWidgetWeatherDebugTextFull"

    private static func cachedWeather(maxAge: TimeInterval) -> DayflowWidgetWeather? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: weatherCacheKey),
              let cached = try? JSONDecoder().decode(DayflowWidgetWeather.self, from: data),
              Date().timeIntervalSince(cached.fetchedAt) <= maxAge
        else { return nil }
        return cached
    }

    private static func storeWeather(_ weather: DayflowWidgetWeather) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(weather) else { return }
        defaults.set(data, forKey: weatherCacheKey)
    }

    /// TEMPORARY — see `weatherDebugTextKey`. Stamps a timestamp on the
    /// front so Settings can show how stale this read is at a glance.
    private static func storeDebugText(_ text: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        defaults.set("[\(f.string(from: Date()))] \(text)", forKey: weatherDebugTextKey)
    }

    /// `@MainActor` added 2026-07-25 (widget-not-showing-weather fix):
    /// `fetchEntry(appearance:)` is `@MainActor`, but this function wasn't —
    /// calling a non-isolated `async` function with `await` from an actor
    /// hops OFF the actor before the function body runs. That meant
    /// `CLLocationManager()` was being created and read on a background
    /// thread with no run loop of its own, which is a well-known way for
    /// `.location` to just come back `nil` even when the containing app has
    /// authorization and a cached fix exists. Pinning this to `@MainActor`
    /// keeps the manager creation/read on the main thread, matching how
    /// `DayflowLocationPrimer` (DayflowApp.swift) and every other
    /// `CLLocationManager` use in this codebase already runs. Everything
    /// else in this function (WeatherKit call, cache read/write) is
    /// actor-agnostic, so this costs nothing.
    /// **TEMPORARY debug return value added 2026-07-25** — see
    /// `DayflowWidgetEntry.weatherDebug`'s comment for why (no device
    /// connection, TestFlight-only, can't read Console.app). Now returns the
    /// weather AND a short reason string covering every path through this
    /// function, instead of just `nil` on failure.
    @MainActor
    private static func fetchWeather() async -> (weather: DayflowWidgetWeather?, debug: String) {
        if let fresh = cachedWeather(maxAge: weatherFreshSeconds) {
            storeDebugText("cache-fresh")
            return (fresh, "cache-fresh")
        }
        // `CLLocationManager().location` is the system's cached fix — a
        // widget process can't run live location updates or prompt, but it
        // CAN read this when the containing app has authorization and this
        // target's Info.plist opts in via NSWidgetWantsLocation. One shared
        // instance for both the auth check and the location read (the old
        // class method `CLLocationManager.authorizationStatus()` is
        // deprecated in favor of the instance property since iOS 14).
        let manager = CLLocationManager()
        let authStatus = manager.authorizationStatus
        guard let location = manager.location else {
            let stale = cachedWeather(maxAge: weatherStaleCapSeconds)
            let authLabel: String
            switch authStatus {
            case .notDetermined: authLabel = "notDet"
            case .restricted: authLabel = "restricted"
            case .denied: authLabel = "denied"
            case .authorizedAlways: authLabel = "always"
            case .authorizedWhenInUse: authLabel = "whenInUse"
            @unknown default: authLabel = "unknown"
            }
            let debug = stale != nil ? "no-fix,stale-cache(\(authLabel))" : "no-fix(\(authLabel))"
            storeDebugText(debug)
            return (stale, debug)
        }
        do {
            let (current, daily) = try await WeatherService.shared.weather(
                for: location, including: .current, .daily
            )
            let unit = UnitTemperature(forLocale: .current)
            let calendar = Calendar.current
            guard let today = daily.first(where: { calendar.isDateInToday($0.date) }) ?? daily.first else {
                let stale = cachedWeather(maxAge: weatherStaleCapSeconds)
                storeDebugText("no-daily-entry")
                return (stale, "no-daily-entry")
            }
            let weather = DayflowWidgetWeather(
                hi: Int(today.highTemperature.converted(to: unit).value.rounded()),
                lo: Int(today.lowTemperature.converted(to: unit).value.rounded()),
                symbolName: current.symbolName,
                fetchedAt: Date()
            )
            storeWeather(weather)
            storeDebugText("live-ok hi:\(weather.hi) lo:\(weather.lo)")
            return (weather, "live-ok")
        } catch {
            let stale = cachedWeather(maxAge: weatherStaleCapSeconds)
            // Full, untruncated error to the App Group text key — this is
            // the one that actually matters for diagnosis. The short
            // capped version below is only for the widget's own tiny
            // on-screen fallback.
            storeDebugText("wx-err full: \(String(describing: error))")
            let errText = String(describing: error).prefix(160)
            return (stale, stale != nil ? "wx-err,stale-cache" : "wx-err:\(errText)")
        }
    }

    @MainActor
    private func fetchEntry(appearance: DayflowWidgetAppearance) async -> DayflowWidgetEntry {
        let now = Date()
        let (weather, weatherDebug) = await Self.fetchWeather()
        guard Self.hasCalendarAccess else {
            return DayflowWidgetEntry(date: now, rows: [], calendarUnavailable: true,
                                      weather: weather, appearance: appearance, weatherDebug: weatherDebug)
        }
        let dayEvents = await CalendarService.shared.fetchDayEvents(for: now)
        let all = dayEvents
            .filter { !$0.isAllDay }
            .filter { !Self.isExcludedPlaceholderTitle($0.title) }
            .sorted { $0.startDate < $1.startDate }

        let visible = all.filter { $0.endDate > now }
        guard let first = visible.first else {
            // Tomorrow-preview (see file header) — once today's remaining
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
                    calendarUnavailable: false,
                    weather: weather,
                    appearance: appearance,
                    weatherDebug: weatherDebug
                )
            }
            return DayflowWidgetEntry(date: now, rows: [], calendarUnavailable: false,
                                      weather: weather, appearance: appearance, weatherDebug: weatherDebug)
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

        return DayflowWidgetEntry(date: now, rows: rows, calendarUnavailable: false,
                                  weather: weather, appearance: appearance, weatherDebug: weatherDebug)
    }
}

// MARK: - Skins

/// One layout, two skins. Light is the widget's original locked palette
/// except the weekday red (burnt orange → iOS system red, per the
/// Fantastical restyle); dark mirrors it against #1c1c1f, with the tomorrow
/// lavender re-tuned so it stays readable. Values match
/// dayflow-widget-fantastical-mockup-v1.html.
struct DayflowWidgetSkin {
    let background: Color
    let month: Color
    let weekday: Color
    let dayNumber: Color
    let today: Color
    let weatherText: Color
    let eventText: Color
    let gapText: Color
    let gapBorder: Color
    let gapFill: Color
    let gapDot: Color
    let tomorrowPillText: Color
    let tomorrowPillBackground: Color
    let tomorrowText: Color

    static let light = DayflowWidgetSkin(
        background: .white,
        month: Color(red: 0.541, green: 0.514, blue: 0.471),
        weekday: Color(red: 1.0, green: 0.231, blue: 0.188),      // #FF3B30
        dayNumber: Color(red: 0.110, green: 0.110, blue: 0.118),
        today: Color(red: 0.231, green: 0.435, blue: 0.878),
        weatherText: Color(red: 0.420, green: 0.420, blue: 0.439),
        eventText: Color(red: 0.110, green: 0.110, blue: 0.118),
        gapText: Color.black.opacity(0.5),
        gapBorder: Color.black.opacity(0.22),
        gapFill: Color.black.opacity(0.035),
        gapDot: Color.black.opacity(0.30),
        tomorrowPillText: Color(red: 0.478, green: 0.435, blue: 0.761),
        tomorrowPillBackground: Color(red: 0.863, green: 0.839, blue: 0.949),
        tomorrowText: Color(red: 0.357, green: 0.310, blue: 0.639)
    )

    static let dark = DayflowWidgetSkin(
        background: Color(red: 0.110, green: 0.110, blue: 0.122), // #1c1c1f
        month: Color(red: 0.596, green: 0.596, blue: 0.620),
        weekday: Color(red: 1.0, green: 0.271, blue: 0.227),      // #FF453A
        dayNumber: .white,
        today: Color(red: 0.369, green: 0.620, blue: 1.0),
        weatherText: Color(red: 0.816, green: 0.816, blue: 0.835),
        eventText: Color(red: 0.949, green: 0.949, blue: 0.961),
        gapText: Color.white.opacity(0.55),
        gapBorder: Color.white.opacity(0.28),
        gapFill: Color.white.opacity(0.05),
        gapDot: Color.white.opacity(0.40),
        tomorrowPillText: Color(red: 0.812, green: 0.776, blue: 0.961),
        tomorrowPillBackground: Color(red: 0.471, green: 0.412, blue: 0.784).opacity(0.35),
        tomorrowText: Color(red: 0.725, green: 0.682, blue: 0.941)
    )
}

// MARK: - Widget View

struct DayflowWidgetView: View {
    let entry: DayflowWidgetEntry
    @Environment(\.colorScheme) private var systemScheme

    private var skin: DayflowWidgetSkin {
        switch entry.appearance {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemScheme == .dark ? .dark : .light
        }
    }

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
            // 2026-07-25: alignment .center → .top, and date-block trailing
            // padding 14 → 44, per David's mockup sign-off — TODAY now sits
            // on the same row as the month label instead of vertically
            // centered against the whole date stack, and the event column
            // sits further from the date number instead of closer to it.
            HStack(alignment: .top, spacing: 0) {
                // Third tap target (added 2026-07-25): the whole date block
                // relays to the Jot capture app via dayflow://openJot — see
                // file header for why a widget can't launch Jot directly.
                Link(destination: URL(string: "dayflow://openJot")!) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(monthLabel)
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(skin.month)
                            .textCase(.uppercase)
                        Text(weekdayLabel)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(skin.weekday)
                            .padding(.top, 1)
                        Text(dayNumberLabel)
                            .font(.system(size: 78, weight: .heavy))
                            .foregroundStyle(skin.dayNumber)
                            .tracking(-3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 96, alignment: .trailing)
                }
                .padding(.trailing, 44)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("TODAY")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(skin.today)
                        Spacer(minLength: 4)
                        weatherView
                    }

                    // TEMPORARY, added 2026-07-25 — moved out of weatherView's
                    // cramped slot (single line there was getting truncated
                    // before David could read the actual error) into its own
                    // full-width row that can wrap across a few lines. See
                    // DayflowWidgetEntry.weatherDebug's comment for why this
                    // exists at all.
                    if entry.weather == nil && !entry.weatherDebug.isEmpty {
                        Text(entry.weatherDebug)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Group {
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
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(skin.background, for: .widget)
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
    private var weatherView: some View {
        if let weather = entry.weather {
            HStack(spacing: 4) {
                Text("\(weather.hi)°/\(weather.lo)°")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(skin.weatherText)
                Image(systemName: weather.symbolName)
                    .font(.system(size: 11))
                    .symbolRenderingMode(.multicolor)
            }
        } else {
            // The debug text itself moved to a full-width row below the
            // header (see the TEMPORARY comment near "TODAY" in `body`) —
            // a single line in this cramped slot was truncating before
            // David could read the actual error. Nothing shown here now,
            // matching final production behavior once weather works.
        }
    }

    @ViewBuilder
    private func rowView(_ row: DayflowWidgetRow) -> some View {
        switch row {
        case .event(_, let timeLabel, let title):
            // Time 11→13, title 12→14, per David's mockup sign-off 2026-07-25.
            HStack(alignment: .top, spacing: 6) {
                Text("🕒").font(.system(size: 10)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(skin.eventText)
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(skin.eventText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .gap(_, let label):
            HStack(spacing: 4) {
                Circle().fill(skin.gapDot).frame(width: 4, height: 4)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .italic()
                    .foregroundStyle(skin.gapText)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(skin.gapBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .background(skin.gapFill, in: RoundedRectangle(cornerRadius: 7))
        // Same lavender "TOMORROW" pill concept as DayflowAgendaSection.swift's
        // tomorrowPreviewRow (Mockup "Option 2") — colors now come from the
        // skin so the pill stays readable on the dark background too. The big
        // date/weekday block still reads today's real date — only this row's
        // own pill tag marks it as tomorrow's meeting, matching how the
        // in-app version leaves its own day header alone too.
        case .tomorrow(_, let timeLabel, let title):
            HStack(alignment: .top, spacing: 6) {
                Text("🕒").font(.system(size: 10)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TOMORROW")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.3)
                        .foregroundStyle(skin.tomorrowPillText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(skin.tomorrowPillBackground, in: RoundedRectangle(cornerRadius: 5))
                    Text(timeLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(skin.tomorrowText)
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(skin.tomorrowText)
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
        // AppIntentConfiguration (was StaticConfiguration) for the Appearance
        // setting — kind string unchanged, so existing placements migrate in
        // place; they get the default (.light), i.e. the original look.
        AppIntentConfiguration(kind: kind, intent: DayflowWidgetConfigIntent.self, provider: DayflowProvider()) { entry in
            DayflowWidgetView(entry: entry)
        }
        .configurationDisplayName("Dayflow")
        .description("Today's schedule, with open time between meetings.")
        .supportedFamilies([.systemMedium])
        // Added 2026-07-25, same day as the restyle: without this, iOS adds
        // its own default content margins (~16pt/edge) INSIDE the card, on
        // top of this view's own .padding(13). The mockup was designed with
        // only the 13pt padding, so the system margins squeezed the date
        // stack's height and the day number's minimumScaleFactor guard
        // shrank the 78pt "24" visibly below the approved look (David
        // caught it on-device: "doesnt the date and day of week look small").
        // Disabling system margins gives the layout the full card, matching
        // the mock 1:1; the view's own padding keeps content off the edges.
        .contentMarginsDisabled()
    }
}
