//
//  DayflowGeofenceBridge.swift
//  Dayflow (the app is called Trace)
//
//  D492, Session 110. Merge pass (b), item 4: geofencing reaches the merged
//  app.
//
//  **The code was already here and had no door.** `Trace/GeofenceManager.swift`
//  came into this target in D469, carried in as a dependency of
//  `NotionService`, which calls `GeofenceManager.shared.isMonitoring` after
//  every places fetch. So the manager has been compiled, instantiated and
//  inert in this app since that build. What was missing was everything AROUND
//  it: the two notification categories, the delegate that receives a tap, the
//  screens that answer one, the launch that starts monitoring, and a switch to
//  turn it on.
//
//  **Why the tap does not use `pendingGeofencePlaceID`.** The old app writes
//  the place ID into `UserDefaults`, posts a `Notification.Name`, and then
//  retries matching it against `notion.places` every time the array changes —
//  `Trace/ContentView.swift`'s `checkPendingGeofence` / `resolveGeofencePlace`
//  pair. That is the exact mechanism `TraceRouter` replaced (D466): it cannot
//  tell a store that has not loaded from one that loaded and found nothing, and
//  it has no way to give up. `.checkIn(placeID:)` declares `.places` in its
//  `needs`, so the router holds it until `NotionService` reports ready and drops
//  it after `patience` rather than firing into a screen he left ten minutes ago.
//
//  **Nothing here is judgeable in the Simulator beyond compiling and the
//  Settings row.** A geofence needs a real phone and somewhere to go.
//

import SwiftUI
import UIKit
import UserNotifications

// MARK: - Notification categories

enum DayflowGeofenceNotifications {

    /// The two categories `GeofenceManager` stamps onto its notifications.
    ///
    /// **Registered, or the action button does not exist.** A notification whose
    /// `categoryIdentifier` names a category the app never registered still
    /// arrives; it just has no actions on it. So the failure mode is a silent
    /// missing button rather than an error, which is why this is written down
    /// beside the strings it has to match rather than left to be noticed.
    static func register() {
        let checkIn = UNNotificationAction(identifier: "CHECKIN_ACTION",
                                           title: "Check In",
                                           options: .foreground)
        let logWorkout = UNNotificationAction(identifier: "LOG_WORKOUT_ACTION",
                                              title: "Log Workout",
                                              options: .foreground)
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "GEOFENCE_CHECKIN",
                                   actions: [checkIn],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "WORKOUT_PROMPT",
                                   actions: [logWorkout],
                                   intentIdentifiers: [])
        ])
    }
}

// MARK: - The delegate

/// Receives the tap and turns it into a route.
///
/// **Its own object rather than a method on `DayflowAppDelegate`.** That file is
/// the quick-action adaptor sandwich and says so in its header; a notification
/// delegate bolted onto it would be a second unrelated job in a file named for
/// the first. This one is retained by the app delegate and does nothing else.
final class DayflowNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    static let shared = DayflowNotificationDelegate()

    /// A notification arriving while the app is open still shows its banner.
    ///
    /// **Deliberate, and it is the old app's behaviour.** Suppressing it would
    /// mean arriving somewhere with the app open produces nothing at all, which
    /// reads as the geofence having failed.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        let placeID = info["placeID"] as? String

        Task { @MainActor in
            switch category {
            case "GEOFENCE_CHECKIN":
                // The ID is passed through rather than resolved here. Resolving
                // would mean reading `NotionService.places` at tap time, which on
                // a cold launch from a notification is an empty array — and an
                // empty array cannot say whether the place is missing or the
                // fetch has not run. That is the whole reason the router exists.
                TraceRouter.shared.deliver(.checkIn(placeID: placeID, notes: nil))
            case "WORKOUT_PROMPT":
                // **No place ID, and that matches the old app.** Trace's own
                // handler stored one and then never read it: the workout prompt
                // opens the wizard empty and he picks. `.workout` carries no
                // payload for the same reason, so nothing here pretends to know
                // more than the screen will use.
                TraceRouter.shared.deliver(.workout)
            default:
                break
            }
            completionHandler()
        }
    }
}

// MARK: - Launch

extension DayflowAppDelegate {

    /// **The app had no `didFinishLaunchingWithOptions` at all** until now.
    /// `DayflowAppDelegate` existed solely to catch a cold-launch quick action in
    /// `configurationForConnecting`. This is implemented in an extension rather
    /// than added to that file, which is the quick-action adaptor and says so.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        startGeofencingIfEnabled()
        return true
    }

    /// Categories, the delegate, and monitoring if the switch is on.
    ///
    /// **`GeofenceManager.shared` is touched here on purpose, at launch.** When
    /// iOS relaunches a terminated app to deliver a region event, the event is
    /// delivered to a `CLLocationManager` whose delegate is set during launch.
    /// Creating the manager later — when a view appears, or when a fetch happens
    /// to reach it — is too late, and the event is dropped with nothing to say
    /// so. The old app never did this: its manager was built whenever something
    /// first touched `.shared`, which on a background relaunch is a race it
    /// sometimes lost.
    ///
    /// Only when the switch is on, so an app that has never been given Always
    /// authorization does not build a location manager it will not use.
    func startGeofencingIfEnabled() {
        DayflowGeofenceNotifications.register()
        UNUserNotificationCenter.current().delegate = DayflowNotificationDelegate.shared
        // The two arrival systems, introduced to each other (D493). Set before
        // any monitoring starts, so the very first registration already knows
        // which places are spoken for.
        GeofenceManager.reservedByHost = { DayflowPlaceAlarms.armedPlaceIDs() }
        guard GeofenceManager.isEnabled else { return }
        GeofenceManager.shared.startMonitoring(places: NotionService.shared.places)
    }
}

// MARK: - The Settings row

/// Arrival check-in, in Settings › Notifications.
///
/// **It lived in `Trace/LeftDrawerView.swift` and that file retires with the old
/// app** (D486), so without this the merged app would carry geofencing with no
/// way to turn it on or off - the same gap D485 found for the Notion and Google
/// keys, and found the same way: by asking what is only in Trace.
///
/// **On the Notifications screen rather than a Location one of its own.** What
/// this switch produces is a notification, and "why am I getting these" or "why
/// am I not" is the question that sends him to Settings. A screen named Location
/// would hold one row and answer neither.
struct DayflowGeofenceSection: View {

    @State private var enabled = GeofenceManager.isEnabled
    @State private var manager = GeofenceManager.shared

    var body: some View {
        Section {
            Toggle("Check in when I arrive", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    GeofenceManager.isEnabled = on
                    if on {
                        manager.requestAlwaysPermission()
                        // **Asked here, not at launch**, which is the pattern the
                        // morning summary, the task alarms and the place alarms
                        // all use in this app: a permission prompt belongs to the
                        // moment a feature is switched on, not to the first
                        // launch after an update.
                        Task {
                            _ = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound, .badge])
                        }
                        manager.startMonitoring(places: NotionService.shared.places)
                    } else {
                        manager.stopMonitoring()
                    }
                }

            if enabled {
                // **The status line exists because this feature fails silently.**
                // Always authorization can be refused, or downgraded later in
                // iOS Settings, and `startMonitoring` simply returns when it is
                // not granted. Without this row the switch would sit on, looking
                // like a promise the app is not keeping - and the only symptom
                // would be notifications that never come, months apart from the
                // cause.
                LabeledContent("Location access", value: accessLabel)
                    .font(.footnote)
                LabeledContent("Places watched", value: manager.isMonitoring
                               ? "\(manager.monitoredRegionCount)" : "none")
                    .font(.footnote)
                if manager.authorizationStatus != .authorizedAlways {
                    Text("iOS has not given Trace background location, so nothing is being watched. Settings › Privacy › Location Services › Trace › Always.")
                        .font(.footnote)
                        .foregroundStyle(Color.dayflowMuted)
                }
                Button("Re-check places") {
                    manager.startMonitoring(places: NotionService.shared.places)
                }
                .font(.footnote)
            }
        } header: {
            Text("Arrival")
        } footer: {
            Text("After a few minutes at a place you have saved, Trace offers to check you in. Leaving somewhere you have marked for workouts offers to log one. iOS watches at most 20 places at a time; the ones you have marked Frequent are watched first, and places set to ring on arrival are skipped here so one arrival is one notification.")
        }
    }

    private var accessLabel: String {
        switch manager.authorizationStatus {
        case .authorizedAlways:    return "Always"
        case .authorizedWhenInUse: return "While using"
        case .denied:              return "Denied"
        case .restricted:          return "Restricted"
        case .notDetermined:       return "Not asked"
        @unknown default:          return "Unknown"
        }
    }
}
