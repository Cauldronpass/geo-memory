// TraceMacSettingsView.swift
// Mac Settings window — enter Notion token and other credentials.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

struct TraceMacSettingsView: View {

    @State private var token:          String = ""
    @State private var claudeKey:      String = ""
    @State private var showClaudeKey   = false
    @State private var googlePlacesKey: String = ""
    @State private var showGooglePlacesKey = false
    @State private var saved = false

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
