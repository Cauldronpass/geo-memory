//
//  DayflowRootView.swift
//  Dayflow
//
//  The tab bar shell (Session 77, step a of the task UI build —
//  Dayflow-Tasks-Design.md). Four tabs, always visible: Today · Tasks ·
//  Upcoming · Notes.
//
//  Session 89: the fourth tab was NOTES and is now RECORDS (D298) — it holds
//  notes, endeavors and the filing queue, and naming a container after one of
//  the things inside it is what made that screen read wrong. The Mac's sidebar
//  groups exactly these under RECORDS.
//
//  Session 89: the second tab was INBOX and is now TASKS, hosting
//  DayflowTasksView — whose first pool is the same triage screen the tab used
//  to hold. That file's header carries why the word moved and what it cost.
//  Still FOUR tabs: five sets of 9pt caps is where these labels start
//  truncating, and the shape of the tab bar is a whole-app decision that
//  should not get made as a side effect of a tasks screen. Replaces the top-bar browse Menu as the way around the
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
    case today, tasks, upcoming, records
}

struct DayflowRootView: View {
    @State private var selectedTab: DayflowTab = .today
    @State private var selectedDate: Date = DayflowRelativeDay.today.date()
    /// Session 77 — the "Add Task" quick action opens the capture card, which
    /// since Session 89 lives inside the Tasks tab's Inbox pool. Observed here
    /// for the tab switch; the room puts itself on that pool and the triage
    /// screen consumes the pending value.
    @State private var quickActions = DayflowQuickActionRouter.shared

    // MARK: Compose (D479)
    //
    // **Here, not on Today**, and that is the whole reason this placement was
    // chosen. Three of the six doors — Check in, Log interaction, Pin here —
    // are things recorded the moment they happen, and half of them are about
    // people and places, which live under RECORDS. A compose button that only
    // existed on Today would be asking him to travel back to Today first.
    //
    // The history is worth carrying: D188 put a floating + on Today, a later
    // build removed it for being too heavy on a page that is otherwise rules
    // and type, and that removal was never written down. D475 then wired this
    // menu to the button that was no longer drawing; D477 moved it to the day
    // strip and pushed that row's minimum width past the screen, laying the
    // whole page off both edges; D478 took it out. This is the fourth
    // placement and the first one in furniture with room to spare.
    @State private var showCompose = false
    @State private var showCheckIn = false
    /// The place a geofence check-in arrived for, resolved from the router
    /// (D492). Nil when Check In was opened from the compose menu or the quick
    /// action, which is what `showCheckIn` covers.
    @State private var geofencePlace: Place? = nil
    @State private var showWorkoutPrompt = false
    @State private var showLogInteraction = false
    /// Pin here writes into today's note with no UI at all, so the only thing
    /// it can ever need to say is that something went wrong.
    @State private var quickPinMessage: String? = nil

    /// The tab a pending destination asked for, captured at the MOMENT the
    /// destination arrived rather than looked up later (Session 84, with
    /// `tab(for:)`).
    ///
    /// A destination set while Quick Find is up cannot switch the tab yet, so
    /// it is held here until the card closes. Holding the ANSWER rather than
    /// re-deriving it from the router closes the same race on that path: the
    /// Notes tab can drain the destination while the card is still on screen,
    /// and the old code then found nothing to route by.
    @State private var routedTab: DayflowTab? = nil

    /// Which tab owns a routed destination (Session 78, Notes redesign):
    /// PROJECT notes open in place on the Notes tab so the tab bar stays,
    /// one tap to Today from any note. Everything else keeps Today's
    /// routing machinery.
    ///
    /// **Takes the destination. It must never re-read the router** (Session
    /// 84). David: *"i click on the note itself under Agenda... it twinkles
    /// when i press but it doesnt take me anywhere"*, and then, decisively:
    /// *"when i went manually to notes the kosta note is there waiting."*
    ///
    /// Two views observe `pendingDestination` and both fire on one change:
    /// `DayflowNotesView` DRAINS it (setting it back to nil) and this view
    /// reads it to pick a tab. **Delivery order across views is undefined**,
    /// the phrase `ContentView` already uses about this same router, and here
    /// the drain won: by the time this function ran the value was nil, it fell
    /// through to `.today`, and the note opened correctly on a tab the user
    /// was being sent away from. The route was never broken; the tab decision
    /// was racing the consumer of the thing it was deciding about.
    ///
    /// Taking the value as an argument is the whole fix: the change handler is
    /// handed the value that caused the change, so nothing can drain it out
    /// from under this.
    private func tab(for destination: MacSearchDestination?) -> DayflowTab {
        if case .dailyOrProjectNote(let path)? = destination,
           path.hasPrefix("Notes/Projects/") { return .records }
        return .today
    }

    /// The Editorial tab bar: paper over one hairline, four caps wordmarks,
    /// active in accent — the band the Notes mockups drew as their stand-in.
    private var editorialTabBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.dayflowHairline).frame(height: 1)
            HStack(spacing: 0) {
                editorialTab(.today, "TODAY", "sun.max")
                editorialTab(.tasks, "TASKS", "checklist")
                composeCell
                editorialTab(.upcoming, "UPCOMING", "calendar")
                editorialTab(.records, "RECORDS", "folder")
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .background(Color.dayflowPaper.ignoresSafeArea(edges: .bottom))
    }

    /// Compose, in the middle of the bar (D479).
    ///
    /// **A mark, not a fifth word.** This file's own header records why the
    /// bar holds four: *"five sets of 9pt caps is where these labels start
    /// truncating"*. A glyph is not a label, so four words stay four and
    /// nothing truncates. It also keeps the bar honest — the four words still
    /// answer "where am I", and the one thing between them that is not a word
    /// is the one thing that is not a place.
    ///
    /// **Filled, unlike its neighbours**, in `dayflowFloatingAction` (ink in
    /// light, accent in dark — the token that exists for exactly this). The
    /// other four cells are navigation and wear their state; this one does
    /// something and never looks selected.
    private var composeCell: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showCompose = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.dayflowPaper)
                .frame(width: 34, height: 34)
                .background(Color.dayflowFloatingAction,
                            in: RoundedRectangle(cornerRadius: 4))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compose")
    }

    /// Pin here. Writes the marker into today's note with a 500 m place match
    /// and no UI, which is what makes it worth a row: one tap in a car park
    /// and it is done. `QuickPin.drop` is shared code this target already
    /// compiled, so nothing had to move for it.
    ///
    /// **Silent when it works.** The only thing it says is that Notion was
    /// unreachable and the line went in unlinked, which is the honest outcome
    /// underground and not a failure of the pin.
    private func pinHere() {
        Task { @MainActor in
            do {
                let result = try await QuickPin.drop(label: nil, emoji: nil)
                await NotionService.shared.fetchCaptures()
                if !result.linked {
                    quickPinMessage = "Pinned to today's note. Couldn't reach Notion, so it isn't linked to a capture."
                }
            } catch {
                quickPinMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Geofence notifications (D492)

    /// Takes the two routes a geofence notification can produce.
    ///
    /// **`.checkIn` is taken only when it carries a place.** A bare
    /// `trace://checkin` needs nothing and is the compose menu's and the quick
    /// action's own door, already answered by `showCheckIn` above. Taking every
    /// `.checkIn` here would mean this sheet and that one race for the same
    /// route, and which won would depend on view order.
    ///
    /// The router has already held the route until `NotionService` reported
    /// places ready, so `first(where:)` here is a lookup and not a retry. If the
    /// ID matches nothing the route is spent and nothing opens: the place was
    /// deleted between the notification firing and the tap, and a check-in sheet
    /// offering the wrong place would be worse than none.
    private func takeGeofenceRoutes() {
        if let route = TraceRouter.shared.take(where: {
            if case .checkIn(let id, _) = $0 { return id != nil }
            return false
        }), case .checkIn(let id, _) = route, let id {
            geofencePlace = NotionService.shared.places.first { $0.id == id }
        }
        if TraceRouter.shared.take(where: {
            if case .workout = $0 { return true } else { return false }
        }) != nil {
            showWorkoutPrompt = true
        }
    }

    /// The middle ground (David's call after seeing wordmarks proposed
    /// alone): the glyph keeps the glance-recognition the system bar had,
    /// the caps label keeps the Editorial voice. Both wear accent when
    /// active, faint when not.
    private func editorialTab(_ tab: DayflowTab, _ label: String, _ icon: String) -> some View {
        let active = selectedTab == tab
        return Button {
            if selectedTab != tab {
                UISelectionFeedbackGenerator().selectionChanged()
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: active ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 9, weight: active ? .bold : .medium))
                    .tracking(1.4)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(active ? Color.dayflowAccent : Color.dayflowFaint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    /// Session 77 — Things-style multi-select, shared by the Today card and
    /// the Upcoming tab; the bar lives HERE so it floats over whichever tab
    /// is selecting. Switching tabs exits selection.
    @State private var selection = DayflowTodaySelection.shared
    @State private var selectionWhenRequest: DayflowWhenRequest? = nil
    @State private var showDeleteConfirm = false
    /// Session 78, D159 — Quick Find. Pull down on any tab's header; the
    /// card presents HERE (an overlay, so it drops from the top over
    /// whichever tab is up — a fullScreenCover would slide in from the
    /// bottom, the wrong direction for a pull-down).
    @State private var quickFind = DayflowQuickFindRouter.shared
    /// Session 78 — the delete-undo pill (DayflowUndo.swift), floating with
    /// the selection bar in the bottom overlay.
    @State private var undoStack = DayflowUndoStack.shared

    var body: some View {
        // Editorial tab bar (Session 78, the polish round). The SYSTEM bar
        // is hidden on every tab and replaced by the flat caps band below —
        // the bar every approved Notes mockup already drew: paper, one
        // hairline, four wordmarks, active in accent. No icons, no floating
        // capsule. `safeAreaPadding(.bottom, 46)` on each tab stands in for
        // the inset the system bar used to provide, so scroll content stops
        // above the band instead of sliding under it.
        TabView(selection: $selectedTab) {
            ContentView(selectedDate: $selectedDate,
                        onOpenNotesTab: { selectedTab = .records })
                .toolbar(.hidden, for: .tabBar)
                .safeAreaPadding(.bottom, 60)
                .tag(DayflowTab.today)

            DayflowTasksView()
                .toolbar(.hidden, for: .tabBar)
                .safeAreaPadding(.bottom, 60)
                .tag(DayflowTab.tasks)

            DayflowUpcomingView(isTabRoot: true)
                .toolbar(.hidden, for: .tabBar)
                .safeAreaPadding(.bottom, 60)
                .tag(DayflowTab.upcoming)

            DayflowNotesView(selectedDate: $selectedDate, isTabRoot: true)
                .toolbar(.hidden, for: .tabBar)
                .safeAreaPadding(.bottom, 60)
                .tag(DayflowTab.records)
        }
        .tint(Color.dayflowAccent)
        // ── The compose menu (D454, D479) ──────────────────────────────────
        //
        // **A confirmation dialog rather than a `Menu`.** The dialog is the
        // control Trace's own floating button used, so the interaction is the
        // one David already has in his hands, and it comes up from the bottom
        // where his thumb already is.
        //
        // No section headings. The mockup drew TRACE and DAYFLOW above the two
        // groups and said in its own caption they were a build aid; in the one
        // app there are not two apps to label.
        //
        // The last three go through `DayflowQuickActionRouter`, which already
        // switches to the right tab and is already drained by the screens that
        // own those composers. A second path to them would be a second thing
        // to keep in step.
        .confirmationDialog("", isPresented: $showCompose, titleVisibility: .hidden) {
            Button("Check in") { showCheckIn = true }
            Button("Log interaction") { showLogInteraction = true }
            Button("Pin here") { pinHere() }
            Button("Add a task") { quickActions.pending = "AddTask" }
            Button("Add an event") { quickActions.pending = "AddEvent" }
            Button("New note") { quickActions.pending = "NewNote" }
            Button("Cancel", role: .cancel) { }
        }
        // **The three rooms** (D486). A sheet rather than a
        // `fullScreenCover`: none of these three carries a close button of its
        // own — they were tabs in Trace and never needed one — so a cover
        // would trap him in a room with no way out. A sheet swipes down.
        .sheet(item: Binding(
            get: { DayflowRecordsRouter.shared.pendingRoom },
            set: { DayflowRecordsRouter.shared.pendingRoom = $0 }
        )) { room in
            // **`VisitsView` is NOT wrapped**, and that is not an
            // oversight: it builds its own `NavigationStack`, and a stack
            // inside a stack gives two navigation bars and pushes that land in
            // the wrong one. The other two do not build one and need it for
            // their own `NavigationLink`s.
            Group {
                switch room {
                case .visits:
                    VisitsView()
                case .fitness:
                    NavigationStack { FitnessView() }
                case .billiards:
                    NavigationStack { BilliardsView() }
                }
            }
            .environment(NotionService.shared)
            .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showCheckIn) {
            CheckInView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        // **The geofence check-in, arriving with a place** (D492). A separate
        // `item:` sheet rather than a flag plus a stored place: the place IS the
        // presentation condition, so binding them together removes the state
        // where one is set and the other is not.
        .sheet(item: $geofencePlace) { place in
            CheckInView(preselectedPlace: place)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        // The workout prompt on leaving somewhere (D492). Empty, as it is in the
        // old app - the notification's place ID was stored there and never read.
        .sheet(isPresented: $showWorkoutPrompt) {
            // **No `NavigationStack` around it**, checked rather than assumed:
            // the wizard builds its own at line 149 and Trace presents it bare.
            // Wrapping it would give two navigation bars, which is the fault
            // D486 avoided the same way for `VisitsView`.
            WorkoutWizardView()
                .environment(NotionService.shared)
        }
        .sheet(isPresented: $showLogInteraction) {
            FABLogInteractionSheet()
                .environment(NotionService.shared)
        }
        .alert("Pin here", isPresented: Binding(
            get: { quickPinMessage != nil },
            set: { if !$0 { quickPinMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(quickPinMessage ?? "")
        }
        // The band pins to the SCREEN bottom: it ignores the keyboard's
        // safe area (the keyboard window simply draws over it, exactly as
        // it did over the system bar) rather than riding up above it.
        .overlay(alignment: .bottom) {
            editorialTabBar
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .overlay {
            if quickFind.show {
                DayflowQuickFindView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Declared AFTER Quick Find so the bar floats above the card —
        // left-swiping a row inside the card starts a selection whose
        // When/Move/Delete happen right here (Session 78 round 2).
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if undoStack.visible {
                    DayflowUndoPill()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if selection.isActive {
                    selectionBar
                }
            }
            .padding(.bottom, 72) // clear of the Editorial band
        }
        .animation(.spring(duration: 0.32), value: quickFind.show)
        // Session 78 evening — agenda NOTE rows (Today/Upcoming) route by
        // setting pendingDestination directly with Quick Find closed; land
        // on the tab that owns the note machinery.
        // **A `trace://discover` link, before its screen can act on it**
        // (D484). `hasHeld` looks without taking — it is what the router grew
        // for exactly this: the root needs to select the tab, and the screen
        // on that tab needs to still find the route waiting for it when it
        // appears. Taking it here would consume it before anything could show
        // it.
        .onChange(of: TraceRouter.shared.version) { _, _ in
            if TraceRouter.shared.hasHeld(where: {
                if case .discover = $0 { return true } else { return false }
            }) {
                selectedTab = .records
            }
            takeGeofenceRoutes()
        }
        // Cold launch from a geofence notification: the route is delivered
        // before this view exists, so `version` never changes for it.
        .task { takeGeofenceRoutes() }
        // A Records row tapped in Quick Find (D480). The tab only; the
        // Records screen owns the value and is the one that clears it.
        .onChange(of: DayflowRecordsRouter.shared.pendingSegment) { _, wanted in
            if wanted != nil { selectedTab = .records }
        }
        .onChange(of: quickFind.pendingDestination) { _, destination in
            // Watches the VALUE, not "is it nil". The old form handed this
            // closure a Bool and left it to look the destination up again,
            // which is the race described on `tab(for:)`.
            guard let destination else { return }
            let wanted = tab(for: destination)
            if quickFind.show { routedTab = wanted } else { selectedTab = wanted }
        }
        .onChange(of: quickFind.show) { _, showing in
            // A tapped result that needs another tab: land on it as the card
            // goes. The tab was decided when the destination arrived, so a
            // drain that has already happened cannot erase the decision.
            guard !showing, let wanted = routedTab else { return }
            routedTab = nil
            selectedTab = wanted
        }
        .sheet(item: $selectionWhenRequest) { request in
            DayflowWhenSheet(tasks: request.tasks) { selection.exit() }
        }
        .onChange(of: selectedTab) { _, _ in
            if selection.isActive { selection.exit() }
        }
        .onChange(of: quickActions.pending) { _, type in
            if type == "AddTask" { selectedTab = .tasks }
            if type == "AddEvent" || type == "NewNote" { selectedTab = .today }
            // **Check In, new in D490.** It presents rather than routing to a
            // tab, so it is consumed here: the other three are drained by the
            // screens that own their composers, and this one has no screen of
            // its own — it is the same sheet the compose menu opens.
            if type == "checkin" {
                quickActions.pending = nil
                showCheckIn = true
            }
        }
        // Cold launch from the quick action: pending was set before this view
        // existed, so onChange never fires — check once on appearance.
        .task {
            if quickActions.pending == "AddTask" { selectedTab = .tasks }
            if quickActions.pending == "AddEvent"
                || quickActions.pending == "NewNote" { selectedTab = .today }
            // Same catch-up for Check In (D490). A quick action taken from a
            // cold start sets `pending` before this view exists, so `onChange`
            // never fires for it and the sheet would never open.
            if quickActions.pending == "checkin" {
                quickActions.pending = nil
                showCheckIn = true
            }
        }
        .onOpenURL { url in
            // Tab selection only — ContentView's own handler does the real
            // work (see this file's header comment).
            switch url.host {
            case "addTask":
                // Session 78 — the tasks widget's "+": same router value the
                // Home Screen quick action uses; DayflowInboxView consumes
                // it and opens the capture card.
                selectedTab = .tasks
                quickActions.pending = "AddTask"
            case "addEvent", "note", "endeavor", "task":
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
        // allTasks since Quick Find joined the selecting surfaces (Session
        // 78) — its card selects across every list, dated or not.
        ReminderTaskStore.shared.allTasks
            .filter { selection.ids.contains($0.id) }
    }

    /// Things' bottom pill, Editorial-dressed: When / Move / trash / close —
    /// no count, no Done (David's calls).
    private var selectionBar: some View {
        // Trash at the FAR end from ✕ (Session 78 — David deleted things
        // reaching for dismiss: "the x to dismiss the window is right next
        // to the trash"), with clear air between it and When; bulk delete
        // additionally confirms below. Distance + confirmation, both.
        HStack(spacing: 0) {
            barButton("", systemImage: "trash", tint: Color.dayflowAccent) {
                showDeleteConfirm = true
            }
            Color.clear.frame(width: 16, height: 44)
            barButton("When", systemImage: "calendar") {
                selectionWhenRequest = DayflowWhenRequest(tasks: selectedTasks)
            }
            Menu {
                // Someday is ALWAYS offered — it may not exist yet, and
                // moveToSomeday creates it; a menu built from existing lists
                // alone hid it until first use (David's catch).
                Button {
                    somedaySelected()
                } label: {
                    Label(ReminderTaskStore.somedayListName, systemImage: "archivebox")
                }
                Divider()
                ForEach(ReminderTaskStore.shared.listNames.filter { $0 != ReminderTaskStore.somedayListName },
                        id: \.self) { name in
                    Button(name) { moveSelected(to: name) }
                }
            } label: {
                barLabel("Move", systemImage: "arrow.right")
            }
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
        .confirmationDialog(
            selection.ids.count == 1 ? "Delete this task?" : "Delete \(selection.ids.count) tasks?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) { }
        }
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
        DayflowUndoStack.shared.record(targets)
        withAnimation { selection.exit() }
        Task {
            for t in targets { _ = await ReminderTaskStore.shared.remove(taskID: t.id) }
        }
    }

    private func somedaySelected() {
        let targets = selectedTasks
        withAnimation { selection.exit() }
        Task {
            for t in targets { _ = await ReminderTaskStore.shared.moveToSomeday(taskID: t.id) }
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
