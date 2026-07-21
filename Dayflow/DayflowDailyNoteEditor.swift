import SwiftUI

// MARK: - DayflowDailyNoteEditor
//
// Dayflow-Design-Plan.md "Daily Note section" (build order step 4). This is
// the shared load/save/wikilink core, reused by both surfaces the design
// plan calls for:
//   - DayflowDailyNoteSection — the bounded, internally-scrollable card on
//     the main screen (caller applies a fixed `.frame(height:)`).
//   - DayflowNoteFullPageView — the full-page expand view (caller lets this
//     fill all remaining space instead).
// Factored out as its own view (rather than duplicating load/save/wiki logic
// in both callers) since the two surfaces are explicitly "same note, same
// text" per the design plan — only the chrome around it differs.
//
// Backend: NoteStore.shared's markdown-file API (readDailyNote/writeFile),
// confirmed during research as the correct backend — NOT DayNoteSheet.swift's
// Notion-backed DayNote system, which is a different, unrelated Trace
// feature that happens to have a similar name.
//
// Formatting toolbar: MarkdownEditorView.swift attaches its own toolbar as a
// native `UITextView.inputAccessoryView` — it appears above the keyboard
// only while the field is focused, exactly like Trace's own NotesView.swift
// usage. The mockup's HTML shows the toolbar as a permanently-visible strip
// under the note body, but that's a static-HTML demo simplification (no real
// keyboard to attach to); the design plan explicitly says this toolbar is
// "not new work" and should be reused "as-is" from MarkdownEditorView.swift,
// so its real (focus-triggered) behavior is what Dayflow gets too. Logged
// here rather than silently guessed at, per David's ground-truth-vs-mockup
// rule — see Dayflow-HANDOFF.md Session 5.
//
// Wikilink taps: PersonDetailView.swift/PlaceDetailView.swift are not in
// Dayflow's target (too entangled with Trace's check-in/visit/billiards
// stack — see Dayflow-Design-Plan.md "Open questions"). Taps resolve to the
// small Dayflow-specific read-only DayflowWikiSummaryView instead, flagged
// as the plan for exactly this situation.

struct DayflowDailyNoteEditor: View {
    let date: Date

    @State private var content: String = ""
    @State private var isLoading = true
    @State private var wikiLinkTarget: WikiLinkTarget? = nil

    private var relativePath: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return "Calendar/\(f.string(from: date)).md"
    }

    var body: some View {
        Group {
            if !NoteStore.shared.hasAccess {
                Text("Vault not linked yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownEditorView(
                    text: $content,
                    onSave: { newText in save(newText) },
                    placeholder: "Nothing here yet — start writing.",
                    relativePath: relativePath,
                    onWikiTap: { name in resolveWikiLink(name) },
                    wikiSuggestions: { query in wikiSuggestions(for: query) },
                    // Dayflow's Daily Note checkboxes are always local-only — no
                    // Send to Things/Tweek menu (that's a Trace-only concept).
                    // Fixed 2026-07-19 after David hit the menu in testing.
                    checklistSendEnabled: false
                )
            }
        }
        .task(id: date) { await load() }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                // sourceNoteText: content — Session 28 AI-prefill. The Daily Note is
                // one of the two note sources the locked design covers; passing the
                // live in-memory text lets the hand-off buttons on the presented
                // card search it without a re-read from disk.
                DayflowWikiSummaryView(target: target, sourceNoteText: content)
            }
        }
    }

    // MARK: Load / save
    //
    // Same pattern as Trace's NotesView.swift E15 daily-note load/save (strip
    // the "# YYYY-MM-DD" header for editing, re-add it on write) — minus the
    // calendar-panel-preview and clear-note extras that view also has, which
    // Dayflow doesn't need for this pass.

    private func load() async {
        isLoading = true
        let raw = (try? NoteStore.shared.readDailyNote(date: date)) ?? ""
        content = Self.stripDateHeader(raw)
        isLoading = false
    }

    private static func stripDateHeader(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.hasPrefix("# "),
              first.dropFirst(2).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return text }
        lines.removeFirst()
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func save(_ text: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        let dateStr = f.string(from: date)
        let fileContent = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "# \(dateStr)\n\n\(text)"
        try? NoteStore.shared.writeFile("Calendar/\(dateStr).md", content: fileContent)
    }

    // MARK: Wikilinks — Places + People from the shared NotionService.shared
    // singleton (already shared with Trace per the design plan). Same
    // matching logic as NotesView.swift's own wikiSuggestions/resolveWikiLink,
    // just resolving to DayflowWikiSummaryView instead of the real
    // PlaceDetailView/PersonDetailView sheets.

    private func wikiSuggestions(for query: String) -> [(name: String, isPlace: Bool)] {
        let q = query.lowercased()
        var results: [(name: String, isPlace: Bool)] = []
        let placeMatches = NotionService.shared.places
            .map { $0.name }
            .filter { q.isEmpty || $0.lowercased().contains(q) }
            .sorted()
            .map { (name: $0, isPlace: true) }
        results.append(contentsOf: placeMatches)
        let peopleMatches = NotionService.shared.people
            .map { $0.name }
            .filter { name in
                (q.isEmpty || name.lowercased().contains(q)) &&
                !results.contains(where: { $0.name == name })
            }
            .sorted()
            .map { (name: $0, isPlace: false) }
        results.append(contentsOf: peopleMatches)
        return Array(results.prefix(8))
    }

    private func resolveWikiLink(_ name: String) {
        if let place = NotionService.shared.places.first(where: { $0.name == name }) {
            wikiLinkTarget = .place(place)
        } else if let person = NotionService.shared.people.first(where: { $0.name == name }) {
            wikiLinkTarget = .person(person)
        }
    }
}
