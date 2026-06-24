import SwiftUI

// MARK: - Left Drawer (nav menu)

struct LeftDrawerView: View {
    @Binding var isShowing: Bool
    var onSave: () async -> Void

    @Environment(NotionService.self) private var notion
    @State private var showingNeedsReview = false
    @State private var showingEnrichVisits = false

    private var needsReviewCount: Int {
        notion.places.filter { $0.enrichmentStatus == "Needs Review" }.count
    }

    private var enrichVisitsCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let excludedPlaceIDs = Set(notion.places.filter { $0.skipEnrichment }.map { $0.id })
        let journaledVisitIDs = Set(notion.workouts.compactMap { $0.visitID })
        let billiardsVisitIDs = Set(notion.billiardsSessions.compactMap { $0.visitID })
        return notion.visits.filter { visit in
            visit.date >= cutoff &&
            !visit.skipEnrichment &&
            (visit.notes == nil || visit.notes!.isEmpty) &&
            visit.rating == nil &&
            visit.photoURLs.isEmpty &&
            !excludedPlaceIDs.contains(visit.placeID) &&
            !journaledVisitIDs.contains(visit.id) &&
            !billiardsVisitIDs.contains(visit.id)
        }.count
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    SettingsView(isShowing: $isShowing, onSave: onSave)
                } label: {
                    Label("Settings", systemImage: "gear")
                }

                Button {
                    showingNeedsReview = true
                } label: {
                    HStack {
                        Label("Needs Review", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(needsReviewCount > 0 ? .orange : .primary)
                        Spacer()
                        if needsReviewCount > 0 {
                            Text("\(needsReviewCount)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.orange, in: Capsule())
                        }
                    }
                }
                .tint(.primary)

                Button {
                    showingEnrichVisits = true
                } label: {
                    HStack {
                        Label("Enrich Visits", systemImage: "pencil.circle")
                            .foregroundStyle(enrichVisitsCount > 0 ? .indigo : .primary)
                        Spacer()
                        if enrichVisitsCount > 0 {
                            Text("\(enrichVisitsCount)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.indigo, in: Capsule())
                        }
                    }
                }
                .tint(.primary)

                NavigationLink {
                    AboutView(isShowing: $isShowing)
                } label: {
                    Label("About Trace", systemImage: "info.circle")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Trace")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeButton
                }
            }
        }
        .sheet(isPresented: $showingNeedsReview) {
            NeedsReviewSheet()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
        .sheet(isPresented: $showingEnrichVisits) {
            EnrichVisitsSheet()
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
    }

    private var closeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.title2)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Binding var isShowing: Bool
    var onSave: () async -> Void

    @State private var notionToken = ""
    @State private var nasPassword = ""
    @State private var b2KeyID = ""
    @State private var b2ApplicationKey = ""
    @State private var googlePlacesKey = ""
    @State private var ouraToken = ""
    @State private var thingsApiURL = ""
    @State private var thingsApiToken = ""
    @State private var billiardsMyName = ""
    @State private var billiardsMyslStr = ""
    @State private var calShowAllDay = false
    @State private var showToken = false
    @State private var showPassword = false
    @State private var showB2Key = false
    @State private var showGoogleKey = false
    @State private var showOuraToken = false
    @State private var saveState: SaveState = .idle
    @State private var geofenceEnabled = false

    enum SaveState { case idle, saving, saved }

    var body: some View {
        List {
            Section {
                credentialRow(text: $notionToken, show: $showToken, placeholder: "ntn_…")
            } header: {
                Label("Notion", systemImage: "note.text")
            } footer: {
                Text("Internal integration token from the Notion developer portal.")
            }

            Section {
                credentialRow(text: $nasPassword, show: $showPassword, placeholder: "DSM password")
            } header: {
                Label("NAS", systemImage: "externaldrive.fill.badge.wifi")
            } footer: {
                Text("Your DiskStation Manager password. Used for NAS backup uploads via Tailscale.")
            }

            Section {
                TextField("Key ID", text: $b2KeyID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                credentialRow(text: $b2ApplicationKey, show: $showB2Key, placeholder: "Application key")
            } header: {
                Label("Backblaze B2", systemImage: "cloud.fill")
            } footer: {
                Text("Used for public photo URLs. Key scoped to the trace-place-photos bucket.")
            }

            Section {
                credentialRow(text: $googlePlacesKey, show: $showGoogleKey, placeholder: "AIza…")
            } header: {
                Label("Google Places", systemImage: "map")
            } footer: {
                Text("API key with Places API (New) enabled. Used for place search in Discover.")
            }

            Section {
                credentialRow(text: $ouraToken, show: $showOuraToken, placeholder: "eyJ…")
            } header: {
                Label("Oura Ring", systemImage: "heart.fill")
            } footer: {
                Text("Personal Access Token from developer.ouraring.com. Used for sleep, readiness, and activity scores on the Home screen.")
            }

            Section {
                TextField("http://100.x.x.x:8000", text: $thingsApiURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .font(.system(.body, design: .monospaced))
                TextField("Bearer token", text: $thingsApiToken)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            } header: {
                Label("Things 3", systemImage: "checkmark.circle")
            } footer: {
                Text("Base URL and auth token for the things-api server on your Mac Mini (via Tailscale). Used for today's tasks on the Home screen.")
            }

            Section {
                TextField("Dave", text: $billiardsMyName)
                    .autocorrectionDisabled()
                TextField("5", text: $billiardsMyslStr)
                    .keyboardType(.numberPad)
            } header: {
                Label("Billiards", systemImage: "circle.grid.2x2")
            } footer: {
                Text("Your name as it appears on APA scorecards (used to auto-identify your row when scanning), and your current APA skill level (pre-fills the wizard).")
            }

            Section {
                Toggle(isOn: $calShowAllDay) {
                    Label("Show all-day events", systemImage: "calendar")
                }
                .onChange(of: calShowAllDay) { _, val in
                    UserDefaults.standard.set(val, forKey: "cal_show_all_day")
                    Task { await CalendarService.shared.fetchUpcomingEvents() }
                }
            } header: {
                Label("Calendar", systemImage: "calendar")
            } footer: {
                Text("When on, all-day events appear in the Next Up section on the Home screen.")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        switch saveState {
                        case .idle:   Text("Save").bold()
                        case .saving: ProgressView()
                        case .saved:  Label("Saved", systemImage: "checkmark").bold().foregroundStyle(.green)
                        }
                        Spacer()
                    }
                }
                .disabled(saveState != .idle)
            }

            Section {
                Toggle(isOn: $geofenceEnabled) {
                    Label("Auto Check-in Reminders", systemImage: "location.circle")
                }
                .onChange(of: geofenceEnabled) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: "geofence_enabled")
                    if enabled {
                        GeofenceManager.shared.requestAlwaysPermission()
                        GeofenceManager.shared.startMonitoring(places: NotionService.shared.places)
                    } else {
                        GeofenceManager.shared.stopMonitoring()
                    }
                }
            } header: {
                Label("Location", systemImage: "location.fill")
            } footer: {
                Text("Sends a \"Check in?\" notification after you've been at a saved place for ~3 minutes. Requires Always On location access.")
            }

            Section {
                let gm = GeofenceManager.shared
                VStack(alignment: .leading, spacing: 6) {
                    Text("Auth: \(gm.authorizationStatus.debugLabel)").font(.caption).foregroundStyle(.secondary)
                    Text("Monitoring: \(gm.isMonitoring ? "yes" : "no")").font(.caption).foregroundStyle(.secondary)
                    Text("Regions: \(gm.monitoredRegionCount)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Clear Geofence Cooldowns") {
                    UserDefaults.standard.removeObject(forKey: "geofence_cooldowns")
                }
                .foregroundStyle(.orange)
                Button("Force Re-register Geofences") {
                    GeofenceManager.shared.startMonitoring(places: NotionService.shared.places)
                }
                .foregroundStyle(.blue)
            } header: {
                Label("Debug", systemImage: "wrench.and.screwdriver")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
            }
        }
        .onAppear {
            notionToken       = (UserDefaults(suiteName: "group.com.david.trace") ?? .standard).string(forKey: "notion_token") ?? ""
            nasPassword       = UserDefaults.standard.string(forKey: "nas_password") ?? ""
            b2KeyID           = UserDefaults.standard.string(forKey: "b2_key_id") ?? ""
            b2ApplicationKey  = UserDefaults.standard.string(forKey: "b2_application_key") ?? ""
            googlePlacesKey   = UserDefaults.standard.string(forKey: "google_places_key") ?? ""
            ouraToken         = UserDefaults.standard.string(forKey: "oura_token") ?? ""
            thingsApiURL      = UserDefaults.standard.string(forKey: "things_api_url") ?? ""
            thingsApiToken    = UserDefaults.standard.string(forKey: "things_api_token") ?? ""
            billiardsMyName   = UserDefaults.standard.string(forKey: "billiards_my_name") ?? ""
            let sl = UserDefaults.standard.integer(forKey: "billiards_my_sl")
            billiardsMyslStr  = sl > 0 ? "\(sl)" : ""
            calShowAllDay     = UserDefaults.standard.bool(forKey: "cal_show_all_day")
            geofenceEnabled   = UserDefaults.standard.bool(forKey: "geofence_enabled")
        }
    }

    @ViewBuilder
    private func credentialRow(text: Binding<String>, show: Binding<Bool>, placeholder: String) -> some View {
        HStack {
            if show.wrappedValue {
                TextField(placeholder, text: text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField(placeholder, text: text)
            }
            Button {
                show.wrappedValue.toggle()
            } label: {
                Image(systemName: show.wrappedValue ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() async {
        saveState = .saving
        let sharedDefaults = UserDefaults(suiteName: "group.com.david.trace") ?? .standard
        sharedDefaults.set(notionToken,      forKey: "notion_token")
        UserDefaults.standard.set(nasPassword,      forKey: "nas_password")
        UserDefaults.standard.set(b2KeyID,          forKey: "b2_key_id")
        UserDefaults.standard.set(b2ApplicationKey, forKey: "b2_application_key")
        UserDefaults.standard.set(googlePlacesKey,  forKey: "google_places_key")
        UserDefaults.standard.set(ouraToken,        forKey: "oura_token")
        UserDefaults.standard.set(thingsApiURL,     forKey: "things_api_url")
        UserDefaults.standard.set(thingsApiToken,   forKey: "things_api_token")
        if !billiardsMyName.isEmpty {
            UserDefaults.standard.set(billiardsMyName, forKey: "billiards_my_name")
        }
        if let sl = Int(billiardsMyslStr), sl > 0 {
            UserDefaults.standard.set(sl, forKey: "billiards_my_sl")
        }
        await onSave()
        saveState = .saved
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
        saveState = .idle
    }
}

// MARK: - Needs Review Sheet

struct NeedsReviewSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(LocationManager.self) private var locationManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlace: Place?

    private var flaggedPlaces: [Place] {
        notion.places
            .filter { $0.enrichmentStatus == "Needs Review" && $0.status != "Archived" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if flaggedPlaces.isEmpty {
                    ContentUnavailableView(
                        "All clear",
                        systemImage: "checkmark.circle",
                        description: Text("Tap the triangle on any place to flag it for review.")
                    )
                } else {
                    List(flaggedPlaces) { place in
                        Button {
                            selectedPlace = place
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: placeIcon(for: place.category))
                                    .foregroundStyle(placeColor(for: place.category))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text([place.category, place.city]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                        }
                        .tint(.primary)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { try? await notion.archivePlace(place) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { try? await notion.clearReviewFlag(place) }
                            } label: {
                                Label("Clear Flag", systemImage: "checkmark.triangle")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Needs Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $selectedPlace) { place in
            PlaceDetailView(place: place)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
    }
}

// MARK: - Enrich Visits Sheet

struct EnrichVisitsSheet: View {
    @Environment(NotionService.self) private var notion
    @Environment(\.dismiss) private var dismiss
    @State private var selectedVisit: Visit?

    private var visitsToEnrich: [Visit] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let excludedPlaceIDs = Set(notion.places.filter { $0.skipEnrichment }.map { $0.id })
        let journaledVisitIDs = Set(notion.workouts.compactMap { $0.visitID })
        let billiardsVisitIDs = Set(notion.billiardsSessions.compactMap { $0.visitID })
        return notion.visits
            .filter { visit in
                visit.date >= cutoff &&
                !visit.skipEnrichment &&
                (visit.notes == nil || visit.notes!.isEmpty) &&
                visit.rating == nil &&
                visit.photoURLs.isEmpty &&
                !excludedPlaceIDs.contains(visit.placeID) &&
                !journaledVisitIDs.contains(visit.id) &&
                !billiardsVisitIDs.contains(visit.id)
            }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visitsToEnrich.isEmpty {
                    ContentUnavailableView(
                        "All caught up",
                        systemImage: "checkmark.circle",
                        description: Text("No recent visits need notes, ratings, or photos.")
                    )
                } else {
                    List(visitsToEnrich) { visit in
                        Button {
                            selectedVisit = visit
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(visit.placeName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    Text(visit.date, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    missingTag("no notes", condition: visit.notes == nil || visit.notes!.isEmpty)
                                    missingTag("no rating", condition: visit.rating == nil)
                                    missingTag("no photos", condition: visit.photoURLs.isEmpty)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .tint(.primary)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                Task { try? await notion.skipVisitEnrichment(visit) }
                            } label: {
                                Label("Skip", systemImage: "xmark.circle")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            }
            .navigationTitle("Enrich Visits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $selectedVisit) { visit in
            VisitDetailView(visit: visit)
                .environment(NotionService.shared)
                .environment(LocationManager.shared)
        }
    }

    @ViewBuilder
    private func missingTag(_ label: String, condition: Bool) -> some View {
        if condition {
            Text(label)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.indigo.opacity(0.12), in: Capsule())
                .foregroundStyle(.indigo)
        }
    }
}

// MARK: - About

struct AboutView: View {
    @Binding var isShowing: Bool

    var body: some View {
        List {
            Section {
                Text("Trace is your personal place memory — a private log of everywhere you go and everything you discover. Built on Notion, it tracks visits, captures quick pins, and helps you rediscover places worth going back to.")
                    .font(.body)
                    .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About Trace")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
            }
        }
    }
}
