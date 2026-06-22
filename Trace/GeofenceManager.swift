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

    // Design decisions (locked Build 18)
    private let defaultDwellSeconds: Double = 180   // 3 minutes
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
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Permission

    func requestAlwaysPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Start / Stop

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

        // Exclude places opted out of geofencing
        let eligible = places.filter { !$0.geofenceExcluded }

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

        let toMonitor = Array((frequent + nonFrequent).prefix(maxGeofences))

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
        if authorizationStatus == .authorizedAlways,
           UserDefaults.standard.bool(forKey: "geofence_enabled") {
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
        guard !isOnCooldown(placeID: place.id) else { return }
        guard !pendingDwellPlaceIDs.contains(place.id) else { return }

        let dwell = place.dwellTime.map { Double($0) * 60 } ?? defaultDwellSeconds
        scheduleDwellNotification(for: place, after: dwell)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        cancelDwellNotification(placeID: region.identifier)
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
    func cancelDwellNotificationForManualCheckIn(placeID: String) {
        cancelDwellNotification(placeID: placeID)
    }

    private func cancelDwellNotification(placeID: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["dwell-\(placeID)"])
        pendingDwellPlaceIDs.remove(placeID)
        // Also remove the cooldown we set at schedule time so it can re-trigger on next entry
        var c = cooldowns
        c.removeValue(forKey: placeID)
        cooldowns = c
    }

    private func cancelAllDwellNotifications() {
        let ids = pendingDwellPlaceIDs.map { "dwell-\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        pendingDwellPlaceIDs.removeAll()
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
