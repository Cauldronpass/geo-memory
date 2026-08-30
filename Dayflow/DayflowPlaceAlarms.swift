import Foundation
import CoreLocation
import UserNotifications

// MARK: - DayflowPlaceAlarms
//
// Session 78, D183. Location alarms, PLACE-attached — David's own question
// ("would it be attached to a task or attached to the place?") exposed the
// better design over the task-attached mockup: a place record gets one
// quiet "Ring on arrival" toggle, and arriving fires a single notification
// carrying whatever open tasks are linked [[place name]] at that moment.
// The linking gesture he already has IS the setup; a place with the toggle
// on but no open linked tasks stays silent; one geofence per place keeps
// iOS's ~20-region budget honest (task-attached would burn one per task).
//
// DayflowTaskAlarms' exact shape: prefix-swept ids, wholesale rewrite on
// the same scene transitions. The body is baked at SCHEDULE time (iOS gives
// no fire-time hook), so the task list it names is as fresh as the last app
// touch — the same honest limit the task alarms and morning summary carry.
// Places without coordinates cannot ring and the toggle never shows for
// them (the picker rule from the mockup round, kept).

/// Which places ring. UserDefaults-backed (DayflowFlagStore's pattern);
/// the first enable asks for When-In-Use location, which is all a
/// UNLocationNotificationTrigger needs.
@Observable
final class DayflowPlaceAlarmStore {
    static let shared = DayflowPlaceAlarmStore()
    private static let key = "dayflow_place_alarms"

    private(set) var enabledIDs: Set<String>
    private let manager = CLLocationManager()

    private init() {
        enabledIDs = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isEnabled(_ placeID: String) -> Bool { enabledIDs.contains(placeID) }

    func toggle(_ placeID: String) {
        if enabledIDs.contains(placeID) {
            enabledIDs.remove(placeID)
        } else {
            enabledIDs.insert(placeID)
            manager.requestWhenInUseAuthorization()
        }
        UserDefaults.standard.set(Array(enabledIDs), forKey: Self.key)
        Task { await DayflowPlaceAlarms.reschedule() }
    }
}

enum DayflowPlaceAlarms {

    private static let idPrefix = "dayflow-place-alarm-"
    /// A city block, roughly — generous enough that walking in the door
    /// beats the geofence race, tight enough that driving past does not.
    private static let radius: CLLocationDistance = 150

    static func reschedule() async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
        else { return }

        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        if !ours.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }

        let enabled = DayflowPlaceAlarmStore.shared.enabledIDs
        guard !enabled.isEmpty else { return }
        let places = await MainActor.run { NotionService.shared.places }
        let tasks = await MainActor.run { ReminderTaskStore.shared.allTasks }

        for place in places where enabled.contains(place.id) {
            // No pin, no ring — the toggle never shows for these, but the
            // guard stands anyway (a record's coordinates can be cleared
            // after the toggle was set).
            guard place.latitude != 0 || place.longitude != 0 else { continue }
            let linked = tasks.filter { ($0.notes ?? "").contains("[[\(place.name)]]") }
            guard !linked.isEmpty else { continue }

            let content = UNMutableNotificationContent()
            content.title = place.name
            let titles = linked.prefix(3).map(\.title).joined(separator: " \u{00B7} ")
            content.body = linked.count == 1
                ? titles
                : "\(linked.count) open here \u{2014} \(titles)"
            content.sound = .default

            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: place.latitude,
                                               longitude: place.longitude),
                radius: radius,
                identifier: idPrefix + place.id)
            region.notifyOnEntry = true
            region.notifyOnExit = false

            // repeats: true — David's call from the mockup round stands in
            // the place-attached shape too: it rings on every arrival while
            // linked open tasks exist; completing them is the off switch
            // (the next rewrite drops the request entirely).
            let trigger = UNLocationNotificationTrigger(region: region, repeats: true)
            try? await center.add(UNNotificationRequest(identifier: idPrefix + place.id,
                                                        content: content,
                                                        trigger: trigger))
        }
    }
}
