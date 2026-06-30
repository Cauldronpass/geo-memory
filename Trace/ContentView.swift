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

    var body: some View {
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
                .confirmationDialog("What would you like to do?", isPresented: $showingActionSheet,
                    titleVisibility: .visible) {
                    Button("Check In") { showingCheckIn = true }
                    Button("Quick Pin") { quickPin() }
                    Button("Add Place") { showingAddPlace = true }
                    Button("Add Note") { showingAddCapture = true }
                    Button("Add Photo") { showingAddPhoto = true }
                    Button("Add Document") { showingAddDocument = true }
                    Button("Cancel", role: .cancel) { }
                }
            }
        }
        .sheet(isPresented: $showingCheckIn) {
            CheckInView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingAddPlace) {
            AddPlaceView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingAddCapture) {
            AddCaptureView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingAddPhoto) {
            AddPhotoView()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingAddDocument) {
            AddDocumentView(incomingDocument: nil)
        }
        .sheet(item: $pendingIncomingDocument) { incoming in
            AddDocumentView(incomingDocument: incoming)
        }
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
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.3)) { showingDrawer = false }
                        }
                    HStack(spacing: 0) {
                        Spacer()
                        CapturesDrawerView(isShowing: $showingDrawer)
                            .environment(NotionService.shared)
                            .frame(width: UIScreen.main.bounds.width * 0.85)
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
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.3)) { showingLeftDrawer = false }
                        }
                    HStack(spacing: 0) {
                        LeftDrawerView(isShowing: $showingLeftDrawer) {
                            await notion.fetchPlaces()
                            await notion.fetchVisits()
                            await notion.fetchCaptures()
                        }
                        .frame(width: UIScreen.main.bounds.width * 0.85)
                        .background(Color(UIColor.systemBackground))
                        .ignoresSafeArea()
                        Spacer()
                    }
                    .transition(.move(edge: .leading))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showingLeftDrawer)
        }
        // Home screen quick actions — cold launch (app was killed)
        // onAppear fires when view is ready; delay lets app fully initialize
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
