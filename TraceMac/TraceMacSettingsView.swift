// TraceMacSettingsView.swift
// Mac Settings window — enter Notion token and other credentials.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.

import SwiftUI

struct TraceMacSettingsView: View {

    @State private var token: String = ""
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
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onAppear {
            token = sharedDefaults.string(forKey: "notion_token") ?? ""
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
        sharedDefaults.set(token.trimmingCharacters(in: .whitespaces), forKey: "notion_token")
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
