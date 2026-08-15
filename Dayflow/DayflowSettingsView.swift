import SwiftUI
import EventKit

// MARK: - DayflowSettingsView
//
// Settings — build order step 6, built 2026-07-20. Ground truth from the
// Session 2 mockup review was thin here ("Settings gear now opens an actual
// Settings screen (Default Calendar, Sync)") since the mockup review predates
// the Things integration entirely — this screen's real, urgent trigger was
// David installing the first TestFlight build on his actual phone and
// discovering there was no way to configure the Things Mini-bridge URL/token
// at all (they'd only ever been seeded on the Simulator via a Terminal
// `defaults write` command, invisible and unreachable from a real device).
// So this screen is really two things bolted together: the Things config
// UI that's now load-bearing/required, plus the originally-scoped Default
// Calendar + Sync items. Also added an Appearance override (System/Light/
// Dark) since David asked about it in the same conversation and Settings is
// the obvious home for it — not in the original mockup scope, small enough
// to fold in here rather than defer.
//
// All persistence is via `@AppStorage` (backed by `UserDefaults.standard`)
// using the exact same keys `ThingsService.swift`'s `baseURL()`/`authorize()`
// already read (`things_api_url`, `things_api_token`) — typing in this
// screen IS saving, live, no separate save step, and the very next
// `ThingsService` fetch anywhere in the app picks up the new values
// automatically.
//
// **"Calendars Shown in Agenda" section added 2026-07-20 (Session 14),
// David asked for this directly.** Separate from "Default Calendar" below —
// that one controls where a *new* event gets written (single choice, an
// event can only live on one calendar); this one is a checkbox multi-select
// controlling which calendars' events get READ into the Agenda/Upcoming/
// Calendar-search surfaces (e.g. hide Birthdays/Holidays, show two of
// several work + personal calendars). Backed by `CalendarService`'s new
// `includedCalendarsForDayflow()` filter — see that file's comment for the
// storage format and the "empty = show everything" default.

struct DayflowSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("things_api_url") private var apiURL: String = ""
    @AppStorage("things_api_token") private var apiToken: String = ""
    @AppStorage("dayflow_appearance") private var appearanceRaw: String = "light"
    @AppStorage("default_calendar_identifier") private var defaultCalendarID: String = ""
    @AppStorage("dayflow_included_calendar_ids") private var includedCalendarIDsRaw: String = ""

    @State private var testState: ConnectionTestState = .idle
    @State private var availableCalendars: [EKCalendar] = []
    @State private var lastSyncedText: String = "Never"
    @State private var isSyncing = false
    /// What the last Sync Now did. **The button used to report nothing at all**,
    /// so a failed sync and a successful one looked identical — which is how
    /// David could sync today and still be looking at a list from yesterday
    /// without anything telling him.
    @State private var syncStatus: String? = nil
    /// **TEMPORARY, added 2026-07-25** — widget weather debug readout. The
    /// widget face is too small to show a full error string legibly
    /// (confirmed: David couldn't read it even zoomed into a screenshot),
    /// so `DayflowWidget.swift`'s `fetchWeather()` now also writes the full,
    /// untruncated failure text to the shared App Group UserDefaults; this
    /// screen reads it back with real space to show it and lets David
    /// copy/paste it directly instead of a screenshot. Remove this state var,
    /// `loadWeatherDebugText()`, and `weatherDebugSection` once weather is
    /// confirmed working — see Dayflow-HANDOFF.md for the matching widget-side
    /// removal checklist.
    @State private var weatherDebugText: String = "(not loaded yet)"

    private enum ConnectionTestState: Equatable {
        case idle, testing, success(String), failure(String)
    }

    var body: some View {
        // Skin fix 2026-07-22 (Session 34). Was `NavigationStack { Form {
        // ... }.navigationTitle("Settings").toolbar { Button("Done") } }` —
        // the native large-title nav bar (bold sans-serif, plain white),
        // David's own flagged mismatch against the rest of the app's warm/
        // serif look. Dropped the `NavigationStack` (not needed — no push
        // navigation happens inside this Form, every Picker here is inline/
        // segmented, not a push destination) in favor of the same plain-
        // VStack-plus-custom-header pattern every other Dayflow screen
        // already uses (DayflowNotesView.swift etc.), so Settings stops being
        // the one screen built a structurally different way.
        VStack(spacing: 0) {
            header
            Form {
                weatherDebugSection
                thingsSection
                // MOVED UP, 2026-08-14 (Session 71). It was below the calendar
                // sections under a bare "Sync" header, which reads as a global
                // sync and is where David went looking for it and did not find
                // it: *"That section of settings is not in the Things section
                // but rather toward the bottom of the settings screen."* It has
                // always been Things and nothing else — the button calls
                // `ThingsService.refreshAll()` and the row reads
                // `ThingsService.lastFetched`. A control filed under the wrong
                // heading is a control you have to already know about.
                syncSection
                appearanceSection
                calendarSection
                includedCalendarsSection
                // One entry here serves Trace, Satchel and the Mac too — they
                // all read the same App Group key. Dayflow gets the field
                // because it is the only iOS app in the family with a Settings
                // screen at all.
                ClaudeAPIKeySection()
            }
            .listStyle(.insetGrouped)
            // `Form`/`List` paint their own opaque .systemGroupedBackground
            // by default — hiding it is required before the gradient below
            // can show through, the same "background painted on/under the
            // wrong layer" issue Session 30 hit with `NavigationStack`.
            .scrollContentBackground(.hidden)
        }
        // Same warm gradient as the rest of the app. Each Form Section
        // already renders as its own rounded white block (inset-grouped
        // style), which reads close enough to the app's card language
        // without rebuilding every row/Picker/SecureField by hand — that
        // rewrite would be a lot of surface area to get right with no
        // simulator in this sandbox to verify against. See DayflowSkin.swift.
        .dayflowSkinBackground()
        .task {
            availableCalendars = await CalendarService.shared.availableCalendars()
            updateLastSyncedText()
            loadWeatherDebugText()
        }
    }

    // MARK: TEMP — Widget Weather Debug (see weatherDebugText's declaration)

    private var weatherDebugSection: some View {
        Section {
            Text(weatherDebugText)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Button("Refresh") { loadWeatherDebugText() }
        } header: {
            Text("TEMP: Widget Weather Debug")
        } footer: {
            Text("Temporary diagnostic screen. Shows the widget's last weather-fetch attempt and, on failure, the full error — long-press the text above to copy it. This section and the widget code writing to it get removed once weather works.")
        }
    }

    private func loadWeatherDebugText() {
        // Inlined rather than `AppGroup.identifier` — that type turns out
        // not to be in the Dayflow target's membership either (build error:
        // "Cannot find 'AppGroup' in scope"), same situation
        // DayflowWidget.swift's own comment already flags for the widget
        // extension. Must match `group.com.david.trace` used everywhere else.
        weatherDebugText = UserDefaults(suiteName: "group.com.david.trace")?
            .string(forKey: "dayflowWidgetWeatherDebugTextFull") ?? "(no debug text written yet — widget hasn't run since this key was added, or App Group isn't shared correctly)"
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Color.clear.frame(width: 50, height: 32)
            Spacer()
            Text("Settings")
                .font(.dayflowSerif(20))
            Spacer()
            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.dayflowInk)
                .frame(width: 50, height: 32, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: Things Integration

    private var thingsSection: some View {
        Section {
            TextField("http://100.x.x.x:8000", text: $apiURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("API Token", text: $apiToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    testStatusIcon
                }
            }
            .disabled(apiURL.isEmpty || testState == .testing)

            if case .success(let msg) = testState {
                Text("Connected — server says \"\(msg)\".")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if case .failure(let msg) = testState {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Things Integration")
        } footer: {
            Text("Your Mac Mini's things-api bridge address and Bearer token. On the Simulator this is usually http://localhost:8000 — on a real device it needs your Mac's actual network address (e.g. a Tailscale hostname), since \"localhost\" on your phone means the phone itself, not your Mac.")
        }
    }

    @ViewBuilder
    private var testStatusIcon: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func testConnection() async {
        testState = .testing
        let base = apiURL.hasSuffix("/") ? apiURL : apiURL + "/"
        guard let url = URL(string: base + "health") else {
            testState = .failure("That doesn't look like a valid URL.")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 6)
        if !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                testState = .failure("Server responded with status \(code) — check the URL/token.")
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String {
                testState = .success(status)
            } else {
                testState = .success("ok")
            }
        } catch {
            testState = .failure("Couldn't connect: \(error.localizedDescription)")
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $appearanceRaw) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Default Calendar

    private var calendarSection: some View {
        Section {
            if availableCalendars.isEmpty {
                Text("No calendars found — check Calendar access for Dayflow in the iOS Settings app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Default Calendar", selection: $defaultCalendarID) {
                    Text("None").tag("")
                    ForEach(availableCalendars, id: \.calendarIdentifier) { cal in
                        Text(cal.title).tag(cal.calendarIdentifier)
                    }
                }
            }
        } header: {
            Text("Default Calendar")
        } footer: {
            // Corrected 2026-07-20 (Session 14) — this used to say "that write
            // path isn't built yet, so this doesn't do anything visible
            // today," which was true when this screen was first built
            // (Session 7) but went stale once Calendar write support shipped
            // in Session 10. Caught while adding the section below.
            Text("New events created in Dayflow are written here. If a calendar isn't picked, Dayflow falls back to your iPhone's own default calendar for new events.")
        }
    }

    // MARK: Calendars Shown in Agenda — added Session 14, 2026-07-20
    //
    // Checkbox multi-select, distinct from the single-choice "Default
    // Calendar" section above. Empty `includedCalendarIDsRaw` is the implicit
    // "show everything" state (every row reads as checked); toggling any row
    // off for the first time materializes the full available-calendar set
    // into storage minus that one row, so from then on the stored value is
    // an explicit include-list. See `CalendarService.includedCalendarsForDayflow()`
    // for the read side.

    private var includedCalendarIDs: Set<String> {
        Set(includedCalendarIDsRaw.split(separator: ",").map(String.init))
    }

    private func isCalendarIncluded(_ id: String) -> Bool {
        includedCalendarIDsRaw.isEmpty || includedCalendarIDs.contains(id)
    }

    private func setCalendarIncluded(_ id: String, included: Bool) {
        var ids: Set<String>
        if includedCalendarIDsRaw.isEmpty {
            // Currently in the implicit "show everything" state — materialize
            // the full set before toggling this one row off.
            ids = Set(availableCalendars.map { $0.calendarIdentifier })
        } else {
            ids = includedCalendarIDs
        }
        if included {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        includedCalendarIDsRaw = ids.sorted().joined(separator: ",")
    }

    private var includedCalendarsSection: some View {
        Section {
            if availableCalendars.isEmpty {
                Text("No calendars found — check Calendar access for Dayflow in the iOS Settings app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableCalendars, id: \.calendarIdentifier) { cal in
                    Button {
                        setCalendarIncluded(cal.calendarIdentifier, included: !isCalendarIncluded(cal.calendarIdentifier))
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(cgColor: cal.cgColor ?? CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)))
                                .frame(width: 10, height: 10)
                            Text(cal.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if isCalendarIncluded(cal.calendarIdentifier) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Calendars Shown in Agenda")
        } footer: {
            Text("Unchecked calendars won't show events in the Agenda, Upcoming, Calendar, or Search views — for example, hiding Birthdays or Holidays. All calendars show by default until you uncheck something here. This doesn't affect where new events are written (see Default Calendar above).")
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        Section {
            Button(isSyncing ? "Syncing…" : "Sync Now") {
                isSyncing = true
                syncStatus = nil
                Task {
                    // `/today` ONLY before reporting. It is the list the Agenda
                    // draws and the only one `lastError` describes; the other
                    // three are browse-view sources and cost up to 60 seconds
                    // more between them. Answering after 20 rather than 80 is
                    // the difference between a slow button and a stuck one.
                    await ThingsService.shared.fetch()
                    await MainActor.run {
                        isSyncing = false
                        updateLastSyncedText()
                        // `lastError` is set and cleared by `/today` alone, so
                        // it describes exactly the list the Agenda draws.
                        if let error = ThingsService.shared.lastError {
                            syncStatus = "Could not reach Things. \(error)"
                        } else {
                            syncStatus = "Up to date."
                        }
                    }
                    // Behind the answer, not in front of it.
                    await ThingsService.shared.refreshBrowseLists()
                }
            }
            .disabled(isSyncing)
            HStack {
                Text("Last synced")
                Spacer()
                Text(lastSyncedText).foregroundStyle(.secondary)
            }
            if let syncStatus {
                Text(syncStatus)
                    .font(.caption)
                    // `Color.` on both branches, explicitly. Bare `.secondary`
                    // resolves to `HierarchicalShapeStyle` and bare `.orange` to
                    // `Color`, and a ternary needs one type.
                    .foregroundStyle(syncStatus.hasPrefix("Up to date") ? Color.secondary : Color.orange)
            }
            // Shown whether or not Sync Now was pressed this visit: a stale list
            // is the thing worth knowing about on arrival, not on request.
            if syncStatus == nil, ThingsService.shared.isShowingStaleTasks {
                Text("The last refresh failed, so the Agenda is showing an older list.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Things Sync")
        } footer: {
            Text("\"Last synced\" only moves when a refresh succeeds. Dayflow also refreshes automatically when you switch back to it from another app.")
        }
    }

    private func updateLastSyncedText() {
        guard let date = ThingsService.shared.lastFetched else {
            lastSyncedText = "Never"
            return
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        lastSyncedText = f.localizedString(for: date, relativeTo: Date())
    }
}
