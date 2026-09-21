// DayflowCredentialSections.swift
// Dayflow — the host target of the one app (D452).
//
// D485, Session 109. The Notion token and the Google Places key, entered here.
//
// ── Why these two, and why now ──────────────────────────────────────────────
//
// **The merged app had no way to enter either of them, and one of them was
// already broken on the phone.** `DayflowConnectionsSettings` carries the
// Claude key and the Todoist token, and its own comment states the rule this
// file follows: *"One entry here serves Trace, Satchel and the Mac too — they
// all read the same App Group key. Dayflow gets the field because it is the
// only iOS app in the family with a Settings screen at all."* That was true
// while Trace had its own Settings. Trace is being deleted.
//
// **Notion.** The only screen in the family that accepts the Notion token is
// Trace's Settings, which retires in pass (c). Without this, the day the old
// app comes off the phone is the day the merged app is one expired
// integration away from having no people, no places and no way to fix it.
//
// **Google Places.** Worse, because it is broken NOW rather than later.
// `GooglePlacesService` read its key from `UserDefaults.standard`, which is
// per-app: the key David pasted lives in TRACE's defaults, and the merged app
// has never had it. So Discover's search field — which D484 just put behind
// the Places map — returns nothing on his phone and says nothing about why.
// The service now reads the App Group first and migrates the old per-app value
// across on first read, the same shape `NotionService.token` has used since it
// moved.
//
// ── What is deliberately NOT here ───────────────────────────────────────────
//
// Trace's Settings also holds Oura, B2, NAS and the Things bridge. Oura fed
// Trace's Home screen, which retires; B2 and NAS have no service in this
// target; the Things bridge is the Mac's. Porting a field for a service this
// app cannot call would be furniture. They stay with the old app and go with
// it, and if one of them turns out to be wanted it comes back as its own
// decision rather than as a row nobody asked for.
//
// The geofence toggle and the billiards details are real and still missing;
// they belong with the geofencing move, which is its own build.

import SwiftUI

/// One secret, stored in the shared App Group so every app in the family reads
/// the same value.
///
/// **Reads through to `UserDefaults.standard` once.** A value typed into
/// Trace's Settings before the merge lives in Trace's own defaults, which this
/// app cannot see — but the reverse migration is free for anything that was
/// ever written to this app's own defaults, and costs nothing when there is
/// nothing to find.
enum DayflowSharedSecret {
    static let suite = "group.com.david.trace"

    static func read(_ key: String) -> String {
        let shared = UserDefaults(suiteName: suite) ?? .standard
        if let v = shared.string(forKey: key), !v.isEmpty { return v }
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            shared.set(legacy, forKey: key)
            return legacy
        }
        return ""
    }

    static func write(_ value: String, _ key: String) {
        let shared = UserDefaults(suiteName: suite) ?? .standard
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            shared.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            shared.set(trimmed, forKey: key)
            // Also to this app's own defaults, so a build that reads the old
            // way still finds it. Same belt-and-braces `NotionService` uses.
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }
}

/// A secret row, built the way `ClaudeAPIKeySection` is built, because that
/// one has already been through the bugs: `.borderless` on every button (a
/// `Form` row with two buttons gives both of them the row's tap, so Save also
/// ran Cancel and wrote an empty string), and the stored value mirrored in
/// `@State` rather than forced to redraw with an `.id()` that resets the very
/// state driving it.
struct DayflowSecretSection: View {
    let title: String
    let placeholder: String
    let storageKey: String
    let footer: String

    @State private var entry = ""
    @State private var editing = false
    @State private var stored = ""

    private var trimmed: String { entry.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Never the whole thing: enough to know which one is loaded, not enough
    /// to be worth a screenshot.
    private var masked: String {
        guard !stored.isEmpty else { return "Not set" }
        guard stored.count > 12 else { return "Set" }
        return "\(stored.prefix(8))…\(stored.suffix(4))"
    }

    var body: some View {
        Section {
            if editing {
                SecureField(placeholder, text: $entry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Cancel") { entry = ""; editing = false }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("Save") {
                        DayflowSharedSecret.write(entry, storageKey)
                        stored = DayflowSharedSecret.read(storageKey)
                        entry = ""
                        editing = false
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .disabled(trimmed.isEmpty)
                }
            } else {
                LabeledContent("Key") {
                    Text(masked)
                        .foregroundStyle(stored.isEmpty ? Color.red : Color.secondary)
                        .monospaced()
                }
                Button(stored.isEmpty ? "Add key" : "Replace key") {
                    entry = ""; editing = true
                }
                .buttonStyle(.borderless)
                if !stored.isEmpty {
                    Button("Remove key", role: .destructive) {
                        DayflowSharedSecret.write("", storageKey)
                        stored = ""
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
        .onAppear { stored = DayflowSharedSecret.read(storageKey) }
    }
}
