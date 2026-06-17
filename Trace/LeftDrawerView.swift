import SwiftUI

struct LeftDrawerView: View {
    @Binding var isShowing: Bool
    var onSave: () async -> Void

    @State private var notionToken = ""
    @State private var nasPassword = ""
    @State private var showToken = false
    @State private var showPassword = false
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
                    Text("Your DiskStation Manager password. Used for photo uploads via Tailscale.")
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
                    Text("Trace 1.0 (3)")
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
        await onSave()
        saveState = .saved
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        withAnimation(.easeInOut(duration: 0.3)) { isShowing = false }
        saveState = .idle
    }
}
