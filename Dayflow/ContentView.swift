//
//  ContentView.swift
//  Dayflow
//
//  The real home screen — top bar (browse menu: Upcoming/Calendar/Anytime/
//  Inbox, Yesterday/Today/Tomorrow day-pill, settings gear), a serif date
//  headline, the real Agenda section (DayflowAgendaSection.swift, build order
//  step 3), and the real Daily Note section (DayflowDailyNoteSection.swift +
//  DayflowNoteFullPageView.swift, build order step 4). Browse views (step 5)
//  are wired for real as of this pass — see DayflowUpcomingView.swift,
//  DayflowCalendarBrowseView.swift, DayflowAnytimeView.swift. Inbox (step 5b)
//  added 2026-07-20 — see DayflowInboxView.swift. Settings (step 6) is still
//  a stub icon that just logs.
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

struct ContentView: View {
    @State private var selectedDate: Date = DayflowRelativeDay.today.date()
    @State private var showQuickAdd = false
    @Environment(\.scenePhase) private var scenePhase
    // Agenda's collapse state, lifted out of DayflowAgendaSection so this
    // screen can bind to it (DayflowAgendaSection.swift's own header comment
    // has the history). Daily Note no longer reads this directly — its card
    // just flexes to fill whatever space Agenda leaves, collapsed or not.
    @State private var agendaCollapsed = false
    @State private var showNoteFullPage = false
    // Browse menu destination (Upcoming/Calendar/Anytime) — one optional
    // value driving a single .fullScreenCover(item:) rather than three Bool
    // flags. See DayflowModels.swift's "Browse views" section.
    @State private var browseDestination: DayflowBrowseDestination? = nil

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

                Text(dateHeadlineText)
                    .font(.custom("Georgia", size: 26).weight(.bold))
                    .padding(.top, 2)
                    .padding(.bottom, 4)

                DayflowAgendaSection(
                    date: selectedDate,
                    onOpenQuickAdd: { showQuickAdd = true },
                    isCollapsed: $agendaCollapsed
                )

                DayflowDailyNoteSection(
                    date: selectedDate,
                    onExpand: { showNoteFullPage = true },
                    onShare: { log("Share — not built yet") }
                )
            }
            .padding()
            .frame(maxHeight: .infinity)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showQuickAdd) {
            DayflowQuickAddSheet { draft in
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
        .fullScreenCover(isPresented: $showNoteFullPage) {
            DayflowNoteFullPageView(initialDate: selectedDate)
        }
        .fullScreenCover(item: $browseDestination) { destination in
            switch destination {
            case .upcoming:
                DayflowUpcomingView(onSwitchToCalendar: { browseDestination = .calendar })
            case .calendar:
                DayflowCalendarBrowseView(
                    onSelect: { picked in selectedDate = picked },
                    onSwitchToUpcoming: { browseDestination = .upcoming }
                )
            case .anytime:
                DayflowAnytimeView()
            case .inbox:
                DayflowInboxView()
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
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Menu {
                Button { browseDestination = .upcoming } label: {
                    Label("Upcoming", systemImage: "calendar.day.timeline.left")
                }
                Button { browseDestination = .calendar } label: {
                    Label("Calendar", systemImage: "calendar")
                }
                Button { browseDestination = .anytime } label: {
                    Label("Anytime", systemImage: "books.vertical")
                }
                Button { browseDestination = .inbox } label: {
                    Label("Inbox", systemImage: "tray")
                }
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 15))
                    .frame(width: 32, height: 32)
                    .background(.background, in: Circle())
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
            }
            Spacer()
            dayPill
            Spacer()
            iconButton(systemName: "gearshape") {
                // Settings (Default Calendar, Sync) — build order step 6, not
                // built yet.
                log("Settings — step 6, not built yet")
            }
        }
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
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
                        .font(.system(size: 13))
                        .foregroundStyle(isActive(day) ? .white : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(isActive(day) ? Color.blue : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.3), in: Capsule())
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
                switch draft.when {
                case .none:
                    await ThingsService.shared.addTask(title: draft.title, list: draft.list, notes: draft.notes)
                case .today:
                    await ThingsService.shared.addTask(title: draft.title, toToday: true, list: draft.list, notes: draft.notes)
                case .date(let d):
                    await ThingsService.shared.addTask(title: draft.title, date: d, list: draft.list, notes: draft.notes)
                case .thisEvening, .someday:
                    // Open architecture question, not yet resolved: these two
                    // Things-native buckets need the URL-scheme-direct path,
                    // which the Mini bridge's /add endpoint can't express (it
                    // only takes an arbitrary date). Conservative fallback so
                    // this doesn't silently mis-schedule: lands undated in the
                    // chosen list (or Inbox) instead of guessing a date.
                    await ThingsService.shared.addTask(title: draft.title, list: draft.list, notes: draft.notes)
                }
                await MainActor.run {
                    log("Task: \(draft.title) — \(draft.when.label)\(draft.list.map { " · \($0)" } ?? "")")
                }
            }
        case .event:
            // CalendarService.swift's write path (build order step 7) isn't
            // built yet — only fetchDayEvents/fetchUpcomingEvents/fetchEvents
            // (all read) exist.
            log("Event (not yet written — calendar write support pending): \(draft.title)")
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
