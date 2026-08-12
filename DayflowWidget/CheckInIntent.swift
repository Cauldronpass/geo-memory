import AppIntents
import WidgetKit
import CoreLocation

// MARK: - CheckInIntent
//
// The launcher widget's Check in tile, Session 69 (2026-08-10). The one thing on
// that widget that is an action rather than a door, which is the argument for
// the widget existing at all: four Home Screen icons already launch four apps.
//
// **It launches nothing.** `openAppWhenRun = false`, the work happens in the
// widget process, and all of it is local: read the cached location fix, pick the
// nearest published place, append a record to the App Group. Trace sends it to
// Notion next time it is opened. `CheckInBridge.swift` has the reasoning for
// that split and what it costs.
//
// **The location fetcher is the existing one, not a second copy.**
// `DayflowWidgetLocationFetcher` was written for the widget's weather block and
// cost three sessions to get right — the manager has to outlive the request, the
// continuation must resume exactly once, and there must be a timeout or
// WidgetKit's budget expires with the widget hung rather than failed. Every one
// of those applies here unchanged. A fresh `CLLocationManager()` in this file
// would have reintroduced all three.
//
// Six seconds rather than the weather block's eight: an intent runs while David
// is looking at his Home Screen waiting for something to happen, where a
// timeline refresh runs unobserved.
//
// **Every path records an outcome and reloads the timeline.** A tile that does
// nothing visible on tap is indistinguishable from a broken one, and this is a
// phone he can only reach through TestFlight — the feature has to be able to
// report on itself. "No place nearby" is a real answer and the face says so.
struct CheckInIntent: AppIntent {
    static var title: LocalizedStringResource = "Check in"
    static var description = IntentDescription("Records a visit at the nearest saved place.")

    /// The entire point. `true` here would make this a slower version of the
    /// link it replaced.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        defer { WidgetCenter.shared.reloadTimelines(ofKind: "DayflowLauncherWidget") }

        guard let fix = await DayflowWidgetLocationFetcher.shared.currentLocation(timeout: 6),
              let place = PlacesFeed.nearest(to: fix)
        else {
            // Covers both no fix and a fix with nothing in range. They are the
            // same thing to the person tapping: it did not know where he was.
            CheckInQueue.recordNoPlaceFound()
            return .result()
        }

        CheckInQueue.stage(placeID: place.id, placeName: place.name)
        return .result()
    }
}
