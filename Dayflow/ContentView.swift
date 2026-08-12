//
//  ContentView.swift
//  Dayflow
//
//  The real home screen — top bar (browse menu: Upcoming/Calendar/Anytime/
//  Unfiled Tasks, Yesterday/Today/Tomorrow day-pill, settings gear), a serif
//  date headline, the real Agenda section (DayflowAgendaSection.swift, build
//  order step 3), and the real Daily Note section
//  (DayflowDailyNoteSection.swift + DayflowNoteFullPageView.swift, build
//  order step 4). Browse views (step 5) are wired for real as of this pass —
//  see DayflowUpcomingView.swift, DayflowCalendarBrowseView.swift,
//  DayflowAnytimeView.swift. The top-bar Menu's fourth entry (step 5b) added
//  2026-07-20 as "Inbox" — see DayflowInboxView.swift — then renamed to
//  "Unfiled Tasks" 2026-07-24 (Session 44 addendum 10) to free up the
//  "Inbox" name for the unrelated notes-staging feature reached by swiping
//  right on this screen (`showNotesInbox` below) — see
//  DayflowNotesInboxView.swift. Settings (step 6) added 2026-07-20 — see
//  DayflowSettingsView.swift. Calendar write support (step 7) added
//  2026-07-20 — see CalendarService.createEvent and saveDraft()'s `.event`
//  case below. Widget (step 8) is the only step left unbuilt.
//
//  **`ThingsService.addTask()` silent-failure fix, added 2026-07-20.** That
//  method used to discard its HTTP response entirely (see its own header
//  comment) — a failed task save had zero signal anywhere. Now it returns a
//  `Bool`, and `saveDraft()`'s `.task` case surfaces a failure via
//  `saveErrorMessage` (a real on-screen `.alert`, not just `log()`) — matches
//  the pattern the `.event` case already used for Calendar write failures.
//
//  **Notes & Project search + Agenda search, added 2026-07-20 (Session 11).**
//  Daily Note's header gained a third icon (DayflowNotesView — search over
//  Daily/Projects/Places notes, plus project-note create/view/append) and the
//  top-bar Browse menu gained a fifth destination, Search (DayflowAgendaSearchView
//  — keyword search over Things tasks + calendar events). Deliberately two
//  separate screens, not one — see Dayflow-Design-Plan.md "Notes & Agenda
//  search" for the reasoning David and Cowork walked through before building.
//
//  Kept the type name `ContentView` (matches DayflowApp.swift's WindowGroup
//  reference and the real Xcode file name `ContentView.swift`) rather than
//  renaming — no functional reason to touch the entry point for this pass.
//
//  **Revised 2026-07-20, Browse views (build order step 5).** `selectedDay:
//  DayflowRelativeDay` became `selectedDate: Date` — Browse: Calendar's whole
//  point is "tap any date to jump the main Agenda there" (Dayflow-Design-Plan.md),
//  and a 3-case enum has no way to represent an arbitrary jumped-to date. The
//  Yesterday/Today/Tomorrow pill now just compares `selectedDate` against each
//  day's real date instead of an enum equality check — same visual behavior
//  for the three pill taps, but no button lights up when `selectedDate` is a
//  Calendar-jumped date outside that 3-day window, which is the honest,
//  correct state (nothing in the pill actually represents that day). Same
//  pattern applied to DayflowNoteFullPageView.swift's own Today/Tomorrow pill
//  — see that file's header comment.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @State private var selectedDate: Date = DayflowRelativeDay.today.date()
    @State private var showQuickAdd = false
    /// Which mode `showQuickAdd`'s sheet opens into — added 2026-07-24
    /// alongside the Dayflow widget's "+" tap target, which deep-links
    /// straight into Event mode instead of the sheet's own Task-mode
    /// default. The normal Agenda "+" (`onOpenQuickAdd` below) explicitly
    /// resets this to `.task` on every open, so a stale `.event` from an
    /// earlier widget tap can't leak into the next normal-path open.
    @State private var quickAddInitialKind: DayflowEntryKind = .task
    @Environment(\.scenePhase) private var scenePhase
    // Agenda's collapse state, lifted out of DayflowAgendaSection so this
    // screen can bind to it (DayflowAgendaSection.swift's own header comment
    // has the history). Daily Note no longer reads this directly — its card
    // just flexes to fill whatever space Agenda leaves, collapsed or not.
    @State private var agendaCollapsed = false
    @State private var showNoteFullPage = false
    /// Session 38 addendum 5 — David found the home card's Daily Note
    /// didn't pick up edits made in the full-page view after dismissing
    /// back to this screen. Root cause: the card's `DayflowDailyNoteEditor`
    /// only reloads when `date` changes or the app returns from the
    /// background (Session 31's fix) — neither fires when a
    /// `.fullScreenCover` is presented and dismissed within the same
    /// foreground session, so the card kept showing whatever it had loaded
    /// before the full page was opened. Bumped in `onDismiss` below and
    /// threaded down to force a fresh reload.
    @State private var dailyNoteReloadToken = 0
    // Browse menu destination (Upcoming/Calendar/Anytime) — one optional
    // value driving a single .fullScreenCover(item:) rather than three Bool
    // flags. See DayflowModels.swift's "Browse views" section.
    @State private var browseDestination: DayflowBrowseDestination? = nil
    /// Settings (build order step 6) — added 2026-07-20. See
    /// DayflowSettingsView.swift's header comment for why this became urgent.
    @State private var showSettings = false
    /// Forces DayflowAgendaSection to tear down and re-run its own `.task(id:
    /// date)` fetch after a new calendar event is saved for the day currently
    /// in view. Added 2026-07-20 for Calendar write support (build order step
    /// 7) — Agenda's `dayEvents` is a local `@State` snapshot populated by its
    /// own `loadDayData()`, not a reactive read off a shared observable like
    /// `ThingsService.shared.tasks` is, so creating an event elsewhere doesn't
    /// otherwise reach it until the next natural trigger (a `date` change, or
    /// the user tapping Agenda's own refresh button). Applied as `.id(...)` on
    /// the section below — changing it recreates the view, which reruns
    /// `.task(id:)` the same as if `date` itself had changed.
    @State private var agendaRefreshToken = UUID()
    /// Surfaces a failed task/event save to the screen instead of only the
    /// Xcode console. Added 2026-07-20 alongside `ThingsService.addTask()`'s
    /// fix (it used to silently discard failures — see that method's header
    /// comment) — a console `log()` line is useless once David's off a real
    /// device with no console attached, which is exactly the TestFlight
    /// scenario this was fixed ahead of.
    @State private var saveErrorMessage: String? = nil
    /// Daily Note's third header icon (Session 11, 2026-07-20) — search over
    /// notes + view/append project notes. A plain Bool + fullScreenCover, not
    /// folded into `browseDestination`, since it's reached from Daily Note's
    /// own header, not the top-bar calendar-icon Browse menu.
    @State private var showNotes = false
    /// Session 21, 2026-07-20 — tapping the serif date headline opens
    /// DayflowCalendarBrowseView directly. A separate Bool rather than
    /// reusing `browseDestination`, since this isn't part of that Menu's
    /// Upcoming/Anytime/Inbox/Search family — same "own Bool, own
    /// fullScreenCover" precedent `showNotes` above already set for a
    /// header-icon entry point that isn't part of that Menu either.
    ///
    /// **Session 24, 2026-07-21 — this is now the ONLY door into Calendar
    /// browsing from the main screen.** The top-bar Menu used to also have a
    /// "Calendar" entry opening this exact same view; removed per David's
    /// call after walking the navigation fresh — see DayflowModels.swift's
    /// `DayflowBrowseDestination` header comment for the full reasoning.
    @State private var showDateCalendar = false
    /// Added 2026-07-24 (Session 44 addendum 10) — David's Inbox concept,
    /// reached by swiping right on the home screen (see the `.gesture(...)`
    /// on this screen's root VStack below), deliberately NOT part of
    /// `browseDestination`'s Upcoming/Anytime/Unfiled Tasks/Search family —
    /// same "own Bool, own fullScreenCover" precedent `showNotes`/
    /// `showDateCalendar` above already set for entry points that aren't
    /// reached from that top-bar Menu. See DayflowNotesInboxView.swift's
    /// header comment for the full feature design.
    @State private var showNotesInbox = false

    // MARK: dayflow://note?path= routing (E35, 2026-07-29)
    //
    // Satchel's counterpart to `trace://note?path=`. A document filed against a
    // day note, an Endeavor or a project note can now jump to it; until this
    // existed Satchel WITHHELD the button rather than offer one that goes
    // nowhere (see `noteOwnerAppURL` in SatchelLibraryView).
    //
    // Held as a pending path rather than acted on immediately, because on a cold
    // launch `onOpenURL` fires before this view's `.task` and before NoteStore
    // has resolved the iCloud container. Same shape as Trace's
    // `pendingNotePath`/`resolvePendingNoteLink()` and Satchel's `drainRouter()`
    // — the third time this pattern has been needed, which is why all three now
    // look alike.
    @State private var pendingNotePath: String? = nil
    /// `dayflow://endeavor?id=japan-2026`. Kept separate from `pendingNotePath`
    /// because it is a different key, not a different path: Satchel files
    /// documents against the slug, so the slug is what it can hand over, and a
    /// renamed note cannot break the link.
    @State private var pendingEndeavorID: String? = nil
    /// Held only so `hasAccess` can be OBSERVED. `NoteStore` resolves the iCloud
    /// container on a background queue and flips `hasAccess` on the main queue
    /// whenever that finishes, which on a cold launch is routinely longer than
    /// any delay worth hard-coding — see the note on the `onChange` below.
    @State private var noteStore = NoteStore.shared
    @State private var endeavorRoute: EndeavorRouteRef? = nil
    /// Set alongside `showNotes` so `DayflowNotesView` opens straight into a
    /// project instead of its browse list.
    @State private var routedProjectTitle: String? = nil

    private var dateHeadlineText: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: selectedDate)
    }

    var body: some View {
        NavigationStack {
            // Fixed viewport, not a ScrollView — this is what lets the Daily
            // Note card actually claim whatever room Agenda doesn't use (see
            // DayflowDailyNoteSection's header comment for why the old
            // ScrollView + two-fixed-heights approach couldn't do that).
            // Agenda sizes to its own natural content height; Daily Note's
            // `.frame(maxHeight: .infinity)` absorbs the rest. (The old
            // `recentLog` debug strip that used to also live in this VStack
            // was removed 2026-07-20 — see `log(_:)`'s doc comment below.)
            VStack(alignment: .leading, spacing: 12) {
                topBar

                Button {
                    showDateCalendar = true
                } label: {
                    Text(dateHeadlineText)
                        // Skin locked 2026-07-21 (Session 29) — was
                        // .custom("Georgia", ...); David flagged Georgia's
                        // capital J as visibly off vs. Parchment's real
                        // letterforms. `design: .serif` resolves to New York
                        // on Apple platforms, which is the actual fix — see
                        // DayflowSkin.swift.
                        .font(.dayflowSerif(26))
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                DayflowAgendaSection(
                    date: selectedDate,
                    onOpenQuickAdd: { quickAddInitialKind = .task; showQuickAdd = true },
                    isCollapsed: $agendaCollapsed
                )
                .id(agendaRefreshToken)

                DayflowDailyNoteSection(
                    date: selectedDate,
                    reloadToken: dailyNoteReloadToken,
                    onExpand: { showNoteFullPage = true },
                    onOpenNotes: {
                        // Clear the deep-link destination first. **REGRESSION,
                        // introduced and fixed the same day (2026-07-30):**
                        // `routedProjectTitle` is set by
                        // `dayflow://note?path=Notes/Projects/…` and was never
                        // cleared, so once David had followed one such link from
                        // Satchel, every later tap of this button re-opened Home
                        // Bills and he had to back out of it. A one-shot route has
                        // to be consumed, not merely acted on.
                        routedProjectTitle = nil
                        showNotes = true
                    }
                )
            }
            .padding()
            .frame(maxHeight: .infinity)
            .toolbar(.hidden, for: .navigationBar)
            // Skin fix 2026-07-21 (Session 30, round 3) — was chained onto
            // the NavigationStack itself (outside this closure). David
            // reported zero visible change across two rounds of gradient
            // tweaks, even after a clean build — the real cause: a
            // `.background()` applied outside a `NavigationStack` doesn't
            // reliably show through, because the nav controller's own opaque
            // backing view sits on top of it. Moved onto this VStack (the
            // actual content NavigationStack hosts) instead, which is the
            // documented fix for this exact symptom. See DayflowSkin.swift.
            .dayflowSkinBackground()
            // Swipe-right-to-Inbox, added 2026-07-24 (Session 44 addendum
            // 10) — David's explicit ask, discussed and confirmed together:
            // the Inbox stays "not front and center," reached only by
            // swiping right on the home screen, not a Menu entry. Attached
            // to this whole VStack rather than confined to a header strip
            // (contrast Jot's CaptureView.swift, where the equivalent
            // swipe-to-day gesture was deliberately confined to the header
            // row to avoid competing with JotTextView's own UITextView
            // gestures) — confirmed by grep before building this that
            // neither this file, DayflowAgendaSection.swift, nor
            // DayflowDailyNoteSection.swift define any DragGesture/
            // TabView/swipeActions of their own, so there's nothing already
            // using horizontal drag on this screen to compete with. Still
            // worth confirming on-device specifically: that normal taps on
            // Agenda rows, the Daily Note card, and the top bar all still
            // feel completely unaffected — the mostly-horizontal + distance
            // gating below is the same conflict-avoidance pattern proven
            // out for Jot, but this is a bigger, more content-dense surface
            // than that one header row was.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        guard horizontal > 0,
                              horizontal > abs(vertical) * 1.5,
                              horizontal > 50 else { return }
                        showNotesInbox = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            )
        }
        .sheet(isPresented: $showQuickAdd) {
            DayflowQuickAddSheet(initialKind: quickAddInitialKind) { draft in
                saveDraft(draft)
            }
            // A single fixed detent, not [.medium, .large]. With more than one
            // detent available, iOS auto-promotes the sheet to the largest one
            // the instant a focused text field inside it would otherwise be
            // cramped by the keyboard — found 2026-07-19 when Task mode's
            // sheet silently jumped to near-fullscreen the moment typing
            // started, leaving a large dead gap below the sparse Details
            // content. One detent means there's nothing larger to promote to.
            .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $showNoteFullPage, onDismiss: {
            // Session 38 addendum 5 — see `dailyNoteReloadToken`'s own
            // comment above. Without this, the home card kept showing
            // whatever it had loaded before the full page opened, even
            // after edits made there were saved to disk.
            dailyNoteReloadToken += 1
        }) {
            // Session 18, 2026-07-20 — `selectedDate` is now a real Binding, not a
            // one-shot `initialDate:` seed. Navigating dates inside the full-page
            // view (its Today/Tomorrow pill, or its Calendar picker) updates this
            // exact same `selectedDate`, so Agenda above and the Daily Note card
            // both reflect it the moment you're back here — see
            // DayflowNoteFullPageView.swift's header comment for the bug this fixes.
            DayflowNoteFullPageView(selectedDate: $selectedDate)
        }
        .sheet(isPresented: $showSettings) {
            DayflowSettingsView()
        }
        // Second half of the same fix: clearing on dismiss means the value cannot
        // outlive the presentation it was set for, whatever opens Notes next.
        .fullScreenCover(isPresented: $showNotes, onDismiss: { routedProjectTitle = nil }) {
            // Session 19, 2026-07-20 — DayflowNotesView now shares this same
            // `selectedDate` binding so a tapped Daily search result inside it
            // (jumping to DayflowNoteFullPageView for that date) also moves
            // Agenda + the main Daily Note card once you're back here — same
            // "share the one real date" pattern as showNoteFullPage above.
            DayflowNotesView(selectedDate: $selectedDate,
                             initialProjectTitle: routedProjectTitle)
        }
        .fullScreenCover(isPresented: $showDateCalendar) {
            // Session 21, 2026-07-20 — DayflowCalendarBrowseView straight off
            // the date headline. Session 24, 2026-07-21: this is now the only
            // door into Calendar browsing from the main screen.
            DayflowCalendarBrowseView(onSelect: { picked in selectedDate = picked })
        }
        .fullScreenCover(isPresented: $showNotesInbox) {
            // Session 44 addendum 10 — swipe-right destination. See
            // `showNotesInbox`'s own declaration above and
            // DayflowNotesInboxView.swift's header comment.
            DayflowNotesInboxView()
        }
        .fullScreenCover(item: $browseDestination) { destination in
            switch destination {
            case .upcoming:
                DayflowUpcomingView()
            case .anytime:
                DayflowAnytimeView()
            case .inbox:
                DayflowInboxView()
            case .search:
                DayflowAgendaSearchView()
            }
        }
        // Added 2026-07-20 alongside the Browse views' pull-to-refresh and
        // Agenda's new refresh button — see DayflowUpcomingView.swift's header
        // comment for the "note edited directly in Things didn't show up in
        // Dayflow" finding. Agenda reads ThingsService.shared's arrays live
        // (no local snapshot), so this alone is enough to bring it current
        // whenever you switch back to Dayflow from Things or anywhere else —
        // no separate plumbing needed for the main screen specifically.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await ThingsService.shared.refreshAll() }
                // A hand-off that arrived while the container was still settling
                // gets another chance here rather than being lost.
                resolveNoteRoute()
            }
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK") { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
        // Added 2026-07-24 for the Dayflow widget's tap targets: the
        // "+" sends `dayflow://addEvent` (opens straight into the quick-add
        // sheet, Event mode preset — see `quickAddInitialKind` above),
        // everywhere else on the card sends a plain `dayflow://open` (just
        // opens the app, no extra state to set — same as launching normally,
        // so there's nothing to do here for that case beyond not crashing on
        // an unrecognized host).
        //
        // `openJot` added 2026-07-25 for the widget's third tap target (the
        // big date block): iOS widgets can only launch their own containing
        // app, so the widget sends `dayflow://openJot` and Dayflow
        // immediately relays to the Jot capture app via its `jot://` scheme
        // (already registered on the Jot target for JotWidget — see
        // JotWidget.swift's header). Costs a sub-second Dayflow flash on the
        // way to Jot; flagged to David before building, accepted. If Jot
        // isn't installed, `open` just fails silently and the user stays in
        // Dayflow — acceptable, and on David's phone Jot is always there.
        //
        // `openCalendar` added 2026-07-26: the widget's default tap
        // (everywhere except the "+" and the date block) used to send plain
        // `dayflow://open`; now it sends `dayflow://openCalendar` instead,
        // and Dayflow relays straight to Fantastical (`fantastical2://`),
        // David's preferred calendar app, same one-hop pattern as Jot above.
        // Falls back to Apple's built-in Calendar (`calshow://`) if
        // Fantastical isn't installed — `open(_:options:completionHandler:)`
        // reports success/failure without needing an `LSApplicationQueriesSchemes`
        // entry in Info.plist (that restriction only applies to
        // `canOpenURL(_:)`), so no Info.plist change was needed for this.
        .onOpenURL { url in
            if url.host == "addEvent" {
                quickAddInitialKind = .event
                showQuickAdd = true
            } else if url.host == "openJot" {
                if let jotURL = URL(string: "jot://open") {
                    UIApplication.shared.open(jotURL)
                }
            } else if url.host == "endeavor" {
                // dayflow://endeavor?id=japan-2026 — Satchel's jump from a
                // document filed to a trip. By id, since that is what the
                // sidecar carries and what survives the note being renamed.
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let id = comps.queryItems?.first(where: { $0.name == "id" })?.value {
                    pendingEndeavorID = id
                    resolveNoteRoute()
                }
            } else if url.host == "note" {
                // dayflow://note?path=Calendar/2026-07-29.md
                // dayflow://note?path=Notes/Endeavors/Japan.md
                // dayflow://note?path=Notes/Projects/Kitchen.md
                //
                // Parsed with `URLComponents`, not by string surgery: an
                // Endeavor called "Mum & Dad's 50th" carries both a space and
                // an ampersand, and an unescaped ampersand truncates the path.
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let path = comps.queryItems?.first(where: { $0.name == "path" })?.value {
                    pendingNotePath = path
                    resolveNoteRoute()
                }
            } else if url.host == "launch" {
                // The launcher widget's four tiles (Session 68).
                //
                // **A widget can only ever hand its URL to its own container**,
                // so the tiles cannot address Jot, Trace or Satchel directly —
                // they address Dayflow, and Dayflow re-opens the real scheme.
                // Same shape as `openCalendar` below, which hands off to
                // Fantastical, and the only route an extension has.
                //
                // **`today` is no longer a no-op.** Session 68 reasoned that
                // opening Dayflow IS the action, and left the tile doing nothing
                // beyond the launch. That is true only when Dayflow happens to
                // already be showing today, and it usually is not: `selectedDate`
                // survives backgrounding, and the screen can be sitting under a
                // full-screen cover (Browse, the full-page note) or a sheet
                // (Settings, Quick Add). So the tile labelled Today could land on
                // Tomorrow, on a calendar grid, or on last Thursday's note.
                //
                // Same mistake as D82 in a different costume: the behaviour was
                // reasoned about from what the code would do, not from what a
                // person tapping a button called "Today" is asking for. A tile
                // that names a destination has to arrive there.
                //
                // Covers are cleared before the date is set, so the reset is
                // never applied to a screen the user cannot see.
                let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "target" })?.value
                if target == "today" {
                    browseDestination = nil
                    showNoteFullPage  = false
                    showSettings      = false
                    showQuickAdd      = false
                    selectedDate      = DayflowRelativeDay.today.date()
                } else {
                    let scheme: String? = {
                        switch target {
                        case "capture": return "jot://"
                        case "checkin": return "trace://checkin"
                        case "file":    return "satchel://scan"
                        default:        return nil          // anything unknown
                        }
                    }()
                    if let scheme, let dest = URL(string: scheme) {
                        UIApplication.shared.open(dest)
                    }
                }
            } else if url.host == "openCalendar" {
                if let fantasticalURL = URL(string: "fantastical2://") {
                    UIApplication.shared.open(fantasticalURL, options: [:]) { success in
                        if !success, let calShowURL = URL(string: "calshow://") {
                            UIApplication.shared.open(calShowURL)
                        }
                    }
                }
            }
        }
        // Cold launch, first attempt. 50ms is a guess and IS SOMETIMES WRONG —
        // David hit exactly that on 2026-07-29: the first tap of "Open in
        // Dayflow" landed on the home screen and the second worked. So this is
        // the optimistic path, not the mechanism.
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            resolveNoteRoute()
        }
        // THE MECHANISM. `NoteStore` resolves the iCloud container on a
        // background queue and sets `hasAccess` on the main queue when it
        // finishes; on a cold launch that lost the race with the 50ms guess
        // above, and nothing fired afterwards, so the hand-off was simply
        // dropped. Waiting for the actual signal cannot lose a race.
        //
        // Trace has done it this way all along — it retries
        // `resolvePendingNoteLink()` off `notion.places.count` and
        // `notion.people.count` rather than off a timer. Dayflow's copy of the
        // pattern picked up the delay and not the observer.
        .onChange(of: noteStore.hasAccess) { _, granted in
            if granted { resolveNoteRoute() }
        }
        .sheet(item: $endeavorRoute) { ref in
            NavigationStack {
                DayflowEndeavorView(endeavorID: ref.id)
            }
        }
    }

    // MARK: - Note routing

    /// Identifiable wrapper so a slug can drive `.sheet(item:)`. A bare `String?`
    /// cannot — `String` is not `Identifiable`. Same reason `EndeavorRef` exists
    /// in DayflowEndeavorViews.swift; that one is `private` to its file, which is
    /// why this is not simply reused.
    struct EndeavorRouteRef: Identifiable, Hashable {
        let id: String
    }

    /// Anything currently covering the home screen.
    ///
    /// **This is why a hand-off used to be swallowed.** David, 2026-07-30: tapping
    /// "Open in Dayflow" for Japan worked from the home screen, and did nothing if
    /// he had left Dayflow inside the Home Bills project. Two separate SwiftUI
    /// facts, both fatal:
    ///
    /// 1. A `sheet` cannot present from a view that is underneath a
    ///    `fullScreenCover`. The Endeavor sheet is attached to this view, so the
    ///    request was simply dropped.
    /// 2. Setting an already-`true` `isPresented` flag does nothing. So the
    ///    project route (`showNotes = true`) was a no-op when Notes was already
    ///    open, and `initialProjectTitle` never reached a freshly built screen.
    ///
    /// `showDateCalendar` is deliberately absent: it is a transient picker that
    /// closes on its own selection, and force-closing it would be the one case
    /// where clearing does more harm than the stuck route it prevents.
    private var isPresentingSomething: Bool {
        showNotes || showNoteFullPage || showNotesInbox || showSettings
            || showQuickAdd || browseDestination != nil || endeavorRoute != nil
    }

    /// Clears whatever is open, then performs the presentation.
    ///
    /// Nothing to clear is the common case and stays synchronous. When there IS
    /// something open, the dismissal is applied with animations off and the new
    /// presentation follows one short hop later — SwiftUI drops a presentation
    /// requested in the same update as a dismissal. Animations are disabled rather
    /// than waited out, so the hop is about letting the state change land, not
    /// about matching a transition duration; a hard-coded delay long enough to
    /// outlast an animation is the mistake already recorded above this one.
    private func route(_ present: @escaping () -> Void) {
        guard isPresentingSomething else {
            present()
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            showNotes = false
            showNoteFullPage = false
            showNotesInbox = false
            showSettings = false
            showQuickAdd = false
            browseDestination = nil
            endeavorRoute = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { present() }
    }

    /// Acts on `pendingNotePath` if it can, leaves it alone if it cannot.
    ///
    /// **Returns WITHOUT clearing the path when the container is unavailable**, so
    /// a later call retries. Clearing on a failed attempt is how a hand-off
    /// silently does nothing on a cold launch, which is the bug this pattern
    /// exists to avoid.
    ///
    /// An unrecognised prefix IS cleared — People and Places belong to Trace and
    /// Horizons has no screen to open yet, so retrying forever would just leave a
    /// stale path waiting to fire at a confusing moment.
    private func resolveNoteRoute() {
        resolveEndeavorRoute()

        guard let path = pendingNotePath else { return }
        guard NoteStore.shared.hasAccess else { return }

        if path.hasPrefix("Notes/Endeavors/") {
            // Reload first: on a cold launch nothing has scanned this folder yet,
            // and matching against an empty list would look exactly like a note
            // that does not exist.
            EndeavorStore.shared.reload()
            guard let match = EndeavorStore.shared.endeavors
                    .first(where: { $0.relativePath == path }) else {
                // The note is genuinely gone, or renamed. Do not retry.
                pendingNotePath = nil
                return
            }
            pendingNotePath = nil
            route { endeavorRoute = EndeavorRouteRef(id: match.id) }

        } else if path.hasPrefix("Calendar/") {
            guard let date = Self.dayNoteDate(from: path) else {
                pendingNotePath = nil
                return
            }
            pendingNotePath = nil
            selectedDate = date
            route { showNoteFullPage = true }

        } else if path.hasPrefix("Notes/Projects/") {
            let title = ((path as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            pendingNotePath = nil
            guard !title.isEmpty else { return }
            // **INSIDE `route`, not before it.** This was set before, on the
            // reasoning that the cover's content closure reads it when the screen
            // is built — true, and it missed what `route` does on the way there.
            //
            // When something is already presented, `route` sets every
            // `isPresented` flag to false and re-presents 0.1s later. Dropping
            // `showNotes` fires the cover's `onDismiss`, which is
            // `{ routedProjectTitle = nil }` — added 2026-07-30 so a stale title
            // could not outlive its presentation, and correct on its own terms.
            // **So the route set the title and the dismissal it triggered wiped
            // it, 0.1s before the screen that wanted it was built.**
            //
            // Which is why it always landed on the bare notes list, why it did so
            // on the second attempt as reliably as the first, and why three fixes
            // aimed at appearance, ordering and one-shot state all missed: the
            // value was gone before any of them ran.
            //
            // Setting it inside `present()` puts it after the dismissal and in
            // the same synchronous block as `showNotes = true`, so the content
            // closure sees it. The no-presentation path is unaffected: `route`
            // calls `present()` immediately there.
            route {
                routedProjectTitle = title
                showNotes = true
            }

        } else {
            // Notes/People and Notes/Places are Trace's, and Satchel sends those
            // to `trace://note`. Notes/Horizons has no deep link yet — logged as
            // part of E35 rather than half-built here.
            pendingNotePath = nil
        }
    }

    /// Same retry contract as `resolveNoteRoute`: leaves the id in place when the
    /// container is not ready, clears it when the Endeavor genuinely is not there.
    private func resolveEndeavorRoute() {
        guard let id = pendingEndeavorID else { return }
        guard NoteStore.shared.hasAccess else { return }

        EndeavorStore.shared.reload()
        guard EndeavorStore.shared.endeavor(id: id) != nil else {
            // Deleted, or a slug from a note that never made it to this device.
            pendingEndeavorID = nil
            return
        }
        pendingEndeavorID = nil
        route { endeavorRoute = EndeavorRouteRef(id: id) }
    }

    private static let dayNoteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `Calendar/2026-07-29.md` → that date. Nil for anything else, including a
    /// day note whose name has been edited by hand into something unparseable.
    private static func dayNoteDate(from path: String) -> Date? {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return dayNoteFormatter.date(from: stem)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Menu {
                // "Calendar" removed from this menu 2026-07-21 (Session 24) —
                // see DayflowModels.swift's `DayflowBrowseDestination` header
                // comment for the full reasoning. This menu is now purely the
                // Things/task-browsing family; Calendar/notes browsing has
                // exactly one door, the date headline below, plus
                // DayflowNoteFullPageView's own calendar icon.
                Button { browseDestination = .upcoming } label: {
                    Label("Upcoming", systemImage: "calendar.day.timeline.left")
                }
                Button { browseDestination = .anytime } label: {
                    Label("Anytime", systemImage: "books.vertical")
                }
                // Renamed from "Inbox" 2026-07-24 (Session 44 addendum 10) —
                // "Inbox" now means the notes-staging feature (evergreen
                // notes waiting to be filed to a Project/Person/Place),
                // reached by swiping right on the home screen, not this
                // Things-task screen. Icon changed from "tray" to
                // "checklist" for the same reason — "tray" is already the
                // established icon for the notes concept (QuickAppendSheet's
                // Inbox destination, TraceMacInboxView's empty state).
                Button { browseDestination = .inbox } label: {
                    Label("Unfiled Tasks", systemImage: "checklist")
                }
                Button { browseDestination = .search } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            } label: {
                // Skin fix 2026-07-21 (Session 30, post-implementation) — was
                // unstyled, which let `Menu`'s default label tinting render
                // this icon in the system accent blue instead of the locked
                // monochrome look. David caught this comparing a real build
                // against Dayflow-Skin-Mockup.html. See DayflowSkin.swift.
                Image(systemName: "calendar")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.dayflowInk)
                    .frame(width: 32, height: 32)
                    .background(.background, in: Circle())
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
            }
            Spacer()
            dayPill
            Spacer()
            iconButton(systemName: "gearshape") {
                showSettings = true
            }
        }
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
                // Skin fix 2026-07-21 (Session 30) — explicit ink color so
                // this can't pick up accent tinting either, matching the
                // Menu-icon fix above even though .buttonStyle(.plain) alone
                // was likely already preventing it here.
                .foregroundStyle(Color.dayflowInk)
                .frame(width: 32, height: 32)
                .background(.background, in: Circle())
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var dayPill: some View {
        HStack(spacing: 2) {
            ForEach(DayflowRelativeDay.allCases) { day in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedDate = day.date() }
                } label: {
                    Text(day.label)
                        // Skin fix 2026-07-21 (Session 30, post-implementation)
                        // — was a solid blue capsule + white text, the
                        // original app's pre-skin styling, never touched by
                        // Session 29/30 since it wasn't assumed to need
                        // fixing. Locked mockup wants a white pill + bold
                        // near-black text for the active day, muted warm-gray
                        // text (no fill) for the inactive days. See
                        // DayflowSkin.swift.
                        .font(.system(size: 13, weight: isActive(day) ? .bold : .medium))
                        .foregroundStyle(isActive(day) ? Color.dayflowInk : Color.dayflowPillInactiveText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(isActive(day) ? Color.white : Color.clear, in: Capsule())
                        .shadow(color: .black.opacity(isActive(day) ? 0.10 : 0), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.dayflowInk.opacity(0.055), in: Capsule())
    }

    private func isActive(_ day: DayflowRelativeDay) -> Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: day.date())
    }

    // MARK: Save routing

    /// Routes a saved draft to the right backend. Task dates that land on a
    /// real calendar day (or "Today") go through ThingsService's existing
    /// Mac Mini bridge — already tested end-to-end per Dayflow-HANDOFF.md
    /// Session 1. "This Evening"/"Someday" and Event mode are both flagged
    /// open items (see Dayflow-Design-Plan.md "Open questions") — handled
    /// conservatively here rather than silently guessed at.
    private func saveDraft(_ draft: DayflowQuickAddDraft) {
        switch draft.kind {
        case .task:
            Task {
                let success: Bool
                switch draft.when {
                case .none:
                    success = await ThingsService.shared.addTask(title: draft.title, list: draft.list, notes: draft.notes)
                case .today:
                    success = await ThingsService.shared.addTask(title: draft.title, toToday: true, list: draft.list, notes: draft.notes)
                case .date(let d):
                    success = await ThingsService.shared.addTask(title: draft.title, date: d, list: draft.list, notes: draft.notes)
                case .thisEvening, .someday:
                    // Open architecture question, not yet resolved: these two
                    // Things-native buckets need the URL-scheme-direct path,
                    // which the Mini bridge's /add endpoint can't express (it
                    // only takes an arbitrary date). Conservative fallback so
                    // this doesn't silently mis-schedule: lands undated in the
                    // chosen list (or Inbox) instead of guessing a date.
                    success = await ThingsService.shared.addTask(title: draft.title, list: draft.list, notes: draft.notes)
                }
                await MainActor.run {
                    if success {
                        log("Task: \(draft.title) — \(draft.when.label)\(draft.list.map { " · \($0)" } ?? "")")
                    } else {
                        log("Task creation FAILED (check Mini bridge connection in Settings): \(draft.title)")
                        saveErrorMessage = "\"\(draft.title)\" wasn't saved to Things. Check Settings → Things Integration → Test Connection, then try again."
                    }
                }
            }
        case .event:
            // CalendarService.createEvent (build order step 7, added
            // 2026-07-20) does the real EventKit write. `draft.eventDate` is
            // the day picked via the Date pill; `draft.eventStart`/`.eventEnd`
            // are the Start/End time pickers — CalendarService combines all
            // three itself (see that method's header comment for why they
            // can't just be used as-is).
            //
            // **Buffer events added 2026-07-24** (backlog item 12, walked
            // through via HTML mockup review first). `draft.bufferBefore`/
            // `.bufferAfter` each add a separate 15-minute "Buffer" calendar
            // hold immediately before/after the real event — deliberately
            // separate EKEvents, not a widened start/end on the real event
            // itself, so the calendar still shows the meeting's actual real
            // time; the buffer is just travel time blocked off around it.
            // Written as up to three sequential `createEvent` calls sharing
            // the same target calendar, in chronological order (buffer
            // before → real event → buffer after) purely for readable
            // console logging — EventKit doesn't care about write order.
            // Known gap, same as `DayflowQuickAddSheet`'s own doc comment on
            // this feature: no rollback if an earlier call in the sequence
            // succeeds and a later one fails (e.g. a written "Buffer" event
            // with no matching real meeting if the main `createEvent` call
            // then fails) — consistent with how this codebase already
            // doesn't attempt multi-call transactional rollback elsewhere
            // (Things task creation has the same property).
            let calendarIdentifier = UserDefaults.standard.string(forKey: "default_calendar_identifier")
            Task {
                var allSucceeded = true

                if draft.bufferBefore {
                    let bufferStart = Calendar.current.date(byAdding: .minute, value: -15, to: draft.eventStart) ?? draft.eventStart
                    let ok = await CalendarService.shared.createEvent(
                        title: "Buffer",
                        date: draft.eventDate,
                        startTime: bufferStart,
                        endTime: draft.eventStart,
                        calendarIdentifier: calendarIdentifier
                    )
                    allSucceeded = allSucceeded && ok
                }

                let mainSuccess = await CalendarService.shared.createEvent(
                    title: draft.title,
                    date: draft.eventDate,
                    startTime: draft.eventStart,
                    endTime: draft.eventEnd,
                    calendarIdentifier: calendarIdentifier
                )
                allSucceeded = allSucceeded && mainSuccess

                if draft.bufferAfter {
                    let bufferEnd = Calendar.current.date(byAdding: .minute, value: 15, to: draft.eventEnd) ?? draft.eventEnd
                    let ok = await CalendarService.shared.createEvent(
                        title: "Buffer",
                        date: draft.eventDate,
                        startTime: draft.eventEnd,
                        endTime: bufferEnd,
                        calendarIdentifier: calendarIdentifier
                    )
                    allSucceeded = allSucceeded && ok
                }

                await MainActor.run {
                    if allSucceeded {
                        log("Event created: \(draft.title)\(draft.bufferBefore || draft.bufferAfter ? " (+ buffer)" : "")")
                    } else {
                        log("Event creation FAILED (check Calendar access + Settings → Default Calendar): \(draft.title)")
                        saveErrorMessage = "\"\(draft.title)\" wasn't saved to Calendar. Check Calendar access in iOS Settings and your Default Calendar in Dayflow Settings, then try again."
                    }
                    // Only force an Agenda refresh if the new event actually
                    // lands on the day currently in view — no visible reason
                    // to tear the view down otherwise.
                    if allSucceeded && Calendar.current.isDate(draft.eventDate, inSameDayAs: selectedDate) {
                        agendaRefreshToken = UUID()
                    }
                }
            }
        }
    }

    /// Console-only debug trace, no UI. **Downgraded from a visible on-screen
    /// strip 2026-07-20** — the old `recentLog` array rendered its last two
    /// entries directly under Agenda (e.g. "Task: Test4 — No date"), which
    /// was always just a Session 3/4 testing convenience from before Agenda
    /// showed real data, never part of the actual design spec. Now that
    /// Agenda/Daily Note both show real state, that visible strip was pure
    /// clutter — kept as a `print` so the same signal is still available in
    /// Xcode's console if useful, without living in the UI.
    private func log(_ line: String) {
        print("[Dayflow] \(line)")
    }
}

#Preview {
    ContentView()
        .environment(NotionService.shared)
}
