import Foundation
import CoreLocation

// MARK: - CheckInBridge
//
// The widget's one-tap Check in, Session 69 (2026-08-10). Two small tables that
// cross the App Group boundary, and they live in one file because they are one
// mechanism read in two directions — the rule this project learned from
// `shortPlaceName` having three copies and two different answers.
//
//   Trace / Dayflow  ──PlacesFeed.publish──▶  App Group  ──▶  the widget
//   the widget       ──CheckInQueue.stage──▶  App Group  ──▶  Trace drains it
//
// **Why staging rather than writing to Notion from the widget.** David chose
// this shape on 2026-08-10 after both were costed. The alternative put
// `NotionService`, `Models` and `Config.swift` — the API key — inside a
// memory-capped widget process, and gave a Notion POST a couple of seconds on
// whatever signal a pool hall has, with no screen on which to report that it
// failed. A check-in lost that way is lost silently. Here the widget writes a
// few hundred bytes to a local container and cannot fail slowly, the key never
// leaves the apps, and **Trace remains the only thing that writes a Visit to
// Notion** — the same "hand across intent, never data" rule `SatchelRouter`'s
// header states for documents.
//
// The cost, stated rather than hidden: a visit reaches Notion when Trace is next
// opened, not at the moment of the tap. The *visit's own date* is the tap's
// timestamp, carried in the record, so only its arrival is late.
//
// **This file deliberately does not import `Models.swift`.** `PlacesFeed.publish`
// takes `[PublishedPlace]`, not `[Place]`, and the caller does the mapping. A
// single reference to `Place` here would make this file uncompilable in the
// widget target, which is the one target that most needs it —
// `DayflowWidgetExtension` shares exactly one file from `Trace/` today.
//
// Target membership (hand-set, `Trace/` is not a buildable folder): Dayflow,
// Jot, TraceMac and DayflowWidgetExtension. Jot and TraceMac need it only
// because they compile `NotionService`, which now publishes the feed.

// MARK: - Places, as much of them as a widget needs

/// One place, reduced to what choosing between them requires. Deliberately not
/// `Place`: the widget has no business carrying Notion enrichment status, and a
/// feed the size of the real model would be rewritten on every fetch.
struct PublishedPlace: Codable, Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

enum PlacesFeed {
    private static let suiteName = "group.com.david.trace"
    private static let key = "trace_places_feed"

    /// How close counts as "here", in metres.
    ///
    /// **Deliberately one constant, and deliberately NOT the geofence rule.**
    /// `GeofenceManager` picks a per-place radius (a custom value, else 200m for
    /// a frequent place, else 50m) because it is deciding, unprompted, whether
    /// David has arrived somewhere — a false positive there fires a notification
    /// he did not ask for, so it is tuned tight and per place.
    ///
    /// A tap on Check in is not a guess. He has already asserted he is
    /// somewhere; the only question left is which of his places is meant, and
    /// nearest-wins answers that. Copying the geofence table here would have
    /// been a second copy of a rule written for a different question, which is
    /// how the two would drift into disagreeing about the same place.
    static let matchRadius: CLLocationDistance = 200

    static func publish(_ places: [PublishedPlace]) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(places)
        else { return }
        defaults.set(data, forKey: key)
    }

    static func all() -> [PublishedPlace] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let feed = try? JSONDecoder().decode([PublishedPlace].self, from: data)
        else { return [] }
        return feed
    }

    /// The closest published place within `within`, or nil.
    ///
    /// Returning nil is a real answer and the widget says so. Checking in to
    /// somewhere five kilometres away because it was the nearest record would
    /// be worse than doing nothing, and unlike a wrong note it writes to Notion.
    static func nearest(to location: CLLocation,
                        within: CLLocationDistance = matchRadius) -> PublishedPlace? {
        all()
            .map { ($0, location.distance(from: $0.location)) }
            .filter { $0.1 <= within }
            .min { $0.1 < $1.1 }?
            .0
    }
}

// MARK: - The pending queue

/// One tap, waiting for Trace to send it.
struct StagedCheckIn: Codable, Identifiable {
    /// A UUID rather than the place id, so a drain that succeeds on three of
    /// four records can clear exactly the three it sent. Keying on the place
    /// would collide the moment David checks in to the same place twice.
    let id: String
    let placeID: String
    let placeName: String
    /// When he tapped, not when it was sent. This becomes the Visit's date.
    let date: Date
}

/// What the last tap did, kept separately from the queue.
///
/// The queue is emptied by the drain, so it cannot be what the widget face
/// reads: the tile would go blank the moment the check-in actually succeeded,
/// which reads as failure. This survives the drain and is only ever overwritten.
struct CheckInOutcome: Codable {
    /// nil means nothing was within range. The tile needs to distinguish that
    /// from "not tapped today", or a tap in the middle of nowhere looks like a
    /// dead button.
    let placeName: String?
    let date: Date
}

enum CheckInQueue {
    private static let suiteName    = "group.com.david.trace"
    private static let queueKey     = "trace_pending_checkins"
    private static let outcomeKey   = "trace_last_checkin_outcome"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    // MARK: Written by the widget

    static func stage(placeID: String, placeName: String, at date: Date = Date()) {
        var queue = pending()
        queue.append(StagedCheckIn(id: UUID().uuidString,
                                   placeID: placeID,
                                   placeName: placeName,
                                   date: date))
        write(queue)
        record(CheckInOutcome(placeName: placeName, date: date))
    }

    /// Records a tap that found no place in range. Nothing is queued.
    static func recordNoPlaceFound(at date: Date = Date()) {
        record(CheckInOutcome(placeName: nil, date: date))
    }

    // MARK: Read by the widget face

    static func lastOutcome() -> CheckInOutcome? {
        guard let data = defaults?.data(forKey: outcomeKey),
              let outcome = try? JSONDecoder().decode(CheckInOutcome.self, from: data)
        else { return nil }
        return outcome
    }

    // MARK: Read and cleared by Trace

    static func pending() -> [StagedCheckIn] {
        guard let data = defaults?.data(forKey: queueKey),
              let queue = try? JSONDecoder().decode([StagedCheckIn].self, from: data)
        else { return [] }
        return queue
    }

    /// Removes only the records named. **Cleared after the POST succeeds, never
    /// before.** A claim-then-send would lose a check-in to a crash between the
    /// two; leaving it queued means the worst case is a retry on the next
    /// foreground, and a retry is visible where a loss is not.
    static func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        write(pending().filter { !ids.contains($0.id) })
    }

    // MARK: Private

    private static func write(_ queue: [StagedCheckIn]) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults?.set(data, forKey: queueKey)
    }

    private static func record(_ outcome: CheckInOutcome) {
        guard let data = try? JSONEncoder().encode(outcome) else { return }
        defaults?.set(data, forKey: outcomeKey)
    }
}
