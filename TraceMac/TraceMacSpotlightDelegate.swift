// TraceMacSpotlightDelegate.swift — receives a Spotlight result on the Mac.
//
// 2026-08-25. `TraceMacContentView` first carried a SwiftUI
// `.onContinueUserActivity(CSSearchableItemActionType)`, with the activity type
// declared in Info.plist. Isolation test: the index wrote (412 records), the
// result appeared in Spotlight, choosing it activated the app, and the modifier
// never fired — not once, with a `print` on its first line. On macOS the
// Spotlight continuation is delivered to `NSApplicationDelegate`'s
// `application(_:continue:restorationHandler:)` and SwiftUI's modifier does not
// see it. So: a delegate, and nothing else in it.
//
// It does not route. It sets `MacSearchRoute.shared.pending`, the same
// consume-and-clear hand-off the floating panel uses, and for the same reason:
// the window may be reopening at the moment the activity lands, and anything
// written straight into the view then is written to nothing. The content view's
// existing `.task(id:)`/`.onChange` pair on `searchRoute.pending` consumes it
// and routes through `openSearchResult`, so the navigator records the jump like
// every other one.
//
// This is the second `NSApplicationDelegateAdaptor` this app has had. The first
// (`TraceMacDropReceiver`, 2026-08-10) was removed the next day with the
// Dock-drop attempt it served. It is not a precedent against delegates; it was a
// delegate for a feature that did not work.

import AppKit
import CoreSpotlight

final class TraceMacSpotlightDelegate: NSObject, NSApplicationDelegate {

    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let destination = TraceSpotlightIndex.destination(for: id),
              destination != .preview else { return false }
        MacSearchRoute.shared.pending = .init(destination: destination, query: "")
        return true
    }
}
