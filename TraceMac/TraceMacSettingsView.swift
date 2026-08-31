// TraceMacSettingsView.swift
// Mac Settings window — enter Notion token and other credentials.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI
import AppKit
import Carbon.HIToolbox

struct TraceMacSettingsView: View {

    @State private var token:          String = ""
    @State private var claudeKey:      String = ""
    @State private var showClaudeKey   = false
    @State private var googlePlacesKey: String = ""
    @State private var showGooglePlacesKey = false
    @State private var saved = false
    /// Shared with the search panel through `@AppStorage`, so the toggle and
    /// the thing it governs read one key and neither owns it.
    @AppStorage("tracemac.ask.includeNotion") private var includeNotionInAsk = false
    @AppStorage(MacInboxCountSetting.sidebarKey) private var showInboxCount = false
    @AppStorage(MacInboxCountSetting.dockKey) private var showDockBadge = false
    /// The same key `TraceMacDocumentsView` reads. `@AppStorage` in two views is
    /// two readers of one default, not two copies — dragging the pane moves this
    /// slider and vice versa, live, with nothing to keep in step.
    @AppStorage(SatchelFilterPane.widthKey) private var facetWidth: Double = SatchelFilterPane.defaultWidth

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.com.david.trace") ?? .standard
    }

    var body: some View {
        Form {
            // Session 80, D192. First, because "which calendars am I looking
            // at" is a question about the screen he opens every morning, and
            // everything below it is a question about a service.
            MacCalendarChoicesSection()

            Section("Notion") {
                SecureField("Notion Integration Token", text: $token)
                    .textContentType(.password)
                Text("Starts with secret_… — find it at notion.so/my-integrations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude API") {
                if showClaudeKey {
                    TextField("Claude API Key", text: $claudeKey)
                } else {
                    SecureField("Claude API Key", text: $claudeKey)
                        .textContentType(.password)
                }
                HStack {
                    // States where the key actually is. "Stored more safely now"
                    // is a claim the user should be able to see rather than take
                    // on trust — and while it reads Keychain: no, something did
                    // not migrate and this is the only place that would say so.
                    Text(ClaudeKeyStore.isSecured
                         ? "Stored in the macOS Keychain. Used for Ask, OT and Billiards scans."
                         : "Not stored yet. Used for Ask, OT and Billiards scans.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(showClaudeKey ? "Hide" : "Show") {
                        showClaudeKey.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            Section("Google Places") {
                if showGooglePlacesKey {
                    TextField("Google Places API Key", text: $googlePlacesKey)
                } else {
                    SecureField("Google Places API Key", text: $googlePlacesKey)
                        .textContentType(.password)
                }
                HStack {
                    Text("Used for Discover map search. Same key you entered on iOS — this is a separate, per-device copy (not shared automatically).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(showGooglePlacesKey ? "Hide" : "Show") {
                        showGooglePlacesKey.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            Section("Tasks") {
                Toggle("Show the Inbox count beside Tasks", isOn: $showInboxCount)
                Text("A small number in the sidebar when captured tasks are waiting to be filed. Visible only while you are in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Also badge the Dock icon", isOn: $showDockBadge)
                    .disabled(!showInboxCount)
                // **Dependent, not independent.** The Dock badge is the louder
                // version of the same message, and wanting the loud one without
                // the quiet one is not a state worth supporting — it would mean
                // being told across every app all day but not while looking at
                // the app that can act on it.
                //
                // The sentence names the trade rather than selling the feature.
                // David: "I dont really like icon badges but the task subtle
                // circle idea might be just enough of a push for me." A setting
                // he is ambivalent about should say what it costs.
                Text("Follows you outside the app. The sidebar count only appears when you are already here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global search") {
                MacHotKeyRecorder()

                Toggle("Let Ask read People and Places", isOn: $includeNotionInAsk)
                // Off by default, and the reason is on screen rather than only
                // in the spec. Spec §6: these records are other people's phone
                // numbers, addresses and birthdays, and including them sends
                // third-party data that those people did not choose. It also
                // buys nothing — "what is Megan's number" is answered by the
                // search box above, locally, with no API call at all.
                Text("Off by default. Search always covers them locally; this only decides whether Ask may send them to Claude. Ask never sends the contents of anything tagged private.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Session 73. The pane's two knobs, both of which have a second
            // control elsewhere and share one stored value with it rather than
            // keeping their own copy: the width also drags at the pane's edge,
            // and the pane also opens from the button beside Satchel's `+`.
            Section("Satchel filter pane") {
                MacSatchelShortcutRecorder()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Width")
                        Spacer()
                        Text("\(Int(facetWidth)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $facetWidth,
                           in: SatchelFilterPane.minWidth...SatchelFilterPane.maxWidth)
                    Text("Also draggable at the pane\u{2019}s left edge \u{2014} both write the same setting, so neither is the real one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onAppear {
            token           = sharedDefaults.string(forKey: "notion_token")   ?? ""
            // `ClaudeKeyStore`, not `sharedDefaults`. On macOS the key now
            // lives in the keychain, and reading it here also performs the
            // one-time migration out of the App Group — so simply opening
            // Settings moves an existing key across.
            claudeKey       = ClaudeKeyStore.key
            // GooglePlacesService.swift reads this from plain UserDefaults.standard
            // (not the app-group suite) — matching that read exactly, not the
            // sharedDefaults pattern used above, so Discover search actually finds it.
            googlePlacesKey = UserDefaults.standard.string(forKey: "google_places_key") ?? ""
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .overlay(alignment: .bottom) {
            if saved {
                Text("Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private func save() {
        sharedDefaults.set(token.trimmingCharacters(in: .whitespaces),     forKey: "notion_token")
        ClaudeKeyStore.set(claudeKey)
        // Plain .standard, not sharedDefaults — see the matching read in .onAppear.
        UserDefaults.standard.set(googlePlacesKey.trimmingCharacters(in: .whitespaces), forKey: "google_places_key")
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}

// MARK: - Hot key recorder

/// Click, press a combination, done.
///
/// A local `NSEvent` monitor, not a global one: it only listens while this
/// control is recording and only inside this app, so it needs no permission at
/// all. (The *global* half of the feature is Carbon — see `TraceMacHotKey.swift`
/// for why neither half uses Accessibility.)
///
/// Three things it refuses, each with a reason on screen rather than a silent
/// no-op:
///
///   * A bare key with no modifier. `S` registered system-wide would swallow the
///     letter S in every app on the Mac.
///   * Escape, which is how you cancel recording.
///   * Anything `RegisterEventHotKey` rejects, which in practice means another
///     app already owns it. The previous shortcut is put back and stays live.
/// The global-search recorder. A thin wrapper since Session 73, when a second
/// shortcut needed the same control and the recording logic was still married to
/// `MacHotKeyCenter`.
struct MacHotKeyRecorder: View {

    @State private var center = MacHotKeyCenter.shared

    var body: some View {
        MacShortcutRecorder(
            title: "Shortcut",
            currentLabel: center.combo.label,
            ownerError: center.lastError,
            help: "Works anywhere on the Mac, and inside Trace. Needs a modifier — fn cannot be used.",
            onRecord: { combo in
                center.update(to: combo) ? nil : (center.lastError ?? "Could not register that combination.")
            },
            onReset: { _ = center.update(to: .default) }
        )
    }
}

/// The Satchel filter pane's recorder.
///
/// Same control, different owner, and the difference that matters is in the
/// helper line: this one is **in-app only**. See `MacSatchelFilterShortcut` for
/// why that is the right scope and why it is a local `NSEvent` monitor rather
/// than either of the two mechanisms this app already had.
struct MacSatchelShortcutRecorder: View {

    @State private var shortcut = MacSatchelFilterShortcut.shared

    var body: some View {
        MacShortcutRecorder(
            title: "Shortcut",
            currentLabel: shortcut.combo.label,
            ownerError: nil,
            help: "Inside Trace only, from any section — it switches to Satchel and opens the pane. Needs a modifier.",
            onRecord: { shortcut.update(to: $0) },
            onReset: { shortcut.reset() }
        )
    }
}

// MARK: - The recorder itself

struct MacShortcutRecorder: View {

    let title: String
    let currentLabel: String
    /// A standing error from whoever owns the shortcut — the global one can be
    /// refused by the system long after it was recorded, when another app takes
    /// the combination. Shown when there is no fresher rejection to show.
    let ownerError: String?
    let help: String
    /// Returns nil on success, or the sentence to put on screen.
    let onRecord: (MacHotKeyCombo) -> String?
    let onReset: () -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button(recording ? "Press a combination…" : currentLabel) {
                    if recording { stop() } else { start() }
                }
                .buttonStyle(.bordered)
                .tint(recording ? .orange : nil)
                Button("Reset") {
                    rejection = nil
                    onReset()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let message = rejection ?? ownerError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        rejection = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            // Swallowed: a key pressed at the recorder must not also reach the
            // Form behind it.
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { stop(); return }

        let modifiers = MacHotKeyCombo.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            rejection = "Needs at least one of ⌃ ⌥ ⇧ ⌘."
            return
        }
        stop()
        apply(MacHotKeyCombo(keyCode: UInt32(event.keyCode),
                             modifiers: modifiers,
                             label: MacHotKeyCombo.label(flags: event.modifierFlags,
                                                         keyCode: event.keyCode,
                                                         characters: event.charactersIgnoringModifiers)))
    }

    private func apply(_ combo: MacHotKeyCombo) {
        rejection = onRecord(combo)
    }
}
