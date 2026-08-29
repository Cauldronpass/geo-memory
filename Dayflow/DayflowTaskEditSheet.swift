import SwiftUI
import UIKit

// MARK: - DayflowTaskEditSheet
//
// Edit an existing Things task's title, date, list, and notes — added
// 2026-07-20 after David asked to "modify the name of the task or the date or
// the list by clicking on the text" from the Agenda, Anytime, and Upcoming
// rows. Presented as a `.sheet(item:)` wherever a task row's title is tapped:
// DayflowAgendaSection.swift, DayflowAnytimeView.swift, DayflowUpcomingView.swift,
// DayflowInboxView.swift.
//
// **Notes section added 2026-07-20 (second pass).** David asked for a way to
// add/see a task's description — previously there was no round-trip for this
// at all (`/add` could write notes but nothing ever read them back). Backend
// now sends `notes` on every GET endpoint and accepts it on `/update`; this
// sheet prefills a multi-line text box with the real current notes and saves
// whatever's there, including a deliberate clear to blank (see
// `ThingsService.update(...)`'s doc comment for the nil-vs-empty-string
// convention this relies on).
//
// Reuses DayflowWhenPickerSheet for the date row (kind: .task, so This
// Evening/Someday show). Those two buckets are Things-native concepts the
// Mini's `/update` endpoint can't express (same open question already logged
// for quick-add — see DayflowModels.swift's `isThingsNativeBucket` doc
// comment); picking either here just clears the task's date rather than
// silently no-op'ing or guessing a stand-in date.
//
// List picker is a plain Menu over DayflowThingsAreas.displayNames plus a
// "No List" option — matching the quick-add sheet's chip set. Free-typed list
// names aren't supported here any more than they are there (Dayflow-Design-
// Plan.md "Open questions" — list-name normalization is still unresolved).
//
// Save calls ThingsService.update(taskID:title:date:clearDate:list:), which
// re-fetches Today/Anytime/Upcoming on success since an edit can move a task
// between those buckets. `onSaved` is an additional caller-supplied hook (each
// of the three call sites also refreshes its own local view state).

struct DayflowTaskEditSheet: View {
    let taskID: String
    let initialTitle: String
    let initialDate: Date?
    let initialList: String?
    let initialNotes: String?
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var when: DayflowWhenValue
    @State private var list: String?
    @State private var notes: String
    @State private var showWhenPicker = false
    @State private var isSaving = false
    /// Session 78 — repeat, seeded from the live reminder on appearance
    /// (the init only gets the ThingsTask's `repeats` Bool, not the rule).
    @State private var repeatRule: ReminderTaskStore.DayflowRepeatRule = .none
    @State private var initialRepeatRule: ReminderTaskStore.DayflowRepeatRule = .none
    /// Session 78 — link a person/place: appends their [[wikilink]] to the
    /// notes, which the task rows render as a tappable chip.
    @State private var linkPicker: DayflowTaskLinkKind? = nil
    @State private var showWebLinkEntry = false
    /// Session 78 — the Reminder section (David: "i dont see the reminder
    /// option"). One datetime picker covers both the When card's cases: a
    /// same-day time, or a lead alarm days before the due day.
    @State private var remindOn = false
    @State private var remindAt = Date()
    @State private var initialRemindAt: Date? = nil
    @State private var webLinkText = ""

    /// Repeats need a date to anchor to.
    private var dateless: Bool {
        switch when {
        case .none, .someday, .thisEvening: return true
        case .today, .date: return false
        }
    }
    /// A save the bridge accepted and Things did not keep. See
    /// `ThingsService.lastWriteMismatch`.
    @State private var writeMismatch: String? = nil

    init(taskID: String, initialTitle: String, initialDate: Date?, initialList: String?,
         initialNotes: String? = nil, onSaved: @escaping () -> Void = {}) {
        self.taskID = taskID
        self.initialTitle = initialTitle
        self.initialDate = initialDate
        self.initialList = initialList
        self.initialNotes = initialNotes
        self.onSaved = onSaved
        _title = State(initialValue: initialTitle)
        _when = State(initialValue: initialDate.map { DayflowWhenValue.date($0) } ?? .none)
        _list = State(initialValue: (initialList?.isEmpty ?? true) ? nil : initialList)
        _notes = State(initialValue: initialNotes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Task title", text: $title)
                }

                Section("Date") {
                    Button {
                        showWhenPicker = true
                    } label: {
                        HStack {
                            Text("Date").foregroundStyle(.primary)
                            Spacer()
                            Text(when.label).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("List") {
                    Menu {
                        Button("No List") { list = nil }
                        Divider()
                        ForEach(DayflowThingsAreas.displayNames, id: \.self) { name in
                            Button(name) { list = name }
                        }
                    } label: {
                        HStack {
                            Text("List").foregroundStyle(.primary)
                            Spacer()
                            Text(list ?? "No List").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Reminder") {
                    Toggle("Remind me", isOn: $remindOn)
                        .disabled(dateless)
                    if remindOn {
                        DatePicker("At", selection: $remindAt,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                    if dateless {
                        Text("A reminder needs a date to anchor to.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Repeat") {
                    Menu {
                        ForEach(ReminderTaskStore.DayflowRepeatRule.allCases, id: \.self) { rule in
                            Button(rule.label) { repeatRule = rule }
                        }
                    } label: {
                        HStack {
                            Text("Repeat").foregroundStyle(.primary)
                            Spacer()
                            Text(repeatRule.label).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(dateless && repeatRule == .none)
                    if dateless && repeatRule != .none {
                        Text("A repeat needs a date to anchor to.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Linked") {
                    ForEach(linkedNames, id: \.name) { link in
                        HStack(spacing: 8) {
                            Image(systemName: link.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(link.name)
                            Spacer()
                            Button {
                                removeLink(link.name)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Menu {
                        Button { linkPicker = .person } label: {
                            Label("Person", systemImage: "person")
                        }
                        Button { linkPicker = .place } label: {
                            Label("Place", systemImage: "mappin.and.ellipse")
                        }
                        // Session 78 — David: "what about adding a link to an
                        // external web address...isnt that a third option?"
                        Button { showWebLinkEntry = true } label: {
                            Label("Web address", systemImage: "globe")
                        }
                    } label: {
                        Label("Link a person, place or web address", systemImage: "link")
                            .font(.system(size: 14))
                    }
                }

                // Added 2026-07-20 (second pass) — real read/write round-trip
                // to Things' own notes field, prefilled with whatever's
                // actually there. TextEditor has no built-in placeholder, so
                // one is overlaid manually when empty, matching the pattern
                // DayflowQuickAddSheet's own new Notes row uses.
                if let writeMismatch {
                    Section {
                        Text(writeMismatch)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Notes") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $notes)
                            .frame(minHeight: 90)
                        if notes.isEmpty {
                            Text("Add a note (optional)")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                    // Detected links in the notes text — 2026-07-24, David's
                    // ask, after a screenshot showed a `Shortcuts://` URL
                    // sitting inert in this field (he stores quick-action
                    // shortcut links here). Deliberately a separate row below
                    // the TextEditor, not a tap target inside the actively-
                    // edited text itself — no simulator here to verify a more
                    // invasive approach against, and this way normal
                    // typing/editing is completely untouched.
                    ForEach(detectedLinks, id: \.absoluteString) { url in
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.blue)
                                Text(url.absoluteString)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showWhenPicker) {
                DayflowWhenPickerSheet(kind: .task, currentValue: when) { picked in
                    when = picked
                }
            }
            .sheet(item: $linkPicker) { kind in
                DayflowTaskLinkPicker(kind: kind) { name in
                    appendLink(name)
                }
            }
            .alert("Web address", isPresented: $showWebLinkEntry) {
                TextField("example.com/page", text: $webLinkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Add") {
                    appendWebLink(webLinkText)
                    webLinkText = ""
                }
                // One tap even on the phone (and immune to the Simulator's
                // separate clipboard, which ate David's first paste): reads
                // the pasteboard directly. iOS shows its paste-permission
                // banner the first time — expected.
                Button("Paste & Add") {
                    appendWebLink(UIPasteboard.general.string ?? "")
                    webLinkText = ""
                }
                Button("Cancel", role: .cancel) { webLinkText = "" }
            }
            .task {
                let current = ReminderTaskStore.shared.repeatRule(taskID: taskID)
                repeatRule = current
                initialRepeatRule = current
                if let alarm = ReminderTaskStore.shared.remindDate(taskID: taskID) {
                    remindOn = true
                    remindAt = alarm
                    initialRemindAt = alarm
                } else if let due = initialDate {
                    // Seed the picker somewhere sensible for a fresh toggle:
                    // 9 AM on the due day, the When card's first chip.
                    remindAt = Calendar.current.date(
                        bySettingHour: 9, minute: 0, second: 0, of: due) ?? due
                }
            }
        }
    }

    // MARK: Linked people/places (Session 78)

    private var linkedNames: [(name: String, icon: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        var rest = Substring(notes)
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]"),
              open.upperBound <= close.lowerBound {
            let name = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            rest = rest[close.upperBound...]
            guard !name.isEmpty, !name.hasPrefix("visit:"), seen.insert(name).inserted else { continue }
            let isPlace = NotionService.shared.places.contains { $0.name == name }
            out.append((name, isPlace ? "mappin.and.ellipse" : "person"))
        }
        return out
    }

    /// A bare host gets https:// — URLs in notes are detected by their
    /// scheme, on the row chip and in this sheet both.
    private func appendWebLink(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = trimmed.contains("://") ? trimmed : "https://" + trimmed
        notes = notes.isEmpty ? url : notes + "\n" + url
    }

    private func appendLink(_ name: String) {
        guard !notes.contains("[[\(name)]]") else { return }
        notes = notes.isEmpty ? "[[\(name)]]" : notes + "\n[[\(name)]]"
    }

    private func removeLink(_ name: String) {
        notes = notes
            .replacingOccurrences(of: "\n[[\(name)]]", with: "")
            .replacingOccurrences(of: "[[\(name)]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Link detection

    /// Every distinct `scheme://...` token in `notes`, in the order they
    /// first appear. Deliberately a plain whitespace-split + `URL(string:)`
    /// scan rather than `NSDataDetector` — `NSDataDetector`'s `.link` type is
    /// tuned toward recognizable real-world schemes (http/https/mailto/tel),
    /// and whether it reliably recognizes an arbitrary custom app scheme like
    /// `Shortcuts://` isn't something this environment can verify without a
    /// simulator. A direct `URL(string:)` parse succeeds for any well-formed
    /// `scheme://...` string regardless of whether the scheme is "known," so
    /// it's the safer bet for the exact case David hit.
    private var detectedLinks: [URL] {
        var seen = Set<String>()
        var links: [URL] = []
        for token in notes.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            guard token.contains("://"),
                  let url = URL(string: String(token)),
                  let scheme = url.scheme, !scheme.isEmpty
            else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            links.append(url)
        }
        return links
    }

    private func save() {
        isSaving = true
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let clearDate: Bool
        let date: Date?
        switch when {
        case .none:
            clearDate = true
            date = nil
        case .date(let d):
            clearDate = false
            date = d
        case .today:
            clearDate = false
            date = Date()
        case .thisEvening, .someday:
            // Things-native buckets /update can't express — clear rather than
            // silently no-op or fake a stand-in date. See header comment.
            clearDate = true
            date = nil
        }

        // Always passed (never nil) — see ThingsService.update()'s doc comment.
        // Trimmed so trailing/leading whitespace-only edits don't register as
        // "notes changed" when they're really just accidental taps.
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reminder deltas (Session 78): a set/changed alarm rides remindAt;
        // switching the toggle off rides clearRemind. Untouched = both nil,
        // the store's carry-the-alarm redate behavior applies as before.
        let remindChanged = remindOn ? (initialRemindAt != remindAt) : (initialRemindAt != nil)
        let remindArg: Date? = (remindOn && remindChanged) ? remindAt : nil
        let clearRemindArg = !remindOn && initialRemindAt != nil
        Task {
            let success = await ReminderTaskStore.shared.update(
                taskID: taskID, title: trimmedTitle, date: date, clearDate: clearDate,
                list: list, notes: trimmedNotes,
                remindAt: remindArg, clearRemind: clearRemindArg
            )
            // Repeat is its own write, only when it changed — and only with
            // a date to anchor to (the reminder without one would produce a
            // rule Reminders can't fire).
            if success, repeatRule != initialRepeatRule, !clearDate {
                _ = await ReminderTaskStore.shared.setRepeat(taskID: taskID, rule: repeatRule)
            }
            await MainActor.run {
                isSaving = false
                if success {
                    writeMismatch = nil
                    onSaved()
                    dismiss()
                } else {
                    // **The sheet stays open and now says why.** Before this it
                    // stayed open and said nothing, which reads as a save that
                    // is still thinking. `lastWriteMismatch` is set only when
                    // the bridge reported success and the value did not take;
                    // any other failure keeps the generic line.
                    writeMismatch = ReminderTaskStore.shared.lastWriteMismatch
                        ?? (ReminderTaskStore.shared.lastError ?? "Reminders did not accept the change.")
                    ReminderTaskStore.shared.lastWriteMismatch = nil
                }
            }
        }
    }
}

// MARK: - Link picker (Session 78)

enum DayflowTaskLinkKind: String, Identifiable {
    case person, place
    var id: String { rawValue }
}

/// A minimal searchable name list — deliberately simpler than the Related
/// Notes flow's candidate picker (no description step: a task link is just
/// the chip; the WHY lives in the task title itself).
struct DayflowTaskLinkPicker: View {
    let kind: DayflowTaskLinkKind
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var names: [String] {
        let all: [String]
        switch kind {
        case .person:
            all = NotionService.shared.people.filter { !$0.isArchived }.map(\.name)
        case .place:
            all = NotionService.shared.places.map(\.name)
        }
        let sorted = all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(names, id: \.self) { name in
                Button {
                    onPick(name)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: kind == .person ? "person" : "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(name).foregroundStyle(.primary)
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle(kind == .person ? "Link a Person" : "Link a Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
