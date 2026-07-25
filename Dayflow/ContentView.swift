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
                    onOpenNotes: { showNotes = true }
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
        .fullScreenCover(isPresented: $showNotes) {
            // Session 19, 2026-07-20 — DayflowNotesView now shares this same
            // `selectedDate` binding so a tapped Daily search result inside it
            // (jumping to DayflowNoteFullPageView for that date) also moves
            // Agenda + the main Daily Note card once you're back here — same
            // "share the one real date" pattern as showNoteFullPage above.
            DayflowNotesView(selectedDate: $selectedDate)
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
        // Added 2026-07-24 for the Dayflow widget's two tap targets: the
        // "+" sends `dayflow://addEvent` (opens straight into the quick-add
        // sheet, Event mode preset — see `quickAddInitialKind` above),
        // everywhere else on the card sends a plain `dayflow://open` (just
        // opens the app, no extra state to set — same as launching normally,
        // so there's nothing to do here for that case beyond not crashing on
        // an unrecognized host).
        .onOpenURL { url in
            if url.host == "addEvent" {
                quickAddInitialKind = .event
                showQuickAdd = true
            }
        }
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
