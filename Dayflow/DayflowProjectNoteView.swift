import SwiftUI

// MARK: - DayflowProjectNoteView
//
// View + append screen for a single project note (`Notes/Projects/<title>.md`),
// reached from DayflowNotesView (Session 11, 2026-07-20). Independent of the
// calendar/date flow per David's ask — this is the same NoteStore-backed
// markdown file Trace's own Notes tab already manages under Notes/Projects/,
// just a small Dayflow-specific screen around it, same precedent as
// DayflowDailyNoteEditor.swift for the calendar-day note.
//
// Uses the identical MarkdownEditorView + native (focus-triggered) formatting
// toolbar Daily Note itself uses — David asked for "something close to the
// daily note's own markdown," not a plain text box. Load/save mirrors
// DayflowDailyNoteEditor's header-strip convention exactly, just swapping the
// "# YYYY-MM-DD" date header for "# <title>" (the same header format Trace's
// own NotesView.swift already writes when a project note is created via its
// promote/move-block flows, so a project note edited from either app reads
// consistently).
//
// **Wikilink taps wired 2026-07-20 (Session 13), David asked for this
// directly — "allowing the people and places links to work... thats major."**
// Copied verbatim from DayflowDailyNoteEditor.swift: same NotionService.shared
// people/places lookup, same DayflowWikiSummaryView sheet (the lightweight
// Dayflow-specific read-only stand-in for Trace's real PersonDetailView/
// PlaceDetailView — those two are deliberately out of Dayflow's target per
// David's Session 1 call, see Dayflow-Design-Plan.md "Open questions"; not
// revisited here). [[Person]]/[[Place]] links inside a project note now
// resolve exactly the same way they already do inside the Daily Note.

struct DayflowProjectNoteView: View {
    let title: String
    var onBack: () -> Void

    @State private var content: String = ""
    @State private var isLoading = true
    @State private var wikiLinkTarget: WikiLinkTarget? = nil

    private var relativePath: String { "Notes/Projects/\(title).md" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MarkdownEditorView(
                        text: $content,
                        onSave: { newText in save(newText) },
                        placeholder: "Nothing here yet — start writing.",
                        relativePath: relativePath,
                        onWikiTap: { name in resolveWikiLink(name) },
                        wikiSuggestions: { query in wikiSuggestions(for: query) },
                        // Same reasoning as DayflowDailyNoteEditor: project-note
                        // checkboxes are local-only in Dayflow, no Send to
                        // Things/Tweek menu (that's a Trace-only concept).
                        checklistSendEnabled: false
                    )
                }
            }
        }
        .task { await load() }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                // sourceNoteText: content — Session 28 AI-prefill, same reasoning as
                // DayflowDailyNoteEditor.swift: this is the other of the two note
                // sources the locked design covers.
                DayflowWikiSummaryView(target: target, sourceNoteText: content)
            }
        }
    }

    // MARK: Header — matches the other Dayflow full-screen views (back
    // chevron / centered Georgia title / invisible trailing spacer)

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(title)
                .font(.custom("Georgia", size: 18).weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 8)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Load / save — same "# <title>" header strip/re-add pattern
    // DayflowDailyNoteEditor uses for "# YYYY-MM-DD", and the same pattern
    // Trace's NotesView.swift already writes via promoteBlock()/moveBlock()
    // for project notes created there.

    private func load() async {
        isLoading = true
        let raw = (try? NoteStore.shared.readFile(relativePath)) ?? ""
        content = Self.stripTitleHeader(raw, title: title)
        isLoading = false
    }

    private static func stripTitleHeader(_ text: String, title: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first == "# \(title)" else { return text }
        lines.removeFirst()
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func save(_ text: String) {
        let fileContent = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "# \(title)\n\n\(text)"
        try? NoteStore.shared.writeFile(relativePath, content: fileContent)
    }

    // MARK: Wikilinks — identical logic to DayflowDailyNoteEditor's own
    // wikiSuggestions/resolveWikiLink, just living here too since project
    // notes are a separate editor instance, not a shared one.

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
