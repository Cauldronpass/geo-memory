// TraceMacSearchPanel.swift
// ⌘K. One field over everything — notes, Satchel, People, Places, Endeavors.
// Mac-only — do not add to iOS, Widget, or Share Extension targets.
//
// The entry point the app has never had. TraceMac has 25 search fields and all
// but one of them match names, in the one list that was already showing the
// thing. This searches bodies, and it searches from anywhere.
//
// ── The two loads this panel must not lie about ───────────────────────────
//
// Notes are on disk; People and Places come from Notion into memory at launch.
// A search run before either has landed finds nothing and **says nothing is
// there**, which is indistinguishable from the record not existing. The spec
// names the Notion half (§6, *"do not ship this half"*); the container half is
// the same bug and is not in the spec, because `NoteStore.hasAccess` is false
// for the first moment of every launch too. Both are handled here, and a
// *failed* load says failed rather than sitting on a spinner that never stops.
//
// This is the fourth appearance of this shape in the project — `resolveGeofencePlace`,
// `resolvePendingCheckIn`, D83, and now search.

import SwiftUI

struct TraceMacSearchPanel: View {

    @Binding var isPresented: Bool
    /// Called with the chosen destination, and the query that found it, once
    /// the panel has closed itself. Routing lives in `TraceMacContentView`,
    /// which owns the pending-link bindings; this view only says where.
    ///
    /// The query rides along so the PDF viewer can paint the term on the page
    /// rather than only in the result row. It is the search text verbatim —
    /// splitting it into terms is `MacSearchEngine`'s job and is done again at
    /// the other end, from the same function, so the two cannot drift.
    var onOpen: (MacSearchDestination, String) -> Void

    @Environment(NoteStore.self)     private var noteStore
    @Environment(NotionService.self) private var notionService

    @State private var query = ""
    @State private var corpus = MacSearchCorpus()
    @State private var documents: [TraceMacDocument] = []
    @State private var results: [MacSearchResult] = []
    @State private var expanded: Set<MacSearchKind> = []
    @State private var selection = 0
    @State private var preview: MacSearchResult? = nil
    @State private var previewText = ""
    @FocusState private var fieldFocused: Bool

    // MARK: Derived

    private var groups: [MacSearchGroup] {
        MacSearchEngine.grouped(results)
    }

    /// The rows actually on screen, in the order they are drawn. Arrow keys and
    /// Return both index into this and nothing else, so the keyboard can never
    /// select a row that is hidden behind a "N more".
    private var visible: [MacSearchResult] {
        groups.flatMap { group in
            expanded.contains(group.kind)
                ? group.items
                : Array(group.items.prefix(MacSearchEngine.groupLimit))
        }
    }

    /// What is still arriving, or what failed. `nil` when everything is in.
    private var notice: String? {
        var waiting: [String] = []
        var failed: [String] = []

        if !noteStore.hasAccess { waiting.append("your notes") }
        switch notionService.peopleLoad {
        case .loaded: break
        case .failed: failed.append("People")
        case .idle, .loading: waiting.append("People")
        }
        switch notionService.placesLoad {
        case .loaded: break
        case .failed: failed.append("Places")
        case .idle, .loading: waiting.append("Places")
        }

        var parts: [String] = []
        if !waiting.isEmpty { parts.append("Still loading \(list(waiting)) — results are incomplete.") }
        if !failed.isEmpty  { parts.append("\(list(failed)) could not be loaded, so \(failed.count == 1 ? "it is" : "they are") not being searched.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Everything the query was actually run against, so the footer's number
    /// means something. People and Places are in it only once Notion has
    /// answered — counting them while they are still arriving would overstate
    /// the search by exactly the amount the notice is warning about.
    private var searchedCount: Int {
        corpus.notes.count
            + documents.count
            + (notionService.peopleLoad == .loaded ? notionService.people.count : 0)
            + (notionService.placesLoad == .loaded ? notionService.places.count : 0)
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            // Click-off. A scrim rather than a modal sheet: this is a lookup, and
            // the window behind it is the context you are looking something up
            // *for*.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            panel
                .frame(width: 720)
                .padding(.top, 90)
        }
        .onExitCommand { close() }
        .onKeyPress(.downArrow) { move(1);  return .handled }
        .onKeyPress(.upArrow)   { move(-1); return .handled }
        // Fires on appear AND again when the container resolves. A panel opened
        // in the first second of a launch would otherwise hold an empty corpus
        // for the rest of its life. One modifier, not two — a plain `.task`
        // beside this one would load the whole container twice on every open.
        .task(id: noteStore.hasAccess) { await loadSources() }
        .task(id: query) { await runSearch() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            if let notice {
                Divider()
                noticeRow(notice)
            }
            if !query.isEmpty {
                Divider()
                content
            }
            Divider()
            footer
        }
        // **Opaque, not a material.** A material samples what is behind it, and
        // what is behind this is the scrim, so the translucent background pulled
        // the dimming *through* the panel and greyed the thing you are reading.
        // David, on first sight: *"the search window also goes gray so it is
        // hard to read."* The scrim is meant to dim the app, not the panel.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search notes, Satchel, people, places", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($fieldFocused)
                .onSubmit { activate() }
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onAppear { fieldFocused = true }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
            Text(text)
            Spacer(minLength: 0)
        }
        .font(MacType.meta)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    @ViewBuilder
    private var content: some View {
        if let preview {
            previewPane(preview)
        } else if results.isEmpty {
            HStack {
                Text("No matches for “\(query)”.")
                    .font(MacType.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            let shown = expanded.contains(group.kind)
                                ? group.items
                                : Array(group.items.prefix(MacSearchEngine.groupLimit))
                            ForEach(shown) { result in
                                row(result)
                                    .id(result.id)
                            }
                            if group.items.count > shown.count {
                                Button {
                                    expanded.insert(group.kind)
                                } label: {
                                    Text("\(group.items.count - shown.count) more")
                                        .font(MacType.meta)
                                        .foregroundStyle(Color.traceOrange)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: group.kind.icon)
                                Text(group.kind.label.uppercased())
                                    .tracking(MacType.labelTracking)
                                Text("\(group.items.count)")
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .font(MacType.label)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
            .onChange(of: selection) {
                guard visible.indices.contains(selection) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(visible[selection].id, anchor: .center)
                }
            }
        }
    }

    private func row(_ result: MacSearchResult) -> some View {
        let isSelected = visible.indices.contains(selection) && visible[selection].id == result.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                highlighted(result.title)
                    .font(MacType.rowEmphasis)
                    .lineLimit(1)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(MacType.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let snippet = result.snippet {
                    // The base colour is passed in rather than applied on the
                    // outside. Whether an outer `.foregroundStyle` on a
                    // concatenated `Text` beats the styles already baked into
                    // its runs is a rule I would be relying on rather than
                    // stating, and the failure would be silent: the highlight
                    // simply stops being orange.
                    highlighted(snippet, base: .secondary)
                        .font(MacType.meta)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            // Only on the selected row, and only when it says something the row
            // does not already: that Return will read this here rather than open
            // a screen. Session 69's whole cleanup was controls that promised
            // what they could not do.
            if isSelected, result.destination == .preview {
                Text("⏎ preview")
                    .font(MacType.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if let index = visible.firstIndex(where: { $0.id == result.id }) { selection = index }
            activate()
        }
    }

    /// The matched terms, bolded and tinted in place.
    ///
    /// Plain `String` ranges and concatenated `Text`, not `AttributedString`.
    /// The first version took index ranges out of an `AttributedSubstring` slice
    /// and then mutated the parent it was sliced from, which is only safe while
    /// nothing shifts and is a bad thing to be only-safe-while.
    private func highlighted(_ text: String, base: Color? = nil) -> Text {
        func plain(_ piece: Text) -> Text { base.map { piece.foregroundStyle($0) } ?? piece }
        let terms = MacSearchEngine.terms(in: query)
        guard !terms.isEmpty, !text.isEmpty else { return plain(Text(text)) }

        var marked = Array(repeating: false, count: text.count)
        for term in terms {
            var from = text.startIndex
            while let found = text.range(of: term, options: .caseInsensitive,
                                         range: from..<text.endIndex) {
                let lower = text.distance(from: text.startIndex, to: found.lowerBound)
                let upper = text.distance(from: text.startIndex, to: found.upperBound)
                for i in lower..<min(upper, marked.count) { marked[i] = true }
                guard found.upperBound < text.endIndex else { break }
                from = found.upperBound
            }
        }

        var out = Text("")
        var run = ""
        var runMarked = false
        func flush() {
            guard !run.isEmpty else { return }
            let piece = Text(run)
            out = out + (runMarked ? piece.bold().foregroundStyle(Color.traceOrange) : plain(piece))
            run = ""
        }
        for (i, character) in text.enumerated() {
            if marked[i] != runMarked { flush(); runMarked = marked[i] }
            run.append(character)
        }
        flush()
        return out
    }

    private func previewPane(_ result: MacSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    preview = nil
                } label: {
                    Image(systemName: "chevron.left")
                    Text("Results")
                }
                .buttonStyle(.plain)
                .font(MacType.meta)
                .foregroundStyle(Color.traceOrange)
                Spacer()
                Text(result.previewPath ?? "")
                    .font(MacType.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                Text(previewText.isEmpty ? "Empty note." : previewText)
                    .font(MacType.row)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: 420)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if query.isEmpty {
                Text("Titles and bodies. Nothing leaves this Mac.")
            } else {
                Text("\(results.count) \(results.count == 1 ? "match" : "matches") in \(searchedCount) records")
            }
            Spacer()
            Text("↑↓ move   ⏎ open   esc close")
        }
        .font(MacType.meta)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        preview = nil
        selection = min(max(0, selection + delta), visible.count - 1)
    }

    private func activate() {
        guard visible.indices.contains(selection) else { return }
        let result = visible[selection]
        if result.destination == .preview {
            previewText = result.previewPath.flatMap { try? noteStore.readFile($0) } ?? ""
            preview = result
            return
        }
        let text = query
        close()
        onOpen(result.destination, text)
    }

    private func close() {
        isPresented = false
    }

    // MARK: Loading

    private func loadSources() async {
        guard noteStore.hasAccess, let url = noteStore.containerURL else { return }
        // The walk reads every markdown file in the container — the same work
        // `findWikilinkMentions` detaches for, and for the same reason.
        let built = await Task.detached { MacSearchCorpus.build(containerURL: url) }.value
        corpus = built

        let store = TraceMacDocumentStore(noteStore: noteStore)
        await store.reload()
        documents = store.documents

        await runSearch(debounce: false)
    }

    private func runSearch(debounce: Bool = true) async {
        if debounce {
            // Enough to swallow a fast typist's inter-key gap, short enough that
            // the list feels like it is keeping up. `.task(id:)` cancels the
            // previous run, so an abandoned query never lands.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            selection = 0
            preview = nil
            return
        }
        results = MacSearchEngine.run(query: query,
                                      corpus: corpus,
                                      documents: documents,
                                      people: notionService.people,
                                      places: notionService.places)
        selection = 0
        expanded = []
        preview = nil
    }
}
