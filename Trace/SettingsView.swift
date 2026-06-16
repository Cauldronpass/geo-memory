import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var token: String = UserDefaults.standard.string(forKey: "notion_token") ?? ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Notion"), footer: Text("Your Notion integration token. Stored locally on this device only.")) {
                    SecureField("ntn_xxxx...", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Button("Save Token") {
                        UserDefaults.standard.set(token, forKey: "notion_token")
                        saved = true
                    }
                    .disabled(token.isEmpty)
                }

                if saved {
                    Section {
                        Label("Token saved", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
