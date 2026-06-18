import SwiftUI

struct LeftDrawerView: View {
    @Binding var isShowing: Bool
    var onSave: () async -> Void

    @State private var notionToken = ""
    @State private var nasPassword = ""
    @State private var b2KeyID = ""
    @State private var b2ApplicationKey = ""
    @State private var showToken = false
    @State private var showPassword = false
    @State private var showB2Key = false
    @State private var saveState: SaveState = .idle

    enum SaveState { case idle, saving, saved }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    credentialRow(
                        text: $notionToken,
                        show: $showToken,
                        placeholder: "ntn_…"
                    )
                } header: {
                    Label("Notion", systemImage: "note.text")
                } footer: {
                    Text("Internal integration token from the Notion developer portal.")
                }

                Section {
                    credentialRow(
                        text: $nasPassword,
                        show: $showPassword,
                        placeholder: "DSM password"
                    )
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
                    credentialRow(
                        text: $b2ApplicationKey,
                        show: $showB2Key,
                        placeholder: "Application key"
                    )
                } header: {
                    Label("Backblaze B2", systemImage: "cloud.fill")
                } footer: {
                    Text("Used for public photo URLs. Key scoped to the trace-place-photos bucket.")
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            switch saveState {
                            case .idle:
                                Text("Save").bold()
                            case .saving:
                                ProgressView()
                            case .saved:
                                Label("Saved", systemImage: "checkmark")
                                    .bold()
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                        }
                    }
                    .disabled(saveState != .idle)
                }

                Section {
                    Text("Trace 1.0")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
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
        .onAppear {
            notionToken = UserDefaults.standard.string(forKey: "notion_token") ?? ""
            nasPassword = UserDefaults.standard.string(forKey: "nas_password") ?? ""
            b2KeyID = UserDefaults.standard.string(forKey: "b2_key_id") ?? ""
            b2ApplicationKey = UserDefaults.standard.string(forKey: "b2_application_key") ?? ""
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
        UserDefaults.standard.set(notionToken, forKey: "notion_token")
        UserDefaults.standard.set(nasPassword, forKey: "nas_password")
        UserDefaults.standard.set(b2KeyID, forKey: "b2_key_id")
        UserDefaults.standard.set(b2ApplicationKey, forKey: "b2_application_key")
        await onSave()
        saveState = .saved
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
        saveState = .idle
    }
}
