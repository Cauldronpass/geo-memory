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
    /// Session 81 (D227's iOS half) — document links. Parsed off the live
    /// `notes` text, resolved against the shared chip store the way the
    /// person/place chips resolve against Notion. No cached titles.
    @State private var chipStore = TraceSatchelChipStore.shared
    @State private var showDocPicker = false
    @State private var satchelUnavailable = false
    /// Session 81 (D239) — the SHORTCUT row's rename/add entry.
    @State private var showShortcutEntry = false
    @State private var shortcutText = ""

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
                    // Session 81 — the D227 document links, resolved live
                    // against the document store. A path the store cannot
                    // resolve renders "(missing)", refuses to navigate, and
                    // still offers removal — same contract as the Mac chip.
                    ForEach(linkedDocumentPaths, id: \.self) { docPath in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button {
                                openDocument(docPath)
                            } label: {
                                Text(documentTitle(for: docPath))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                removeDocumentLink(docPath)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Session 81 (D239) — the SHORTCUT row: the decoded name,
                    // never the raw URL (the name is the only part carrying
                    // information; the rest is boilerplate). Tap runs it;
                    // Change renames it KEEPING every other query item
                    // (rewrittenShortcutURL); the xmark removes it.
                    if shortcutURL != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button {
                                if let url = shortcutURL { UIApplication.shared.open(url) }
                            } label: {
                                Text(shortcutName ?? "Run shortcut")
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button("Change") {
                                shortcutText = shortcutName ?? ""
                                showShortcutEntry = true
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                            Button {
                                removeShortcut()
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
                        // Session 81 — the fourth kind (D227): a Satchel
                        // document, linked by PATH via a marker line.
                        Button { showDocPicker = true } label: {
                            Label("Document", systemImage: "doc.text")
                        }
                        // Offered only when there is none — a task carries at
                        // most one shortcut, and the row's Change is the door
                        // once it exists (the Mac card's rule).
                        if shortcutURL == nil {
                            Button {
                                shortcutText = ""
                                showShortcutEntry = true
                            } label: {
                                Label("Shortcut", systemImage: "bolt")
                            }
                        }
                    } label: {
                        Label("Link a person, place, document or web address", systemImage: "link")
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
                // Session 78 round 3 (David, off TestFlight: "Clicking the
                // date in any task edit gives me a different experience than
                // the nice feeling I get from the main screens. Its a week
                // at a time and the view doesnt match") — the old week-paged
                // DayflowWhenPickerSheet is retired from here; this is the
                // app's own month language: Today/Tomorrow rows, then the
                // same grid the masthead unfolds.
                DayflowDatePickSheet(current: when) { picked in
                    when = picked
                }
            }
            .sheet(item: $linkPicker) { kind in
                DayflowTaskLinkPicker(kind: kind) { name in
                    appendLink(name)
                }
            }
            .sheet(isPresented: $showDocPicker) {
                DayflowTaskDocumentPicker { docPath in
                    appendDocumentLink(docPath)
                }
            }
            .alert("Satchel isn't installed", isPresented: $satchelUnavailable) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("This document lives in Satchel, the documents app. Install it on this device to open it.")
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
            .alert("Shortcut", isPresented: $showShortcutEntry) {
                TextField("Shortcut name", text: $shortcutText)
                Button("Save") {
                    applyShortcutName(shortcutText)
                    shortcutText = ""
                }
                Button("Cancel", role: .cancel) { shortcutText = "" }
            } message: {
                Text("The shortcut's name, as it appears in the Shortcuts app. Leave empty to remove it from this task.")
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
                // Session 81 — after the synchronous seeding, so the repeat
                // and reminder rows never wait on a sidecar sweep. Loaded
                // here so a task opened before any note screen has populated
                // the store still resolves titles rather than "(missing)".
                await chipStore.loadIfNeeded()
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

    // MARK: Linked documents (Session 81, D227's iOS half)

    /// The `satchel:doc:` marker lines in the notes text, in order, deduped.
    /// Parsed off `notes` (the live edit), not the task, so a document added
    /// in this visit shows its row before Save.
    private var linkedDocumentPaths: [String] {
        var seen = Set<String>()
        return notes.split(separator: "\n").compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix(ThingsTask.documentMarkerPrefix) else { return nil }
            let docPath = String(s.dropFirst(ThingsTask.documentMarkerPrefix.count))
            guard !docPath.isEmpty, seen.insert(docPath).inserted else { return nil }
            return docPath
        }
    }

    /// Live resolution, no cached title — the D227 rule: a chip displaying
    /// one name while pointing at another is worse than one that briefly
    /// says nothing.
    private func documentTitle(for docPath: String) -> String {
        chipStore.all.first { $0.relativePath == docPath }?.title ?? "(missing)"
    }

    private func openDocument(_ docPath: String) {
        guard chipStore.all.contains(where: { $0.relativePath == docPath }),
              let url = TraceSatchelHandoff.documentURL(path: docPath) else { return }
        UIApplication.shared.open(url, options: [:]) { accepted in
            if !accepted { satchelUnavailable = true }
        }
    }

    /// Appended at the end, after whatever prose is there — the composer's
    /// prose-before-machinery order, kept by hand here because this sheet
    /// edits the raw notes text.
    private func appendDocumentLink(_ docPath: String) {
        let marker = ThingsTask.documentMarkerPrefix + docPath
        guard !notes.contains(marker) else { return }
        notes = notes.isEmpty ? marker : notes + "\n" + marker
    }

    private func removeDocumentLink(_ docPath: String) {
        let marker = ThingsTask.documentMarkerPrefix + docPath
        notes = notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != marker }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Shortcut (Session 81, D239 — the Mac card's treatment)

    /// The shortcut token's range in the live notes text — from the scheme
    /// (any case; RFC 3986, and David's own note reads `Shortcuts://`) to the
    /// first whitespace. The token may share a line with prose, so edits
    /// replace the TOKEN, never the line.
    private var shortcutTokenRange: Range<String.Index>? {
        guard let start = notes.range(of: ThingsTask.shortcutScheme, options: .caseInsensitive)
        else { return nil }
        let token = notes[start.lowerBound...].prefix { !$0.isWhitespace && $0 != "\"" }
        return start.lowerBound..<token.endIndex
    }

    private var shortcutURL: URL? {
        guard let r = shortcutTokenRange else { return nil }
        let raw = notes[r]
        // Lowercase the scheme before building the URL — `URL` keeps whatever
        // case it is given, and not every opener is as forgiving as the spec.
        let normalised = ThingsTask.shortcutScheme + raw.dropFirst(ThingsTask.shortcutScheme.count)
        return URL(string: String(normalised))
    }

    private var shortcutName: String? {
        guard let url = shortcutURL,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        return items.first(where: { $0.name == "name" })?.value
    }

    /// Renaming KEEPS every other query item (`&input=`, `&text=`) — the Mac
    /// card's rewrittenShortcutURL, same reasoning: a Shortcuts URL can carry
    /// more than a name, and rebuilding from the name alone silently drops it
    /// the first time such a shortcut is renamed.
    private func rewrittenShortcutURL(name: String) -> String {
        let encodedFallback = name.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? name
        let plain = "\(ThingsTask.shortcutScheme)run-shortcut?name=\(encodedFallback)"
        guard let url = shortcutURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return plain }
        var items = (parts.queryItems ?? []).filter { $0.name != "name" }
        items.insert(URLQueryItem(name: "name", value: name), at: 0)
        parts.queryItems = items
        return parts.string ?? plain
    }

    /// Empty name removes; otherwise the token is rewritten in place, or
    /// appended after the prose when there is none.
    private func applyShortcutName(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            removeShortcut()
            return
        }
        let rewritten = rewrittenShortcutURL(name: name)
        if let r = shortcutTokenRange {
            notes.replaceSubrange(r, with: rewritten)
        } else {
            notes = notes.isEmpty ? rewritten : notes + "\n" + rewritten
        }
    }

    private func removeShortcut() {
        guard let r = shortcutTokenRange else { return }
        notes.removeSubrange(r)
        notes = notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
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
            // The shortcut is the SHORTCUT row's job (Session 81, D239): its
            // name shows and runs there, and a second row spelling the raw
            // URL is the redundancy that row exists to remove.
            guard !ThingsTask.isShortcutLine(token) else { continue }
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
    /// Session 78 — David: the cursor should land in the search field so he
    /// can just type. (His screenshot was THIS picker, not the Related Notes
    /// one, which got the same fix separately — two pickers, two fixes.)
    @FocusState private var searchFocused: Bool

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
            .searchFocused($searchFocused)
            .navigationTitle(kind == .person ? "Link a Person" : "Link a Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    searchFocused = true
                }
            }
        }
    }
}

// MARK: - Date pick sheet (Session 78 round 3)
//
// The edit sheet's Date row, in the app's own calendar language:
// Today (sun) / Tomorrow (sunrise) / Clear (slash) rows over the SAME month
// grid the Today masthead unfolds (DayflowMonthUnfold, note and pin dots
// included). Replaces DayflowWhenPickerSheet here — its week-at-a-time view
// was the last date surface out of step with the skin.

struct DayflowDatePickSheet: View {
    let current: DayflowWhenValue
    var onPick: (DayflowWhenValue) -> Void
    @Environment(\.dismiss) private var dismiss

    private var currentDate: Date {
        switch current {
        case .date(let d): return d
        case .today: return Date()
        default: return Date()
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("WHEN")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Color.dayflowInk)
                    .padding(.bottom, 6)
                Rectangle().fill(Color.dayflowInk).frame(height: 1)
                quickRow("Today", systemImage: "sun.max") { pick(.today) }
                hairline
                quickRow("Tomorrow", systemImage: "sunrise") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    pick(.date(Calendar.current.startOfDay(for: tomorrow)))
                }
                hairline
                DayflowMonthUnfold(selectedDate: currentDate, onPick: { day in
                    pick(.date(day))
                }, hint: "tap a day to set it")
                quickRow("Clear date", systemImage: "slash.circle",
                         tint: Color.dayflowAccent) { pick(.none) }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.height(600), .large])
        .presentationBackground(Color.dayflowPaper)
    }

    private func pick(_ value: DayflowWhenValue) {
        UISelectionFeedbackGenerator().selectionChanged()
        onPick(value)
        dismiss()
    }

    private var hairline: some View {
        Rectangle().fill(Color.dayflowHairline).frame(height: 1)
    }

    private func quickRow(_ label: String, systemImage: String,
                          tint: Color = .dayflowInk,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(label)
                    .font(.dayflowSerif(16))
                Spacer()
            }
            .foregroundStyle(tint)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Document picker (Session 81, D227's iOS half)

/// Satchel documents, newest first — the linking case is nearly always a
/// document scanned minutes ago, so the one he wants is already on top and
/// the common path needs no search at all (which is also why the search
/// field does NOT autofocus here, unlike the person/place picker: raising
/// the keyboard would cover the list the common path never types into).
/// Single-pick, like the pickers beside it; reopen to add another.
struct DayflowTaskDocumentPicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var chipStore = TraceSatchelChipStore.shared

    private var documents: [TraceMacDocument] {
        let sorted = chipStore.all.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(documents, id: \.relativePath) { doc in
                Button {
                    onPick(doc.relativePath)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(doc.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        if let created = doc.created {
                            Text(created, format: .dateTime.month(.abbreviated).day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Link a Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await chipStore.loadIfNeeded() }
        }
    }
}
