import SwiftUI

// MARK: - DayflowNotesView
//
// Reached via Daily Note's third header icon (DayflowDailyNoteSection.swift,
// Session 11, 2026-07-20). One screen doing double duty, per David's own
// framing during the design conversation that preceded this build: a
// keyword/#tag search over NoteStore's Daily/Projects/Places files (ported
// from Trace's own GlobalSearchView in NotesView.swift — same folder scan,
// same token-matching rules, restyled to Dayflow's minimal look), and —
// since a Projects-scope search with nothing typed is really just "browse
// your project notes" — the same screen is also where a new project note
// gets created and where an existing one is opened for view/append
// (DayflowProjectNoteView).
//
// Deliberately does NOT reuse Trace's real GlobalSearchView/NotesView.swift
// UI — same precedent as DayflowWikiSummaryView.swift (Session 5): read the
// same NoteStore data, build a small Dayflow-specific view around it, so
// Trace's own Notes-tab machinery (tag filter chips, promote/move blocks,
// Horizons, document attachments) never has to enter Dayflow's target.
// "Horizons" scope is intentionally left out — it's a Trace weekly/monthly-
// review concept never part of Dayflow's design, no reason to surface it
// here just because the underlying folder scan could technically include it.
//
// Agenda/task search (Things tasks + calendar events) is a separate screen,
// DayflowAgendaSearchView, reached from the top-bar Browse menu instead —
// see that file's header comment and Dayflow-Design-Plan.md "Notes & Agenda
// search" for why these stayed two screens rather than one.
//
// **Daily/Places result rows made tappable — Session 19, 2026-07-20.** David
// found a Daily Note via search ("test wed") and reported it wasn't
// clickable — the original build deliberately left Daily/Places as no-ops
// per this file's own comment ("no dedicated Dayflow detail view exists for
// those yet"), flagged in Session 11's "not done" list. That's no longer
// true: Session 17 built out DayflowWikiSummaryView's Place Notes tab, and
// the full-page Daily Note editor has existed since Session 4/5 — both
// destinations already exist, this was just never wired up. Daily results
// now jump straight to DayflowNoteFullPageView for that exact date (parsed
// from the filename, `Calendar/YYYY-MM-DD.md`); Places results resolve the
// matching `Place` (via `NoteStore.placeNoteFilename` reverse-match against
// `NotionService.shared.places`) and open it in DayflowWikiSummaryView,
// same as tapping a [[Place]] wikilink anywhere else. Project rows were
// already tappable and are unchanged. `selectedDate` is now threaded in from
// ContentView (`$selectedDate`) rather than being its own separate value —
// same "share the one real date, don't seed a copy" fix as
// DayflowNoteFullPageView.swift's own Session 18 header comment — so jumping
// to a Daily search result also moves Agenda/the main Daily Note card to
// that date, consistent with every other date-jump in the app.

struct DayflowNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDate: Date
    @State private var showDailyNote = false
    @State private var wikiLinkTarget: WikiLinkTarget? = nil

    private enum Scope: String, CaseIterable, Identifiable {
        case all = "All", daily = "Daily", projects = "Projects", places = "Places"
        var id: String { rawValue }

        var subfolders: [(label: String, path: String)] {
            switch self {
            case .all:      return [("Daily", "Calendar"), ("Projects", "Notes/Projects"), ("Places", "Notes/Places")]
            case .daily:    return [("Daily", "Calendar")]
            case .projects: return [("Projects", "Notes/Projects")]
            case .places:   return [("Places", "Notes/Places")]
            }
        }
    }

    private struct SearchResult: Identifiable {
        let id = UUID()
        let subfolder: String
        let displayName: String
        let scopeLabel: String
        let snippet: String
    }

    @State private var searchText = ""
    @State private var scope: Scope = .all
    @State private var results: [SearchResult] = []
    @State private var projectNames: [String] = []
    @State private var selectedProjectTitle: String? = nil
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""

    private let noteStore = NoteStore.shared

    var body: some View {
        Group {
            if let title = selectedProjectTitle {
                DayflowProjectNoteView(title: title, onBack: {
                    selectedProjectTitle = nil
                    loadProjectNames()
                })
            } else {
                mainBody
            }
        }
        .alert("New Project Note", isPresented: $showNewProjectAlert) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) { newProjectName = "" }
            Button("Create") { createProject() }
        }
        .onChange(of: searchText) { _, _ in runSearch() }
        .onChange(of: scope) { _, _ in runSearch() }
        .onAppear { loadProjectNames() }
        .fullScreenCover(isPresented: $showDailyNote) {
            DayflowNoteFullPageView(selectedDate: $selectedDate)
        }
        .sheet(item: $wikiLinkTarget) { target in
            NavigationStack {
                DayflowWikiSummaryView(target: target)
            }
        }
    }

    private var mainBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            scopeRow
            newProjectRow
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        browseContent
                    } else if results.isEmpty {
                        Text("No notes match \"\(searchText)\".")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    } else {
                        ForEach(results) { r in resultRow(r) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: Header — matches DayflowAnytimeView's Browse-destination header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Notes").font(.custom("Georgia", size: 20).weight(.bold))
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notes, #tags…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.quaternarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var scopeRow: some View {
        HStack(spacing: 6) {
            ForEach(Scope.allCases) { s in
                Button { scope = s } label: {
                    Text(s.rawValue)
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(scope == s ? Color.blue : Color(.quaternarySystemFill), in: Capsule())
                        .foregroundStyle(scope == s ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var newProjectRow: some View {
        Button {
            newProjectName = ""
            showNewProjectAlert = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                Text("New project note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.blue.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: Browse (no search text — project list only; Daily/Places have no
    // Dayflow-side browse list yet, same "don't build a target that doesn't
    // exist" rule as the calendar-event rows elsewhere in the app)

    @ViewBuilder
    private var browseContent: some View {
        if !projectNames.isEmpty {
            Text("PROJECT NOTES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ForEach(projectNames, id: \.self) { name in
                projectRow(name)
            }
        } else {
            Text("No project notes yet — tap \"New project note\" above to start one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        }
    }

    @ViewBuilder
    private func projectRow(_ name: String) -> some View {
        Button { selectedProjectTitle = name } label: {
            HStack {
                Text(name).font(.system(size: 13.5)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        Divider()
    }

    // MARK: Result row (search mode)

    @ViewBuilder
    private func resultRow(_ r: SearchResult) -> some View {
        Button {
            openResult(r)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(r.displayName).font(.system(size: 13.5)).foregroundStyle(.primary)
                    Spacer()
                    Text(r.scopeLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.75)))
                }
                if !r.snippet.isEmpty {
                    Text(r.snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        Divider()
    }

    /// Dispatches a tapped search result to whichever detail view already
    /// exists for its subfolder — see this file's Session 19 header comment.
    /// Projects: unchanged, sets `selectedProjectTitle` (handled by `body`'s
    /// own `Group` switch). Calendar (Daily): parses the filename back into a
    /// `Date` (same "yyyy-MM-dd" / en_US_POSIX / TimeZone.current pattern
    /// `DayflowDailyNoteEditor` uses to go the other direction) and opens
    /// `DayflowNoteFullPageView` on that date via the shared `selectedDate`
    /// binding. Places: reverse-matches the filename against
    /// `NoteStore.placeNoteFilename(for:)` over `NotionService.shared.places`
    /// to recover the actual `Place`, then opens it the same way a [[Place]]
    /// wikilink does. If a Calendar date fails to parse or a Place can't be
    /// matched (shouldn't happen — both are round-trips of values this view
    /// itself produced), this silently no-ops rather than crashing; nothing
    /// else in the row implies a destination exists in that case.
    private func openResult(_ r: SearchResult) {
        switch r.subfolder {
        case "Notes/Projects":
            selectedProjectTitle = r.displayName
        case "Calendar":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            if let parsed = formatter.date(from: r.displayName) {
                selectedDate = parsed
                showDailyNote = true
            }
        case "Notes/Places":
            if let place = NotionService.shared.places.first(where: {
                noteStore.placeNoteFilename(for: $0.name) == r.displayName
            }) {
                wikiLinkTarget = .place(place)
            }
        default:
            break
        }
    }

    // MARK: Data

    private func loadProjectNames() {
        let files = (try? noteStore.listFiles(in: "Notes/Projects")) ?? []
        projectNames = files.map { $0.replacingOccurrences(of: ".md", with: "") }
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = "Notes/Projects/\(name).md"
        let existing = (try? noteStore.readFile(path)) ?? ""
        if existing.isEmpty {
            try? noteStore.writeFile(path, content: "# \(name)\n\n")
        }
        loadProjectNames()
        newProjectName = ""
        selectedProjectTitle = name
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { results = []; return }
        let tokens = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let tagTokens = tokens.filter { $0.hasPrefix("#") }.map { String($0.dropFirst()).lowercased() }
        let plainTokens = tokens.filter { !$0.hasPrefix("#") }.map { $0.lowercased() }

        var found: [SearchResult] = []
        for (label, path) in scope.subfolders {
            let files = (try? noteStore.listFiles(in: path)) ?? []
            for filename in files {
                guard filename.hasSuffix(".md") else { continue }
                let content = (try? noteStore.readFile("\(path)/\(filename)")) ?? ""
                let contentLower = content.lowercased()
                let nameLower = filename.replacingOccurrences(of: ".md", with: "").lowercased()

                let tagsMatch = tagTokens.allSatisfy { contentLower.contains("#\($0)") }
                let plainMatch = plainTokens.allSatisfy { nameLower.contains($0) || contentLower.contains($0) }
                guard tagsMatch && plainMatch else { continue }

                found.append(SearchResult(
                    subfolder: path,
                    displayName: filename.replacingOccurrences(of: ".md", with: ""),
                    scopeLabel: label,
                    snippet: snippet(from: content, tokens: plainTokens + tagTokens.map { "#\($0)" })
                ))
            }
        }
        results = found
    }

    private func snippet(from content: String, tokens: [String]) -> String {
        let lines = content.components(separatedBy: "\n")
        for token in tokens where !token.isEmpty {
            if let line = lines.first(where: { $0.lowercased().contains(token) }) {
                return String(line.trimmingCharacters(in: .whitespaces).prefix(120))
            }
        }
        return String((lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "").prefix(120))
    }
}
