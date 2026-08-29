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
    /// Session 77: lifted to DayflowRootView (the tab bar shell) so the Notes
    /// tab shares the one real date. Was `@State private` before that.
    @Binding var selectedDate: Date
    /// Session 77: the Daily Note card's notes icon and the swipe-left gesture
    /// select the Notes TAB (DayflowRootView) instead of presenting the
    /// `showNotes` cover. The cover survives for routed project deep links and
    /// search results, which need `initialProjectTitle` / a fresh presentation.
    var onOpenNotesTab: () -> Void = {}
    /// Session 77: the + is EVENT-ONLY now (dated tasks = "Add for today",
    /// undated = the Inbox +) — DayflowEventComposer replaced
    /// DayflowQuickAddSheet, and the Task/Event mode switch retired with it.
    @State private var showEventComposer = false
    /// Guards the FAB's tap action after its long-press (hold = note) fires.
    @State private var fabLongPressed = false
    @Environment(\.scenePhase) private var scenePhase
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
    /// `ReminderTaskStore.shared.tasks` is, so creating an event elsewhere doesn't
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
    /// For handing a Satchel document path back to Satchel. Search is the first
    /// thing in this file that opens another app.
    @Environment(\.openURL) private var openURL
    /// Whether the Inbox should open straight into a blank note.
    ///
    /// **The swipe and the menu are different intents and now say so.** David,
    /// after the first round: *"i have no way to look at the inbox other than
    /// to swipe left so in order to do that i have to create a document now."*
    /// Right — making the capture gesture the only door meant browsing had to
    /// go through creating. The parameter for this already existed; it just had
    /// no caller passing `false`.
    @State private var inboxStartsInNewNote = true
    /// Session 78, D159 — Quick Find (pull down on the header) replaced the
    /// Session 71 search cover; observed here to drain tapped destinations
    /// through the routing this screen already owns.
    @State private var quickFindRouter = DayflowQuickFindRouter.shared
    /// People and Places have no Dayflow screen, but they do have the summary
    /// sheet the wikilinks already use.
    @State private var searchWikiTarget: WikiLinkTarget? = nil

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
    /// Session 77 — Things-style multi-select. The action bar moved to
    /// DayflowRootView when Upcoming joined the selection club; this view
    /// only observes the state to hide its floating + while selecting.
    @State private var selection = DayflowTodaySelection.shared
    @State private var endeavorRoute: EndeavorRouteRef? = nil
    /// Set alongside `showNotes` so `DayflowNotesView` opens straight into a
    /// project instead of its browse list.
    @State private var routedProjectTitle: String? = nil

    // Editorial masthead (Session 77, locked on the "Dayflow Skin" canvas).
    // David's call, from Things: day NUMBER leads, day name beside it, and
    // the month moves up into the kicker line. Weather joins the kicker when
    // the home screen has a weather source (backlog); month alone until then.
    @State private var homeWeather = DayflowHomeWeather.shared
    private var mastheadKicker: String {
        let f = DateFormatter(); f.dateFormat = "MMMM"
        let month = f.string(from: selectedDate).uppercased()
        // "AUGUST \u{00B7} 78\u{00B0} AND CLEAR" when a fetch has landed; month
        // alone otherwise (the Simulator, usually \u{2014} no location fix there).
        if let weather = homeWeather.kicker {
            return month + " \u{00B7} " + weather
        }
        return month
    }
    private var mastheadDayNumber: String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: selectedDate)
    }
    private var mastheadWeekday: String {
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: selectedDate)
    }

    var body: some View {
        NavigationStack {
            // Session 77, step (b): the content below the header is now a
            // ScrollView ("page scrolls as one sheet", Dayflow-Tasks-Design.md
            // § Today). The comment below describes the pre-77 fixed-viewport
            // layout, kept as the history of why Daily Note used to flex.
            // Fixed viewport, not a ScrollView — this is what lets the Daily
            // Note card actually claim whatever room Agenda doesn't use (see
            // DayflowDailyNoteSection's header comment for why the old
            // ScrollView + two-fixed-heights approach couldn't do that).
            // Agenda sizes to its own natural content height; Daily Note's
            // `.frame(maxHeight: .infinity)` absorbs the rest. (The old
            // `recentLog` debug strip that used to also live in this VStack
            // was removed 2026-07-20 — see `log(_:)`'s doc comment below.)
            VStack(alignment: .leading, spacing: 12) {
                // PULL DOWN ON THE HEADER FOR SEARCH (Session 71).
                //
                // **On the header, not on the root VStack**, and that is the
                // whole of the design. The swipe-right gesture below could sit
                // on the root because it was gated to mostly-HORIZONTAL drags,
                // and a grep confirmed nothing on this screen used those. A
                // vertical gate has no such luxury: `DayflowAgendaSection` is a
                // list and vertical drag is what a list is for. Confining the
                // pull to the header is the same call Jot's CaptureView made for
                // the same reason, and it keeps the gesture off every scrollable
                // thing on the screen.
                //
                // The Mac reaches search with a system-wide hot key. A phone has
                // no equivalent, and both obvious gestures on this screen were
                // already spent — right on the Inbox, left on Notes as of this
                // session. Pull-down is the iOS convention for revealing a
                // search field and it was the one direction still free.
                VStack(alignment: .leading, spacing: 12) {
                    topBar

                    // Still the one door into Calendar browsing (Session 24);
                    // only the clothes changed for the Editorial skin.
                    Button {
                        showDateCalendar = true
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Rectangle().fill(Color.dayflowInk).frame(height: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mastheadKicker)
                                    .font(.system(size: 11, weight: .medium))
                                    .tracking(2.2)
                                    .foregroundStyle(Color.dayflowMuted)
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(mastheadDayNumber)
                                        .font(.dayflowSerif(38, weight: .heavy))
                                        .foregroundStyle(Color.dayflowInk)
                                    Text(mastheadWeekday)
                                        .font(.dayflowSerif(22, weight: .semibold))
                                        .foregroundStyle(Color.dayflowNoteText)
                                }
                            }
                            .padding(.vertical, 9)
                            Rectangle().fill(Color.dayflowInk).frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                // `contentShape` so the gaps between the two rows drag too; a
                // gesture you have to land on a glyph to start is a gesture
                // nobody finds twice.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            let vertical = value.translation.height
                            let horizontal = value.translation.width
                            guard vertical > 50,
                                  vertical > abs(horizontal) * 1.5 else { return }
                            // Session 78, D159 — the pull now opens Quick
                            // Find (presented by DayflowRootView, over any
                            // tab); TraceSearchView's cover retired with it.
                            withAnimation(.spring(duration: 0.32)) {
                                DayflowQuickFindRouter.shared.show = true
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                )

                // Session 77, step (b): task card first, events strip, then
                // the Day note with a minimum height — replaces
                // DayflowAgendaSection (file kept on disk, unused; delete in
                // the housekeeping pass). `agendaRefreshToken` keeps its old
                // job: saving a calendar event for the visible day recreates
                // the section, re-running its `.task(id:)` fetch.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DayflowTodaySection(date: selectedDate)
                            .id(agendaRefreshToken)

                        DayflowDailyNoteSection(
                            date: selectedDate,
                            reloadToken: dailyNoteReloadToken,
                            onExpand: { showNoteFullPage = true },
                            onOpenNotes: {
                                // Session 77: Notes is a tab now — select it
                                // rather than present the cover. (The
                                // 2026-07-30 regression note about consuming
                                // `routedProjectTitle` moved with the cover,
                                // which deep-link routing still uses — see
                                // resolveNoteRoute's Notes/Projects branch.)
                                onOpenNotesTab()
                            }
                        )
                        // A FIXED height, not minHeight — found 2026-08-28
                        // when David opened the pinned July 22 note (which
                        // carries chips + a Related Notes table) and Today's
                        // note section rendered overlapped. Inside a
                        // ScrollView the section gets no height proposal, so
                        // its editor (built for the old bounded viewport,
                        // maxHeight .infinity inside) collapses and its
                        // footer rows climb over the text. A definite height
                        // restores the bounded world the editor was designed
                        // for; longer notes scroll inside it, and the pencil
                        // expands to full page as always.
                        .frame(height: 360)
                        // Room for the floating + and the tab bar.
                        .padding(.bottom, 56)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await ReminderTaskStore.shared.refreshAll()
                    agendaRefreshToken = UUID()
                }
            }
            .padding()
            .frame(maxHeight: .infinity)
            // Session 77, step (b): the + above the tab bar (design doc §
            // Navigation), task mode — the same reset the old Agenda + did.
            .overlay(alignment: .bottomTrailing) {
                if selection.isActive { EmptyView() } else {
                Button {
                    if fabLongPressed { fabLongPressed = false; return }
                    showEventComposer = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.dayflowPaper)
                        .frame(width: 50, height: 50)
                        .background(Color.dayflowFloatingAction, in: RoundedRectangle(cornerRadius: 2))
                        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                // Hold for a note: tap = event, hold = a blank note into To
                // file — the swipe-right door's visible backup (composer
                // round, 2026-08-28).
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        fabLongPressed = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        inboxStartsInNewNote = true
                        showNotesInbox = true
                    }
                )
                .padding(.trailing, 4)
                }
            }
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
            //
            // **Swipe LEFT to Notes, added 2026-08-14 (Session 71).** David:
            // *"I keep going to the notes screen in Dayflow. it is one of my
            // favorite sections but it requires me to click that small icon on
            // the Daily Note screen. I was thinking a left swipe would take me
            // to that screen."* Left was the free direction, right was already
            // taken by the Inbox above, and the mostly-horizontal gating below
            // is already proven on this exact surface — so this is a mirror of a
            // working gesture rather than a new one to re-validate. The small
            // icon on the Daily Note card stays; a gesture is a shortcut, not a
            // replacement for a control you can see.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        // One gate for both directions, deliberately. Written as
                        // two guards it would be two thresholds to keep in step,
                        // and they would eventually disagree.
                        guard abs(horizontal) > abs(vertical) * 1.5,
                              abs(horizontal) > 50 else { return }
                        if horizontal > 0 {
                            inboxStartsInNewNote = true
                            showNotesInbox = true
                        } else {
                            // Session 77: Notes is a tab now — same call as the
                            // card's own notes icon above.
                            onOpenNotesTab()
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            )
        }
        .sheet(isPresented: $showEventComposer) {
            DayflowEventComposer(initialDate: selectedDate) { savedDay in
                if Calendar.current.isDate(savedDay, inSameDayAs: selectedDate) {
                    agendaRefreshToken = UUID()
                }
            }
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
        // Session 78, D159 — Quick Find replaced the TraceSearchView cover.
        // The card lives on DayflowRootView; a tapped result that needs this
        // screen's routing arrives through the router, and the 0.35s hop
        // gives the overlay's exit animation room before a presentation is
        // asked for (the same present-during-dismiss trap
        // `pendingSearchDestination` was born from).
        .onChange(of: quickFindRouter.pendingDestination != nil) { _, hasPending in
            guard hasPending else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let destination = quickFindRouter.pendingDestination else { return }
                quickFindRouter.pendingDestination = nil
                if canOpenFromSearch(destination) {
                    openSearchDestination(destination)
                }
            }
        }
        .sheet(item: $searchWikiTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target, sourceNoteText: "")
            }
        }
        .fullScreenCover(isPresented: $showNotesInbox) {
            // Session 44 addendum 10 — swipe-right destination. See
            // `showNotesInbox`'s own declaration above and
            // DayflowNotesInboxView.swift's header comment.
            // The swipe lands in a blank note; the Browse menu lands on the
            // list. See that view's own comment on the parameter.
            DayflowNotesInboxView(startInNewNote: inboxStartsInNewNote)
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
        // Dayflow" finding. Agenda reads ReminderTaskStore.shared's arrays live
        // (no local snapshot), so this alone is enough to bring it current
        // whenever you switch back to Dayflow from Things or anywhere else —
        // no separate plumbing needed for the main screen specifically.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await ReminderTaskStore.shared.refreshAll() }
                Task { await DayflowHomeWeather.shared.refresh() }
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
                // The widget's + always wanted event mode; it gets the
                // composer directly now.
                showEventComposer = true
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
                    showEventComposer = false
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
            await DayflowHomeWeather.shared.refresh()
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

    // MARK: - Search routing

    /// Whether this app can actually show the thing.
    ///
    /// **Asked before the cover closes**, so a row that cannot be routed expands
    /// its text in place instead of dismissing search and landing nowhere.
    /// `.weeklyNote` is `Notes/Horizons`, which Dayflow deliberately has no
    /// screen for — see `DayflowBacklinksView.isOpenable`, which has said so
    /// since it was written. `.document` needs Satchel installed, which is not
    /// knowable until `openURL` reports back, so it is optimistically true and
    /// the failure surfaces there.
    private func canOpenFromSearch(_ destination: MacSearchDestination) -> Bool {
        switch destination {
        case .dailyOrProjectNote, .inboxNote, .endeavor, .document:
            return true
        case .person(let id):
            return NotionService.shared.people.contains { $0.id == id }
        case .place(let id):
            return NotionService.shared.places.contains { $0.id == id }
        case .weeklyNote, .preview:
            return false
        }
    }

    /// Every branch here is a route that already existed. Nothing new was
    /// invented to receive a search result, which is the same rule
    /// `MacSearchDestination` was written under.
    private func openSearchDestination(_ destination: MacSearchDestination) {
        switch destination {
        case .dailyOrProjectNote(let path):
            pendingNotePath = path
            resolveNoteRoute()
        case .inboxNote:
            // The Inbox list, NOT `startInNewNote:` — arriving from a search
            // result means he is looking for something that exists, and minting
            // a blank note on top of it would be the opposite of the answer.
            route { showNotesInbox = true }
        case .endeavor(let id):
            pendingEndeavorID = id
            resolveNoteRoute()
        case .person(let id):
            guard let person = NotionService.shared.people.first(where: { $0.id == id })
            else { return }
            route { searchWikiTarget = .person(person) }
        case .place(let id):
            guard let place = NotionService.shared.places.first(where: { $0.id == id })
            else { return }
            route { searchWikiTarget = .place(place) }
        case .document(let path):
            guard let url = TraceSatchelHandoff.documentURL(path: path) else { return }
            openURL(url)
        case .weeklyNote, .preview:
            // Declined by `canOpenFromSearch`, so this is unreachable. Left
            // exhaustive rather than `default:` so a new case has to be thought
            // about here instead of silently falling through to nothing.
            break
        }
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
            || showEventComposer || browseDestination != nil || endeavorRoute != nil
            || DayflowQuickFindRouter.shared.show
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
            showEventComposer = false
            browseDestination = nil
            endeavorRoute = nil
            DayflowQuickFindRouter.shared.show = false
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
            // Session 78, D159 — the hamburger is GONE. Quick Find (pull
            // down anywhere) absorbed its whole family: Anytime and the
            // per-list screens live under GO TO / LISTS, Settings rides at
            // the card's foot, and search IS the card. The notes-staging
            // Inbox stayed reachable through the Notes tab's TO FILE
            // segment. Top row is now just the day strip — the calm David
            // asked Session 77's "why have the gear and the hamburger?"
            // question toward, taken to its end.
            Color.clear.frame(width: 32, height: 32)
            Spacer()
            dayPill
            Spacer()
            // Session 77: the gear moved into the hamburger menu; this clear
            // frame keeps the day pill centered.
            Color.clear.frame(width: 32, height: 32)
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
                    // Editorial (Session 77): plain small-caps text, accent
                    // on the active day, no pill fill — the white-capsule
                    // treatment above this line's history was the cream skin.
                    Text(day.label.uppercased())
                        .font(.system(size: 11, weight: isActive(day) ? .bold : .medium))
                        .tracking(1.2)
                        .foregroundStyle(isActive(day) ? Color.dayflowAccent : Color.dayflowFaint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
    }

    private func isActive(_ day: DayflowRelativeDay) -> Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: day.date())
    }

    // Save routing for the old Quick Add sheet lived here until Session 77;
    // DayflowEventComposer owns event creation (buffers included) now, and
    // task creation lives in the Today card's Add row and the Inbox +.

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
    DayflowRootView()
        .environment(NotionService.shared)
}
