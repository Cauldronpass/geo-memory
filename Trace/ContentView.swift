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
    @State private var geofencePlace: Place? = nil
    @State private var showingGeofenceCheckIn = false
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

    /// Screen width without using the deprecated UIScreen.main
    private var windowWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 393
    }

    private enum FABContext { case places, people, activity, notes, global }
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
        case .global:   return "What would you like to do?"
        }
    }

    @ViewBuilder private var fabPlacesButtons: some View {
        Button("Check In")     { showingCheckIn = true }
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
        Button("Log Visit")     { showingCheckIn = true }
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
        Button("Check In")     { showingCheckIn = true }
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
                CheckInView().environment(NotionService.shared).environment(LocationManager.shared)
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
    var body: some View {
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
        .sheet(isPresented: $showingGeofenceCheckIn) {
            if let place = geofencePlace {
                CheckInView(preselectedPlace: place)
                    .environment(NotionService.shared)
                    .environment(LocationManager.shared)
            }
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
            case "checkin":   showingCheckIn = true
            case "workout":   showingWorkoutFromURL = true
            case "addphoto":    showingAddPhoto = true
            case "adddocument": showingAddDocument = true
            case "addplace":    showingAddPlace = true
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
        case "checkin":  showingCheckIn = true
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
        guard let place = notion.places.first(where: { $0.id == placeID }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            geofencePlace = place
            showingGeofenceCheckIn = true
        }
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
