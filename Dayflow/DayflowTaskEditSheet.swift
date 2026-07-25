import SwiftUI

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

                // Added 2026-07-20 (second pass) — real read/write round-trip
                // to Things' own notes field, prefilled with whatever's
                // actually there. TextEditor has no built-in placeholder, so
                // one is overlaid manually when empty, matching the pattern
                // DayflowQuickAddSheet's own new Notes row uses.
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
        }
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

        Task {
            let success = await ThingsService.shared.update(
                taskID: taskID, title: trimmedTitle, date: date, clearDate: clearDate,
                list: list, notes: trimmedNotes
            )
            await MainActor.run {
                isSaving = false
                if success {
                    onSaved()
                    dismiss()
                }
            }
        }
    }
}
