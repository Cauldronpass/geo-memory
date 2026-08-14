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

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.com.david.trace") ?? .standard
    }

    var body: some View {
        Form {
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
                    Text("Used for OT and Billiards scan features.")
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

        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onAppear {
            token           = sharedDefaults.string(forKey: "notion_token")   ?? ""
            claudeKey       = sharedDefaults.string(forKey: "claude_api_key") ?? ""
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
        sharedDefaults.set(claudeKey.trimmingCharacters(in: .whitespaces), forKey: "claude_api_key")
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
struct MacHotKeyRecorder: View {

    @State private var center = MacHotKeyCenter.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shortcut")
                Spacer()
                Button(recording ? "Press a combination…" : center.combo.label) {
                    if recording { stop() } else { start() }
                }
                .buttonStyle(.bordered)
                .tint(recording ? .orange : nil)
                Button("Reset") {
                    apply(.default)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let message = rejection ?? center.lastError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Works anywhere on the Mac, and inside Trace. Needs a modifier — fn cannot be used.")
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
        rejection = center.update(to: combo) ? nil : center.lastError
    }
}
