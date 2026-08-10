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
//   - THREE tap targets: the blue "+" opens Dayflow straight into the
//     quick-add sheet in Event mode (`dayflow://addEvent`); the date block
//     (month/weekday/number) opens the Jot capture app via a
//     `dayflow://openJot` relay — iOS widgets can only launch their own
//     containing app, so Dayflow catches this URL and immediately hands off
//     with `UIApplication.open("jot://open")` (DayflowContentView.swift's
//     `.onOpenURL`; the `jot` scheme is already registered on the Jot target
//     for JotWidget). Expect a sub-second Dayflow flash on the way — flagged
//     to David before building, accepted.
//   - **Everywhere else on the card (2026-07-26): opens Fantastical, not
//     Dayflow.** David's ask — he had no quick way to reach Fantastical (his
//     preferred calendar app) from the widget, and was fine trading away the
//     "tap the card to open Dayflow" shortcut for it since Dayflow is always
//     reachable from the home screen anyway. Same relay pattern as Jot:
//     `.widgetURL(dayflow://openCalendar)`, Dayflow's `.onOpenURL` catches it
//     and hands off to Fantastical (`fantastical2://`), falling back to
//     Apple's own Calendar app (`calshow://`) if Fantastical isn't
//     installed. The `dayflow` scheme lives on the Dayflow APP target's Info
//     tab (not this widget target).
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
// **Weather (added 2026-07-25, switched off WeatherKit 2026-07-26)** —
// `DayflowProvider.fetchWeather()`:
//   - **Source is now Open-Meteo (open-meteo.com), not WeatherKit.** David
//     hit a persistent `WDSJWTAuthenticatorServiceListener Code=2` WeatherKit
//     auth error that traced back to Apple's Paid Applications Agreement
//     needing to be fully signed (banking + tax info) even though Dayflow is
//     free — David didn't want to add a bank account or sign a W-9 just to
//     unblock a free app's weather widget, so this swaps in a free,
//     no-API-key, no-account REST API instead. Open-Meteo's non-commercial
//     free tier is 10,000 calls/day; a single-user widget on a 15–30 min
//     cache cycle is nowhere close. See `fetchOpenMeteoWeather(for:)` below
//     for the request/response handling and `sfSymbolName(forWeatherCode:isDay:)`
//     for the WMO-code → SF Symbol mapping (Open-Meteo returns a numeric WMO
//     weather code, not an SF Symbol name the way WeatherKit's
//     `CurrentWeather.symbolName` did, so this maps it by hand).
//   - Shows today's high/low, converted from Open-Meteo's Celsius response
//     into the locale's unit (same `UnitTemperature(forLocale:)` conversion
//     WeatherKit's version used) plus a multicolor SF Symbol for the current
//     condition.
//   - **Rain chip, added 2026-08-02 (Session 63).** A blue droplet and a
//     percentage at the right edge of the header, drawn ONLY when
//     `precipitation_probability_max` is 40% or higher (threshold chosen by
//     David; see `precipChipThreshold`). Dry days are unchanged. This exists
//     because the SF Symbol reports the `current` block — conditions right
//     now — while the temperatures beside it describe the whole day, so a dry
//     morning before an afternoon storm renders a sun and said nothing about
//     the storm. See `weatherView`'s comment for why this was built instead of
//     the "turn the icon blue when it rains" that was originally asked for.
//   - **Location, corrected 2026-08-02 (Session 63).** This block used to
//     say the fix came from `CLLocationManager().location` — "the system's
//     cached fix, which a widget process gets when the containing app holds
//     authorization". That was wrong, and it is why the widget showed
//     `no-fix(whenInUse)` in red for a week: `.location` is the last fix
//     *that manager instance* retrieved, and a manager created fresh in a
//     freshly launched widget process has retrieved none. There is no
//     ambient fix to read. The widget has to ASK — `requestLocation()` plus
//     a delegate callback — which is what `DayflowWidgetLocationFetcher`
//     below now does, with a retained manager, a resume-once continuation
//     and an 8s timeout. Read that type's doc comment before touching any
//     of this. `NSWidgetWantsLocation` was always necessary and never
//     sufficient; `whenInUse` authorization IS enough (the level was never
//     the problem); widgets still can't prompt, so DayflowApp.swift's
//     `DayflowLocationPrimer` still does that at app launch.
//   - Cached in the `group.com.david.trace` App Group UserDefaults (suite
//     name inlined below rather than referencing AppGroup.swift — that file
//     isn't in this widget target's membership, and one string constant
//     isn't worth adding it): fresh within 30 min → no network call at all;
//     on any failure (no location fix, offline, network/API error) a stale
//     cache up to 6 h old is shown rather than nothing; past that the
//     weather block simply disappears (layout collapses gracefully — TODAY
//     keeps the header line to itself).
//   - MANUAL XCODE SETUP this needs (one-time, David-side): (1)
//     `NSWidgetWantsLocation` = YES in the DayflowWidget target's Info.plist,
//     (1b) added 2026-08-02: `NSLocationWhenInUseUsageDescription` on the
//     WIDGET target's Info.plist too, not just the app's — a widget that
//     calls `requestLocation()` is widely reported to need its own purpose
//     string, and a missing one fails silently as `kCLErrorDenied`,
//     (2) `NSLocationWhenInUseUsageDescription` string on the DAYFLOW APP
//     target's Info tab, (3) launch Dayflow once and accept the location
//     prompt, (4) optionally confirm the App Group `group.com.david.trace`
//     is also on the widget extension target — only the weather CACHE
//     depends on it; live fetches work without it. **The WeatherKit
//     capability is no longer required** — David can remove it from the
//     DayflowWidget extension target's Signing & Capabilities if he wants to
//     tidy up, but leaving it there is harmless too since nothing calls it
//     anymore.
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

// MARK: - Active endeavor
//
// **The counterpart of `EndeavorWidgetFeed` in DayflowEndeavor.swift.** Dayflow
// publishes a list of endeavors with their date ranges into the shared
// container; this reads it and decides which one is today's. Change either side
// and you must change the other — the shape and the key are the contract, and
// they are duplicated because this target cannot see Dayflow's code.
//
// **Why a list of ranges rather than "the active one".** If Dayflow published a
// single answer, a trip starting tomorrow would stay dark until the app was next
// opened, because nothing runs at midnight to change it. Deciding here means the
// widget's own timeline refresh across a date boundary is enough.

private struct PublishedEndeavor: Codable {
    let id: String
    let name: String
    let starts: Date
    let ends: Date
}

enum ActiveEndeavorFeed {
    private static let suiteName = "group.com.david.trace"
    private static let key = "dayflow_endeavor_feed"

    /// The endeavor covering `date`, soonest-ending first when several overlap.
    /// David's rule: the nearest deadline is the one you need to be told about.
    static func active(on date: Date = Date()) -> (id: String, name: String)? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let feed = try? JSONDecoder().decode([PublishedEndeavor].self, from: data)
        else { return nil }

        let today = Calendar.current.startOfDay(for: date)
        let match = feed
            .filter { $0.starts <= today && today <= $0.ends }
            .min { $0.ends < $1.ends }
        guard let match else { return nil }
        return (match.id, match.name)
    }
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
    /// Today's endeavor, if any. Replaces the "TODAY" label — see the label's
    /// own comment for why that slot rather than a row of its own.
    var activeEndeavor: (id: String, name: String)? = nil
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
    /// Chance of precipitation for the day, 0–100, from Open-Meteo's
    /// `precipitation_probability_max`. Added Session 63 (2026-08-02).
    ///
    /// **Optional for two reasons, both load-bearing.** Open-Meteo can return
    /// `null` for this at some locations, and more importantly this struct
    /// doubles as the App Group cache payload — a cached blob written before
    /// this field existed has no key for it. Swift's synthesized `Codable`
    /// decodes `Optional` properties with `decodeIfPresent`, so old blobs
    /// still decode, as `nil`, instead of failing outright and blanking the
    /// weather for up to six hours after the update lands. A non-optional
    /// `Int` here would have been a silent regression on install day.
    let precipChance: Int?
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

// MARK: - Location for the widget

/// **Session 63 (2026-08-02) — this is why weather never appeared.**
///
/// David's widget had been showing `no-fix(whenInUse)` in red for a week. That
/// string means authorization was granted and `CLLocationManager().location`
/// came back `nil` anyway. The code above it carried this comment:
///
/// > `CLLocationManager().location` is the system's cached fix — a widget
/// > process can't run live location updates or prompt, but it CAN read this
/// > when the containing app has authorization and this target's Info.plist
/// > opts in via NSWidgetWantsLocation.
///
/// **That is wrong, and it was the bug.** In a widget extension `.location` is
/// documented as "the most recently retrieved location" — meaning the most
/// recent one *this manager instance* retrieved. A freshly created manager in a
/// freshly launched widget process has never retrieved anything, so the
/// property is `nil` no matter how the app is authorized. There is no ambient
/// system fix to read. A widget has to **ask**, via `requestLocation()` and a
/// delegate callback, exactly like an app does.
///
/// Everything else that was tried against this bug was aimed at the wrong
/// thing. `NSWidgetWantsLocation` was already set and was always necessary but
/// never sufficient. The `@MainActor` fix on 2026-07-25 was correct on its own
/// terms — a `CLLocationManager` does need a main-thread run loop — but it
/// could not help, because the call it was protecting never asked for a fix.
/// And the authorization level is a red herring: `whenInUse` is enough. The
/// widget was reading an empty property, patiently, on the right thread.
///
/// Three things this class has to get right, all of them ways the naive version
/// fails in a widget specifically:
///
/// 1. **The manager must outlive the request.** A local `CLLocationManager`
///    deallocates the moment the enclosing function suspends, and the delegate
///    callback never arrives. Hence `shared`.
/// 2. **The continuation must resume exactly once.** Resuming twice traps.
///    `didUpdateLocations`, `didFailWithError` and the timeout can all fire, so
///    `finish` is the single door and it nils the continuation on the way out.
/// 3. **There must be a timeout.** WidgetKit gives timeline generation a wall
///    clock budget; a location request that never calls back would hang the
///    widget rather than fail it. Eight seconds, then give up and let the
///    caller fall through to the stale cache.
///
/// Also `locations.last` rather than `locations.last!`: an empty array in the
/// callback is rare but real, and the force-unwrap version is a known widget
/// crash.
@MainActor
final class DayflowWidgetLocationFetcher: NSObject, CLLocationManagerDelegate {

    static let shared = DayflowWidgetLocationFetcher()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        // Weather for a city-sized area. Kilometre accuracy returns faster and
        // costs less power than the default, and the Open-Meteo call rounds to
        // a grid cell anyway.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// The widget-specific authorization signal, distinct from
    /// `authorizationStatus`. If this is `false` while the status looks fine,
    /// the problem is the extension's Info.plist or entitlements rather than
    /// anything the user did — worth having in the debug string, because those
    /// two failures look identical from the widget face.
    var isAuthorizedForWidgetUpdates: Bool { manager.isAuthorizedForWidgetUpdates }

    func currentLocation(timeout: TimeInterval = 8) async -> CLLocation? {
        // A second caller while one is in flight gets nil rather than stomping
        // the first one's continuation.
        guard continuation == nil else { return nil }

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            continuation = cont
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(nil)
            }
        }
    }

    /// The only place the continuation is ever resumed.
    private func finish(_ location: CLLocation?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: location)
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
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
    /// else in this function (the Open-Meteo network call, cache
    /// read/write) is actor-agnostic, so this costs nothing.
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
        // **Rewritten Session 63 (2026-08-02).** This used to read
        // `CLLocationManager().location` and treat `nil` as "no fix
        // available". In a widget that property is always `nil` — see
        // `DayflowWidgetLocationFetcher` for the full explanation. The widget
        // has to request a fix and wait for the delegate callback, which is
        // what `currentLocation()` does.
        let fetcher = DayflowWidgetLocationFetcher.shared
        let authStatus = fetcher.authorizationStatus
        let authLabel: String
        switch authStatus {
        case .notDetermined: authLabel = "notDet"
        case .restricted: authLabel = "restricted"
        case .denied: authLabel = "denied"
        case .authorizedAlways: authLabel = "always"
        case .authorizedWhenInUse: authLabel = "whenInUse"
        @unknown default: authLabel = "unknown"
        }
        // A widget can never prompt, so an unauthorized state is terminal here
        // and `requestLocation()` would only fail slowly. Fail fast and say so.
        guard authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways else {
            let stale = cachedWeather(maxAge: weatherStaleCapSeconds)
            let debug = "no-auth(\(authLabel)) — open Dayflow once to grant location"
            storeDebugText(debug)
            return (stale, stale != nil ? "no-auth,stale-cache" : "no-auth(\(authLabel))")
        }
        let widgetAuth = fetcher.isAuthorizedForWidgetUpdates
        guard let location = await fetcher.currentLocation() else {
            let stale = cachedWeather(maxAge: weatherStaleCapSeconds)
            // `widgetAuth:0` here means the extension itself is not cleared for
            // location — Info.plist / entitlements — rather than the request
            // simply timing out. The two are indistinguishable without it.
            let debug = "req-fail(\(authLabel),widgetAuth:\(widgetAuth ? 1 : 0))"
            storeDebugText(debug)
            return (stale, stale != nil ? "\(debug),stale-cache" : debug)
        }
        do {
            let weather = try await fetchOpenMeteoWeather(for: location)
            storeWeather(weather)
            storeDebugText("live-ok hi:\(weather.hi) lo:\(weather.lo) p:\(weather.precipChance.map(String.init) ?? "-")")
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

    /// **Added 2026-07-26, replaces the old WeatherKit call.** Open-Meteo
    /// (open-meteo.com) — free, no API key, no account, no Apple Paid
    /// Applications Agreement required. See the file header's Weather
    /// section for why this was swapped in. Always requests Celsius from
    /// the API and converts client-side to the locale's unit, matching
    /// exactly how the old WeatherKit path converted its
    /// `Measurement<UnitTemperature>` values — so the rest of the pipeline
    /// (cache struct, `weatherView`'s rendering) didn't need to change.
    private static func fetchOpenMeteoWeather(for location: CLLocation) async throws -> DayflowWidgetWeather {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "weather_code,is_day"),
            // `precipitation_probability_max` added Session 63 (2026-08-02) for
            // the rain chip. Same request, one more daily variable — no extra
            // round trip, no extra latency, and it rides the existing 30-minute
            // cache like everything else here.
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = components.url else { throw OpenMeteoError.badURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OpenMeteoError.badResponse(statusCode: code)
        }
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        guard let hiC = decoded.daily.temperature_2m_max.first,
              let loC = decoded.daily.temperature_2m_min.first
        else {
            throw OpenMeteoError.missingDailyData
        }
        let unit = UnitTemperature(forLocale: .current)
        let hi = Measurement(value: hiC, unit: UnitTemperature.celsius).converted(to: unit).value.rounded()
        let lo = Measurement(value: loC, unit: UnitTemperature.celsius).converted(to: unit).value.rounded()
        return DayflowWidgetWeather(
            hi: Int(hi),
            lo: Int(lo),
            symbolName: Self.sfSymbolName(forWeatherCode: decoded.current.weatherCode, isDay: decoded.current.isDay == 1),
            fetchedAt: Date(),
            precipChance: (decoded.daily.precipitation_probability_max?.first ?? nil)
                .map { Int($0.rounded()) }
        )
    }

    private enum OpenMeteoError: Error {
        case badURL
        case badResponse(statusCode: Int)
        case missingDailyData
    }

    /// Minimal decode target — only pulls the fields this widget actually
    /// uses out of Open-Meteo's response.
    private struct OpenMeteoResponse: Codable {
        struct Current: Codable {
            let weatherCode: Int
            let isDay: Int
            enum CodingKeys: String, CodingKey {
                case weatherCode = "weather_code"
                case isDay = "is_day"
            }
        }
        struct Daily: Codable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            /// **`Double`, not `Int`, and doubly optional.** Three separate
            /// hedges, each against a real failure:
            ///
            /// - **`Double`** because that is what Open-Meteo declares. Their
            ///   own OpenAPI spec (`openapi/forecast.yml` in
            ///   github.com/open-meteo/open-meteo) types this field as
            ///   `number` / `format: float`, same as the temperatures beside
            ///   it — checked 2026-08-02, after shipping it as a hedge and
            ///   before David had to trust the hedge. So `Int` here would not
            ///   have been cautious-vs-not, it would have been wrong by
            ///   contract, working only for as long as their encoder happened
            ///   to drop trailing zeros. A throw on `40.0` takes the whole
            ///   `Daily` down with it and the **temperatures** vanish over a
            ///   field that is decoration. The caller rounds.
            /// - **The array optional** so a response without the variable at
            ///   all (or a future request that stops asking for it) still
            ///   yields temperatures.
            /// - **The element optional** because individual entries come back
            ///   `null` at some locations.
            ///
            /// The general rule, learned the expensive way one commit earlier
            /// in this same file: an unverified assumption about someone else's
            /// API belongs behind a hedge, not in a type signature.
            let precipitation_probability_max: [Double?]?
        }
        let current: Current
        let daily: Daily
    }

    /// Maps Open-Meteo's numeric WMO weather codes
    /// (https://open-meteo.com/en/docs — "WMO Weather interpretation
    /// codes") to an SF Symbol name, multicolor-rendered the same way
    /// WeatherKit's own `CurrentWeather.symbolName` was in `weatherView`.
    /// Not an exhaustive 1:1 of every WMO code — collapses adjacent
    /// intensities (e.g. light/moderate/dense drizzle) onto one icon, which
    /// is the same level of detail a glance at a home screen widget needs.
    private static func sfSymbolName(forWeatherCode code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 77, 85: return "cloud.snow.fill"
        case 75, 86: return "snow"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    @MainActor
    private func fetchEntry(appearance: DayflowWidgetAppearance) async -> DayflowWidgetEntry {
        let now = Date()
        // Read once per render. Cheap (one UserDefaults blob, decoded), and
        // every return below needs the same answer.
        let active = ActiveEndeavorFeed.active(on: now)
        let (weather, weatherDebug) = await Self.fetchWeather()
        guard Self.hasCalendarAccess else {
            return DayflowWidgetEntry(date: now, rows: [], calendarUnavailable: true,
                                      weather: weather, appearance: appearance, activeEndeavor: active, weatherDebug: weatherDebug)
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
                    activeEndeavor: active,
                    weatherDebug: weatherDebug
                )
            }
            return DayflowWidgetEntry(date: now, rows: [], calendarUnavailable: false,
                                      weather: weather, appearance: appearance, activeEndeavor: active, weatherDebug: weatherDebug)
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
                                  weather: weather, appearance: appearance, activeEndeavor: active, weatherDebug: weatherDebug)
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
    /// The rain chip. Deliberately the same blue as `today` rather than a
    /// second one: both sit on the header row, and two nearly-identical
    /// blues four inches apart reads as a mistake rather than a system. It
    /// is a separate token anyway so the chip can change later without
    /// dragging the "TODAY" label with it.
    let precip: Color
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
        precip: Color(red: 0.231, green: 0.435, blue: 0.878),
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
        precip: Color(red: 0.369, green: 0.620, blue: 1.0),
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
                        // Same treatment for the month. "SEPTEMBER" with 1.2pt
                        // tracking is the widest of the twelve and sits in the same
                        // 96pt column; fixing only the weekday would have left the
                        // identical bug waiting for September.
                        Text(monthLabel)
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(skin.month)
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        // SHRINK, DO NOT WRAP. The date column is a fixed 96pt and
                        // "Thursday" at 20pt bold does not fit, so it broke as
                        // "Thursda / y" — David's 30 July screenshot. Wednesday and
                        // Saturday are longer still.
                        //
                        // Not a new bug: the same wrap has always happened on
                        // long-named days. It was invisible until the overflow fix
                        // landed, because on exactly those days the weekday was
                        // being cropped off the top of the widget instead. One bug
                        // was hiding the other.
                        //
                        // 0.6 rather than the day number's 0.7 because "Wednesday"
                        // is the longest weekday in English and needs the extra
                        // room; a scale floor that is too high just wraps again,
                        // which is the failure this replaces.
                        Text(weekdayLabel)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(skin.weekday)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.top, 1)
                        Text(dayNumberLabel)
                            // WEIGHT ONLY. Size stays at 78 — David, 2026-07-31:
                            // "I definitely do not want smaller... ideally same
                            // size number but less thick."
                            //
                            // `.heavy` → `.bold` → `.semibold` on SF's scale
                            // (black, heavy, bold, semibold, medium, regular).
                            // Bold was tried on device first: "the weighting is
                            // a little chubby still to be honest." `.medium` is
                            // the next step if this is still not enough, though
                            // it starts to look thin against the 20pt bold
                            // weekday sitting directly above it.
                            //
                            // The scale floor below is untouched and should stay
                            // untouched: two digits at 78pt fit the 96pt column,
                            // so it is an emergency measure here, not the normal
                            // case. What made the 30 July widget look lighter
                            // than the 23rd was the WEEKDAY shrinking to fit a
                            // long name; the number was not smaller.
                            .font(.system(size: 78, weight: .semibold))
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
                        // WHAT TODAY IS, not just that it is today.
                        //
                        // The endeavor name takes this slot rather than a row of
                        // its own: a row costs vertical space the overflow fix
                        // just bought back, and this label's job is already to say
                        // what kind of day this is. No endeavor, it reads TODAY
                        // and is not a link, exactly as before.
                        //
                        // Its own `Link`, and **not** the date block's. That block
                        // opens Jot and keeps doing so. Splitting it so the month
                        // and weekday opened the endeavor was considered and
                        // rejected: the words would say "Thursday" while the tap
                        // opened "Japan", which is a door with no sign on it.
                        // Here what you read is what you tap.
                        //
                        // `lineLimit(1)` is not optional. A long name with no
                        // limit does not truncate under pressure, it wraps and
                        // grows — that exact mistake made an Endeavor row 700pt
                        // tall on 2026-07-31.
                        if let active = entry.activeEndeavor,
                           let url = URL(string: "dayflow://endeavor?id=\(active.id)") {
                            Link(destination: url) {
                                Text(active.name.uppercased())
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(skin.today)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    // Padding, not a bigger font: widens a
                                    // deliberately small target without borrowing
                                    // space from anything beside it.
                                    .padding(.vertical, 4)
                                    .padding(.trailing, 6)
                                    .contentShape(Rectangle())
                            }
                        } else {
                            Text("TODAY")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(skin.today)
                        }
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
                            fittedRows
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(13)
            // `.topLeading`, not `.leading`. **This alone caused the missing date
            // line.** `.leading` centres content vertically, so once the column was
            // taller than the widget the overflow was cut off the TOP as well as the
            // bottom — which is why David's 30 July screenshot lost "JULY / Monday"
            // entirely while still showing three events. Anchored to the top, the
            // header can no longer be the thing that disappears.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(skin.background, for: .widget)
            // Changed 2026-07-26 from `dayflow://open` — David's ask: the
            // card's default tap now relays to Fantastical instead of
            // opening Dayflow (see file header). The "+" and date-block
            // Link()s above still claim their own regions and are
            // unaffected by this.
            .widgetURL(URL(string: "dayflow://openCalendar"))

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

    /// Show the rain chip at or above this chance of precipitation.
    ///
    /// **40, chosen by David 2026-08-02.** 30 is the conventional
    /// "consider an umbrella" line and was the alternative on the table; he
    /// took the quieter one, which fires closer to the point where you would
    /// actually change what you carry. Lower it here if it turns out to be too
    /// silent through a Chicago summer.
    private static let precipChipThreshold = 40

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

                // The rain chip. Session 63 (2026-08-02).
                //
                // David asked for the icon to turn blue when rain is expected.
                // Built as this instead, for two reasons worth keeping.
                //
                // **The icon is already coloured** — `.symbolRenderingMode(
                // .multicolor)` above already gives `cloud.rain.fill` blue
                // droplets and `sun.max.fill` a yellow disc. Recolouring it
                // would have meant dropping multicolor for a monochrome tint,
                // trading away the yellow sun and the yellow lightning bolt to
                // emphasise something the glyph shape already states.
                //
                // **And the icon reports the wrong window.** It comes from
                // Open-Meteo's `current` block, so it is conditions *right
                // now*, while the temperatures beside it are the day's high and
                // low. On a dry morning before an afternoon storm the icon is a
                // sun, and no colour rule fixes that because it is not a rain
                // glyph to begin with. That morning is exactly when you want to
                // be told something, and it was the case the widget was silent
                // about. `precipitation_probability_max` is a claim about the
                // day, which is what the row is otherwise made of.
                //
                // **Drawn only above the threshold, never below.** Dry days look
                // exactly as they did before. Same rule as the Mac day column
                // (design decision D4): mark the exception, not the norm — a
                // widget where something is always highlighted has nothing
                // highlighted.
                //
                // Not suppressed when the icon is already wet, even though 90%
                // under a rain cloud is close to redundant. A chip that
                // sometimes vanishes on the rainiest days of the year would
                // read as a bug, and "when is it missing" is a worse question
                // to leave the reader than one redundant number.
                if let chance = weather.precipChance, chance >= Self.precipChipThreshold {
                    HStack(spacing: 1) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 9))
                        Text("\(chance)%")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(skin.precip)
                    // One unit, so it wraps or truncates as one rather than
                    // leaving a droplet next to a severed number.
                    .fixedSize()
                }
            }
        } else {
            // The debug text itself moved to a full-width row below the
            // header (see the TEMPORARY comment near "TODAY" in `body`) —
            // a single line in this cramped slot was truncating before
            // David could read the actual error. Nothing shown here now,
            // matching final production behavior once weather works.
        }
    }

    // MARK: Fitting the rows
    //
    // THE BUG, 2026-07-30. David: *"when I have more meetings in a day the events
    // overflow the screen and this morning the date itself on the left was off as
    // well."* Both symptoms, one cause: `ForEach(entry.rows)` rendered **every**
    // row with no cap, so a busy day produced a column taller than the widget.
    // A widget cannot scroll and cannot grow, so the surplus was simply cropped —
    // and because the container was aligned `.leading` (vertically centred) it was
    // cropped at BOTH ends, taking the month and weekday with it.
    //
    // Row height is not predictable from the event count either: a `.gap` pill is
    // ~17pt, an `.event` ~34pt, a `.tomorrow` ~46pt, and gaps appear only between
    // events that have space between them. Three meetings with two gaps is taller
    // than four meetings back to back.
    //
    // SO: `ViewThatFits` rather than arithmetic. It renders the first candidate
    // that actually fits, measured by SwiftUI with the real font metrics, on the
    // real widget size for whatever device this is. No estimated line heights to be
    // wrong about, and no per-device height table to maintain.
    //
    // Candidates run from `min(rows.count, 8)` rows down to 1, so the **last
    // candidate is a single row and always fits** — there is no path where this
    // falls through to overflowing again. Eight is the ceiling because more than
    // eight rows cannot fit a medium widget on any device, so trying is wasted.

    @ViewBuilder
    private var fittedRows: some View {
        let top = min(entry.rows.count, 8)
        ViewThatFits(in: .vertical) {
            rowsColumn(top)
            rowsColumn(top - 1)
            rowsColumn(top - 2)
            rowsColumn(top - 3)
            rowsColumn(top - 4)
            rowsColumn(top - 5)
            rowsColumn(top - 6)
            rowsColumn(top - 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One candidate: the first `count` rows, tidied, plus an honest count of what
    /// was left out.
    @ViewBuilder
    private func rowsColumn(_ count: Int) -> some View {
        let rows = Self.tidied(Array(entry.rows.prefix(max(count, 1))))
        let hidden = Self.meetingCount(entry.rows) - Self.meetingCount(rows)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row)
                    // Only the LAST row can run under the "+" button, which is an
                    // overlay pinned bottom-trailing. Reserving that width on every
                    // row would truncate every title for the sake of one — which is
                    // what put "SAP Signavio License" under the + in David's
                    // 27 July screenshot.
                    .padding(.trailing, index == rows.count - 1 ? 32 : 0)
            }
            if hidden > 0 {
                // Silently dropping meetings is the one outcome worse than
                // overflowing: the widget would look complete and be wrong.
                Text("+\(hidden) more")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(skin.gapText)
                    .padding(.trailing, 32)
            }
        }
    }

    /// Drops a trailing gap pill. A gap describes the space *before* the next
    /// meeting, so one left dangling at the bottom points at something that is no
    /// longer on screen.
    private static func tidied(_ rows: [DayflowWidgetRow]) -> [DayflowWidgetRow] {
        var out = rows
        while let last = out.last, case .gap = last { out.removeLast() }
        return out
    }

    /// Meetings only — a gap pill is not something that can be "hidden".
    private static func meetingCount(_ rows: [DayflowWidgetRow]) -> Int {
        rows.reduce(into: 0) { total, row in
            if case .gap = row { return }
            total += 1
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
