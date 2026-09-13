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
// at all. That original screen is now the six sub-screens below.
//
// **Restructured into a menu, Session 99 (2026-09-12).** David: *"the settings
// screen itself ... is starting to get very congested and I think we need
// menus now."* It was ten Sections in one scroll, in the order they were
// added rather than any order you would look in, and the two that matter most
// day to day (Reminders access, Refresh) sat above three calendar blocks and
// two API keys. The root is now a short list of six destinations and every
// old Section moved, unchanged, into one of them.
//
// The push navigation is a `NavigationStack`, which Session 34 deliberately
// removed — but for the native large-title nav bar it drew, not for the
// stack itself. So every screen here, root and pushed, hides the system bar
// (`.toolbar(.hidden, for: .navigationBar)`) and draws the same custom
// serif header the rest of the app uses. A pushed screen's `dismiss()` pops;
// only the root's `dismiss()` closes the sheet.
//
// All persistence is still `@AppStorage` on `UserDefaults.standard`: typing
// or toggling in these screens IS saving, live, no separate save step.

struct DayflowSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dayflow_appearance") private var appearanceRaw: String = "light"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Form {
                    Section {
                        NavigationLink { DayflowRemindersSettings() } label: {
                            settingsRow("Tasks & Reminders", icon: "checklist",
                                        value: reminderAccessSummary)
                        }
                        NavigationLink { DayflowNotificationsSettings() } label: {
                            settingsRow("Notifications", icon: "bell", value: nil)
                        }
                        NavigationLink { DayflowCalendarSettings() } label: {
                            settingsRow("Calendars", icon: "calendar", value: nil)
                        }
                    }
                    Section {
                        NavigationLink { DayflowAppearanceSettings() } label: {
                            settingsRow("Appearance", icon: "paintbrush",
                                        value: appearanceRaw.capitalized)
                        }
                        NavigationLink { DayflowConnectionsSettings() } label: {
                            settingsRow("Connections", icon: "key", value: nil)
                        }
                    }
                    // TEMP — goes when the widget weather bug is closed out.
                    Section {
                        NavigationLink { DayflowDiagnosticsSettings() } label: {
                            settingsRow("Diagnostics", icon: "stethoscope", value: nil)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                // `Form`/`List` paint their own opaque .systemGroupedBackground
                // by default — hiding it is required before the gradient below
                // can show through.
                .scrollContentBackground(.hidden)
            }
            .dayflowSkinBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var reminderAccessSummary: String? {
        switch ReminderTaskStore.shared.accessGranted {
        case .some(true):  return nil
        case .some(false): return "Not allowed"
        case .none:        return "Not set up"
        }
    }

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
}

// MARK: - Menu row

/// One line of the root menu. `value` is the at-a-glance state worth seeing
/// without opening the screen — and it is deliberately nil when there is
/// nothing wrong, so the only text that ever appears here is text that
/// deserves a look.
@ViewBuilder
private func settingsRow(_ title: String, icon: String, value: String?) -> some View {
    HStack(spacing: 12) {
        Image(systemName: icon)
            .font(.system(size: 15))
            .foregroundStyle(Color.dayflowInk.opacity(0.7))
            .frame(width: 22)
        Text(title)
        Spacer()
        if let value {
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(value == "Not allowed" ? Color.orange : Color.secondary)
        }
    }
}

// MARK: - Sub-screen scaffold

/// Every pushed settings screen: custom serif header with a back chevron,
/// the same warm gradient, the system nav bar hidden. `dismiss()` here pops
/// back to the menu rather than closing the Settings sheet.
private struct DayflowSettingsScreen<Content: View>: View {
    // `content` is declared LAST on purpose: the trailing closure at every
    // call site binds to the final parameter of the synthesized memberwise
    // init, and an @Environment property sitting after it makes that match
    // depend on Swift's backward-scanning rule rather than on the obvious
    // reading.
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.dayflowInk)
                        .frame(width: 50, height: 32, alignment: .leading)
                }
                Spacer()
                Text(title)
                    .font(.dayflowSerif(20))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Color.clear.frame(width: 50, height: 32)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            Form { content() }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
        }
        .dayflowSkinBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Tasks & Reminders
//
// 2026-08-27. This was the Things Integration section: a Mac Mini bridge
// URL, a Bearer token and a Test Connection button. Tasks now come from
// Apple Reminders through EventKit, so the only setting is whether Dayflow
// is allowed to read them. `things_api_url` / `things_api_token` are left
// in UserDefaults untouched; nothing reads them until `ThingsService` is
// deleted with the export.
//
// Refresh lives here too. It moved up out of the calendar block in Session 71
// because David went looking for it under Things and did not find it; the
// menu makes that permanent — it has always been Reminders and nothing else.

private struct DayflowRemindersSettings: View {
    @State private var lastSyncedText: String = "Never"
    @State private var isSyncing = false
    /// What the last Sync Now did. **The button used to report nothing at all**,
    /// so a failed sync and a successful one looked identical.
    @State private var syncStatus: String? = nil

    var body: some View {
        DayflowSettingsScreen(title: "Tasks & Reminders") {
            accessSection
            refreshSection
        }
        .task { updateLastSyncedText() }
    }

    private var accessSection: some View {
        Section {
            HStack {
                Text("Access")
                Spacer()
                switch ReminderTaskStore.shared.accessGranted {
                case .some(true):  Text("Allowed").foregroundStyle(.secondary)
                case .some(false): Text("Not allowed").foregroundStyle(.orange)
                case .none:        Text("Not asked yet").foregroundStyle(.secondary)
                }
            }
            if ReminderTaskStore.shared.accessGranted == false {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            HStack {
                Text("Lists")
                Spacer()
                Text(ReminderTaskStore.shared.listNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Tasks come from Apple's Reminders app. Every list is read. New tasks you type here go to the Personal list; documents and birthdays from Trace and Satchel go to the Trace list.")
        }
    }

    private var refreshSection: some View {
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
                    await ReminderTaskStore.shared.fetch()
                    await MainActor.run {
                        isSyncing = false
                        updateLastSyncedText()
                        if let error = ReminderTaskStore.shared.lastError {
                            syncStatus = "Could not read Reminders. \(error)"
                        } else {
                            syncStatus = "Up to date."
                        }
                    }
                    // Behind the answer, not in front of it.
                    await ReminderTaskStore.shared.refreshBrowseLists()
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
            if syncStatus == nil, ReminderTaskStore.shared.isShowingStaleTasks {
                Text("The last refresh failed, so the Agenda is showing an older list.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Refresh")
        } footer: {
            Text("Dayflow refreshes on its own whenever Reminders changes, including from the Watch or Siri. This button is for reassurance.")
        }
    }

    private func updateLastSyncedText() {
        guard let date = ReminderTaskStore.shared.lastFetched else {
            lastSyncedText = "Never"
            return
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        lastSyncedText = f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Notifications

private struct DayflowNotificationsSettings: View {
    /// Session 77 — morning summary notification. Defaults mirror
    /// DayflowMorningSummary's own reads (on, 8:00).
    @AppStorage("morning_summary_enabled") private var morningSummaryEnabled: Bool = true
    @State private var morningSummaryTime: Date = Calendar.current.date(
        bySettingHour: DayflowMorningSummary.fireMinutes / 60,
        minute: DayflowMorningSummary.fireMinutes % 60,
        second: 0, of: Date()) ?? Date()
    /// Session 99 — which halves of the Inbox the app icon badge counts.
    /// Keys and defaults must match `DayflowInboxBadge.countsNotes/countsTasks`.
    @AppStorage("dayflow_badge_notes") private var badgeNotes: Bool = true
    @AppStorage("dayflow_badge_tasks") private var badgeTasks: Bool = true

    var body: some View {
        DayflowSettingsScreen(title: "Notifications") {
            morningSummarySection
            badgeSection
        }
    }

    private var morningSummarySection: some View {
        Section {
            Toggle("Morning summary", isOn: $morningSummaryEnabled)
            if morningSummaryEnabled {
                DatePicker("Time", selection: $morningSummaryTime,
                           displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Morning Summary")
        } footer: {
            Text("One notification each morning listing the day's tasks. Nothing is sent on a day with no dated tasks. Tasks given their own time also ring when that time arrives.")
        }
        .onChange(of: morningSummaryEnabled) { _, _ in
            Task { await DayflowMorningSummary.reschedule() }
        }
        .onChange(of: morningSummaryTime) { _, newValue in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            UserDefaults.standard.set((comps.hour ?? 8) * 60 + (comps.minute ?? 0),
                                      forKey: "morning_summary_minutes")
            Task { await DayflowMorningSummary.reschedule() }
        }
    }

    /// The number on the Home Screen icon. Either switch on its own is a
    /// clean number; both on is the sum, which holds together because Inbox
    /// means the same thing on both sides — captured, not yet decided — and
    /// the answer to either is the same gesture. Both off clears the badge.
    private var badgeSection: some View {
        Section {
            Toggle("Unfiled notes", isOn: $badgeNotes)
            Toggle("Inbox tasks", isOn: $badgeTasks)
        } header: {
            Text("App Icon Badge")
        } footer: {
            Text(badgeFooter)
        }
        .onChange(of: badgeNotes) { _, _ in
            Task { await DayflowInboxBadge.refresh() }
        }
        .onChange(of: badgeTasks) { _, _ in
            Task { await DayflowInboxBadge.refresh() }
        }
    }

    private var badgeFooter: String {
        switch (badgeNotes, badgeTasks) {
        case (true, true):
            return "The badge counts notes sitting in the Notes Inbox plus undated tasks in the Reminders Inbox list. Turn one off to count only the other."
        case (true, false):
            return "The badge counts notes sitting in the Notes Inbox."
        case (false, true):
            return "The badge counts undated tasks in the Reminders Inbox list."
        case (false, false):
            return "No badge. The app icon shows no number."
        }
    }
}

// MARK: - Calendars

private struct DayflowCalendarSettings: View {
    @AppStorage("default_calendar_identifier") private var defaultCalendarID: String = ""
    @AppStorage("dayflow_included_calendar_ids") private var includedCalendarIDsRaw: String = ""
    @State private var availableCalendars: [EKCalendar] = []

    var body: some View {
        DayflowSettingsScreen(title: "Calendars") {
            defaultCalendarSection
            includedCalendarsSection
        }
        .task {
            availableCalendars = await CalendarService.shared.availableCalendars()
        }
    }

    private var defaultCalendarSection: some View {
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
        // Tell the day surfaces, or the change does not appear until the app is
        // relaunched — see the notification's own comment for how that looked
        // from the outside.
        NotificationCenter.default.post(name: .dayflowIncludedCalendarsDidChange, object: nil)
    }

    /// How many of the saved identifiers actually resolve right now. The
    /// number the READ side will really use, not the number of ticks on screen.
    private var effectiveCount: Int {
        availableCalendars.filter { includedCalendarIDs.contains($0.calendarIdentifier) }.count
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
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cal.title)
                                    .foregroundStyle(.primary)
                                // **Two rows can wear the same name.** A work
                                // account subscribed twice lists twice here,
                                // identically, and there is no way to tell
                                // which checkmark belongs to which — which is
                                // exactly the state David was trying to
                                // diagnose on 2026-09-13. The source says it.
                                if let source = cal.source?.title, !source.isEmpty {
                                    Text(source)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
            Text("Shown in Agenda")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unchecked calendars won't show events in the Agenda, Upcoming, Calendar, or Search views — for example, hiding Birthdays or Holidays. All calendars show by default until you uncheck something here. This doesn't affect where new events are written (see Default Calendar above).")
                // **The fallback used to be invisible, and that is a screen
                // making a claim that is not true** (Session 103). If none of
                // the saved identifiers still resolve — an account removed and
                // re-added gives its calendars new ones — the read filter
                // returns nil and EVERY calendar shows, while every checkmark
                // here carries on looking obeyed. Now it says so.
                if !includedCalendarIDsRaw.isEmpty && effectiveCount == 0 {
                    Text("None of your saved choices match a calendar on this phone any more, so every calendar is showing. Re-check the ones you want.")
                        .foregroundStyle(.orange)
                } else if !includedCalendarIDsRaw.isEmpty {
                    Text("Showing \(effectiveCount) of \(availableCalendars.count) calendars.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Appearance

private struct DayflowAppearanceSettings: View {
    @AppStorage("dayflow_appearance") private var appearanceRaw: String = "light"

    var body: some View {
        DayflowSettingsScreen(title: "Appearance") {
            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Light is the app's designed look. System follows your iPhone's own light/dark setting.")
            }
        }
    }
}

// MARK: - Connections

private struct DayflowConnectionsSettings: View {
    var body: some View {
        DayflowSettingsScreen(title: "Connections") {
            // One entry here serves Trace, Satchel and the Mac too — they
            // all read the same App Group key. Dayflow gets the field
            // because it is the only iOS app in the family with a Settings
            // screen at all.
            ClaudeAPIKeySection()
            TodoistKeySection()
        }
    }
}

// MARK: - Diagnostics
//
// **TEMPORARY, added 2026-07-25** — widget weather debug readout. The widget
// face is too small to show a full error string legibly (confirmed: David
// couldn't read it even zoomed into a screenshot), so `DayflowWidget.swift`'s
// `fetchWeather()` also writes the full, untruncated failure text to the
// shared App Group UserDefaults; this screen reads it back with real space to
// show it and lets David copy/paste it directly instead of a screenshot.
// Remove this whole struct and its row in the root menu once weather is
// confirmed working — see Dayflow-HANDOFF.md for the matching widget-side
// removal checklist.

private struct DayflowDiagnosticsSettings: View {
    @State private var weatherDebugText: String = "(not loaded yet)"

    var body: some View {
        DayflowSettingsScreen(title: "Diagnostics") {
            Section {
                Text(weatherDebugText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Button("Refresh") { loadWeatherDebugText() }
            } header: {
                Text("Widget Weather")
            } footer: {
                Text("Temporary diagnostic. Shows the widget's last weather-fetch attempt and, on failure, the full error — long-press the text above to copy it. This screen and the widget code writing to it get removed once weather works.")
            }
        }
        .task { loadWeatherDebugText() }
    }

    private func loadWeatherDebugText() {
        // Inlined rather than `AppGroup.identifier` — that type turns out
        // not to be in the Dayflow target's membership either (build error:
        // "Cannot find 'AppGroup' in scope"). Must match
        // `group.com.david.trace` used everywhere else.
        weatherDebugText = UserDefaults(suiteName: "group.com.david.trace")?
            .string(forKey: "dayflowWidgetWeatherDebugTextFull") ?? "(no debug text written yet — widget hasn't run since this key was added, or App Group isn't shared correctly)"
    }
}
