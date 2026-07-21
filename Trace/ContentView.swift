import SwiftUI
import CoreLocation

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
    @State private var showingAddDocument = false
    @State private var pendingIncomingDocument: IncomingDocument? = nil
    @State private var isKeyboardVisible = false
    @State private var showingLifeContextMenu = false
    @State private var isPeopleContext = false
    @State private var showingFABAddPerson = false
    @State private var showingFABLogInteraction = false
    @State private var showingFABAddAgenda = false
    @State private var isActivityContext = false
    @State private var showingFABLogWorkout = false
    @State private var showingFABLogBilliards = false
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
    @State private var checkInPrefillNotes: String? = nil
    @State private var loginteractionPrefillType: String? = nil
    @State private var loginteractionPrefillNotes: String? = nil

    /// Screen width without using the deprecated UIScreen.main
    private var windowWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 393
    }

    private enum FABContext { case places, people, activity, notes, life, global }
    private var fabContext: FABContext {
        if isPeopleContext   { return .people }
        if isActivityContext { return .activity }
        if selectedTab == 1  { return .places }
        if selectedTab == 4  { return .notes }
        return .global
    }
    private var fabDialogTitle: String {
        switch fabContext {
        case .places:   return "Places"
        case .people:   return "People"
        case .activity: return "Activity"
        case .notes:    return "Notes"
        case .life:     return "Life"
        case .global:   return "What would you like to do?"
        }
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
    @ViewBuilder private var fabActivityButtons: some View {
        Button("Log Workout")   { showingFABLogWorkout = true }
        Button("Log Billiards") { showingFABLogBilliards = true }
        Button("Log Visit")     { checkInPreselectedPlace = nil; checkInPrefillNotes = nil; showingCheckIn = true }
        Button("Cancel", role: .cancel) { }
    }
    @ViewBuilder private var fabLifeButtons: some View {
        Button("Activity")  { deepLinkLife(.activity) }
        Button("Trips")     { deepLinkLife(.trips) }
        Button("Fitness")   { deepLinkLife(.fitness) }
        Button("Billiards") { deepLinkLife(.billiards) }
        Button("People")    { deepLinkLife(.people) }
        Button("Cancel", role: .cancel) { }
    }
    @ViewBuilder private var fabNotesButtons: some View {
        Button("Daily Note")   { NotificationCenter.default.post(name: .traceNotesNewNote, object: nil, userInfo: ["type": "daily"]) }
        Button("Horizon Note") { NotificationCenter.default.post(name: .traceNotesNewNote, object: nil, userInfo: ["type": "horizons"]) }
        Button("Project Note") { NotificationCenter.default.post(name: .traceNotesNewNote, object: nil, userInfo: ["type": "projects"]) }
        Button("Place Note")   { NotificationCenter.default.post(name: .traceNotesNewNote, object: nil, userInfo: ["type": "places"]) }
        Button("Add to Inbox") { showingAddCapture = true }
        Button("Cancel", role: .cancel) { }
    }
    @ViewBuilder private var fabGlobalButtons: some View {
        Button("Check In")     { checkInPreselectedPlace = nil; checkInPrefillNotes = nil; showingCheckIn = true }
        Button("Quick Pin")    { quickPin() }
        Button("Add Place")    { showingAddPlace = true }
        Button("Add Note")     { showingAddCapture = true }
        Button("Add Photo")    { showingAddCapture = true }
        Button("Add Document") { showingAddDocument = true }
        Button("Cancel", role: .cancel) { }
    }
    @ViewBuilder private var fabDialogButtons: some View {
        switch fabContext {
        case .places:   fabPlacesButtons
        case .people:   fabPeopleButtons
        case .activity: fabActivityButtons
        case .notes:    fabNotesButtons
        case .life:     fabLifeButtons
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
                LifeView()
                    .tabItem { Label("Life", systemImage: "waveform") }
                    .tag(3)
                NotesView()
                    .tabItem { Label("Notes", systemImage: "note.text") }
                    .tag(4)
            }
            .background(LifeTabLongPressInstaller { showingLifeContextMenu = true })
            .confirmationDialog("Life", isPresented: $showingLifeContextMenu, titleVisibility: .visible) {
                Button("Activity")  { deepLinkLife(.activity) }
                Button("Trips")     { deepLinkLife(.trips) }
                Button("Fitness")   { deepLinkLife(.fitness) }
                Button("Billiards") { deepLinkLife(.billiards) }
                Button("People")    { deepLinkLife(.people) }
                Button("Cancel", role: .cancel) { }
            }

            if selectedTab != 0 && !isKeyboardVisible {
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
            // FAB context notifications
            .onReceive(NotificationCenter.default.publisher(for: .tracePeopleVisible))   { _ in isPeopleContext = true }
            .onReceive(NotificationCenter.default.publisher(for: .tracePeopleHidden))    { _ in isPeopleContext = false }
            .onReceive(NotificationCenter.default.publisher(for: .traceActivityVisible)) { _ in isActivityContext = true }
            .onReceive(NotificationCenter.default.publisher(for: .traceActivityHidden))  { _ in isActivityContext = false }
            // People FAB sheets
            .sheet(isPresented: $showingFABAddPerson)     { AddPersonView().environment(NotionService.shared) }
            .sheet(isPresented: $showingFABLogInteraction){ FABLogInteractionSheet().environment(NotionService.shared) }
            .sheet(isPresented: $showingFABAddAgenda)     { FABAddAgendaSheet().environment(NotionService.shared) }
            // Activity FAB sheets
            .sheet(isPresented: $showingFABLogWorkout) {
                WorkoutWizardView().environment(NotionService.shared).environment(LocationManager.shared)
            }
            .sheet(isPresented: $showingFABLogBilliards) {
                BilliardsWizardView(visitID: nil, initialDate: nil).environment(NotionService.shared)
            }
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
            .sheet(isPresented: $showingAddDocument) { AddDocumentView(incomingDocument: nil) }
            .sheet(item: $pendingIncomingDocument)  { AddDocumentView(incomingDocument: $0) }
            .sheet(isPresented: $showingQuickPin) {
                QuickPinLabelSheet(coord: quickPinCoord)
                    .environment(NotionService.shared)
                    .presentationDetents([.height(340)])
                    .presentationDragIndicator(.visible)
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
                checkIncomingDocument()
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
                }
                checkIncomingDocument()
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
            }
        }
        // Session 27 — retries the Dayflow loginteraction hand-off once
        // notion.people has loaded (see pendingLogInteractionPersonID's declaration).
        // No pre-existing watcher on notion.people.count to piggyback on, unlike
        // places above, so this is its own onChange.
        .onChange(of: notion.people.count) { _, count in
            if count > 0 { resolvePendingLogInteraction() }
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
            case "workout":   showingWorkoutFromURL = true
            case "addphoto":    showingAddPhoto = true
            case "adddocument": showingAddDocument = true
            case "addplace":    showingAddPlace = true
            case "addperson":   showingFABAddPerson = true
            case "addnote":   showingAddCapture = true
            case "pin":       quickPin()
            default: break
            }
        }
        .sheet(isPresented: $showingWorkoutFromURL) {
            WorkoutWizardView()
                .environment(NotionService.shared)
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

    // MARK: - Life tab deep link

    private func deepLinkLife(_ section: LifeSection) {
        selectedTab = 3
        // Small delay so the tab switch completes before LifeView receives the notification
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(
                name: .traceLifeDeepLink,
                object: nil,
                userInfo: ["section": section]
            )
        }
    }

    // MARK: - Incoming document (from Share Extension)

    private func checkIncomingDocument() {
        guard let incoming = AppGroup.consumeIncoming() else { return }
        pendingIncomingDocument = incoming
    }

    // MARK: - Shortcut handling

    // Reads pending action from UserDefaults (written by AppDelegate), clears it, fires the action.
    // Called from both onAppear (cold launch) and onReceive (foreground).
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

// MARK: - Life section jump menu
// Shown in the nav bar of each Life section view so you can jump sideways
// without navigating back to the Life list first.

extension View {
    func lifeJumpMenu() -> some View {
        self.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { NotificationCenter.default.post(name: .traceLifeDeepLink, object: nil, userInfo: ["section": LifeSection.activity]) }
                        label: { Label("Activity", systemImage: "calendar") }
                    Button { NotificationCenter.default.post(name: .traceLifeDeepLink, object: nil, userInfo: ["section": LifeSection.trips]) }
                        label: { Label("Trips", systemImage: "airplane") }
                    Button { NotificationCenter.default.post(name: .traceLifeDeepLink, object: nil, userInfo: ["section": LifeSection.fitness]) }
                        label: { Label("Fitness", systemImage: "figure.run") }
                    Button { NotificationCenter.default.post(name: .traceLifeDeepLink, object: nil, userInfo: ["section": LifeSection.billiards]) }
                        label: { Label("Billiards", systemImage: "8.circle.fill") }
                    Button { NotificationCenter.default.post(name: .traceLifeDeepLink, object: nil, userInfo: ["section": LifeSection.people]) }
                        label: { Label("People", systemImage: "person.2.fill") }
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
            }
        }
    }
}

// MARK: - UIKit long-press installer for Life tab
// UITabBar intercepts all touches before SwiftUI gestures can fire, so we attach
// a UILongPressGestureRecognizer directly to the UITabBarButton at index 3.

import UIKit

struct LifeTabLongPressInstaller: UIViewRepresentable {
    let onLongPress: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // Defer until the tab bar is fully in the hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            context.coordinator.install(from: view, onLongPress: onLongPress)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        private var installed = false

        func install(from view: UIView, onLongPress: @escaping () -> Void) {
            guard !installed else { return }
            guard let tabBar = Self.findTabBar(from: view) else { return }

            // UITabBarButton subviews are in left-to-right tab order
            let buttons = tabBar.subviews
                .filter { String(describing: type(of: $0)).contains("UITabBarButton") }
                .sorted { $0.frame.minX < $1.frame.minX }

            guard buttons.count > 3 else { return }
            let lifeButton = buttons[3]

            let gr = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
            gr.minimumPressDuration = 0.4
            gr.cancelsTouchesInView = false
            lifeButton.addGestureRecognizer(gr)
            self.onLongPress = onLongPress
            installed = true
        }

        var onLongPress: (() -> Void)?

        @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began else { return }
            DispatchQueue.main.async { self.onLongPress?() }
        }

        private static func findTabBar(from view: UIView) -> UITabBar? {
            // Walk up to window, then search downward for UITabBar
            var root: UIView = view
            while let parent = root.superview { root = parent }
            return search(in: root)
        }

        private static func search(in view: UIView) -> UITabBar? {
            if let tb = view as? UITabBar { return tb }
            for sub in view.subviews {
                if let found = search(in: sub) { return found }
            }
            return nil
        }
    }
}
