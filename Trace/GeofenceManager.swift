import CoreLocation
import UserNotifications
import Foundation

// MARK: - GeofenceManager
// Monitors up to 20 CLCircularRegions (iOS cap). Frequent places always included first,
// remaining slots filled by nearest non-frequent places. Refreshes on significant location change.
// Schedules a UNTimeIntervalNotificationTrigger after dwell period — works in background.
// Cancels the pending notification if the user exits before dwell elapses.

@Observable
class GeofenceManager: NSObject, CLLocationManagerDelegate {
    static let shared = GeofenceManager()

    private let locationManager = CLLocationManager()
    private var pendingDwellPlaceIDs: Set<String> = []  // tracks places with scheduled dwell notifications
    private var entryTimes: [String: Date] = [:]         // records when we entered each geofence

    // Design decisions (locked Build 18)
    private let defaultDwellSeconds: Double = 180   // 3 minutes
    private let workoutMinDwellSeconds: Double = 30 * 60  // must be inside 30+ min to trigger workout prompt
    private let defaultRadius: Double = 50          // metres
    private let frequentRadius: Double = 200        // metres for Frequent places
    private let cooldownSeconds: Double = 4 * 3600  // 4 hours between notifications per place
    private let maxGeofences = 20                   // iOS hard cap

    var isMonitoring = false
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var monitoredRegionCount: Int { locationManager.monitoredRegions.count }

    private override init() {
        super.init()
        locationManager.delegate = self
        // **`allowsBackgroundLocationUpdates` is deliberately NOT set** (D492).
        //
        // It was `true` here for years and it bought nothing. That flag is for
        // CONTINUOUS updates while backgrounded - `startUpdatingLocation` running
        // with the app away - and this manager never calls that. Region
        // monitoring and significant-location-change both relaunch the app on
        // their own, without it and without any `UIBackgroundModes` entry, which
        // is why geofencing has worked all this time in an app whose project file
        // has never declared one.
        //
        // Setting it without `location` in `UIBackgroundModes` is documented to
        // raise. It evidently has not on his phone, but leaving a line that is
        // both useless and documented to throw is a crash waiting for an OS
        // version to start enforcing it.
        locationManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - The on/off switch

    /// **Read from the App Group, not `UserDefaults.standard`** (D492, and the
    /// same fault D485 found in `GooglePlacesService`).
    ///
    /// `UserDefaults.standard` is PER APP. The switch David turned on lives in
    /// the OLD Trace app's defaults, so the merged app read `false` and
    /// geofencing was simply off in it, silently, with a Settings row that would
    /// have said so honestly and nothing to explain why it had reset.
    ///
    /// **The legacy read below does NOT rescue his setting, and D492 claimed it
    /// did.** `UserDefaults.standard` here means the defaults of whichever app is
    /// RUNNING. Read from the merged app it is the merged app's own, which never
    /// held this key; the value David set is in the old Trace app's sandbox and
    /// is not reachable from outside it. The legacy branch only lets the OLD app
    /// publish its value to the group, and that needs the old app rebuilt with
    /// this code and run once - which will not happen, because it was deleted
    /// from his phone on 2026-09-20.
    ///
    /// So the branch is correct and useless to him, and the honest answer is the
    /// Settings row: he turns it on once. Kept rather than deleted because it is
    /// still right for any other app in the family that carries a legacy value.
    static var isEnabled: Bool {
        get {
            let group = UserDefaults(suiteName: "group.com.david.trace")
            if let shared = group?.object(forKey: enabledKey) as? Bool { return shared }
            let legacy = UserDefaults.standard.bool(forKey: enabledKey)
            if legacy { group?.set(true, forKey: enabledKey) }
            return legacy
        }
        set {
            UserDefaults(suiteName: "group.com.david.trace")?.set(newValue, forKey: enabledKey)
            // Written to both while the old Trace app is still installed, so the
            // two cannot disagree about whether they are monitoring.
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    private static let enabledKey = "geofence_enabled"

    // MARK: - Permission

    func requestAlwaysPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Start / Stop

    /// Places the HOST app is already watching by some other means, and the
    /// slots they cost. **D493.**
    ///
    /// **Why a closure and not a direct call.** The merged app has a second
    /// arrival system, `DayflowPlaceAlarms` (D183): an opt-in "Ring on arrival"
    /// per place that fires a notification naming the open tasks linked there.
    /// It lives in `Dayflow/` and this file is in `Trace/`, compiled by up to
    /// seven targets. Naming that type from here breaks every one of them that
    /// does not have it, which is D440's trap and has cost this project a
    /// session. So the host sets this; where nothing sets it, nothing changes.
    ///
    /// Returns the place IDs that have a live region of their own right now.
    static var reservedByHost: (() -> Set<String>)?

    func startMonitoring(places: [Place]) {
        guard authorizationStatus == .authorizedAlways else { return }

        // Clear existing regions only — leave any pending dwell notifications intact
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }

        guard !places.isEmpty else {
            locationManager.startMonitoringSignificantLocationChanges()
            isMonitoring = true
            return
        }

        // **Two exclusions, not one** (D493).
        //
        // `geofenceExcluded` is his own per-place opt-out and has always been
        // here. `reserved` is the merge's: a place that already rings on arrival
        // would otherwise notify him TWICE for one arrival — the alarm naming
        // his tasks, then this one asking him to check in a few minutes later.
        // The alarm is the more useful of the two, so this one gives way.
        let reserved = Self.reservedByHost?() ?? []
        let eligible = places.filter { !$0.geofenceExcluded && !reserved.contains($0.id) }

        // Frequent places first (regardless of distance), then nearest non-frequent
        let frequent = eligible.filter { $0.frequent }
        let nonFrequent: [Place]
        if let userLocation = locationManager.location {
            nonFrequent = eligible
                .filter { !$0.frequent }
                .sorted {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: userLocation)
                    < CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: userLocation)
                }
        } else {
            nonFrequent = eligible.filter { !$0.frequent }
        }

        // **And the budget shrinks by what is reserved**, which is the half of
        // this that is not about notifications at all. iOS caps an app at twenty
        // monitored regions, and a `UNLocationNotificationTrigger` region counts
        // against the SAME twenty. So every armed place alarm is one fewer
        // geofence whether or not anything here admits it. Taking the full
        // twenty anyway would push the total past the cap and iOS would drop
        // registrations, silently, in an order nobody chose.
        let budget = max(0, maxGeofences - reserved.count)
        let toMonitor = Array((frequent + nonFrequent).prefix(budget))

        for place in toMonitor {
            let radius: Double
            if let custom = place.geofenceRadius, custom > 0 {
                radius = Double(custom)
            } else {
                radius = place.frequent ? frequentRadius : defaultRadius
            }
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                radius: radius,
                identifier: place.id
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            locationManager.startMonitoring(for: region)
        }

        locationManager.startMonitoringSignificantLocationChanges()
        isMonitoring = true
    }

    func stopMonitoring() {
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
        locationManager.stopMonitoringSignificantLocationChanges()
        cancelAllDwellNotifications()
        isMonitoring = false
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways, Self.isEnabled {
            startMonitoring(places: NotionService.shared.places)
        }
    }

    // Significant location change → re-rank and refresh the 20 monitored regions
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let places = NotionService.shared.places
        guard !places.isEmpty else { return }
        startMonitoring(places: places)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let place = NotionService.shared.places.first(where: { $0.id == region.identifier }) else { return }

        // Record entry time for workout prompt calculation on exit
        entryTimes[region.identifier] = Date()

        guard !isOnCooldown(placeID: place.id) else { return }
        guard !pendingDwellPlaceIDs.contains(place.id) else { return }

        let dwell = place.dwellTime.map { Double($0) * 60 } ?? defaultDwellSeconds
        scheduleDwellNotification(for: place, after: dwell)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let placeID = region.identifier
        cancelDwellNotification(placeID: placeID)

        // Fire log prompt if place has it enabled and we were inside long enough
        if let place = NotionService.shared.places.first(where: { $0.id == placeID }),
           place.promptLog,
           let entryTime = entryTimes[placeID] {
            let duration = Date().timeIntervalSince(entryTime)
            if duration >= workoutMinDwellSeconds && !isOnWorkoutCooldown(placeID: placeID) {
                scheduleWorkoutPromptNotification(for: place, duration: duration)
                setWorkoutCooldown(placeID: placeID)
            }
        }
        entryTimes.removeValue(forKey: placeID)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // Best-effort — silently ignore individual region failures
    }

    // MARK: - Dwell Notification (UNTimeIntervalNotificationTrigger — works in background)

    private func scheduleDwellNotification(for place: Place, after seconds: Double) {
        setCooldown(placeID: place.id)  // set cooldown at schedule time to prevent double-scheduling
        pendingDwellPlaceIDs.insert(place.id)

        let content = UNMutableNotificationContent()
        content.title = place.name
        content.body = "You've been here a few minutes — check in?"
        content.sound = .default
        content.userInfo = ["placeID": place.id, "placeName": place.name]
        content.categoryIdentifier = "GEOFENCE_CHECKIN"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(
            identifier: "dwell-\(place.id)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Call this after a manual check-in to prevent the dwell notification from firing redundantly.
    /// Keeps the cooldown active so geofencing won't prompt again for 4 hours.
    func cancelDwellNotificationForManualCheckIn(placeID: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["dwell-\(placeID)"])
        pendingDwellPlaceIDs.remove(placeID)
        // Do NOT clear the cooldown — user just checked in manually, suppress for 4 hours.
        // Ensure a cooldown is set in case the dwell timer hadn't fired yet.
        setCooldown(placeID: placeID)
    }

    private func cancelDwellNotification(placeID: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["dwell-\(placeID)"])
        pendingDwellPlaceIDs.remove(placeID)
        // Clear the cooldown on geofence exit so it can re-trigger on next entry
        var c = cooldowns
        c.removeValue(forKey: placeID)
        cooldowns = c
    }

    private func cancelAllDwellNotifications() {
        let ids = pendingDwellPlaceIDs.map { "dwell-\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        pendingDwellPlaceIDs.removeAll()
    }

    // MARK: - Workout Prompt Notification

    private func scheduleWorkoutPromptNotification(for place: Place, duration: TimeInterval) {
        let minutes = Int(duration / 60)
        let content = UNMutableNotificationContent()
        content.title = "Log your \(place.name) workout?"
        content.body  = "You were there for \(minutes) minutes."
        content.sound = .default
        content.userInfo = ["placeID": place.id, "placeName": place.name]
        content.categoryIdentifier = "WORKOUT_PROMPT"

        // Fire immediately (1-second delay required by UNTimeIntervalNotificationTrigger)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "workout-\(place.id)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Workout Cooldown (separate from check-in cooldown)

    private func isOnWorkoutCooldown(placeID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "workout_prompt_cooldowns"),
              let cooldowns = try? JSONDecoder().decode([String: Date].self, from: data),
              let last = cooldowns[placeID] else { return false }
        return Date().timeIntervalSince(last) < cooldownSeconds
    }

    private func setWorkoutCooldown(placeID: String) {
        var cooldowns: [String: Date] = [:]
        if let data = UserDefaults.standard.data(forKey: "workout_prompt_cooldowns"),
           let existing = try? JSONDecoder().decode([String: Date].self, from: data) {
            cooldowns = existing
        }
        cooldowns[placeID] = Date()
        if let encoded = try? JSONEncoder().encode(cooldowns) {
            UserDefaults.standard.set(encoded, forKey: "workout_prompt_cooldowns")
        }
    }

    // MARK: - Cooldown (UserDefaults-backed [placeID: Date])

    private func isOnCooldown(placeID: String) -> Bool {
        guard let last = cooldowns[placeID] else { return false }
        return Date().timeIntervalSince(last) < cooldownSeconds
    }

    private func setCooldown(placeID: String) {
        var c = cooldowns
        c[placeID] = Date()
        cooldowns = c
    }

    private var cooldowns: [String: Date] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "geofence_cooldowns"),
                  let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(encoded, forKey: "geofence_cooldowns")
            }
        }
    }
}

extension CLAuthorizationStatus {
    var debugLabel: String {
        switch self {
        case .notDetermined:       return "notDetermined"
        case .restricted:          return "restricted"
        case .denied:              return "denied"
        case .authorizedAlways:    return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default:          return "unknown"
        }
    }
}
