//
//  DayflowRootView.swift
//  Dayflow
//
//  The tab bar shell (Session 77, step a of the task UI build —
//  Dayflow-Tasks-Design.md). Four tabs, always visible: Today · Inbox ·
//  Upcoming · Notes. Replaces the top-bar browse Menu as the way around the
//  app; the Menu survives on the Today screen for now with only the entries
//  that have no tab yet (Anytime, the notes Inbox, Search) — where those
//  land permanently is an open design question for steps c/d.
//
//  This view deliberately owns almost nothing:
//  - `selectedDate` is lifted here from ContentView so the Notes tab and the
//    Today screen keep sharing "the one real date" (the pattern every
//    fullScreenCover in ContentView.swift already relied on — see its
//    Session 18/19 comments). ContentView's `selectedDate` became a
//    `@Binding` in the same pass.
//  - Deep links: ContentView keeps its full `.onOpenURL` handler unchanged
//    (SwiftUI fires every registered handler in the hierarchy, and the Today
//    tab is the initial tab so ContentView always exists). The handler here
//    ONLY selects the Today tab for the routes that present something from
//    ContentView (`addEvent`, `note`, `endeavor`, `launch?target=today`), so
//    a widget tap taken while sitting on another tab lands on the screen the
//    presentation is attached to instead of firing invisibly underneath it.
//  - Tab-hosted copies of DayflowInboxView / DayflowUpcomingView /
//    DayflowNotesView pass `isTabRoot: true`, which hides their chevron
//    close buttons (an `@Environment(\.dismiss)` with no presentation to
//    dismiss is a dead control). The fullScreenCover copies still present
//    with the chevron as before.
//

import SwiftUI

enum DayflowTab: String {
    case today, inbox, upcoming, notes
}

struct DayflowRootView: View {
    @State private var selectedTab: DayflowTab = .today
    @State private var selectedDate: Date = DayflowRelativeDay.today.date()
    /// Session 77 — the "Add Task" quick action opens the INBOX tab's capture
    /// card (the + went event-only in the composer round). Observed here for
    /// the tab switch; DayflowInboxView consumes the pending value.
    @State private var quickActions = DayflowQuickActionRouter.shared
    /// Session 77 — Things-style multi-select, shared by the Today card and
    /// the Upcoming tab; the bar lives HERE so it floats over whichever tab
    /// is selecting. Switching tabs exits selection.
    @State private var selection = DayflowTodaySelection.shared
    @State private var selectionWhenRequest: DayflowWhenRequest? = nil

    var body: some View {
        TabView(selection: $selectedTab) {
            ContentView(selectedDate: $selectedDate,
                        onOpenNotesTab: { selectedTab = .notes })
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(DayflowTab.today)

            DayflowInboxView(isTabRoot: true)
                .tabItem { Label("Inbox", systemImage: "tray") }
                .tag(DayflowTab.inbox)

            DayflowUpcomingView(isTabRoot: true)
                .tabItem { Label("Upcoming", systemImage: "calendar") }
                .tag(DayflowTab.upcoming)

            DayflowNotesView(selectedDate: $selectedDate, isTabRoot: true)
                .tabItem { Label("Notes", systemImage: "note.text") }
                .tag(DayflowTab.notes)
        }
        .tint(Color.dayflowAccent)
        .overlay(alignment: .bottom) {
            if selection.isActive {
                selectionBar
                    .padding(.bottom, 64) // clear of the tab bar
            }
        }
        .sheet(item: $selectionWhenRequest) { request in
            DayflowWhenSheet(tasks: request.tasks) { selection.exit() }
        }
        .onChange(of: selectedTab) { _, _ in
            if selection.isActive { selection.exit() }
        }
        .onChange(of: quickActions.pending) { _, type in
            if type == "AddTask" { selectedTab = .inbox }
        }
        // Cold launch from the quick action: pending was set before this view
        // existed, so onChange never fires — check once on appearance.
        .task {
            if quickActions.pending == "AddTask" { selectedTab = .inbox }
        }
        .onOpenURL { url in
            // Tab selection only — ContentView's own handler does the real
            // work (see this file's header comment).
            switch url.host {
            case "addEvent", "note", "endeavor":
                selectedTab = .today
            case "launch":
                let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "target" })?.value
                if target == "today" { selectedTab = .today }
            default:
                break
            }
        }
    }
}

// MARK: - Multi-select action bar (Session 77; moved here when Upcoming
// joined the selection club — the bar floats over whichever tab is
// selecting)

extension DayflowRootView {

    /// Tasks currently selected, resolved against the live store (today's
    /// list plus the 60-day upcoming window covers both selecting surfaces).
    private var selectedTasks: [ThingsTask] {
        (ReminderTaskStore.shared.tasks + ReminderTaskStore.shared.upcomingTasks)
            .filter { selection.ids.contains($0.id) }
    }

    /// Things' bottom pill, Editorial-dressed: When / Move / trash / close —
    /// no count, no Done (David's calls).
    private var selectionBar: some View {
        HStack(spacing: 0) {
            barButton("When", systemImage: "calendar") {
                selectionWhenRequest = DayflowWhenRequest(tasks: selectedTasks)
            }
            Menu {
                ForEach(ReminderTaskStore.shared.listNames, id: \.self) { name in
                    Button(name) { moveSelected(to: name) }
                }
            } label: {
                barLabel("Move", systemImage: "arrow.right")
            }
            barButton("", systemImage: "trash", tint: Color.dayflowAccent) { deleteSelected() }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { selection.exit() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dayflowPaper.opacity(0.7))
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(Color.dayflowInk, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
    }

    private func barLabel(_ label: String, systemImage: String,
                          tint: Color = .dayflowPaper) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 13.5, weight: .semibold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, label.isEmpty ? 10 : 14)
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    private func barButton(_ label: String, systemImage: String,
                           tint: Color = .dayflowPaper,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(label, systemImage: systemImage, tint: tint) }
            .buttonStyle(.plain)
            .disabled(selection.ids.isEmpty)
    }

    private func deleteSelected() {
        let targets = selectedTasks
        withAnimation { selection.exit() }
        Task {
            for t in targets { _ = await ReminderTaskStore.shared.remove(taskID: t.id) }
        }
    }

    private func moveSelected(to list: String) {
        let targets = selectedTasks
        withAnimation { selection.exit() }
        Task {
            for t in targets {
                _ = await ReminderTaskStore.shared.update(
                    taskID: t.id, title: t.title, date: nil,
                    clearDate: false, list: list, notes: t.notes)
            }
        }
    }
}
