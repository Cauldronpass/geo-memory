// DayflowLauncherWidget.swift
// One surface in front of Trace, Dayflow, Jot and Satchel.
//
// Session 68 (2026-08-09). David: *"Would there be any benefit for a simple
// wrapper app that connects all of them into one interface? One that would allow
// me to have a nice widget for different things i might want to do as a launching
// off point."*
//
// **A wrapper app was the wrong shape and this is the right one.** iOS will not
// let one app host another's UI, so a wrapper could only ever be a launcher —
// and a fifth app to launch four apps costs a bundle id, a provisioning profile,
// a TestFlight lane and one more Home Screen icon, while removing none of the
// four. A widget costs a file.
//
// **The rule this design is built on: four icons already launch four apps in one
// tap.** So a widget that launches *apps* is worse than the Home Screen it sits
// on. It has to do the two things an icon cannot — start an *action*, and show
// *state* before you choose. Everything below is one of those two.
//
// It lives in Dayflow's widget bundle because that target already holds the App
// Group entitlement and `ActiveEndeavorFeed`, and Dayflow is the app opened
// daily. Nothing here is Dayflow-specific beyond that.

import WidgetKit
import SwiftUI
// `Button(intent:)` lives in SwiftUI but its initialiser is gated on the
// `AppIntents` module being imported, so the symbol resolves and the
// initialiser does not. Session 69: the error reads "Initializer
// 'init(intent:label:)' is not available due to missing import of defining
// module 'AppIntents'", which names the fix in full and is worth reading
// literally rather than treating as a target-membership problem.
import AppIntents

// MARK: - Palette
//
// Hardcoded rather than semantic, matching `DayflowWidget`'s own choice and for
// the reason recorded in `SatchelApp`: a system colour flips in dark mode and a
// widget drawn on parchment then renders ink-on-ink. These are the mockup's.

private enum LauncherPalette {
    /// `#1c1c1f`, lifted verbatim from `DayflowWidget`'s own dark palette rather
    /// than eyeballed to match. Two widgets sitting on one Home Screen are read
    /// as one thing, and "nearly the same dark" is more visible side by side than
    /// two obviously different colours would be.
    static let card      = Color(red: 0.110, green: 0.110, blue: 0.122)
    /// The tile fill: the card lifted just enough to read as a surface on it.
    static let parchment = Color(red: 0.176, green: 0.176, blue: 0.192)
    static let ink       = Color(red: 0.949, green: 0.949, blue: 0.961)
    static let muted     = Color(red: 0.596, green: 0.596, blue: 0.620)
    static let hair      = Color(red: 0.290, green: 0.290, blue: 0.310)
    /// The date widget's dark "tomorrow" violet, which is the nearest thing it
    /// has to an accent, so the endeavor line belongs to the same family.
    static let indigo    = Color(red: 0.725, green: 0.682, blue: 0.941)
}

// MARK: - The four doors
//
// **Named for what you get, not for where it lives.** You do not think "I need
// Jot", you think "write this down before I lose it". The app name is not on the
// tile at all.
//
// **A widget cannot open another app, and that is why v1's buttons did nothing.**
//
// `Link` and `widgetURL` hand their URL to the widget's OWN containing app —
// always. So `jot://` from a widget in Dayflow's bundle was delivered to
// *Dayflow*, which does not know that scheme and correctly ignored it. Three of
// the four tiles were dead on arrival and the fourth worked only because it
// happened to be Dayflow's own scheme.
//
// Verifying that the destination routes existed — which I did, one by one — was
// checking the wrong end. **The question was never "does `satchel://scan` work",
// it was "who receives this tap".**
//
// So every tile is now `dayflow://launch?target=…`, and Dayflow re-opens the
// foreign scheme with `UIApplication.shared.open`. That is not a workaround, it
// is the only route available: an extension cannot open an arbitrary app, its
// container can. Dayflow already does exactly this for `openCalendar`, which
// hands off to Fantastical.
//
// Cost, stated: every tile except Today bounces through Dayflow, so there is a
// visible flash of it on the way. Unavoidable from a widget.
//
// **Session 69 audit of the four routes, by reading each receiving end rather
// than by trusting this file's own notes.**
//
// - `capture` → `jot://`. **Works, and needs no `onOpenURL`.** The queue said
//   Jot having no URL handler was the first thing to fix. Jot is a one-screen
//   app: `DayflowJotApp`'s `WindowGroup` is `CaptureView()` and nothing else, so
//   launching it by any URL lands in the capture field by construction. A router
//   would have been code that could only route to where the app already was.
// - `checkin` → `trace://checkin`. Works. `Trace/ContentView.swift:520` handles
//   it, with the pending/retry resolution Session 27 built.
// - `file` → `satchel://scan`. Works. `SatchelRouter` handles it.
// - `today` → **was a no-op and is now handled.** See the `launch` branch in
//   `Dayflow/ContentView.swift`: the tile now resets `selectedDate` and clears
//   any cover, because Dayflow holds its date across launches and "Today" that
//   lands on Tomorrow is a broken button, not a free one.
//
// **What one-tap Check in would actually cost, measured 2026-08-10 rather than
// assumed.** `Button(intent:)` is the easy half. The write is
// `NotionService.checkIn(place:…)`, a Notion POST that needs the API key from
// `Config.swift`, and it takes a `Place` — so the widget must also know *which*
// place, which means the location leg this item lists third is a prerequisite,
// not an independent piece. Today the extension's only shared file is
// `CalendarService.swift`; pulling Notion's client into a memory-capped widget
// process is the real decision, and the lighter alternative is staging the
// check-in into the App Group (the shape `AppGroup.stageIncoming` already uses
// for documents) and letting Trace drain it. Not built: it is David's call
// whether a check-in that reaches Notion on next app launch is a check-in.

private struct LauncherAction: Identifiable {
    let id: String
    let glyph: String
    let title: String
    /// **nil is the interesting case: the tile that runs in place.** Check in no
    /// longer has a URL because it no longer goes anywhere — it runs
    /// `CheckInIntent` in this process. Modelled as an absent destination rather
    /// than a `isInteractive` flag so the two states cannot both be set.
    let url: URL?

    /// Referenced by the small family too, so it is named rather than reached
    /// for as `all[0]` — an index is a claim about array order that nothing
    /// enforces.
    static let capture = LauncherAction(
        id: "capture", glyph: "square.and.pencil", title: "Capture",
        url: URL(string: "dayflow://launch?target=capture")!)

    static let all: [LauncherAction] = [
        capture,
        .init(id: "checkin",  glyph: "mappin.circle.fill",
              title: "Check in", url: nil),
        .init(id: "today",    glyph: "checklist",
              title: "Today",    url: URL(string: "dayflow://launch?target=today")!),
        .init(id: "scan",     glyph: "doc.viewfinder",
              title: "File",     url: URL(string: "dayflow://launch?target=file")!),
    ]
}

// MARK: - Entry

struct LauncherEntry: TimelineEntry {
    let date: Date
    /// The endeavor covering today, if any. Read from the same App Group feed
    /// `DayflowWidget` uses, so the two cannot disagree about what is running.
    let endeavor: (id: String, name: String)?
    /// The last Check in tap, **only if it was today**. Older than that and the
    /// tile goes back to reading "Check in": a tile still saying "Arlington
    /// Lanes" on Tuesday from a Saturday tap is worse than one saying nothing,
    /// because it looks like current state.
    let checkIn: CheckInOutcome?
}

// MARK: - Provider

struct LauncherProvider: TimelineProvider {

    func placeholder(in context: Context) -> LauncherEntry {
LauncherEntry(date: .now,
                      endeavor: ("megan-s-wedding-week-2026", "Megan's Wedding Week"),
                      checkIn: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        // Refreshed at the next midnight rather than on an interval. Nothing here
        // changes within a day: the date is the date, and an endeavor starts and
        // ends on day boundaries. An hourly reload would spend the widget's
        // refresh budget to redraw the same pixels.
        let start = Calendar.current.startOfDay(for: .now)
        let next  = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry()], policy: .after(next)))
    }

    private func entry() -> LauncherEntry {
        let outcome = CheckInQueue.lastOutcome()
        let todaysOutcome = outcome.flatMap {
            Calendar.current.isDateInToday($0.date) ? $0 : nil
        }
        return LauncherEntry(date: .now,
                             endeavor: ActiveEndeavorFeed.active(),
                             checkIn: todaysOutcome)
    }
}

// MARK: - Views

private struct LauncherContext: View {
    let date: Date
    let endeavor: (id: String, name: String)?

    var body: some View {
        HStack(spacing: 8) {
            // The same indigo stripe the Mac's day list uses for an endeavor
            // (D68). A range drawn as a range, in the one place on a phone where
            // there is room for exactly one mark.
            if endeavor != nil {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LauncherPalette.indigo)
                    .frame(width: 3, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let endeavor {
                    Text(endeavor.name.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(LauncherPalette.indigo)
                        .lineLimit(1)
                }
                Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(LauncherPalette.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LauncherTile: View {
    let action: LauncherAction
    /// Today's Check in result, passed to every tile and read by one. Cheaper
    /// than a second tile type, and it keeps all four the same shape.
    var checkIn: CheckInOutcome? = nil

    /// What this tile says right now. Only Check in ever changes.
    private var label: (glyph: String, title: String, tinted: Bool) {
        guard action.url == nil, let checkIn else {
            return (action.glyph, action.title, false)
        }
        guard let place = checkIn.placeName else {
            // A tap that found nothing. Says so, and stays tappable — he may
            // have been indoors, or early.
            return ("mappin.slash", "No place", false)
        }
        return ("checkmark.circle.fill", place, true)
    }

    var body: some View {
        // `Link`, not `widgetURL`. A medium widget can carry several tap targets
        // and `widgetURL` is one for the whole widget — which is the difference
        // between a launcher and a shortcut.
        //
        // Except for the tile with no destination, which is a `Button(intent:)`
        // and never leaves the widget. One label view for both, because two
        // copies of a tile's styling is how the four stop looking like a set.
        if let url = action.url {
            Link(destination: url) { face }
        } else {
            Button(intent: CheckInIntent()) { face }
                .buttonStyle(.plain)
        }
    }

    private var face: some View {
        let l = label
        return VStack(spacing: 4) {
            Image(systemName: l.glyph)
                .font(.system(size: 16, weight: .medium))
            Text(l.title)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(l.tinted ? LauncherPalette.indigo : LauncherPalette.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(LauncherPalette.parchment, in: RoundedRectangle(cornerRadius: 11))
    }
}

struct LauncherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LauncherEntry

    var body: some View {
        switch family {
        case .systemSmall: small
        default:           medium
        }
    }

    /// One glance, one tap. **Not four tiles shrunk** — at 158pt a four-up grid
    /// gives four illegible glyphs, and the small size is where a widget has to
    /// answer one question rather than offer four.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherContext(date: entry.date, endeavor: entry.endeavor)
            Spacer(minLength: 6)
            Link(destination: LauncherAction.capture.url ?? URL(string: "dayflow://launch?target=capture")!) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                    Text("Capture").font(.system(size: 13, weight: .semibold))
                }
                // On dark, the filled button inverts: the card is nearly black,
                // so `ink` as a background would be invisible.
                .foregroundStyle(LauncherPalette.card)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(LauncherPalette.ink, in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherContext(date: entry.date, endeavor: entry.endeavor)
            Divider().overlay(LauncherPalette.hair).padding(.vertical, 9)
            HStack(spacing: 7) {
                ForEach(LauncherAction.all) { LauncherTile(action: $0, checkIn: entry.checkIn) }
            }
        }
    }
}

// MARK: - Widget

struct DayflowLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DayflowLauncherWidget", provider: LauncherProvider()) { entry in
            LauncherWidgetView(entry: entry)
                .containerBackground(LauncherPalette.card, for: .widget)
        }
        .configurationDisplayName("Launcher")
        .description("Today, what you are in the middle of, and the four things you do most.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
