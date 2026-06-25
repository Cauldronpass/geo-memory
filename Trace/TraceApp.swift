import SwiftUI
import UIKit

// MARK: - Scene Delegate
// In scene-based SwiftUI apps, shortcut actions come here — NOT to UIApplicationDelegate.

class SceneDelegate: NSObject, UIWindowSceneDelegate {

    // Cold launch: app was not running when shortcut was tapped.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            UserDefaults.standard.set(shortcutItem.type, forKey: "pendingShortcutAction")
        }
    }

    // Foreground: app was running/suspended when shortcut was tapped.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        UserDefaults.standard.set(shortcutItem.type, forKey: "pendingShortcutAction")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .traceShortcut, object: nil)
        }
        completionHandler(true)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register geofence notification category with Check In action
        let checkInAction = UNNotificationAction(
            identifier: "CHECKIN_ACTION",
            title: "Check In",
            options: .foreground
        )
        let geofenceCategory = UNNotificationCategory(
            identifier: "GEOFENCE_CHECKIN",
            actions: [checkInAction],
            intentIdentifiers: []
        )
        let logWorkoutAction = UNNotificationAction(
            identifier: "LOG_WORKOUT_ACTION",
            title: "Log Workout",
            options: .foreground
        )
        let workoutCategory = UNNotificationCategory(
            identifier: "WORKOUT_PROMPT",
            actions: [logWorkoutAction],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([geofenceCategory, workoutCategory])
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: "quickpin",
                localizedTitle: "Quick Pin",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "mappin.circle.fill")
            ),
            UIApplicationShortcutItem(
                type: "checkin",
                localizedTitle: "Check In",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "checkmark.circle.fill")
            ),
            UIApplicationShortcutItem(
                type: "addnote",
                localizedTitle: "Add Note",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "note.text.badge.plus")
            ),
            UIApplicationShortcutItem(
                type: "addphoto",
                localizedTitle: "Add Photo",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "camera.fill")
            ),
        ]
        return true
    }

    // Wire SceneDelegate so iOS delivers shortcut actions to it.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Belt-and-suspenders: capture cold-launch shortcut here too.
        if let shortcutItem = options.shortcutItem {
            UserDefaults.standard.set(shortcutItem.type, forKey: "pendingShortcutAction")
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let traceShortcut        = Notification.Name("TraceShortcut")
    static let traceGeofenceCheckIn = Notification.Name("TraceGeofenceCheckIn")
    static let traceWorkoutPrompt   = Notification.Name("TraceWorkoutPrompt")
    static let traceOpenLeftDrawer  = Notification.Name("TraceOpenLeftDrawer")
    static let traceOpenRightDrawer = Notification.Name("TraceOpenRightDrawer")
}

// MARK: - UNUserNotificationCenterDelegate
// Handles "Check In" tap on geofence notifications.

extension AppDelegate: UNUserNotificationCenterDelegate {

    // Notification tapped while app is in foreground — show the banner
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // User tapped notification or the "Check In" action
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier

        if let placeID = userInfo["placeID"] as? String, category == "GEOFENCE_CHECKIN" {
            UserDefaults.standard.set(placeID, forKey: "pendingGeofencePlaceID")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .traceGeofenceCheckIn, object: nil)
            }
        } else if let placeID = userInfo["placeID"] as? String, category == "WORKOUT_PROMPT" {
            UserDefaults.standard.set(placeID, forKey: "pendingWorkoutPlaceID")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .traceWorkoutPrompt, object: nil)
            }
        }
        completionHandler()
    }
}

// MARK: - App Entry Point

@main
struct TraceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var notionService = NotionService.shared
    @State private var locationManager = LocationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(notionService)
                .environment(locationManager)
                .preferredColorScheme(.light)
                .task {
                    await notionService.fetchPlaces()
                    await notionService.fetchVisits()
                    await notionService.fetchCaptures()
                    await notionService.fetchPeople()
                    await notionService.fetchBilliardsSessions()
                    // Start geofencing if enabled in Settings
                    if UserDefaults.standard.bool(forKey: "geofence_enabled") {
                        GeofenceManager.shared.startMonitoring(places: notionService.places)
                    }
                }
        }
    }
}
