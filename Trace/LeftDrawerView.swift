import SwiftUI

// MARK: - Left Drawer (nav menu)

struct LeftDrawerView: View {
    @Binding var isShowing: Bool
    var onSave: () async -> Void

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    SettingsView(isShowing: $isShowing, onSave: onSave)
                } label: {
                    Label("Settings", systemImage: "gear")
                }

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
    @State private var showToken = false
    @State private var showPassword = false
    @State private var showB2Key = false
    @State private var showGoogleKey = false
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
            notionToken       = UserDefaults.standard.string(forKey: "notion_token") ?? ""
            nasPassword       = UserDefaults.standard.string(forKey: "nas_password") ?? ""
            b2KeyID           = UserDefaults.standard.string(forKey: "b2_key_id") ?? ""
            b2ApplicationKey  = UserDefaults.standard.string(forKey: "b2_application_key") ?? ""
            googlePlacesKey   = UserDefaults.standard.string(forKey: "google_places_key") ?? ""
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
        UserDefaults.standard.set(notionToken,      forKey: "notion_token")
        UserDefaults.standard.set(nasPassword,      forKey: "nas_password")
        UserDefaults.standard.set(b2KeyID,          forKey: "b2_key_id")
        UserDefaults.standard.set(b2ApplicationKey, forKey: "b2_application_key")
        UserDefaults.standard.set(googlePlacesKey,  forKey: "google_places_key")
        await onSave()
        saveState = .saved
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
        saveState = .idle
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
