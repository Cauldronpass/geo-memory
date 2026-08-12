import SwiftUI
import CoreLocation
import UIKit

struct ContentView: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingActionSheet = false
    @State private var selectedTab = 0
    @State private var showingCheckIn = false
    @State private var showingAddPlace = false
    @State private var showingAddCapture = false
    @State private var showingDrawer = false
    @State private var showingAddPhoto = false
    @State private var showingLeftDrawer = false
    @State private var showingQuickPin = false
    @State private var quickPinCoord = CLLocationCoordinate2D()
    /// Session 48 follow-up — failure feedback for quickPinToNote(_:_:)
    /// (Home's FAB Quick Pin variants). Drives a plain .alert; nil = hidden.
    @State private var quickPinFailedMessage: String? = nil
    // Session 48 (Trace redesign) — removed showingLifeContextMenu,
    // isPeopleContext, isActivityContext, showingFABLogWorkout,
    // showingFABLogBilliards. Life tab is retired (see LifeView.swift's new
    // header comment); People is now its own tab so fabContext below reads
    // selectedTab directly instead of a notification-driven flag; Activity's
    // Log Workout/Log Billiards FAB shortcuts are dropped because
    // FitnessView/BilliardsView (still reachable via Home's Jump To tiles)
    // already have their own "+" toolbar buttons for the same actions.
    /// Fixed 2026-07-22 (Session 27 addendum, second instance) — this used to be
    /// paired with its own `showingGeofenceCheckIn` boolean, gating the sheet's
    /// content on `if let place = geofencePlace`. Same bug David hit with
    /// `logInteractionPerson`/`showingLogInteractionFromURL` (blank sheet on
    /// presentation, works on a retry) — he reported the identical symptom here,
    /// from a real geofence "you're near a place" notification tap. Switched to
    /// `.sheet(item:)` bound directly to this optional for the same reason.
    @State private var geofencePlace: Place? = nil
    @State private var pendingGeofencePlaceID: String? = nil
    @State private var showingWorkoutPrompt = false
    @State private var showingWorkoutFromURL = false
    /// `trace://visit?id=…` — the return leg of Dayflow's read-only visit card.
    /// Dayflow shows a visit and cannot edit it (a Session 17 boundary); Trace's
    /// `VisitDetailView` is where the notes field actually lives. Same
    /// pending/retry shape as `pendingCheckInPlaceID` below, and for the same
    /// reason: on a cold launch `notion.visits` is empty when the URL arrives.
    @State private var pendingVisitID: String? = nil
    @State private var visitFromURL: Visit? = nil
    @State private var isKeyboardVisible = false
    @State private var showingFABAddPerson = false
    @State private var showingFABLogInteraction = false
    @State private var showingFABAddAgenda = false
    /// Set only when a `trace://checkin?placeID=…` deep link resolves to a
    /// known place — 2026-07-21, Dayflow hand-off. Every other path that
    /// sets `showingCheckIn = true` (the FAB buttons, the Home Screen
    /// shortcut) resets this to nil first so a stale deep-linked place never
    /// leaks into an unrelated manual check-in.
    @State private var checkInPreselectedPlace: Place? = nil
    /// Fifth Dayflow hand-off button, 2026-07-21 (Session 26) — `trace://
    /// loginteraction?personID=…` resolves to a known person and presents
    /// `LogInteractionSheet` pre-scoped to them, same shape as `checkin`'s
    /// `checkInPreselectedPlace` above. Unlike CheckInView, LogInteractionSheet
    /// has no "generic, nobody preselected" mode — personID/personName are
    /// non-optional — so there's no shared boolean to reset the way every
    /// other `showingCheckIn = true` caller resets `checkInPreselectedPlace`.
    /// This sheet only ever opens via this one path.
    ///
    /// Fixed 2026-07-22 (Session 27 addendum): originally paired with its own
    /// `showingLogInteractionFromURL` boolean, gating the sheet's content on
    /// `if let person = logInteractionPerson`. David hit a real bug from that on
    /// a cold-launch test — the sheet opened but showed a blank screen, then
    /// worked correctly on a second try. Two independent `@State` vars driving
    /// one presentation can settle across two separate render passes instead of
    /// one, and since the `if let` produces nothing when it fails, "blank sheet"
    /// is exactly what a person-not-set-yet moment looks like. Switched to
    /// `.sheet(item:)` bound directly to this optional — same pattern
    /// `pendingIncomingDocument` below already uses — so there's one source of
    /// truth instead of two that can drift apart.
    @State private var logInteractionPerson: Person? = nil
    /// Cold-launch race fix, 2026-07-22 (Session 27) — same problem
    /// `resolveGeofencePlace()`/`pendingGeofencePlaceID` below already solves for
    /// geofence notifications: a Dayflow hand-off URL almost always cold-launches
    /// Trace, and `TraceApp.swift`'s `.task` awaits `fetchPlaces()` then
    /// `fetchVisits()` then `fetchCaptures()` then `fetchPeople()` (in that order,
    /// sequentially) before any of `notion.places`/`notion.people` are populated —
    /// so a same-tick lookup in `.onOpenURL` almost always finds nothing, even for
    /// a perfectly valid ID, and (for `loginteraction`, which has no unconditional
    /// fallback) the sheet just never opens at all. These two hold the ID until
    /// the corresponding list actually loads; see `resolvePendingCheckIn()` /
    /// `resolvePendingLogInteraction()` below for the retry logic.
    @State private var pendingCheckInPlaceID: String? = nil
    @State private var pendingLogInteractionPersonID: String? = nil
    /// AI-prefill, Session 28 — suggested field values riding alongside the two
    /// pending IDs above, on the same `trace://checkin`/`trace://loginteraction`
    /// URLs (see DayflowWikiSummaryView.swift's placeVisitsTab/personLogTab, which
    /// compute these before opening the URL). Unlike the pending-ID vars, these
    /// don't need their own retry logic — they're just data riding along, only
    /// read once the corresponding sheet actually presents. Reset to nil by every
    /// other `showingCheckIn = true` / non-hand-off path alongside
    /// `checkInPreselectedPlace = nil`, same as that var already is, so a stale
    /// prefill from a previous hand-off can never leak into an unrelated manual
    /// check-in.
    /// `trace://note?path=…` — the return leg of the Satchel hand-off. Satchel
    /// knows which note a document is filed to but cannot display notes, so it
    /// hands the path back to whichever app owns it. Held rather than resolved
    /// on the spot for the same reason as the two IDs above: `notion.people` and
    /// `notion.places` load asynchronously, so a same-tick lookup finds nothing
    /// on a cold launch — which is the common case, since the app is being
    /// opened *by* the URL. Retried by the existing count watchers.
    @State private var pendingNotePath: String? = nil
    @State private var noteLinkPerson: Person? = nil
    @State private var noteLinkPlace: Place? = nil

    @State private var checkInPrefillNotes: String? = nil
    @State private var loginteractionPrefillType: String? = nil
    @State private var loginteractionPrefillNotes: String? = nil

    /// Screen width without using the deprecated UIScreen.main
    private var windowWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 393
    }

    // Session 48 — was notification-driven (isPeopleContext/isActivityContext)
    // because People/Activity used to be sub-screens reached through the Life
    // tab, so the tab index alone couldn't tell them apart. People is now its
    // own tab (index 3), so selectedTab is sufficient; Activity has no tab of
    // its own anymore (see the state-var removal note above).
    //
    // Session 48 follow-up — added `.home`. Home used to fall through to
    // `.global` (the same generic menu Discover still uses); David asked for
    // Home's own FAB instead, tuned to what he actually does from Home: log
    // something about a person, or drop a pin without leaving the screen.
    // Discover (tab 2) has no dedicated case and still falls through to
    // `.global`.
    private enum FABContext { case home, places, people, notes, global }
    private var fabContext: FABContext {
        if selectedTab == 0  { return .home }
        if selectedTab == 1  { return .places }
        if selectedTab == 3  { return .people }
        if selectedTab == 4  { return .notes }
        return .global
    }
    private var fabDialogTitle: String {
        switch fabContext {
        case .home:     return "Home"
        case .places:   return "Places"
        case .people:   return "People"
        case .notes:    return "Notes"
        case .global:   return "What would you like to do?"
        }
    }

    // Session 48 follow-up — Home's own FAB menu. "Quick Pin" and its named
    // variants below are deliberately NOT the existing QuickPinLabelSheet
    // flow (that opens a picker sheet and only saves a Capture, viewable via
    // the Captures drawer). These fire immediately, no intermediate sheet,
    // and append a `[label](capture://open?id=…) ` marker straight into
    // TODAY's daily note via `NoteStore.appendToDailyNote` — same marker
    // format and in-app map-card summary (CaptureSummaryView, opened via
    // NotesView.swift's onCaptureTap) that MarkdownEditorView's dropPin()
    // already provides from inside an open note, just reachable now without
    // opening Notes first. See quickPinToNote(label:emoji:) below. Only
    // Parked, Scenic, Notable, and Address are included as named one-tap
    // variants (David's picks). Photo Spot from QuickPinLabelSheet's grid
    // is deliberately left off — it's just a label with no camera action
    // attached, and David found that ambiguous/not worth a FAB slot.
    @ViewBuilder private var fabHomeButtons: some View {
        Button("Check In")             { checkInPreselectedPlace = nil; checkInPrefillNotes = nil; showingCheckIn = true }
        Button("Log Interaction")      { showingFABLogInteraction = true }
        Button("Add Agenda Item")      { showingFABAddAgenda = true }
        Button("Quick Pin")            { quickPinToNote(label: nil, emoji: nil) }
        Button("Pin: 🚗")               { quickPinToNote(label: "Parked", emoji: "🚗") }
        Button("Pin: 🌄")               { quickPinToNote(label: "Scenic", emoji: "🌄") }
        Button("Pin: ⭐")               { quickPinToNote(label: "Notable", emoji: "⭐") }
        Button("Pin: 📍")               { quickPinToNote(label: "Address", emoji: "📍") }
        Button("Cancel", role: .cancel) { }
    }
    @ViewBuilder private var fabPlacesButtons: some View {
        Button("Check In")     { checkInPreselectedPlace = nil; checkInPrefillNotes = nil; showingCheckIn = true }
        Button("Quick Pin")    { quickPin() }
        Button("Add Place")    { showingAddPlace = true }
        Button("Go to Visits") { NotificationCenter.default.post(name: .tracePlacesShowVisits, object: nil) }
        Button("Cancel", role: .cancel) { }
    }
    @ViewBuilder private var fabPeopleButtons: some View {
        Button("Add Person")      { showingFABAddPerson = true }
        Button("Log Interaction") { showingFABLogInteraction = true }
        Button("Add Agenda Item") { showingFABAddAgenda = true }
        Button("Cancel", role: .cancel) { }
    }
    // Session 48 — Project Note/Place Note/Horizon Note options dropped: Notes
    // no longer has Projects/Places tabs to land on after creating one (see
    // NotesView.swift's new header comment), and "Week" is now an
    // auto-populated visits rollup, not a freeform note, so there's no
    // "Horizon Note" to create either.
    @ViewBuilder private var fabNotesButtons: some View {
        Button("Daily Note")   { NotificationCenter.default.post(name: .traceNotesNewNote, object: nil, userInfo: ["type": "daily"]) }
        Button("Add to Inbox") { showingAddCapture = true }
        Button("Cancel", role: .cancel) { }
    }
    @ViewBuilder private var fabGlobalButtons: some View {
        Button("Check In")     { checkInPreselectedPlace = nil; checkInPrefillNotes = nil; showingCheckIn = true }
        Button("Quick Pin")    { quickPin() }
        Button("Add Place")    { showingAddPlace = true }
        Button("Add Note")     { showingAddCapture = true }
        Button("Add Photo")    { showingAddCapture = true }
        // Hands off rather than opening Trace's own form, which is retired
        // (scope §7). Repointed rather than removed on purpose: the action keeps
        // its place in the menu, so the muscle memory still works and it lands
        // where documents actually live now.
        Button("Add Document") { openSatchelCapture() }
        Button("Cancel", role: .cancel) { }
    }
    @ViewBuilder private var fabDialogButtons: some View {
        switch fabContext {
        case .home:     fabHomeButtons
        case .places:   fabPlacesButtons
        case .people:   fabPeopleButtons
        case .notes:    fabNotesButtons
        case .global:   fabGlobalButtons
        }
    }

    // MARK: - Body layers (split to avoid type-checker timeout)

    // Layer 1: the tab stack + FAB
    private var mainTabStack: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                HomeView()
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(0)
                NavigationStack {
                    PlacesView()
                        .environment(NotionService.shared)
                        .environment(LocationManager.shared)
                }
                .tabItem { Label("Places", systemImage: "mappin") }
                .tag(1)
                DiscoverView()
                    .tabItem { Label("Discover", systemImage: "magnifyingglass") }
                    .tag(2)
                // Session 48 — Life tab retired, People promoted in its place
                // (same tag/position so nothing else that keys off tab index
                // needs to shift). See PeopleView.swift's header comment.
                NavigationStack {
                    PeopleView()
                        .environment(NotionService.shared)
                }
                .tabItem { Label("People", systemImage: "person.2.fill") }
                .tag(3)
                NotesView()
                    .tabItem { Label("Notes", systemImage: "note.text") }
                    .tag(4)
            }

            // Session 48 — FAB now shows on every tab including Home (mockup's
            // Home frame has its own "＋" in the same bottom-right slot; Home
            // previously had no FAB at all). It reuses this same global menu
            // rather than the mockup's sketched tap-for-text/hold-for-voice
            // natural-language capture — that flow's parsing approach is
            // explicitly flagged as an undecided open question in Session 47's
            // addendum, not something to build here.
            if !isKeyboardVisible {
                Button(action: { showingActionSheet = true }) {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 80)
                .confirmationDialog(fabDialogTitle, isPresented: $showingActionSheet,
                                    titleVisibility: .visible, actions: { fabDialogButtons })
            }
        }
    }

    // Layer 2: mainTabStack + all sheets + drawers + context notifications
    private var stackWithSheets: some View {
        mainTabStack
            // People FAB sheets
            .sheet(isPresented: $showingFABAddPerson)     { AddPersonView().environment(NotionService.shared) }
            .sheet(isPresented: $showingFABLogInteraction){ FABLogInteractionSheet().environment(NotionService.shared) }
            .sheet(isPresented: $showingFABAddAgenda)     { FABAddAgendaSheet().environment(NotionService.shared) }
            // Global FAB sheets
            .sheet(isPresented: $showingCheckIn) {
                // prefillNotes: checkInPrefillNotes — Session 28 AI-prefill, only ever
                // non-nil when this sheet was reached via the checkin hand-off URL.
                CheckInView(preselectedPlace: checkInPreselectedPlace, prefillNotes: checkInPrefillNotes)
                    .environment(NotionService.shared).environment(LocationManager.shared)
            }
            // Dayflow hand-off, 2026-07-21 (Session 26) — trace://loginteraction.
            // .sheet(item:) bound directly to logInteractionPerson — see its
            // declaration above for why this isn't a separate isPresented boolean
            // (Session 27 addendum: that version showed a blank sheet on cold launch).
            .sheet(item: $logInteractionPerson) { person in
                // prefillType/prefillNotes — Session 28 AI-prefill, only ever non-nil
                // when this sheet was reached via the loginteraction hand-off URL.
                LogInteractionSheet(
                    personID: person.id,
                    personName: person.name,
                    prefillType: loginteractionPrefillType,
                    prefillNotes: loginteractionPrefillNotes
                ) { }
                    .environment(notion)
            }
            .sheet(isPresented: $showingAddPlace) {
                AddPlaceView().environment(NotionService.shared).environment(LocationManager.shared)
            }
            .sheet(isPresented: $showingAddCapture) {
                AddCaptureView().environment(NotionService.shared).environment(LocationManager.shared)
            }
            .sheet(isPresented: $showingAddPhoto) {
                AddPhotoView().environment(NotionService.shared).environment(LocationManager.shared)
            }
            .sheet(isPresented: $showingQuickPin) {
                QuickPinLabelSheet(coord: quickPinCoord)
                    .environment(NotionService.shared)
                    .presentationDetents([.height(340)])
                    .presentationDragIndicator(.visible)
            }
            .alert("Quick Pin", isPresented: Binding(
                get: { quickPinFailedMessage != nil },
                set: { if !$0 { quickPinFailedMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(quickPinFailedMessage ?? "")
            }
            // Right drawer — Captures
            .overlay {
                ZStack {
                    if showingDrawer {
                        Color.black.opacity(0.3).ignoresSafeArea()
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { showingDrawer = false } }
                        HStack(spacing: 0) {
                            Spacer()
                            CapturesDrawerView(isShowing: $showingDrawer)
                                .environment(NotionService.shared)
                                .frame(width: windowWidth * 0.85)
                                .background(Color(UIColor.systemBackground))
                                .ignoresSafeArea()
                        }
                        .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showingDrawer)
            }
            // Left drawer — Settings
            .overlay {
                ZStack {
                    if showingLeftDrawer {
                        Color.black.opacity(0.3).ignoresSafeArea()
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { showingLeftDrawer = false } }
                        HStack(spacing: 0) {
                            LeftDrawerView(isShowing: $showingLeftDrawer) {
                                await notion.fetchPlaces()
                                await notion.fetchVisits()
                                await notion.fetchCaptures()
                            }
                            .frame(width: windowWidth * 0.85)
                            .background(Color(UIColor.systemBackground))
                            .ignoresSafeArea()
                            Spacer()
                        }
                        .transition(.move(edge: .leading))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showingLeftDrawer)
            }
    }

    // Layer 3: stackWithSheets + events/lifecycle
    // Layer 3a: stackWithSheets + app lifecycle notifications.
    // Split out from body 2026-07-22 (Session 27) — see body's own comment below for why.
    private var stackWithLifecycle: some View {
        stackWithSheets
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                checkPendingShortcut()
            }
        }
        // Home screen quick actions — foreground (app was suspended)
        // performActionFor fires after scenePhase, so we use a notification
        .onReceive(NotificationCenter.default.publisher(for: .traceShortcut)) { _ in
            checkPendingShortcut()
        }
        // Geofence check-in notification tapped
        .onReceive(NotificationCenter.default.publisher(for: .traceGeofenceCheckIn)) { _ in
            checkPendingGeofence()
        }
        // Workout prompt notification tapped
        .onReceive(NotificationCenter.default.publisher(for: .traceWorkoutPrompt)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showingWorkoutPrompt = true
            }
        }
        // Drawer buttons from child tabs
        .onReceive(NotificationCenter.default.publisher(for: .traceOpenLeftDrawer)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) { showingLeftDrawer = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .traceOpenRightDrawer)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) { showingDrawer = true }
        }
        // Hide FAB while the keyboard is visible (e.g. when editing a note)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) { isKeyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) { isKeyboardVisible = false }
        }
    }

    // Layer 3b: stackWithLifecycle + secondary sheets/state observers.
    // Split out from body 2026-07-22 (Session 27) — see body's own comment below for why.
    private var stackWithObservers: some View {
        stackWithLifecycle
        // .sheet(item:) bound directly to geofencePlace — see its declaration
        // above for why this isn't a separate isPresented boolean.
        .sheet(item: $geofencePlace) { place in
            CheckInView(preselectedPlace: place)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingWorkoutPrompt) {
            WorkoutWizardView()
                .environment(NotionService.shared)
        }
        // Re-fetch when app returns to foreground
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await notion.fetchPlaces()
                    await notion.fetchVisits()
                    // Added 2026-07-25 — was missing from this list entirely.
                    // David dropped several Quick Pins from Jot/Dayflow (separate
                    // processes — their own NotionService.shared instances can't
                    // update Trace's in-memory `notion.captures` directly) and the
                    // Captures drawer showed none of them despite the writes
                    // succeeding (confirmed directly against the Notion database).
                    // CapturesDrawerView has no refresh of its own — this and the
                    // showingDrawer onChange below are the only two paths that
                    // now keep `notion.captures` current without a full relaunch.
                    await notion.fetchCaptures()
                    // Send anything the widget staged while Trace was closed.
                    // AFTER `fetchPlaces()`, not beside it: the drain resolves a
                    // place id against `notion.places`, and on a cold launch that
                    // array is empty. The ordering IS the retry mechanism — same
                    // lesson `pendingCheckInPlaceID` records, where a same-tick
                    // lookup found nothing and the hand-off was simply dropped.
                    await drainStagedCheckIns()
                }
            }
        }
        // Added 2026-07-25, alongside the scenePhase fix above — refetches the
        // instant the Captures drawer is actually opened, not just on the next
        // foreground transition. Covers the more likely real case: Trace was
        // already in the foreground the whole time (never backgrounded), the
        // drawer just hadn't been opened yet since the last pin was dropped.
        .onChange(of: showingDrawer) { _, isShowing in
            if isShowing {
                Task { await notion.fetchCaptures() }
            }
        }
        // Resolve a pending geofence notification once places have loaded.
        // On cold launch, notion.places is empty when the notification fires —
        // we store the placeID and retry here when the fetch completes.
        // Session 27 addendum: same watcher now also retries the Dayflow
        // checkin hand-off (see pendingCheckInPlaceID's declaration).
        .onChange(of: notion.places.count) { _, count in
            if count > 0 {
                resolveGeofencePlace()
                resolvePendingCheckIn()
                resolvePendingNoteLink()
            }
        }
        // Session 27 — retries the Dayflow loginteraction hand-off once
        // notion.people has loaded (see pendingLogInteractionPersonID's declaration).
        // No pre-existing watcher on notion.people.count to piggyback on, unlike
        // places above, so this is its own onChange.
        .onChange(of: notion.people.count) { _, count in
            if count > 0 {
                resolvePendingLogInteraction()
                resolvePendingNoteLink()
            }
        }
        // Retries the Dayflow visit hand-off once notion.visits has loaded.
        .onChange(of: notion.visits.count) { _, count in
            if count > 0 { resolvePendingVisit() }
        }
    }

    // Layer 4: stackWithObservers + gestures/URL routing.
    // Session 27 note: this used to be one single `body` chain covering everything
    // from Layer 3a through Layer 4 below. Adding this session's third onChange
    // (notion.people.count, for the loginteraction hand-off fix) pushed that one
    // giant expression over Swift's type-checker complexity limit — "The compiler
    // is unable to type-check this expression in reasonable time" — the exact
    // failure mode the original mainTabStack/stackWithSheets split already existed
    // to avoid, just one modifier too many past what that split still covered.
    // Split into stackWithLifecycle/stackWithObservers/body instead of adding to
    // the same chain further.
    var body: some View {
        stackWithObservers
        // Right edge swipe → opens Captures drawer
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .local)
                        .onEnded { value in
                            if value.translation.width < -10 {
                                withAnimation(.easeInOut(duration: 0.3)) { showingDrawer = true }
                            }
                        }
                )
        }
        // URL scheme: trace://quicknote → redirects to Captures (QuickNoteSheet retired)
        .onOpenURL { url in
            guard url.scheme == "trace" else { return }
            switch url.host {
            case "quicknote": showingAddCapture = true
            case "checkin":
                // Dayflow hand-off, 2026-07-21: trace://checkin?placeID=<Notion place ID>
                // pre-loads that place into CheckInView (see checkInPreselectedPlace's
                // declaration above); plain trace://checkin (or an unrecognized/missing
                // placeID) falls back to the generic picker, same as every other caller.
                // Fixed 2026-07-22 (Session 27): resolution now goes through
                // resolvePendingCheckIn() instead of a same-tick lookup — see
                // pendingCheckInPlaceID's declaration above for why.
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let placeID = comps.queryItems?.first(where: { $0.name == "placeID" })?.value {
                    pendingCheckInPlaceID = placeID
                    // AI-prefill, Session 28 — optional "notes" query param, set by
                    // DayflowWikiSummaryView.swift's placeVisitsTab hand-off button.
                    // Not part of the pending/retry mechanism above — just carried
                    // data, read once resolvePendingCheckIn() actually presents the
                    // sheet.
                    checkInPrefillNotes = comps.queryItems?.first(where: { $0.name == "notes" })?.value
                    resolvePendingCheckIn()
                } else {
                    checkInPreselectedPlace = nil
                    checkInPrefillNotes = nil
                    showingCheckIn = true
                }
            case "loginteraction":
                // Dayflow hand-off, 2026-07-21 (Session 26): trace://loginteraction?personID=<Notion person ID>
                // pre-loads that person into LogInteractionSheet (see logInteractionPerson's declaration
                // above), same pattern as checkin's placeID. Unlike checkin, a missing or unresolved
                // personID does nothing rather than falling back to a generic picker — LogInteractionSheet
                // has no "nobody preselected" mode to fall back to (FABLogInteractionSheet is a different,
                // unrelated component), so silently no-oping is the safer default until David says otherwise.
                // Fixed 2026-07-22 (Session 27): resolution now goes through
                // resolvePendingLogInteraction() instead of a same-tick lookup — see
                // pendingLogInteractionPersonID's declaration above for why.
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let personID = comps.queryItems?.first(where: { $0.name == "personID" })?.value {
                    pendingLogInteractionPersonID = personID
                    // AI-prefill, Session 28 — optional "type"/"notes" query params, set
                    // by DayflowWikiSummaryView.swift's personLogTab hand-off button.
                    // Same "just carried data" reasoning as checkInPrefillNotes above.
                    loginteractionPrefillType = comps.queryItems?.first(where: { $0.name == "type" })?.value
                    loginteractionPrefillNotes = comps.queryItems?.first(where: { $0.name == "notes" })?.value
                    resolvePendingLogInteraction()
                }
            case "capture":
                // Session 45 addendum 6 — trace://capture?id=<Notion capture page ID>,
                // opened from CaptureSummaryView's "Open in Trace" button (Jot/Dayflow/
                // Trace all share that view). No pending-ID/retry machinery like
                // checkin/loginteraction above, and no scroll-to-specific-capture
                // attempt: CapturesDrawerView.swift only renders local Notes/Inbox
                // markdown files (InboxNote) — it never actually displays
                // notion.captures (the GPS Quick Pin database this feature's captures
                // live in), despite addendum 4/5's fetchCaptures() refresh fixes
                // assuming it did. Flagged in this addendum's HANDOFF entry as a
                // pre-existing gap, not fixed here — so for now this just opens the
                // drawer, same "if not feasible, just open the drawer" fallback
                // addendum 6 itself pre-approved for this exact case.
                withAnimation(.easeInOut(duration: 0.3)) { showingDrawer = true }
            case "note":
                // trace://note?path=Notes/People/Mitch%20Weiss.md
                // trace://note?path=Notes/Places/la-bella.md
                //
                // Opens that person or place on its Notes tab. Only People and
                // Places are Trace's to display — day and project notes belong
                // to Dayflow, and Satchel is expected not to send those here.
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let path = comps.queryItems?.first(where: { $0.name == "path" })?.value {
                    pendingNotePath = path
                    resolvePendingNoteLink()
                    // Still pending means the list it needs has not loaded. Fetch
                    // that one list NOW rather than waiting for TraceApp's
                    // sequential launch chain to reach it — see
                    // `fetchListForNoteLink`. 2026-07-30.
                    if pendingNotePath != nil {
                        Task { await fetchListForNoteLink(path) }
                    }
                }
            case "visit":
                // trace://visit?id=<Notion visit page ID>, sent by Dayflow's
                // DayflowVisitDetailView "Add Notes in Trace" button. Opens the
                // real editor on that visit. An unresolvable id does NOTHING
                // rather than falling back to a blank editor — the alternative
                // to "the right visit" here is a NEW visit, and silently
                // offering to create a duplicate is the worst outcome available.
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let id = comps.queryItems?.first(where: { $0.name == "id" })?.value {
                    pendingVisitID = id
                    resolvePendingVisit()
                    // Visits load late in TraceApp's sequential launch chain, so
                    // fetch them now rather than waiting — same reasoning as
                    // `fetchListForNoteLink`.
                    if pendingVisitID != nil {
                        Task { await notion.fetchVisits() }
                    }
                }
            case "workout":   showingWorkoutFromURL = true
            case "addphoto":    showingAddPhoto = true
            case "adddocument":
                // FORWARDED, not deleted. Any Shortcut, Back Tap or Action
                // Button already bound to `trace://adddocument` keeps working
                // and now lands in Satchel. Deleting the case would have made
                // those bindings silently do nothing, which is the worst of the
                // available outcomes.
                openSatchelCapture()
            case "addplace":    showingAddPlace = true
            case "addperson":   showingFABAddPerson = true
            case "addnote":   showingAddCapture = true
            case "pin":       quickPin()
            case "homefab":
                // Session 48 follow-up — trace://homefab, for a Shortcuts/Action
                // Button/Back Tap binding so David can jump straight to the
                // Home tab's FAB menu (Check In / Log Interaction / Add Agenda /
                // the four Pin variants) without opening the app and tapping the
                // "+" manually. selectedTab and showingActionSheet are both plain
                // @State read by mainTabStack/fabContext each render, so setting
                // both together here is enough — no delay/retry needed like
                // checkin/loginteraction above, since nothing here depends on
                // async-loaded Notion data.
                selectedTab = 0
                showingActionSheet = true
            default: break
            }
        }
        .sheet(item: $visitFromURL) { visit in
            NavigationStack {
                VisitDetailView(visit: visit)
                    .environment(notion)
            }
        }
        .sheet(isPresented: $showingWorkoutFromURL) {
            WorkoutWizardView()
                .environment(NotionService.shared)
        }
        .sheet(item: $noteLinkPerson) { person in
            PersonDetailView(personID: person.id, personName: person.name, openToNotes: true)
                .environment(NotionService.shared)
        }
        .sheet(item: $noteLinkPlace) { place in
            // Both environments passed explicitly, matching how `PlacesView`
            // presents this same view. `LocationManager.shared`, not a
            // `locationManager` property — ContentView has none.
            PlaceDetailView(place: place, openToNotes: true)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        // Left edge swipe → opens Settings drawer
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .local)
                        .onEnded { value in
                            if value.translation.width > 10 {
                                withAnimation(.easeInOut(duration: 0.3)) { showingLeftDrawer = true }
                            }
                        }
                )
        }
    }

    // MARK: - Incoming document (from Share Extension)

    // `checkIncomingDocument()` lived here until 2026-07-29. The iOS share
    // sheet stages a file into the app group and Trace used to consume it and
    // open its own Add Document form. **Satchel consumes it now**
    // (`SatchelLibraryView.consumeSharedFile`), which is the last piece of
    // scope §7's retirement.
    //
    // Both consumers cannot coexist: `AppGroup.consumeIncoming()` deletes the
    // staged file as it reads it, so whichever app opened first would win and
    // the other would find nothing. Removing this side is what makes Satchel's
    // side deterministic.

    // MARK: - Shortcut handling

    // Reads pending action from UserDefaults (written by AppDelegate), clears it, fires the action.
    // Called from both onAppear (cold launch) and onReceive (foreground).
    // MARK: - Staged check-ins (widget hand-off, Session 69)
    //
    // The launcher widget's Check in tile writes a record into the App Group and
    // launches nothing; this is the other half. See `CheckInBridge.swift` for
    // why the widget does not write to Notion itself — briefly, that would put
    // the API key and a two-second network call inside a memory-capped process
    // with no screen on which to report failure.
    //
    // **Trace drains, and nothing else does.** Dayflow also carries
    // `NotionService` and is opened more often, so it is the tempting second
    // drainer — but two processes reading one queue and POSTing what they find
    // is a duplicate Visit whenever they overlap, and `UserDefaults` offers no
    // cross-process lock to prevent it. One drainer is correct by construction.
    // The cost, stated: a check-in waits for Trace specifically. If that proves
    // too slow in practice the fix is a claim protocol, not a second
    // unsynchronised reader.

    /// Sends every staged check-in, clearing only what actually succeeded.
    private func drainStagedCheckIns() async {
        let queue = CheckInQueue.pending()
        guard !queue.isEmpty else { return }

        var sent: Set<String> = []
        for item in queue {
            guard let place = notion.places.first(where: { $0.id == item.placeID }) else {
                // The place is gone from the fetch — archived, or made
                // temporary. Dropped rather than retried: `fetchPlaces` filters
                // both out, so this record can never resolve, and a queue that
                // only grows is a worse failure than one lost check-in at a
                // place he has since archived.
                sent.insert(item.id)
                continue
            }
            do {
                // `date:` is the tap's timestamp, carried from the widget. Using
                // `Date()` here would file every delayed check-in under the
                // morning he happened to open the app.
                _ = try await notion.checkIn(place: place, date: item.date)
                sent.insert(item.id)
            } catch {
                // Left queued deliberately. The next foreground retries it, and
                // a retry is visible where a silent drop is not.
            }
        }

        CheckInQueue.remove(ids: sent)
        if !sent.isEmpty { await notion.fetchVisits() }
    }

    private func checkPendingShortcut() {
        guard let action = UserDefaults.standard.string(forKey: "pendingShortcutAction") else { return }
        UserDefaults.standard.removeObject(forKey: "pendingShortcutAction")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            handleShortcut(action)
        }
    }

    private func handleShortcut(_ action: String) {
        switch action {
        case "quickpin": quickPin()
        case "checkin":  checkInPreselectedPlace = nil; showingCheckIn = true
        case "addnote":  showingAddCapture = true
        case "addphoto": showingAddPhoto = true
        default: break
        }
    }

    // MARK: - Quick Pin

    private func quickPin() {
        quickPinCoord = LocationManager.shared.location?.coordinate ?? CLLocationCoordinate2D()
        showingQuickPin = true
    }

    /// Session 48 follow-up — Home's FAB "Quick Pin" and its named variants
    /// (Parked, Scenic, …). Unlike `quickPin()` above (which opens
    /// QuickPinLabelSheet and only ever saves a Capture), this fires
    /// immediately with no sheet and writes straight into today's daily
    /// note. Mirrors MarkdownEditorView.swift's `dropPin()` almost exactly —
    /// same location wait-loop, same 500m nearest-place match, same marker
    /// format — the difference is dropPin() inserts into a live UITextView
    /// because it's only ever called from inside an already-open editor;
    /// this has no editor to insert into, so it goes through
    /// `NoteStore.appendToDailyNote`, which handles "file doesn't exist yet
    /// today" itself and posts `.noteStoreCalendarDidChange` so an open
    /// DailyNoteTab (if the user happens to already be looking at today's
    /// note) picks up the new line without needing a manual reload.
    ///
    /// `label`/`emoji` nil (the plain "Quick Pin" button) mirrors dropPin()'s
    /// own always-📍 behavior exactly: matched place name or "Dropped Pin".
    /// Passing a label (e.g. "Parked"/"🚗") instead skips the place-name
    /// lookup for the *visible* text (same as QuickPinLabelSheet.swift's
    /// labeled options) but still runs the proximity match so the marker
    /// still links to a real Trace place when one is nearby.
    private func quickPinToNote(label: String?, emoji: String?) {
        Task { @MainActor in
            if LocationManager.shared.location == nil {
                LocationManager.shared.requestPermission()
                LocationManager.shared.startUpdating()
                for _ in 0..<20 {
                    if LocationManager.shared.location != nil { break }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            guard let loc = LocationManager.shared.location else {
                quickPinFailedMessage = "Couldn't get your location — check Location Services, then try again."
                return
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            let timeStr = formatter.string(from: Date())

            if notion.places.isEmpty { await notion.fetchPlaces() }
            // Auto-link to the nearest Trace place within 500 m — same logic
            // as QuickPinLabelSheet.swift's save() and dropPin().
            let nearbyPlace = notion.places.filter { p in
                CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: loc) <= 500
            }.min { a, b in
                CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: loc)
                    < CLLocation(latitude: b.latitude, longitude: b.longitude).distance(from: loc)
            }

            let display: String
            if let label {
                let prefix = emoji.map { "\($0) " } ?? ""
                display = "\(prefix)\(label) · \(timeStr)"
            } else {
                display = nearbyPlace != nil ? "📍 \(nearbyPlace!.name) · \(timeStr)" : "📍 Dropped Pin · \(timeStr)"
            }

            let pageID: String
            do {
                pageID = try await notion.saveCapture(
                    notes: display,
                    placeID: nearbyPlace?.id,
                    placeName: nearbyPlace?.name ?? display,
                    lat: loc.coordinate.latitude,
                    lon: loc.coordinate.longitude,
                    photoURL: nil
                )
            } catch {
                quickPinFailedMessage = "Couldn't save the pin — try again."
                return
            }
            await notion.fetchCaptures()

            let marker = "[\(display)](capture://open?id=\(pageID)) "
            do {
                try NoteStore.shared.appendToDailyNote(marker)
            } catch {
                quickPinFailedMessage = "Pin saved, but couldn't add it to today's note — check iCloud and try again from Notes."
            }
        }
    }

    // MARK: - Geofence check-in

    private func checkPendingGeofence() {
        guard let placeID = UserDefaults.standard.string(forKey: "pendingGeofencePlaceID") else { return }
        UserDefaults.standard.removeObject(forKey: "pendingGeofencePlaceID")
        // Store placeID so resolveGeofencePlace() can retry after places load.
        pendingGeofencePlaceID = placeID
        resolveGeofencePlace()
    }

    /// Attempts to match pendingGeofencePlaceID against the loaded places list.
    /// Called immediately on notification tap (may no-op if places not loaded yet)
    /// and again via .onChange(of: notion.places.count) once the fetch completes.
    private func resolveGeofencePlace() {
        guard let placeID = pendingGeofencePlaceID,
              let place = notion.places.first(where: { $0.id == placeID }) else { return }
        pendingGeofencePlaceID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            geofencePlace = place
        }
    }

    // MARK: - Dayflow hand-off resolution (Session 27 cold-launch race fix)
    //
    // Same shape as resolveGeofencePlace() above, called both immediately (in case
    // notion.places/.people already loaded — a warm launch, Trace already running
    // in the background) and again from the onChange watchers once the corresponding
    // fetch completes. Distinguishes "not found yet, data still loading" (leaves the
    // pending ID set, so a later retry can still succeed) from "genuinely not found"
    // (only decided once the list is confirmed non-empty, i.e. the fetch actually ran) —
    // collapsing that distinction would either drop a valid ID that just hadn't loaded
    // yet, or open a fallback sheet prematurely before we'd really given the real match
    // a chance.

    /// Resolves `trace://note?path=…` to the record whose note that is.
    ///
    /// Matching is by NAME, because the path is all Satchel has — a sidecar
    /// stores `linked_note`, never a Notion ID. For places that means comparing
    /// against `placeNoteFilename(for:)` rather than the raw name, since that is
    /// the transform Trace itself applies when writing the file (slashes and
    /// colons become hyphens). Comparing against the raw name would silently
    /// fail for exactly the places whose names need escaping.
    ///
    /// Unresolvable paths do nothing rather than opening something arbitrary.
    /// The likeliest cause is a renamed person or place, and guessing wrong is
    /// worse than a button that appears not to have worked.
    /// Opens Satchel's scanner. The other half of `satchel://…?note=`, minus
    /// the note — this is the general "add a document" entry, not one tied to a
    /// specific note, so no `note=` parameter is sent.
    private func openSatchelCapture() {
        guard let url = URL(string: "satchel://scan") else { return }
        UIApplication.shared.open(url)
    }

    /// Loads just the list this hand-off needs, straight away.
    ///
    /// **Why this exists.** `TraceApp`'s launch `.task` awaits `fetchPlaces()`,
    /// then `fetchVisits()`, then `fetchCaptures()`, then `fetchPeople()` — four
    /// Notion round trips, sequentially. A `trace://note` for a PERSON therefore
    /// waits on three unrelated network calls before the list it needs even starts
    /// loading. David hit this on 2026-07-30: "Open Mitch in Trace" left him on
    /// the home screen. Nothing was broken; `people` was still three fetches away,
    /// so there was nothing to match against and the retry watcher had not fired.
    ///
    /// Deliberately narrow: it fetches the ONE list needed and nothing else. The
    /// broader fix — making the launch chain concurrent — changes how every screen
    /// in Trace loads, and Trace is being retired (scope §7). Not the place to
    /// take that risk.
    ///
    /// Safe to run alongside the launch chain: `fetchPeople()` assigns a fresh
    /// list, so the worst case is the same data written twice.
    private func fetchListForNoteLink(_ path: String) async {
        if path.hasPrefix("Notes/People/"), notion.people.isEmpty {
            await notion.fetchPeople()
        } else if path.hasPrefix("Notes/Places/"), notion.places.isEmpty {
            await notion.fetchPlaces()
        }
        resolvePendingNoteLink()
    }

    private func resolvePendingNoteLink() {
        guard let path = pendingNotePath else { return }

        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        if path.hasPrefix("Notes/People/") {
            // Exact match first, then a forgiving one. A note filename is written
            // from the person's name, so they normally agree — but a renamed
            // person, or a stray trailing space typed into Notion, would otherwise
            // fail with no symptom at all.
            let match = notion.people.first(where: { $0.name == base })
                ?? notion.people.first(where: {
                    $0.name.trimmingCharacters(in: .whitespaces)
                        .caseInsensitiveCompare(base.trimmingCharacters(in: .whitespaces)) == .orderedSame
                })
            if let match {
                pendingNotePath = nil
                noteLinkPerson = match
                return
            }
            if !notion.people.isEmpty {
                // People are loaded and this person is genuinely not among them.
                // DO NOT fail silently: that is indistinguishable from the app
                // ignoring the tap. Land on the People tab so the hand-off at
                // least arrives in the right part of Trace.
                pendingNotePath = nil
                selectedTab = 3
            }
            return
        }

        if path.hasPrefix("Notes/Places/") {
            if let place = notion.places.first(where: {
                NoteStore.shared.placeNoteFilename(for: $0.name) == base
            }) {
                pendingNotePath = nil
                noteLinkPlace = place
            } else if !notion.places.isEmpty {
                // Same reasoning as People above — the Places tab beats nothing.
                pendingNotePath = nil
                selectedTab = 1
            }
            return
        }

        // Not a note Trace displays. Drop it rather than holding it forever.
        pendingNotePath = nil
    }

    private func resolvePendingCheckIn() {
        guard let placeID = pendingCheckInPlaceID else { return }
        if let place = notion.places.first(where: { $0.id == placeID }) {
            pendingCheckInPlaceID = nil
            checkInPreselectedPlace = place
            showingCheckIn = true
        } else if !notion.places.isEmpty {
            // Places have loaded and this ID still isn't in there — genuinely
            // unresolvable, not just a timing race. Same fallback a missing/malformed
            // placeID always had: open the generic picker instead of nothing.
            pendingCheckInPlaceID = nil
            checkInPreselectedPlace = nil
            showingCheckIn = true
        }
        // else: places haven't loaded yet. Leave pendingCheckInPlaceID set — the
        // onChange(of: notion.places.count) watcher retries this once they do.
    }

    /// Same three-way shape as `resolvePendingCheckIn`, with one deliberate
    /// difference: when visits HAVE loaded and the id is not among them, this
    /// gives up quietly. Check In can fall back to its generic picker because
    /// picking a place is harmless. The equivalent here would be opening an
    /// editor on no visit, which invites creating a second one for something
    /// already recorded.
    private func resolvePendingVisit() {
        guard let id = pendingVisitID else { return }
        if let visit = notion.visits.first(where: { $0.id == id }) {
            pendingVisitID = nil
            visitFromURL = visit
        } else if !notion.visits.isEmpty {
            pendingVisitID = nil
        }
        // else: visits have not loaded. The onChange(of: notion.visits.count)
        // watcher retries this once they do.
    }

    private func resolvePendingLogInteraction() {
        guard let personID = pendingLogInteractionPersonID else { return }
        if let person = notion.people.first(where: { $0.id == personID }) {
            pendingLogInteractionPersonID = nil
            logInteractionPerson = person
        } else if !notion.people.isEmpty {
            // People have loaded and this ID still isn't in there — genuinely
            // unresolvable. No generic fallback exists for this one (see the
            // .onOpenURL case's own comment) — same do-nothing default as before,
            // just no longer decided before people has actually had a chance to load.
            pendingLogInteractionPersonID = nil
        }
        // else: people haven't loaded yet. Leave pendingLogInteractionPersonID set —
        // the onChange(of: notion.people.count) watcher retries this once they do.
    }
}

#Preview {
    ContentView()
}

// MARK: - Shared drawer toolbar buttons
// Applied to all NavigationStack-based tabs via .drawerToolbar()

extension View {
    func drawerToolbar() -> some View {
        self.toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    NotificationCenter.default.post(name: .traceOpenLeftDrawer, object: nil)
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    NotificationCenter.default.post(name: .traceOpenRightDrawer, object: nil)
                } label: {
                    Image(systemName: "tray")
                }
            }
        }
    }
}

// MARK: - Floating drawer buttons for ZStack-based tabs (no NavigationStack)

struct DrawerButtons: View {
    var body: some View {
        HStack {
            Button {
                NotificationCenter.default.post(name: .traceOpenLeftDrawer, object: nil)
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
            Spacer()
            Button {
                NotificationCenter.default.post(name: .traceOpenRightDrawer, object: nil)
            } label: {
                Image(systemName: "tray")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 16)
    }
}

// Session 48 — lifeJumpMenu() and LifeTabLongPressInstaller removed. Both were
// Life-tab-only: lifeJumpMenu() was the nav-bar menu Life's own sub-screens
// used to jump sideways between Activity/Trips/Fitness/Billiards/People
// without going back to the Life list; LifeTabLongPressInstaller attached the
// long-press gesture that opened the same menu from the tab bar itself.
// Neither had any caller left once Life was retired (LifeCalendarView and the
// other Life sub-screens are gone — see LifeView.swift's header comment) —
// confirmed via a grep across the Trace target before removing them.
