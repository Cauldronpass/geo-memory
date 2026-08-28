//
//  DayflowQuickActions.swift
//  Dayflow
//
//  Home Screen quick action (long-press the app icon → "Add Task"), asked
//  for by David 2026-08-28, Session 77: "Id like to long press on the app
//  icon to add a task" — the same door Things gave him.
//
//  SwiftUI has no native API for UIApplicationShortcutItem, so this is the
//  standard adaptor sandwich: an app delegate that installs a scene delegate,
//  both of which only ever write the shortcut type into
//  `DayflowQuickActionRouter.shared.pending`. Since the composer round the
//  INBOX tab consumes it (DayflowInboxView.consumeQuickAction — the root
//  selects the Inbox tab, the capture card opens ready to type; Today's + is
//  event-only). Same held-pending-value shape as
//  `pendingNotePath` / `resolveNoteRoute()` — the fourth time this pattern
//  has been needed, for the same cold-launch reason as the other three.
//
//  The shortcut itself is declared statically in Dayflow/Info.plist
//  (`UIApplicationShortcutItems`, type "AddTask") — no pbxproj edit; the
//  generated Info.plist merges this file via INFOPLIST_FILE.
//

import SwiftUI
import UIKit

@Observable
final class DayflowQuickActionRouter {
    static let shared = DayflowQuickActionRouter()
    /// The `UIApplicationShortcutItemType` waiting to be acted on.
    /// Currently only "AddTask". Consumed (set back to nil) by ContentView.
    var pending: String? = nil
}

final class DayflowAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Cold launch straight from the quick action: the shortcut arrives in
        // the connection options, never at the scene delegate.
        if let item = options.shortcutItem {
            DayflowQuickActionRouter.shared.pending = item.type
        }
        let config = UISceneConfiguration(name: connectingSceneSession.configuration.name,
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = DayflowSceneDelegate.self
        return config
    }
}

final class DayflowSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Warm resume from the quick action.
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        DayflowQuickActionRouter.shared.pending = shortcutItem.type
        completionHandler(true)
    }
}
