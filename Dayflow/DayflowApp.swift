//
//  DayflowApp.swift
//  Dayflow
//
//  Entry point. Mirrors TraceApp.swift's structure — same shared
//  NotionService/NoteStore singletons via target membership (see
//  Dayflow-HANDOFF.md "One-time setup"), same iCloud container
//  (iCloud.com.david.Trace), separate bundle ID (com.david.Dayflow).
//
//  **Fetch calls added 2026-07-20 (Session 13)** — David asked directly for
//  wikilink taps to actually work ("allowing the people and places links to
//  work... thats major"). Turned out the taps themselves were already wired
//  in DayflowDailyNoteEditor.swift since Session 5 (and just got wired into
//  DayflowProjectNoteView.swift this same session), but `NotionService.shared`
//  is a plain in-memory cache per process — `places`/`people` start as `[]`
//  and stay that way until something calls `fetchPlaces()`/`fetchPeople()`.
//  Nothing in Dayflow ever did, so wikiSuggestions always returned zero
//  results and resolveWikiLink could never match a name, everywhere in the
//  app, since Session 5 — this line used to say "add the specific fetch
//  calls when that work starts, not here," and that work has now started.
//  Deliberately only the two Dayflow actually needs — NOT the full
//  fetchCaptures/fetchBilliardsSessions/fetchWorkouts spread TraceApp.swift's
//  own `.task` does at launch; Dayflow still doesn't need Trace's full
//  browsing surface, only enough Place/Person data in memory to resolve a
//  [[wikilink]] someone taps.
//
//  **fetchVisits() added 2026-07-20 (Session 17)** — DayflowWikiSummaryView's
//  new Activity tab (person) and Visits tab (place) read `NotionService.shared
//  .visits` directly, same as Trace's own PersonDetailView/PlaceDetailView do.
//  Without this call that array stays empty forever, same class of gap
//  fetchPlaces/fetchPeople fixed for wikilinks in Session 13. Still not the
//  full Trace spread — fetchCaptures/fetchBilliardsSessions/fetchWorkouts
//  remain genuinely unneeded (nothing in Dayflow reads them).
//
//  **Appearance override added 2026-07-20** (DayflowSettingsView.swift,
//  build order step 6) — `.preferredColorScheme` applied here at the
//  WindowGroup root so it covers every screen (sheets, full covers included),
//  not just the top-level ContentView. Reads the same `@AppStorage` key
//  Settings writes (`dayflow_appearance`); `nil` means "follow the system
//  setting," which was already the app's only behavior before this existed.
//
//  **Inbox badge added 2026-07-24** (Session 44 addendum 10) — confirmed
//  directly with David: a real app icon badge showing the Notes/Inbox/
//  count, not just an in-app indicator. `DayflowInboxBadge.refresh()` below
//  requests badge-only notification authorization the first time it runs
//  (one system prompt — note the dialog itself still reads as the generic
//  "Would Like to Send You Notifications," iOS doesn't word it differently
//  for a badge-only request even though that's all this ever asks for or
//  uses; worth knowing so the wording isn't a surprise) and refreshes the
//  count at launch plus on every `noteStoreInboxDidChange` post — which
//  already fires for iCloud-delivered changes too (NoteStore's own
//  NSMetadataQuery observer), so the badge stays right even when a note is
//  filed/deleted from another device, not just from this one.
//

import SwiftUI
import UserNotifications
import CoreLocation

@main
struct DayflowApp: App {
    @State private var notionService = NotionService.shared
    /// Defaults to **light**, not system. The Dayflow skin is a hardcoded warm
    /// cream palette; in dark mode its adaptive cards render black on cream and
    /// the whole screen is unreadable. With a "system" default, a phone set to
    /// dark showed that on first launch without anyone choosing it.
    /// Changed 2026-07-28 after David hit it. See `dayflowCard`.
    @AppStorage("dayflow_appearance") private var appearanceRaw: String = "light"
    @Environment(\.scenePhase) private var scenePhase

    private var preferredScheme: ColorScheme? {
        switch appearanceRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(notionService)
                .preferredColorScheme(preferredScheme)
                .task {
                    await notionService.fetchPlaces()
                    await notionService.fetchPeople()
                    await notionService.fetchVisits()
                    await DayflowInboxBadge.refresh()
                    DayflowLocationPrimer.primeIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: .noteStoreInboxDidChange)) { _ in
                    Task { await DayflowInboxBadge.refresh() }
                }
                // Re-read the pin index whenever the app comes back to the
                // foreground. Added 2026-08-10 (Session 69), after the Mac
                // became a second writer of `Dayflow-Flags.json`.
                //
                // **This was not a bug until today, and that is the point.**
                // `DayflowFlagStore` loads once in `init`. While Dayflow was the
                // only app that wrote the file, memory and disk could not drift:
                // every change came from `toggleFlag`, which updates both. The
                // moment the Mac writes it too, a resident Dayflow is answering
                // from a snapshot — David pinned on the Mac and the phone showed
                // nothing, with the correct file sitting on disk the whole time.
                //
                // At the `WindowGroup` root so it covers every screen that reads
                // flags: the project list, the pinned-days section, the day and
                // project note pin buttons, the calendar browse grid. A hook per
                // screen would be five places to keep in step with a sixth.
                //
                // `.active` only, and only from a real background return, so this
                // cannot land mid-edit: a foreground toggle has already written
                // through to disk before the app can be backgrounded.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { DayflowFlagStore.shared.reload() }
                }
        }
    }
}

// MARK: - Inbox app icon badge

/// Keeps the Home Screen app icon badge in sync with how many notes are
/// currently sitting in `Notes/Inbox/`. Badge-only authorization — never
/// requests `.alert`/`.sound`, and nothing in this app ever schedules an
/// actual notification, so accepting the one prompt this triggers doesn't
/// open the door to banners or sounds later.
enum DayflowInboxBadge {
    static func refresh() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.badge])
        }
        let count = (try? NoteStore.shared.listFiles(in: "Notes/Inbox").count) ?? 0
        try? await center.setBadgeCount(count)
    }
}

// MARK: - Location priming (for the widget's weather)

/// Added 2026-07-25 for the Dayflow widget's weather block. The widget
/// process reads the system's cached location fix via
/// `CLLocationManager().location`, but a widget can never PROMPT for
/// location permission — only its containing app can. This asks once
/// (when-in-use) on first launch after the update; if David declines, the
/// widget simply never shows weather and everything else is unaffected.
/// Deliberately not a full LocationManager.swift dependency — Dayflow
/// doesn't otherwise use location, and pulling that file (with its geofence
/// machinery) into this target for one authorization prompt would be far
/// more than the job needs. Requires `NSLocationWhenInUseUsageDescription`
/// on the Dayflow app target's Info tab (manual Xcode step, see
/// DayflowWidget.swift's header checklist).
enum DayflowLocationPrimer {
    // Retained statically — CLLocationManager must stay alive for its
    // authorization prompt to complete; a local would deallocate first.
    private static let manager = CLLocationManager()

    static func primeIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
