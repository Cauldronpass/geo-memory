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
import AppIntents
import UserNotifications
import CoreLocation

@main
struct DayflowApp: App {
    /// Session 77 — Home Screen quick action ("Add Task"). See
    /// DayflowQuickActions.swift.
    @UIApplicationDelegateAdaptor(DayflowAppDelegate.self) private var appDelegate
    @State private var notionService = NotionService.shared
    /// Session 77: back to **system**. The forced-light default existed
    /// because the cream skin had no real dark palette (see the 2026-07-28
    /// history in git); the Editorial skin is dynamic light+dark, so the
    /// Settings Appearance row (light/dark/system) now genuinely works and
    /// system is the honest default. A stored explicit choice still wins.
    @AppStorage("dayflow_appearance") private var appearanceRaw: String = "system"
    @Environment(\.scenePhase) private var scenePhase

    /// **Registered here because a snippet's `@Dependency` is resolved at the
    /// moment an intent runs, and by then there is nowhere else to do it.**
    /// The event card and its three buttons all read one shared draft
    /// (`DayflowEventSnippet.swift`, D362); an unregistered dependency is a
    /// crash on the first chip tap rather than a compile error, so this line
    /// and that file live and die together.
    init() {
        // **`assumeIsolated`, and it is honest here rather than a silencer.**
        // An `App`'s `init()` is nonisolated as far as the compiler is
        // concerned, and these three drafts are main-actor types, so merely
        // naming `.shared` warns. In fact app initialisation runs on the main
        // thread in every case this ships in, including the background launch
        // an intent causes — which is exactly the claim `assumeIsolated` makes.
        //
        // Registering here rather than from a view's `.task` is deliberate: an
        // intent can run with no window on screen, and a dependency registered
        // by a view that never appeared is a crash on the first button press.
        MainActor.assumeIsolated {
            AppDependencyManager.shared.add(dependency: DayflowEventDraft.shared)
            AppDependencyManager.shared.add(dependency: DayflowTaskDraft.shared)
            AppDependencyManager.shared.add(dependency: DayflowSearchDraft.shared)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch appearanceRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            // Session 77: DayflowRootView is the tab bar shell (Today / Inbox /
            // Upcoming / Notes — Dayflow-Tasks-Design.md); ContentView is now
            // the Today tab inside it.
            DayflowRootView()
                .environment(notionService)
                .preferredColorScheme(preferredScheme)
                .task {
                    // D468 — the router's stores report readiness from here on.
                    // FIRST in the chain, so the fetches below are heard; the
                    // call also catches up on anything already loaded.
                    TraceRouter.wireStores()
                    await notionService.fetchPlaces()
                    await notionService.fetchPeople()
                    // Session 78, D165 — birthdays become tasks: a sweep
                    // after every people load ensures each person with a
                    // birthday has the heads-up (3 days out) and day-of
                    // yearly reminders, created once, deletion respected.
                    await ReminderTaskStore.shared.ensureBirthdayTasks(
                        for: notionService.people.map {
                            ReminderTaskStore.BirthdayPerson(
                                id: $0.id, name: $0.name,
                                birthday: $0.birthday, isArchived: $0.isArchived)
                        })
                    await notionService.fetchVisits()
                    // Bookings (Session 88). The endeavor screen's
                    // bands read `bookingsLoad` and draw nothing at
                    // all while it is idle or loading, so the fetch
                    // has to have STARTED for idle to mean anything.
                    await notionService.fetchBookings()
                    // Same sweep the Mac runs at launch. Idempotent, so
                    // whichever app opens first does the work and the other
                    // finds nothing left to do.
                    await notionService.reconcileVisitedStatuses()
                    await DayflowInboxBadge.refresh()
                    DayflowLocationPrimer.primeIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: .noteStoreInboxDidChange)) { _ in
                    Task { await DayflowInboxBadge.refresh() }
                }
                // Tasks move in and out of the Inbox without any note being
                // written, so the note-inbox notification alone would leave the
                // badge right only by coincidence (D377).
                .onChange(of: ReminderTaskStore.shared.revision) { _, _ in
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
                    // Session 77 — morning summary notifications are rewritten
                    // from live Reminders data on BOTH transitions: .active so
                    // a fresh look at the day corrects the week ahead, and
                    // .background so completions and adds made during the
                    // session land in tomorrow's 8:00 ping. See
                    // DayflowMorningSummary.swift.
                    if phase == .background {
                        Task { await DayflowMorningSummary.reschedule() }
                        Task { await DayflowTaskAlarms.reschedule() }
                        Task { await DayflowPlaceAlarms.reschedule() }
                        return
                    }
                    guard phase == .active else { return }
                    Task { await DayflowMorningSummary.reschedule() }
                    // Session 78, D168 — Dayflow rings the task alarms now
                    // (David is switching Apple Reminders' alerts off).
                    Task { await DayflowTaskAlarms.reschedule() }
                    // D183 — and the place alarms, same rewrite cadence.
                    Task { await DayflowPlaceAlarms.reschedule() }
                    DayflowFlagStore.shared.reload()
                    // D103 on the phone (Session 71). Until now these caches
                    // loaded once in the `.task` above and never again, so a
                    // place added on another device was invisible until Dayflow
                    // was force-quit — and a launch fetch that came back short
                    // stayed short for the whole session, which is the other
                    // half of the "destination pills are not clickable" report
                    // that opened this session.
                    //
                    // `refreshStale` is already in the shared `NotionService`
                    // with its own per-collection windows (visits 2 min, places
                    // 15, people 60) and it SKIPS anything that never loaded, so
                    // this cannot turn into a first fetch for a screen that is
                    // never opened. One line, no new code.
                    Task { await NotionService.shared.refreshStale() }
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
    /// **Which halves count is a setting now** (Session 99). David asked for
    /// it the same day he asked what the badge was: a number you can't
    /// decompose is a number you learn to ignore. Two switches, both on by
    /// default, so the badge behaves exactly as it did for anyone who never
    /// opens Settings. Both off means no badge at all — cleared, not frozen
    /// at its last value, and no authorization prompt.
    nonisolated static var countsNotes: Bool {
        UserDefaults.standard.object(forKey: "dayflow_badge_notes") as? Bool ?? true
    }
    nonisolated static var countsTasks: Bool {
        UserDefaults.standard.object(forKey: "dayflow_badge_tasks") as? Bool ?? true
    }

    /// **Tasks waiting in the Inbox list, plus unfiled note captures** (D377).
    ///
    /// It counted only `Notes/Inbox/` until now, and that number had not served
    /// him: the one thing in it was a test capture from July that he found in
    /// September, by asking what the badge was for. Meanwhile the pile he
    /// actually triages — undated tasks in the Inbox list — was never on the
    /// icon at all.
    ///
    /// **Both, summed, and the sum is defensible here for one reason:** they are
    /// the same pile in two shapes. Inbox means "captured, not yet decided" for
    /// both, and the answer to either is the same gesture — open Dayflow and
    /// triage. A badge whose number mixes two things you would act on
    /// differently would be worse than no badge; this one does not.
    static func refresh() async {
        let center = UNUserNotificationCenter.current()
        let wantsNotes = countsNotes
        let wantsTasks = countsTasks
        // Both off: clear and leave. `setBadgeCount` never prompts, so this
        // is safe to call even on a build that has never asked for badge
        // permission.
        guard wantsNotes || wantsTasks else {
            try? await center.setBadgeCount(0)
            return
        }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.badge])
        }
        var total = 0
        if wantsNotes {
            total += (try? NoteStore.shared.listFiles(in: "Notes/Inbox").count) ?? 0
        }
        if wantsTasks {
            // **Reads the count; does NOT fetch** (D476).
            //
            // This line used to be `await ReminderTaskStore.shared.refreshAll()`
            // followed by the read, and the two of them formed a loop with no
            // bottom. `refreshAll` calls `fetch`, `fetch` calls `apply`, and
            // `apply` ends by bumping `revision` — which is the value
            // `DayflowApp`'s `.onChange` watches to call this function. Every
            // refresh caused the next one. EventKit was queried, every task
            // array reassigned and every task-showing view invalidated,
            // continuously, for as long as the app was open.
            //
            // That is what David felt as the app being choppy, and it is the
            // `onChange(of: UInt64) action tried to update multiple times per
            // frame` warning in the console, written down since the first
            // iOS 27 run and read as harmless.
            //
            // **Fetching here was never needed.** The badge is refreshed
            // BECAUSE the store just applied a fetch, so the count is fresh by
            // construction. On the two paths where it is not — launch, and a
            // note-inbox change — the task figure is briefly whatever the last
            // fetch left, and the next real fetch corrects it through the same
            // `onChange`. A badge one fetch behind for a moment is worth
            // incomparably less than a permanent loop.
            total += ReminderTaskStore.shared.inboxCount
        }
        try? await center.setBadgeCount(total)
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
